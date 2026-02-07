defmodule Arbor.Actions.MemoryIdentityTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.MemoryIdentity

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
  # AddInsight
  # ============================================================================

  describe "AddInsight" do
    test "stores a capability insight", %{context: ctx} do
      assert {:ok, result} =
               MemoryIdentity.AddInsight.run(
                 %{content: "Pattern matching", category: "capability", confidence: 0.8},
                 ctx
               )

      assert result.stored == true
      assert result.category == :capability
      assert result.type == :self_knowledge
    end

    test "stores a trait insight", %{context: ctx} do
      assert {:ok, result} =
               MemoryIdentity.AddInsight.run(
                 %{content: "curious", category: "trait", confidence: 0.7},
                 ctx
               )

      assert result.stored == true
      assert result.category == :trait
    end

    test "stores a value insight", %{context: ctx} do
      assert {:ok, result} =
               MemoryIdentity.AddInsight.run(
                 %{content: "honesty", category: "value", confidence: 0.9},
                 ctx
               )

      assert result.stored == true
      assert result.category == :value
    end

    test "stores unknown category as knowledge node", %{context: ctx} do
      assert {:ok, result} =
               MemoryIdentity.AddInsight.run(
                 %{content: "I notice I work best in morning", category: "observation"},
                 ctx
               )

      assert result.stored == true
      assert result.type == :knowledge_node
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               MemoryIdentity.AddInsight.run(
                 %{content: "test", category: "capability"},
                 %{}
               )
    end

    test "validates action metadata" do
      assert MemoryIdentity.AddInsight.name() == "memory_add_insight"
      assert MemoryIdentity.AddInsight.category() == "memory_identity"
      assert "insight" in MemoryIdentity.AddInsight.tags()
    end

    test "generates tool schema" do
      tool = MemoryIdentity.AddInsight.to_tool()
      assert is_map(tool)
      assert tool[:name] == "memory_add_insight"
    end

    test "has taint roles" do
      roles = MemoryIdentity.AddInsight.taint_roles()
      assert roles[:category] == :control
      assert roles[:content] == :data
    end
  end

  # ============================================================================
  # ReadSelf
  # ============================================================================

  describe "ReadSelf" do
    test "returns self-knowledge", %{context: ctx} do
      assert {:ok, result} =
               MemoryIdentity.ReadSelf.run(%{aspect: "all"}, ctx)

      assert result.aspect == :all
      assert is_map(result.data)
    end

    test "returns specific aspect", %{context: ctx} do
      assert {:ok, result} =
               MemoryIdentity.ReadSelf.run(%{aspect: "identity"}, ctx)

      assert result.aspect == :identity
    end

    test "defaults to all", %{context: ctx} do
      assert {:ok, result} =
               MemoryIdentity.ReadSelf.run(%{}, ctx)

      assert result.aspect == :all
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               MemoryIdentity.ReadSelf.run(%{}, %{})
    end

    test "validates action metadata" do
      assert MemoryIdentity.ReadSelf.name() == "memory_read_self"
      assert "self-knowledge" in MemoryIdentity.ReadSelf.tags()
    end

    test "has taint roles" do
      roles = MemoryIdentity.ReadSelf.taint_roles()
      assert roles[:aspect] == :control
    end
  end

  # ============================================================================
  # IntrospectMemory
  # ============================================================================

  describe "IntrospectMemory" do
    test "returns memory stats", %{context: ctx} do
      assert {:ok, result} =
               MemoryIdentity.IntrospectMemory.run(%{}, ctx)

      assert result.agent_id
      assert Map.has_key?(result, :preferences)
    end

    test "includes graph stats when graph exists", %{agent_id: agent_id, context: ctx} do
      Arbor.Memory.add_knowledge(agent_id, %{type: :fact, content: "Test fact"})

      assert {:ok, result} =
               MemoryIdentity.IntrospectMemory.run(%{}, ctx)

      assert Map.has_key?(result, :knowledge_graph)
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               MemoryIdentity.IntrospectMemory.run(%{}, %{})
    end

    test "validates action metadata" do
      assert MemoryIdentity.IntrospectMemory.name() == "memory_introspect"
      assert "introspect" in MemoryIdentity.IntrospectMemory.tags()
    end
  end
end
