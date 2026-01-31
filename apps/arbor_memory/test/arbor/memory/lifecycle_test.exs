defmodule Arbor.Memory.LifecycleTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory
  alias Arbor.Memory.Lifecycle
  alias Arbor.Memory.WorkingMemory

  @moduletag :fast

  setup do
    # Use unique agent IDs to avoid test interference
    agent_id = "lifecycle_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> Memory.cleanup_for_agent(agent_id) end)
    {:ok, agent_id: agent_id}
  end

  describe "on_agent_start/2" do
    test "initializes memory and returns working memory", %{agent_id: agent_id} do
      {:ok, state} = Lifecycle.on_agent_start(agent_id)

      assert is_map(state)
      assert %WorkingMemory{} = state.working_memory
      assert state.working_memory.agent_id == agent_id
    end

    test "loads existing working memory if present", %{agent_id: agent_id} do
      # Pre-create working memory with some state
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("Previous thought")
        |> WorkingMemory.set_goals(["Previous goal"])

      Memory.save_working_memory(agent_id, wm)

      # Now call on_agent_start
      {:ok, state} = Lifecycle.on_agent_start(agent_id)

      assert state.working_memory.recent_thoughts == ["Previous thought"]
      assert state.working_memory.active_goals == ["Previous goal"]
    end

    test "creates new working memory if none exists", %{agent_id: agent_id} do
      {:ok, state} = Lifecycle.on_agent_start(agent_id)

      assert state.working_memory.recent_thoughts == []
      assert state.working_memory.active_goals == []
    end

    test "passes options through to init_for_agent", %{agent_id: agent_id} do
      # Just verify it doesn't crash with options
      {:ok, state} = Lifecycle.on_agent_start(agent_id, max_entries: 100)

      assert %WorkingMemory{} = state.working_memory
    end
  end

  describe "on_agent_stop/1" do
    test "persists working memory", %{agent_id: agent_id} do
      # Start agent and add some state
      {:ok, _state} = Lifecycle.on_agent_start(agent_id)

      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("Thought to persist")
        |> WorkingMemory.set_goals(["Goal to persist"])

      Memory.save_working_memory(agent_id, wm)

      # Stop agent
      :ok = Lifecycle.on_agent_stop(agent_id)

      # Verify working memory is still there (persisted)
      loaded = Memory.get_working_memory(agent_id)
      assert loaded.recent_thoughts == ["Thought to persist"]
      assert loaded.active_goals == ["Goal to persist"]
    end

    test "handles agent with no working memory gracefully", %{agent_id: agent_id} do
      # Stop without ever starting
      :ok = Lifecycle.on_agent_stop(agent_id)

      # Should complete without error
    end

    test "returns :ok", %{agent_id: agent_id} do
      {:ok, _state} = Lifecycle.on_agent_start(agent_id)
      result = Lifecycle.on_agent_stop(agent_id)

      assert result == :ok
    end
  end

  describe "on_heartbeat/1" do
    test "returns :ok", %{agent_id: agent_id} do
      result = Lifecycle.on_heartbeat(agent_id)

      assert result == :ok
    end

    test "works without agent initialization", %{agent_id: agent_id} do
      # Heartbeat should work even if agent hasn't been started
      result = Lifecycle.on_heartbeat(agent_id)

      assert result == :ok
    end
  end
end
