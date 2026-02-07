defmodule Arbor.Actions.MemoryCognitiveTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.MemoryCognitive

  @moduletag :fast

  setup_all do
    {:ok, _} = Application.ensure_all_started(:arbor_memory)

    for table <- [:arbor_memory_graphs, :arbor_working_memory, :arbor_memory_proposals] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    children = [
      {Registry, keys: :unique, name: Arbor.Memory.Registry},
      {Arbor.Memory.IndexSupervisor, []},
      {Arbor.Persistence.EventLog.ETS, name: :memory_events},
      {Arbor.Memory.GoalStore, []},
      {Arbor.Memory.IntentStore, []},
      {Arbor.Memory.Thinking, []},
      {Arbor.Memory.CodeStore, []}
    ]

    for child <- children do
      Supervisor.start_child(Arbor.Memory.Supervisor, child)
    end

    :ok
  end

  setup do
    agent_id = "test_agent_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Arbor.Memory.init_for_agent(agent_id)

    on_exit(fn ->
      Arbor.Memory.cleanup_for_agent(agent_id)
    end)

    {:ok, agent_id: agent_id, context: %{agent_id: agent_id}}
  end

  # ============================================================================
  # AdjustPreference
  # ============================================================================

  describe "AdjustPreference" do
    test "adjusts decay_rate", %{context: ctx} do
      assert {:ok, result} =
               MemoryCognitive.AdjustPreference.run(
                 %{param: "decay_rate", value: 0.15},
                 ctx
               )

      assert result.adjusted == true
      assert result.param == :decay_rate
    end

    test "returns error for invalid param", %{context: ctx} do
      assert {:error, _reason} =
               MemoryCognitive.AdjustPreference.run(
                 %{param: "invalid_param_xyz", value: 0.5},
                 ctx
               )
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               MemoryCognitive.AdjustPreference.run(
                 %{param: "decay_rate", value: 0.1},
                 %{}
               )
    end

    test "validates action metadata" do
      assert MemoryCognitive.AdjustPreference.name() == "memory_adjust_preference"
      assert MemoryCognitive.AdjustPreference.category() == "memory_cognitive"
    end

    test "has taint roles" do
      roles = MemoryCognitive.AdjustPreference.taint_roles()
      assert roles[:param] == :control
      assert roles[:value] == :data
    end
  end

  # ============================================================================
  # PinMemory
  # ============================================================================

  describe "PinMemory" do
    test "pins a memory node", %{agent_id: agent_id, context: ctx} do
      {:ok, node_id} =
        Arbor.Memory.add_knowledge(agent_id, %{type: :fact, content: "Important fact"})

      assert {:ok, result} =
               MemoryCognitive.PinMemory.run(%{node_id: node_id}, ctx)

      assert result.pinned == true
      assert result.node_id == node_id
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               MemoryCognitive.PinMemory.run(%{node_id: "some_id"}, %{})
    end

    test "validates action metadata" do
      assert MemoryCognitive.PinMemory.name() == "memory_pin"
      assert "pin" in MemoryCognitive.PinMemory.tags()
    end

    test "generates tool schema" do
      tool = MemoryCognitive.PinMemory.to_tool()
      assert is_map(tool)
      assert tool[:name] == "memory_pin"
    end
  end

  # ============================================================================
  # UnpinMemory
  # ============================================================================

  describe "UnpinMemory" do
    test "unpins a memory node", %{agent_id: agent_id, context: ctx} do
      {:ok, node_id} =
        Arbor.Memory.add_knowledge(agent_id, %{type: :fact, content: "Pinned fact"})

      # Pin first
      Arbor.Memory.pin_memory(agent_id, node_id)

      assert {:ok, result} =
               MemoryCognitive.UnpinMemory.run(%{node_id: node_id}, ctx)

      assert result.unpinned == true
      assert result.node_id == node_id
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               MemoryCognitive.UnpinMemory.run(%{node_id: "some_id"}, %{})
    end

    test "validates action metadata" do
      assert MemoryCognitive.UnpinMemory.name() == "memory_unpin"
      assert "unpin" in MemoryCognitive.UnpinMemory.tags()
    end
  end
end
