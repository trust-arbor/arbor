defmodule Arbor.Agent.CheckpointRaceTest do
  @moduledoc """
  Tests for checkpoint race conditions: concurrent save/load,
  async checkpoint conflicts, threshold boundary conditions,
  and schedule/cancel races.
  """
  use ExUnit.Case, async: false

  alias Arbor.Agent.CheckpointManager
  alias Arbor.Agent.Test.TestAgent

  @moduletag :fast

  # ============================================================================
  # Helpers
  # ============================================================================

  defp seed_state(overrides \\ %{}) do
    Map.merge(
      %{
        id: "race-seed-agent",
        memory_initialized: true,
        memory_enabled: true,
        working_memory: nil,
        recalled_memories: [],
        query_count: 10,
        heartbeat_count: 5,
        last_user_message_at: nil,
        last_assistant_output_at: nil,
        responded_to_last_user_message: true,
        context_window: nil,
        name: "Race Test Agent",
        last_checkpoint_query_count: 0,
        checkpoint_timer_ref: nil
      },
      overrides
    )
  end

  defp jido_state(overrides \\ %{}) do
    agent = TestAgent.new(%{id: "race-jido-agent", state: %{value: 42}})

    Map.merge(
      %{
        agent_id: "race-jido-agent",
        agent_module: TestAgent,
        jido_agent: agent,
        metadata: %{module: TestAgent, started_at: System.system_time(:millisecond)},
        checkpoint_storage: Arbor.Persistence.Checkpoint.Store.Agent,
        auto_checkpoint_interval: nil,
        checkpoint_timer: nil
      },
      overrides
    )
  end

  defp start_agent_store do
    case Arbor.Persistence.Checkpoint.Store.Agent.start_link() do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  # ============================================================================
  # Concurrent save operations
  # ============================================================================

  describe "concurrent checkpoint saves" do
    setup do
      pid = start_agent_store()

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      :ok
    end

    test "concurrent saves for different agents all succeed" do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            state = jido_state(%{agent_id: "concurrent-save-#{i}"})
            CheckpointManager.save_checkpoint(state)
          end)
        end

      results = Task.await_many(tasks, 5_000)

      for result <- results do
        assert result == :ok
      end
    end

    test "concurrent saves for the same agent do not corrupt data" do
      agent_id = "same-agent-save-#{System.unique_integer([:positive])}"

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            state =
              jido_state(%{
                agent_id: agent_id,
                metadata: %{
                  module: TestAgent,
                  started_at: System.system_time(:millisecond),
                  save_index: i
                }
              })

            CheckpointManager.save_checkpoint(state)
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # All saves should succeed (last writer wins is acceptable)
      for result <- results do
        assert result == :ok
      end

      # The stored checkpoint should be valid (from one of the saves)
      {:ok, loaded} =
        CheckpointManager.load_checkpoint(agent_id,
          store: Arbor.Persistence.Checkpoint.Store.Agent
        )

      assert loaded.agent_id == agent_id
      assert is_map(loaded)
    end

    test "async saves do not block the caller" do
      state = jido_state(%{agent_id: "async-nonblock-#{System.unique_integer([:positive])}"})

      start_time = System.monotonic_time(:millisecond)

      for _i <- 1..5 do
        CheckpointManager.save_checkpoint(state,
          store: Arbor.Persistence.Checkpoint.Store.Agent,
          async: true
        )
      end

      elapsed = System.monotonic_time(:millisecond) - start_time

      # Async saves should return near-instantly (well under 500ms for 5 calls)
      assert elapsed < 500, "Async saves took #{elapsed}ms, expected < 500ms"

      # Give tasks time to complete
      Process.sleep(200)
    end
  end

  # ============================================================================
  # Concurrent save and load
  # ============================================================================

  describe "concurrent save and load" do
    setup do
      pid = start_agent_store()

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      :ok
    end

    test "load during concurrent saves returns valid data or not_found" do
      agent_id = "save-load-race-#{System.unique_integer([:positive])}"

      # Start writers
      writer_tasks =
        for i <- 1..5 do
          Task.async(fn ->
            state =
              jido_state(%{
                agent_id: agent_id,
                metadata: %{
                  module: TestAgent,
                  started_at: System.system_time(:millisecond),
                  version: i
                }
              })

            CheckpointManager.save_checkpoint(state)
          end)
        end

      # Start readers concurrently
      reader_tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            CheckpointManager.load_checkpoint(agent_id,
              store: Arbor.Persistence.Checkpoint.Store.Agent,
              retries: 0
            )
          end)
        end

      writer_results = Task.await_many(writer_tasks, 5_000)
      reader_results = Task.await_many(reader_tasks, 5_000)

      # All writes should succeed
      for result <- writer_results do
        assert result == :ok
      end

      # Reads should return valid data or :not_found (never crash)
      for result <- reader_results do
        case result do
          {:ok, data} ->
            assert is_map(data)
            assert data.agent_id == agent_id

          {:error, :not_found} ->
            :ok

          {:error, reason} ->
            flunk("Unexpected error during concurrent read: #{inspect(reason)}")
        end
      end
    end
  end

  # ============================================================================
  # Threshold boundary conditions
  # ============================================================================

  describe "should_checkpoint? threshold boundary" do
    test "exactly at threshold returns true" do
      threshold = Application.get_env(:arbor_agent, :checkpoint_query_threshold, 5)
      state = seed_state(%{query_count: threshold, last_checkpoint_query_count: 0})
      assert CheckpointManager.should_checkpoint?(state)
    end

    test "one below threshold returns false" do
      threshold = Application.get_env(:arbor_agent, :checkpoint_query_threshold, 5)
      state = seed_state(%{query_count: threshold - 1, last_checkpoint_query_count: 0})
      refute CheckpointManager.should_checkpoint?(state)
    end

    test "at threshold with non-zero last_checkpoint_query_count" do
      threshold = Application.get_env(:arbor_agent, :checkpoint_query_threshold, 5)
      state = seed_state(%{query_count: 20, last_checkpoint_query_count: 20 - threshold})
      assert CheckpointManager.should_checkpoint?(state)
    end

    test "one below threshold with non-zero last_checkpoint_query_count" do
      threshold = Application.get_env(:arbor_agent, :checkpoint_query_threshold, 5)
      state = seed_state(%{query_count: 20, last_checkpoint_query_count: 20 - threshold + 1})
      refute CheckpointManager.should_checkpoint?(state)
    end

    test "zero query_count and zero last_checkpoint return false" do
      state = seed_state(%{query_count: 0, last_checkpoint_query_count: 0})
      refute CheckpointManager.should_checkpoint?(state)
    end
  end

  # ============================================================================
  # Schedule/cancel race conditions
  # ============================================================================

  describe "schedule/cancel race conditions" do
    test "scheduling multiple timers and canceling all prevents messages" do
      refs =
        for _i <- 1..10 do
          CheckpointManager.schedule_checkpoint(interval_ms: 200)
        end

      # Cancel all immediately
      for ref <- refs do
        CheckpointManager.cancel_checkpoint(ref)
      end

      # No checkpoint messages should arrive
      refute_receive :checkpoint, 400
    end

    test "canceling an already-fired timer is safe" do
      ref = CheckpointManager.schedule_checkpoint(interval_ms: 10)
      # Wait for the timer to fire
      assert_receive :checkpoint, 200

      # Canceling after fire should not crash
      assert :ok = CheckpointManager.cancel_checkpoint(ref)
    end

    test "concurrent schedule/cancel does not leak timers" do
      # Schedule and immediately cancel in parallel
      tasks =
        for _i <- 1..20 do
          Task.async(fn ->
            ref = CheckpointManager.schedule_checkpoint(interval_ms: 5_000)
            CheckpointManager.cancel_checkpoint(ref)
            :ok
          end)
        end

      results = Task.await_many(tasks, 5_000)

      for result <- results do
        assert result == :ok
      end

      # No lingering checkpoint messages should arrive
      refute_receive :checkpoint, 200
    end
  end

  # ============================================================================
  # Apply checkpoint with edge-case data
  # ============================================================================

  describe "apply_checkpoint edge cases" do
    test "apply_checkpoint with empty map for unknown type returns original state" do
      state = %{some: :random, data: true}
      result = CheckpointManager.apply_checkpoint(state, %{})
      assert result == state
    end

    test "apply_checkpoint for jido with missing jido_state key" do
      state = jido_state()
      # Checkpoint data without jido_state key
      checkpoint_data = %{metadata: %{module: TestAgent}}
      restored = CheckpointManager.apply_checkpoint(state, checkpoint_data)

      # Should still restore (with empty jido_state)
      assert is_map(restored)
    end

    test "apply_checkpoint for seed with string vs atom metadata keys" do
      state = seed_state()
      now_str = DateTime.utc_now() |> DateTime.to_iso8601()

      # Use string keys (as would come from JSON deserialization)
      checkpoint_data = %{
        "id" => "string-keys-test",
        "agent_id" => "race-seed-agent",
        "seed_version" => 1,
        "version" => 1,
        "metadata" => %{
          "query_count" => 77,
          "last_user_message_at" => now_str,
          "responded_to_last_user_message" => false
        },
        "goals" => [],
        "recent_intents" => [],
        "recent_percepts" => []
      }

      restored = CheckpointManager.apply_checkpoint(state, checkpoint_data)
      assert restored.query_count == 77
      assert restored.responded_to_last_user_message == false
    end

    test "apply_checkpoint for seed with atom keys in metadata" do
      state = seed_state()
      now_str = DateTime.utc_now() |> DateTime.to_iso8601()

      # Use atom keys
      checkpoint_data = %{
        "id" => "atom-keys-test",
        "agent_id" => "race-seed-agent",
        "seed_version" => 1,
        "version" => 1,
        "metadata" => %{
          query_count: 88,
          last_user_message_at: now_str,
          responded_to_last_user_message: true
        },
        "goals" => [],
        "recent_intents" => [],
        "recent_percepts" => []
      }

      restored = CheckpointManager.apply_checkpoint(state, checkpoint_data)
      assert restored.query_count == 88
    end
  end

  # ============================================================================
  # Config override precedence
  # ============================================================================

  describe "config precedence" do
    test "per-agent opts override application config" do
      custom_store = Arbor.Persistence.Checkpoint.Store.Agent

      config =
        CheckpointManager.config(store: custom_store, interval_ms: 1234, query_threshold: 99)

      assert config.store == custom_store
      assert config.interval_ms == 1234
      assert config.query_threshold == 99
    end

    test "application defaults used when no per-agent opts" do
      config = CheckpointManager.config()
      assert config.store == Arbor.Persistence.Checkpoint.Store.ETS
      assert config.interval_ms == 300_000
      assert config.query_threshold == 5
      assert config.enabled == true
    end
  end
end
