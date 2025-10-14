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
    GenServer.call(__MODULE__, {:deduplicate, request_hash, self()}, :infinity)
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
    # Format: {hash, state, data, timestamp}
    # States: {:in_flight, [waiters]} | {:completed, result}
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

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:deduplicate, hash, caller_pid}, _from, state) do
    case :ets.lookup(state.table, hash) do
      [] ->
        ref = make_ref()
        :ets.insert(state.table, {hash, {:in_flight, []}, ref, timestamp()})
        {:reply, {:ok, :execute}, state}

      [{^hash, {:in_flight, waiters}, ref, _ts}] ->
        # Monitor the waiter to detect if it dies/times out
        Process.monitor(caller_pid)
        :ets.update_element(state.table, hash, {2, {:in_flight, [caller_pid | waiters]}})
        {:reply, {:ok, :wait, ref}, state}

      [{^hash, {:completed, result}, _ref, _ts}] ->
        {:reply, {:ok, result}, state}
    end
  end

  @impl true
  def handle_cast({:complete, hash, result}, state) do
    case :ets.lookup(state.table, hash) do
      [{^hash, {:in_flight, waiters}, ref, _ts}] ->
        Enum.each(waiters, fn pid ->
          send(pid, {:dedup_response, ref, result})
        end)

        # Mark as completed with short TTL for race conditions
        :ets.insert(state.table, {hash, {:completed, result}, ref, timestamp()})

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:cancel, hash}, state) do
    :ets.delete(state.table, hash)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # This prevents memory leaks when waiters timeout or crash
    :ets.foldl(
      fn
        {hash, {:in_flight, waiters}, ref, ts}, acc ->
          new_waiters = List.delete(waiters, pid)

          if new_waiters != waiters do
            :ets.insert(state.table, {hash, {:in_flight, new_waiters}, ref, ts})
          end

          acc

        _other, acc ->
          acc
      end,
      nil,
      state.table
    )

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

  # Private Functions

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, 1_000)
  end

  defp timestamp do
    System.monotonic_time(:millisecond)
  end
end
