defmodule Arbor.Agent.CheckpointManagerTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.CheckpointManager
  alias Arbor.Agent.Seed
  alias Arbor.Agent.Test.TestAgent

  @moduletag :fast

  # ============================================================================
  # Helpers
  # ============================================================================

  defp seed_state(overrides \\ %{}) do
    Map.merge(
      %{
        id: "test-seed-agent",
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
        name: "Test Seed Agent",
        last_checkpoint_query_count: 0,
        checkpoint_timer_ref: nil
      },
      overrides
    )
  end

  defp jido_state(overrides \\ %{}) do
    agent = TestAgent.new(%{id: "test-jido-agent", state: %{value: 42}})

    Map.merge(
      %{
        agent_id: "test-jido-agent",
        agent_module: TestAgent,
        jido_agent: agent,
        metadata: %{module: TestAgent, started_at: System.system_time(:millisecond)},
        checkpoint_storage: Arbor.Checkpoint.Store.Agent,
        auto_checkpoint_interval: nil,
        checkpoint_timer: nil
      },
      overrides
    )
  end

  defp start_agent_store do
    case Arbor.Checkpoint.Store.Agent.start_link() do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  # ============================================================================
  # agent_type detection (via public API)
  # ============================================================================

  describe "agent type detection" do
    test "should_checkpoint?/1 identifies seed agents" do
      state = seed_state(%{query_count: 10, last_checkpoint_query_count: 0})
      assert CheckpointManager.should_checkpoint?(state)
    end

    test "should_checkpoint?/1 identifies jido agents as always true" do
      state = jido_state()
      assert CheckpointManager.should_checkpoint?(state)
    end

    test "should_checkpoint?/1 returns true for unknown agents" do
      assert CheckpointManager.should_checkpoint?(%{some: :state})
    end
  end

  # ============================================================================
  # save_checkpoint/2 for seed agents
  # ============================================================================

  describe "save_checkpoint/2 for seed agents" do
    setup do
      pid = start_agent_store()

      on_exit(fn ->
        if Process.alive?(pid), do: Arbor.Checkpoint.Store.Agent.stop()
      end)

      :ok
    end

    test "saves seed agent state to store" do
      state = seed_state()
      result = CheckpointManager.save_checkpoint(state, store: Arbor.Checkpoint.Store.Agent)

      assert result == :ok
    end

    test "handles missing subsystems gracefully" do
      state = seed_state(%{context_window: nil, working_memory: nil})
      result = CheckpointManager.save_checkpoint(state, store: Arbor.Checkpoint.Store.Agent)

      assert result == :ok
    end

    test "async mode wraps in Task" do
      state = seed_state()

      result =
        CheckpointManager.save_checkpoint(state,
          store: Arbor.Checkpoint.Store.Agent,
          async: true
        )

      assert result == :ok
      # Give the task time to complete
      Process.sleep(100)
    end
  end

  # ============================================================================
  # save_checkpoint/2 for jido agents
  # ============================================================================

  describe "save_checkpoint/2 for jido agents" do
    setup do
      pid = start_agent_store()

      on_exit(fn ->
        if Process.alive?(pid), do: Arbor.Checkpoint.Store.Agent.stop()
      end)

      :ok
    end

    test "saves jido agent state to store" do
      state = jido_state()
      result = CheckpointManager.save_checkpoint(state)

      assert result == :ok
    end

    test "handles nil checkpoint_storage gracefully" do
      state = jido_state(%{checkpoint_storage: nil})
      result = CheckpointManager.save_checkpoint(state)

      assert result == :ok
    end
  end

  # ============================================================================
  # load_checkpoint/2
  # ============================================================================

  describe "load_checkpoint/2" do
    setup do
      pid = start_agent_store()

      on_exit(fn ->
        if Process.alive?(pid), do: Arbor.Checkpoint.Store.Agent.stop()
      end)

      :ok
    end

    test "loads from configured store" do
      # Save something first
      data = %{agent_id: "load-test", version: 1}
      :ok = Arbor.Checkpoint.save("load-test", data, Arbor.Checkpoint.Store.Agent)

      assert {:ok, loaded} =
               CheckpointManager.load_checkpoint("load-test",
                 store: Arbor.Checkpoint.Store.Agent
               )

      assert loaded.agent_id == "load-test"
    end

    test "returns {:error, :not_found} when missing" do
      assert {:error, :not_found} =
               CheckpointManager.load_checkpoint("nonexistent",
                 store: Arbor.Checkpoint.Store.Agent,
                 retries: 0
               )
    end
  end

  # ============================================================================
  # apply_checkpoint/2 for jido agents
  # ============================================================================

  describe "apply_checkpoint/2 for jido agents" do
    test "recreates Jido agent from checkpointed state" do
      state = jido_state()

      checkpoint_data = %{
        jido_state: %{value: 99},
        metadata: %{module: TestAgent}
      }

      restored = CheckpointManager.apply_checkpoint(state, checkpoint_data)

      assert Map.has_key?(restored.metadata, :restored_at)
      assert is_integer(restored.metadata.restored_at)
    end
  end

  # ============================================================================
  # apply_checkpoint/2 for seed agents
  # ============================================================================

  describe "apply_checkpoint/2 for seed agents" do
    test "extracts timing from metadata" do
      state = seed_state()
      now_str = DateTime.utc_now() |> DateTime.to_iso8601()

      # Build a checkpoint map that Seed.from_map can parse
      checkpoint_data = %{
        "id" => "seed_test",
        "agent_id" => "test-seed-agent",
        "seed_version" => 1,
        "version" => 1,
        "metadata" => %{
          "query_count" => 42,
          "last_user_message_at" => now_str,
          "responded_to_last_user_message" => false
        },
        "goals" => [],
        "recent_intents" => [],
        "recent_percepts" => []
      }

      restored = CheckpointManager.apply_checkpoint(state, checkpoint_data)

      assert restored.query_count == 42
      assert restored.responded_to_last_user_message == false
    end

    test "handles corrupt data gracefully" do
      state = seed_state()

      # This will fail Seed.from_map since it's not a valid map
      restored = CheckpointManager.apply_checkpoint(state, %{"invalid" => true})

      # Should return original state since from_map won't find agent_id
      assert is_map(restored)
    end
  end

  # ============================================================================
  # schedule_checkpoint/1
  # ============================================================================

  describe "schedule_checkpoint/1" do
    test "sends :checkpoint after interval" do
      ref = CheckpointManager.schedule_checkpoint(interval_ms: 50)
      assert is_reference(ref)

      assert_receive :checkpoint, 200
    end

    test "uses configured interval_ms" do
      ref = CheckpointManager.schedule_checkpoint(interval_ms: 100)
      assert is_reference(ref)

      # Cancel to avoid leftover messages
      Process.cancel_timer(ref)
    end
  end

  # ============================================================================
  # cancel_checkpoint/1
  # ============================================================================

  describe "cancel_checkpoint/1" do
    test "cancels a timer reference" do
      ref = CheckpointManager.schedule_checkpoint(interval_ms: 5000)
      assert :ok = CheckpointManager.cancel_checkpoint(ref)

      refute_receive :checkpoint, 100
    end

    test "handles nil gracefully" do
      assert :ok = CheckpointManager.cancel_checkpoint(nil)
    end
  end

  # ============================================================================
  # should_checkpoint?/1
  # ============================================================================

  describe "should_checkpoint?/1" do
    test "seed agent: true when threshold exceeded" do
      state = seed_state(%{query_count: 10, last_checkpoint_query_count: 0})
      assert CheckpointManager.should_checkpoint?(state)
    end

    test "seed agent: false when below threshold" do
      state = seed_state(%{query_count: 3, last_checkpoint_query_count: 0})
      refute CheckpointManager.should_checkpoint?(state)
    end

    test "jido agent: always true" do
      state = jido_state()
      assert CheckpointManager.should_checkpoint?(state)
    end
  end

  # ============================================================================
  # config/1
  # ============================================================================

  describe "config/1" do
    test "provides sensible defaults" do
      config = CheckpointManager.config()

      assert config.store == Arbor.Checkpoint.Store.ETS
      assert config.interval_ms == 300_000
      assert config.enabled == true
      assert config.query_threshold == 5
    end

    test "merges per-agent opts with application config" do
      config = CheckpointManager.config(store: Arbor.Checkpoint.Store.Agent, interval_ms: 1000)

      assert config.store == Arbor.Checkpoint.Store.Agent
      assert config.interval_ms == 1000
    end
  end

  # ============================================================================
  # save_seed_checkpoint/2
  # ============================================================================

  describe "save_seed_checkpoint/2" do
    setup do
      pid = start_agent_store()

      on_exit(fn ->
        if Process.alive?(pid), do: Arbor.Checkpoint.Store.Agent.stop()
      end)

      :ok
    end

    test "saves a pre-captured seed" do
      seed = Seed.new("direct-save-test", name: "Direct Save")

      result =
        CheckpointManager.save_seed_checkpoint(seed, store: Arbor.Checkpoint.Store.Agent)

      assert result == :ok

      assert {:ok, data} =
               Arbor.Checkpoint.load(
                 "direct-save-test",
                 Arbor.Checkpoint.Store.Agent,
                 retries: 0
               )

      assert data["agent_id"] == "direct-save-test"
    end
  end
end
