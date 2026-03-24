defmodule TeslaDedup.Server do
  @moduledoc """
  GenServer managing in-flight request deduplication state.

  Maintains an ETS table tracking concurrent identical requests and coordinates
  response sharing to prevent duplicate operations.
  """

  use GenServer
  require Logger

  @completed_ttl 500

  # Client API

  @doc """
  Starts the deduplication server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attempts to deduplicate a request.

  Returns:
  - `{:ok, :execute}` - First occurrence, proceed with execution
  - `{:ok, :wait, ref}` - Duplicate request, wait for in-flight to complete
  - `{:ok, env}` - Request just completed, return cached response
  """
  @spec deduplicate(String.t()) ::
          {:ok, :execute} | {:ok, :wait, reference()} | {:ok, any()}
  def deduplicate(request_hash) do
    GenServer.call(__MODULE__, {:deduplicate, request_hash, self()})
  end

  @doc """
  Completes a request, storing the response/error and notifying waiters.
  """
  @spec complete(String.t(), {:ok, any()} | {:error, any()}) :: :ok
  def complete(request_hash, result) do
    GenServer.cast(__MODULE__, {:complete, request_hash, result})
  end

  @doc """
  Cancels an in-flight request (called on error/timeout).
  """
  @spec cancel(String.t()) :: :ok
  def cancel(request_hash) do
    GenServer.cast(__MODULE__, {:cancel, request_hash})
  end

  @doc """
  Generates a deduplication hash from request parameters.
  """
  @spec hash(atom(), String.t(), String.t() | nil) :: String.t()
  def hash(method, url, body) do
    content = "#{method}:#{url}:#{body || ""}"
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # ETS table for tracking requests
    # Format: {hash, state, ref, timestamp}
    # States: {:in_flight, [waiter_pids], owner_pid} | {:completed, result}
    # heir: :none ensures table dies with process (prevents orphaning on crash)
    # read/write_concurrency improves performance under high concurrent load
    table =
      :ets.new(__MODULE__, [
        :set,
        :public,
        :named_table,
        {:read_concurrency, true},
        {:write_concurrency, true},
        {:heir, :none}
      ])

    # Schedule periodic cleanup
    schedule_cleanup()

    # pid_to_hashes: reverse index for O(1) lookup on process death
    #   %{pid => MapSet.t(hash)} — supports multiple concurrent hashes per PID
    # monitors: %{pid => monitor_ref} for cleanup (one monitor per PID)
    {:ok, %{table: table, pid_to_hashes: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:deduplicate, hash, caller_pid}, _from, state) do
    case :ets.lookup(state.table, hash) do
      [] ->
        ref = make_ref()
        :ets.insert(state.table, {hash, {:in_flight, [], caller_pid}, ref, timestamp()})
        {:reply, {:ok, :execute}, monitor_pid(state, caller_pid, hash)}

      [{^hash, {:in_flight, waiters, owner}, ref, _ts}] ->
        :ets.update_element(state.table, hash, {2, {:in_flight, [caller_pid | waiters], owner}})
        {:reply, {:ok, :wait, ref}, monitor_pid(state, caller_pid, hash)}

      [{^hash, {:completed, result}, _ref, _ts}] ->
        {:reply, {:ok, result}, state}
    end
  end

  @impl true
  def handle_cast({:complete, hash, result}, state) do
    case :ets.lookup(state.table, hash) do
      [{^hash, {:in_flight, waiters, owner}, ref, _ts}] ->
        Enum.each(waiters, fn pid ->
          send(pid, {:dedup_response, ref, result})
        end)

        # Mark as completed with short TTL for race conditions
        :ets.insert(state.table, {hash, {:completed, result}, ref, timestamp()})

        # Clean up monitors for all participants of this hash
        {:noreply, demonitor_pids(state, [owner | waiters], hash)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:cancel, hash}, state) do
    case :ets.lookup(state.table, hash) do
      [{^hash, {:in_flight, _waiters, _owner}, _ref, _ts}] ->
        {:noreply, abort_in_flight(state, hash, :request_cancelled)}

      _ ->
        :ets.delete(state.table, hash)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _mon_ref, :process, pid, _reason}, state) do
    {hashes, pid_to_hashes} = Map.pop(state.pid_to_hashes, pid, MapSet.new())
    {_mon_ref, monitors} = Map.pop(state.monitors, pid)
    state = %{state | pid_to_hashes: pid_to_hashes, monitors: monitors}

    state =
      Enum.reduce(hashes, state, fn hash, acc ->
        case :ets.lookup(acc.table, hash) do
          [{^hash, {:in_flight, _waiters, ^pid}, _ref, _ts}] ->
            # Original requester died — notify all waiters and clean up
            abort_in_flight(acc, hash, :requester_down)

          [{^hash, {:in_flight, waiters, owner}, ref, ts}] ->
            # A waiter died — remove from waiter list
            new_waiters = List.delete(waiters, pid)
            :ets.insert(acc.table, {hash, {:in_flight, new_waiters, owner}, ref, ts})
            acc

          _ ->
            acc
        end
      end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = timestamp()
    completed_cutoff = now - @completed_ttl

    :ets.select_delete(state.table, [
      {
        {:"$1", {:completed, :"$2"}, :"$3", :"$4"},
        [{:<, :"$4", completed_cutoff}],
        [true]
      }
    ])

    schedule_cleanup()

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp abort_in_flight(state, hash, reason) do
    [{^hash, {:in_flight, waiters, owner}, ref, _ts}] = :ets.lookup(state.table, hash)

    Enum.each(waiters, fn pid ->
      send(pid, {:dedup_error, ref, reason})
    end)

    :telemetry.execute(
      [:tesla_dedup, :abort],
      %{waiter_count: length(waiters)},
      %{dedup_key: hash, reason: reason}
    )

    :ets.delete(state.table, hash)
    demonitor_pids(state, [owner | waiters], hash)
  end

  defp monitor_pid(state, pid, hash) do
    hashes = Map.get(state.pid_to_hashes, pid, MapSet.new())
    state = put_in(state, [:pid_to_hashes, pid], MapSet.put(hashes, hash))

    if Map.has_key?(state.monitors, pid) do
      state
    else
      mon_ref = Process.monitor(pid)
      put_in(state, [:monitors, pid], mon_ref)
    end
  end

  defp demonitor_pids(state, pids, hash) do
    Enum.reduce(pids, state, fn pid, acc ->
      case Map.get(acc.pid_to_hashes, pid) do
        nil ->
          acc

        hashes ->
          remaining = MapSet.delete(hashes, hash)

          if Enum.empty?(remaining) do
            {mon_ref, monitors} = Map.pop(acc.monitors, pid)
            if mon_ref, do: Process.demonitor(mon_ref, [:flush])
            %{acc | monitors: monitors, pid_to_hashes: Map.delete(acc.pid_to_hashes, pid)}
          else
            put_in(acc, [:pid_to_hashes, pid], remaining)
          end
      end
    end)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, 1_000)
  end

  defp timestamp do
    System.monotonic_time(:millisecond)
  end
end
