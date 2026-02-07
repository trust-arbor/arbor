defmodule Arbor.Actions.MemoryTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.Memory

  @moduletag :fast

  setup_all do
    {:ok, _} = Application.ensure_all_started(:arbor_memory)

    # Ensure ETS tables exist (test env uses start_children: false)
    for table <- [:arbor_memory_graphs, :arbor_working_memory, :arbor_memory_proposals] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    # Start memory system children if not already running
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
  # Remember
  # ============================================================================

  describe "Remember" do
    test "stores a memory node", %{context: ctx} do
      assert {:ok, result} =
               Memory.Remember.run(
                 %{content: "Elixir uses pattern matching", type: "fact"},
                 ctx
               )

      assert result.node_id
      assert result.type == :fact
      assert result.stored == true
    end

    test "stores with importance", %{context: ctx} do
      assert {:ok, result} =
               Memory.Remember.run(
                 %{content: "Critical fact", type: "fact", importance: 0.9},
                 ctx
               )

      assert result.stored == true
    end

    test "links entities when they exist", %{agent_id: agent_id, context: ctx} do
      # Create a node named "Elixir"
      {:ok, _id} =
        Arbor.Memory.add_knowledge(agent_id, %{
          type: :fact,
          content: "Elixir is a programming language",
          metadata: %{name: "Elixir"}
        })

      assert {:ok, result} =
               Memory.Remember.run(
                 %{
                   content: "Elixir uses pattern matching",
                   type: "fact",
                   entities: ["Elixir"]
                 },
                 ctx
               )

      assert result.stored == true
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               Memory.Remember.run(
                 %{content: "test", type: "fact"},
                 %{}
               )
    end

    test "validates action metadata" do
      assert Memory.Remember.name() == "memory_remember"
      assert Memory.Remember.description() =~ "knowledge graph"
      assert Memory.Remember.category() == "memory"
      assert "memory" in Memory.Remember.tags()
    end

    test "generates tool schema" do
      tool = Memory.Remember.to_tool()
      assert is_map(tool)
      assert tool[:name] == "memory_remember"
      assert is_map(tool[:parameters_schema])
    end

    test "has taint roles" do
      roles = Memory.Remember.taint_roles()
      assert roles[:content] == :data
      assert roles[:type] == :control
    end
  end

  # ============================================================================
  # Recall
  # ============================================================================

  describe "Recall" do
    test "searches memory", %{agent_id: agent_id, context: ctx} do
      # Index some content first
      Arbor.Memory.index(agent_id, "Elixir pattern matching is powerful", %{type: :fact})

      assert {:ok, result} =
               Memory.Recall.run(
                 %{query: "pattern matching"},
                 ctx
               )

      assert is_list(result.results)
      assert result.query == "pattern matching"
    end

    test "returns empty results for no matches", %{context: ctx} do
      assert {:ok, result} =
               Memory.Recall.run(
                 %{query: "nonexistent topic xyzzy"},
                 ctx
               )

      assert result.count == 0
    end

    test "respects limit parameter", %{context: ctx} do
      assert {:ok, result} =
               Memory.Recall.run(
                 %{query: "test", limit: 5},
                 ctx
               )

      assert result.count <= 5
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               Memory.Recall.run(%{query: "test"}, %{})
    end

    test "validates action metadata" do
      assert Memory.Recall.name() == "memory_recall"
      assert "recall" in Memory.Recall.tags()
    end

    test "generates tool schema" do
      tool = Memory.Recall.to_tool()
      assert is_map(tool)
      assert tool[:name] == "memory_recall"
    end

    test "has taint roles" do
      roles = Memory.Recall.taint_roles()
      assert roles[:query] == :data
    end
  end

  # ============================================================================
  # Connect
  # ============================================================================

  describe "Connect" do
    test "links two knowledge nodes", %{agent_id: agent_id, context: ctx} do
      {:ok, node_a} =
        Arbor.Memory.add_knowledge(agent_id, %{type: :fact, content: "Node A"})

      {:ok, node_b} =
        Arbor.Memory.add_knowledge(agent_id, %{type: :fact, content: "Node B"})

      assert {:ok, result} =
               Memory.Connect.run(
                 %{from_id: node_a, to_id: node_b, relationship: "related_to"},
                 ctx
               )

      assert result.linked == true
      assert result.relationship == :related_to
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               Memory.Connect.run(
                 %{from_id: "a", to_id: "b", relationship: "related_to"},
                 %{}
               )
    end

    test "validates action metadata" do
      assert Memory.Connect.name() == "memory_connect"
      assert "connect" in Memory.Connect.tags()
    end

    test "generates tool schema" do
      tool = Memory.Connect.to_tool()
      assert is_map(tool)
      assert tool[:name] == "memory_connect"
    end

    test "has taint roles" do
      roles = Memory.Connect.taint_roles()
      assert roles[:relationship] == :control
      assert roles[:from_id] == :data
    end
  end

  # ============================================================================
  # Reflect
  # ============================================================================

  describe "Reflect" do
    test "returns graph stats", %{agent_id: agent_id, context: ctx} do
      # Add some knowledge first
      Arbor.Memory.add_knowledge(agent_id, %{type: :fact, content: "Test fact"})

      assert {:ok, result} =
               Memory.Reflect.run(%{include_stats: true}, ctx)

      assert Map.has_key?(result, :stats)
    end

    test "works without stats", %{context: ctx} do
      assert {:ok, result} =
               Memory.Reflect.run(%{include_stats: false}, ctx)

      refute Map.has_key?(result, :stats)
    end

    test "returns error without agent_id" do
      assert {:error, :missing_agent_id} =
               Memory.Reflect.run(%{}, %{})
    end

    test "validates action metadata" do
      assert Memory.Reflect.name() == "memory_reflect"
      assert "reflect" in Memory.Reflect.tags()
    end

    test "generates tool schema" do
      tool = Memory.Reflect.to_tool()
      assert is_map(tool)
      assert tool[:name] == "memory_reflect"
    end

    test "has taint roles" do
      roles = Memory.Reflect.taint_roles()
      assert roles[:prompt] == :data
    end
  end
end
