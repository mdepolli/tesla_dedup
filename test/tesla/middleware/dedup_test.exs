defmodule Tesla.Middleware.DedupTest do
  use ExUnit.Case, async: true
  alias TeslaDedup.Server

  setup do
    :ok
  end

  describe "Server.hash/3" do
    test "generates consistent hash for same inputs" do
      hash1 = Server.hash(:post, "https://api.com/charge", ~s({"amount": 100}))
      hash2 = Server.hash(:post, "https://api.com/charge", ~s({"amount": 100}))

      assert hash1 == hash2
      assert is_binary(hash1)
      # SHA256 hex = 64 chars
      assert String.length(hash1) == 64
    end

    test "generates different hash for different methods" do
      hash1 = Server.hash(:post, "https://api.com/charge", ~s({"amount": 100}))
      hash2 = Server.hash(:put, "https://api.com/charge", ~s({"amount": 100}))

      assert hash1 != hash2
    end

    test "generates different hash for different URLs" do
      hash1 = Server.hash(:post, "https://api.com/charge", ~s({"amount": 100}))
      hash2 = Server.hash(:post, "https://api.com/refund", ~s({"amount": 100}))

      assert hash1 != hash2
    end

    test "generates different hash for different bodies" do
      hash1 = Server.hash(:post, "https://api.com/charge", ~s({"amount": 100}))
      hash2 = Server.hash(:post, "https://api.com/charge", ~s({"amount": 200}))

      assert hash1 != hash2
    end

    test "handles nil body" do
      hash1 = Server.hash(:get, "https://api.com/users", nil)
      hash2 = Server.hash(:get, "https://api.com/users", nil)

      assert hash1 == hash2
      assert is_binary(hash1)
    end

    test "nil vs empty string body are treated the same" do
      hash1 = Server.hash(:get, "https://api.com/users", nil)
      hash2 = Server.hash(:get, "https://api.com/users", "")

      assert hash1 == hash2
    end
  end

  describe "Server.deduplicate/1 - first request" do
    test "returns :execute for first occurrence of request" do
      hash = Server.hash(:post, "https://api.com/test1", "data")

      assert {:ok, :execute} = Server.deduplicate(hash)
    end
  end

  describe "Server.deduplicate/1 - duplicate requests" do
    test "returns :wait with ref for duplicate in-flight request" do
      hash = Server.hash(:post, "https://api.com/test4", "data")

      # First request
      assert {:ok, :execute} = Server.deduplicate(hash)

      # Duplicate request while first is in-flight
      assert {:ok, :wait, ref} = Server.deduplicate(hash)
      assert is_reference(ref)
    end

    test "multiple duplicates all get same ref" do
      hash = Server.hash(:post, "https://api.com/test5", "data")

      # First request
      assert {:ok, :execute} = Server.deduplicate(hash)

      # Multiple duplicates
      assert {:ok, :wait, ref1} = Server.deduplicate(hash)
      assert {:ok, :wait, ref2} = Server.deduplicate(hash)
      assert {:ok, :wait, ref3} = Server.deduplicate(hash)

      assert ref1 == ref2
      assert ref2 == ref3
    end
  end

  describe "Server.complete/2 - response sharing" do
    test "notifies waiting requests when first request completes" do
      hash = Server.hash(:post, "https://api.com/test6", "data")

      # First request
      assert {:ok, :execute} = Server.deduplicate(hash)

      # Spawn duplicate requests that will wait
      task1 =
        Task.async(fn ->
          {:ok, :wait, ref} = Server.deduplicate(hash)

          receive do
            {:dedup_response, ^ref, result} -> result
          after
            5_000 -> :timeout
          end
        end)

      task2 =
        Task.async(fn ->
          {:ok, :wait, ref} = Server.deduplicate(hash)

          receive do
            {:dedup_response, ^ref, result} -> result
          after
            5_000 -> :timeout
          end
        end)

      # Give tasks time to register
      Process.sleep(10)

      # Complete the first request
      result = {:ok, %Tesla.Env{status: 200, body: "success"}}
      Server.complete(hash, result)

      # Both waiting requests should receive the response
      assert Task.await(task1) == result
      assert Task.await(task2) == result
    end

    test "marks request as completed after notification" do
      hash = Server.hash(:post, "https://api.com/test7", "data")

      # First request
      assert {:ok, :execute} = Server.deduplicate(hash)

      # Complete it
      result = {:ok, %Tesla.Env{status: 200, body: "success"}}
      Server.complete(hash, result)

      # Small delay for state update
      Process.sleep(10)

      # New request should get cached response
      assert {:ok, ^result} = Server.deduplicate(hash)
    end

    test "handles error results correctly" do
      hash = Server.hash(:post, "https://api.com/test_error", "data")

      # First request
      assert {:ok, :execute} = Server.deduplicate(hash)

      # Spawn waiter
      task =
        Task.async(fn ->
          {:ok, :wait, ref} = Server.deduplicate(hash)

          receive do
            {:dedup_response, ^ref, result} -> result
          after
            5_000 -> :timeout
          end
        end)

      Process.sleep(10)

      # Complete with error
      error_result = {:error, :timeout}
      Server.complete(hash, error_result)

      # Waiter should receive the error
      assert Task.await(task) == error_result
    end
  end

  describe "Server.cancel/1" do
    test "removes in-flight request on error" do
      hash = Server.hash(:post, "https://api.com/test8", "data")

      # First request
      assert {:ok, :execute} = Server.deduplicate(hash)

      # Cancel it (simulating error)
      Server.cancel(hash)

      # Small delay for state update
      Process.sleep(10)

      # New request should be treated as first request
      assert {:ok, :execute} = Server.deduplicate(hash)
    end
  end

  describe "cleanup" do
    test "removes completed requests after TTL" do
      hash = Server.hash(:post, "https://api.com/test9", "data")

      # Complete a request
      assert {:ok, :execute} = Server.deduplicate(hash)
      result = {:ok, %Tesla.Env{status: 200, body: "success"}}
      Server.complete(hash, result)

      # Should return cached response immediately
      Process.sleep(10)
      assert {:ok, ^result} = Server.deduplicate(hash)

      # Wait for cleanup (completed_ttl is 500ms, cleanup runs every 1s)
      Process.sleep(1_600)

      # Should be cleaned up - new request starts fresh
      assert {:ok, :execute} = Server.deduplicate(hash)
    end
  end

  describe "concurrent requests" do
    test "handles high concurrency correctly" do
      hash = Server.hash(:post, "https://api.com/test12", "data")

      # Spawn many concurrent duplicate requests
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            case Server.deduplicate(hash) do
              {:ok, :execute} ->
                # Stay alive until signaled so owner doesn't die mid-test
                receive do
                  :complete -> {:execute, i}
                after
                  5_000 -> {:execute_timeout, i}
                end

              {:ok, :wait, ref} ->
                receive do
                  {:dedup_response, ^ref, result} -> {:waited, i, result}
                  {:dedup_error, ^ref, reason} -> {:error, i, reason}
                after
                  5_000 -> {:timeout, i}
                end

              {:ok, result} ->
                {:cached, i, result}
            end
          end)
        end

      # Small delay to let all tasks start
      Process.sleep(50)

      # Complete the request
      result = {:ok, %Tesla.Env{status: 200, body: "concurrent success"}}
      Server.complete(hash, result)

      # Signal the executor to finish
      Enum.each(tasks, fn task -> send(task.pid, :complete) end)

      # Collect results
      results = Task.await_many(tasks, 5_000)

      executes = Enum.filter(results, fn result -> elem(result, 0) == :execute end)

      # Should have exactly one executor
      assert length(executes) == 1
    end
  end

  describe "crash recovery" do
    test "GenServer crash doesn't orphan ETS table" do
      hash = Server.hash(:post, "https://api.com/crash-test", "data")

      # Use deduplicator
      assert {:ok, :execute} = Server.deduplicate(hash)

      # Get GenServer pid and kill it
      pid = Process.whereis(TeslaDedup.Server)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      # Wait for process to die
      receive do
        {:DOWN, ^ref, :process, ^pid, :killed} -> :ok
      after
        1_000 -> flunk("GenServer didn't die")
      end

      # Wait for supervisor to restart
      :timer.sleep(100)

      # Should be able to use deduplicator again (new ETS table created)
      hash2 = Server.hash(:post, "https://api.com/crash-test2", "data")
      assert {:ok, :execute} = Server.deduplicate(hash2)

      # New GenServer should be running
      new_pid = Process.whereis(TeslaDedup.Server)
      assert new_pid != nil
      assert new_pid != pid
    end

    test "waiter process death removes it from waiter list" do
      hash = Server.hash(:post, "https://api.com/waiter-death-test", "data")

      # First request
      assert {:ok, :execute} = Server.deduplicate(hash)

      # Spawn a waiter process that will die immediately
      waiter_pid =
        spawn(fn ->
          {:ok, :wait, _ref} = Server.deduplicate(hash)
          # Process exits immediately without waiting for response
        end)

      # Give the waiter time to register
      Process.sleep(50)

      # Waiter should be dead by now
      refute Process.alive?(waiter_pid)

      # Wait a bit more for DOWN message to be processed
      Process.sleep(50)

      # Complete the request
      result = {:ok, %Tesla.Env{status: 200, body: "success"}}
      Server.complete(hash, result)

      # The test passes if no error occurs when trying to send to dead process
      :ok
    end

    test "waiter timeout doesn't cause memory leak" do
      hash = Server.hash(:post, "https://api.com/timeout-test", "data")

      # First request
      assert {:ok, :execute} = Server.deduplicate(hash)

      # Spawn waiters that will timeout
      waiter_pids =
        for i <- 1..10 do
          spawn(fn ->
            {:ok, :wait, ref} = Server.deduplicate(hash)

            # Simulate timeout - give up waiting after 100ms
            receive do
              {:dedup_response, ^ref, _result} -> :ok
            after
              100 -> {:timeout, i}
            end
          end)
        end

      # Wait for all waiters to timeout and die
      Process.sleep(200)

      # All waiters should be dead
      Enum.each(waiter_pids, fn pid ->
        refute Process.alive?(pid)
      end)

      # Wait for DOWN messages to be processed
      Process.sleep(50)

      # Complete the request - should not try to send to dead processes
      result = {:ok, %Tesla.Env{status: 200, body: "success"}}
      Server.complete(hash, result)

      # Test passes if no errors occurred
      :ok
    end
  end

  describe "multi-hash per process" do
    test "same process can deduplicate two different hashes without leaking" do
      hash1 = Server.hash(:post, "https://api.com/multi-hash-1", "data1")
      hash2 = Server.hash(:post, "https://api.com/multi-hash-2", "data2")

      # Same process starts two different dedup hashes
      assert {:ok, :execute} = Server.deduplicate(hash1)
      assert {:ok, :execute} = Server.deduplicate(hash2)

      # Complete the first hash
      result1 = {:ok, %Tesla.Env{status: 200, body: "response1"}}
      Server.complete(hash1, result1)

      # Second hash should still be in-flight (not leaked)
      waiter_task =
        Task.async(fn ->
          case Server.deduplicate(hash2) do
            {:ok, :wait, ref} ->
              receive do
                {:dedup_response, ^ref, result} -> {:waited, result}
              after
                2_000 -> :timeout
              end

            {:ok, :execute} ->
              :leaked
          end
        end)

      Process.sleep(20)

      result2 = {:ok, %Tesla.Env{status: 200, body: "response2"}}
      Server.complete(hash2, result2)

      result = Task.await(waiter_task, 2_000)
      assert {:waited, ^result2} = result
    end

    test "process death cleans up all tracked hashes" do
      hash1 = Server.hash(:post, "https://api.com/multi-death-1", "data1")
      hash2 = Server.hash(:post, "https://api.com/multi-death-2", "data2")

      {pid, ref} =
        spawn_monitor(fn ->
          {:ok, :execute} = Server.deduplicate(hash1)
          {:ok, :execute} = Server.deduplicate(hash2)
        end)

      receive do
        {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
      after
        1_000 -> flunk("Process didn't die")
      end

      Process.sleep(50)

      assert {:ok, :execute} = Server.deduplicate(hash1)
      assert {:ok, :execute} = Server.deduplicate(hash2)
    end

    test "process that is owner of one hash and waiter on another cleans up both on death" do
      hash_owned = Server.hash(:post, "https://api.com/multi-role-owned", "data")
      hash_waited = Server.hash(:post, "https://api.com/multi-role-waited", "data")

      # Start the first hash from another process (so our spawned process will be a waiter)
      owner_task =
        Task.async(fn ->
          {:ok, :execute} = Server.deduplicate(hash_waited)

          receive do
            :complete -> :ok
          end
        end)

      Process.sleep(20)

      # Spawn a process that owns hash_owned and waits on hash_waited, then dies
      {pid, ref} =
        spawn_monitor(fn ->
          {:ok, :execute} = Server.deduplicate(hash_owned)
          {:ok, :wait, _ref} = Server.deduplicate(hash_waited)
        end)

      receive do
        {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
      after
        1_000 -> flunk("Process didn't die")
      end

      Process.sleep(50)

      # hash_owned should have been cleaned up (owner died)
      assert {:ok, :execute} = Server.deduplicate(hash_owned)

      # hash_waited should still be in-flight (the original owner_task is alive)
      waiter_task =
        Task.async(fn ->
          case Server.deduplicate(hash_waited) do
            {:ok, :wait, _ref} -> :still_in_flight
            {:ok, :execute} -> :was_cleaned_up
          end
        end)

      result = Task.await(waiter_task, 2_000)
      assert result == :still_in_flight

      # Clean up
      send(owner_task.pid, :complete)
      Task.await(owner_task, 1_000)
      Server.complete(hash_waited, {:ok, %Tesla.Env{status: 200}})
    end
  end

  describe "Tesla middleware integration" do
    defmodule TestClient do
      use Tesla

      plug(Tesla.Middleware.Dedup)
      adapter(Tesla.Mock)
    end

    test "prevents duplicate concurrent POST requests" do
      # Setup mock adapter
      Tesla.Mock.mock(fn env ->
        # Simulate slow request
        Process.sleep(100)
        {:ok, %{env | status: 201, body: "created"}}
      end)

      # Spawn concurrent identical requests
      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            TestClient.post("/orders", %{item: "widget", amount: 100})
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # All should succeed with same response
      assert Enum.all?(results, fn {:ok, env} ->
               env.status == 201 && env.body == "created"
             end)
    end

    test "handles errors correctly" do
      Tesla.Mock.mock(fn _env ->
        {:error, :timeout}
      end)

      tasks =
        for _ <- 1..3 do
          Task.async(fn ->
            TestClient.post("/failing", %{data: "test"})
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # All should receive the same error
      assert Enum.all?(results, &match?({:error, :timeout}, &1))
    end
  end

  describe "custom key function" do
    defmodule CustomKeyClient do
      use Tesla

      # Only deduplicate based on URL, ignore body
      plug(Tesla.Middleware.Dedup,
        key_fn: fn env -> env.url end
      )

      adapter(Tesla.Mock)
    end

    test "uses custom key function for deduplication" do
      call_count = Agent.start_link(fn -> 0 end)
      {:ok, agent} = call_count

      Tesla.Mock.mock(fn env ->
        Agent.update(agent, &(&1 + 1))
        Process.sleep(50)
        {:ok, %{env | status: 200, body: "ok"}}
      end)

      # These requests have same URL but different bodies
      # With custom key_fn, they should deduplicate
      tasks = [
        Task.async(fn -> CustomKeyClient.post("/api", %{id: 1}) end),
        Task.async(fn -> CustomKeyClient.post("/api", %{id: 2}) end),
        Task.async(fn -> CustomKeyClient.post("/api", %{id: 3}) end)
      ]

      Task.await_many(tasks, 5_000)

      # Should only execute once due to custom key function
      assert Agent.get(agent, & &1) == 1
    end
  end

  describe "telemetry events" do
    setup do
      # Attach telemetry handler
      ref = make_ref()
      test_pid = self()

      events = [
        [:tesla_dedup, :execute],
        [:tesla_dedup, :wait],
        [:tesla_dedup, :cache_hit]
      ]

      :telemetry.attach_many(
        ref,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(ref) end)

      %{ref: ref}
    end

    test "emits execute event for first request" do
      defmodule TelemetryClient1 do
        use Tesla
        plug(Tesla.Middleware.Dedup)
        adapter(Tesla.Mock)
      end

      Tesla.Mock.mock(fn env ->
        {:ok, %{env | status: 200, body: "ok"}}
      end)

      TelemetryClient1.get("/test")

      assert_received {:telemetry, [:tesla_dedup, :execute], _measurements, metadata}
      assert metadata.dedup_key
      assert metadata.method == :get
      assert metadata.url
    end

    test "emits wait event for duplicate request" do
      defmodule TelemetryClient2 do
        use Tesla
        plug(Tesla.Middleware.Dedup)
        adapter(Tesla.Mock)
      end

      Tesla.Mock.mock(fn env ->
        Process.sleep(100)
        {:ok, %{env | status: 200, body: "ok"}}
      end)

      # Start two concurrent requests
      task1 = Task.async(fn -> TelemetryClient2.post("/charge", %{amount: 100}) end)
      Process.sleep(10)
      task2 = Task.async(fn -> TelemetryClient2.post("/charge", %{amount: 100}) end)

      Task.await_many([task1, task2], 5_000)

      assert_received {:telemetry, [:tesla_dedup, :execute], _, _}
      assert_received {:telemetry, [:tesla_dedup, :wait], _, _}
    end
  end
end
