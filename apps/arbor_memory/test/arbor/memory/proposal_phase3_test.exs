defmodule Arbor.Memory.ProposalPhase3Test do
  use ExUnit.Case, async: false

  alias Arbor.Memory.{GraphOps, IntentStore, KnowledgeGraph, Proposal}
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast

  setup do
    ensure_durable_store()

    agent_id = "test_agent_p3_#{System.unique_integer([:positive])}"
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)
    assert :ok = GraphOps.save_graph(agent_id, graph)

    on_exit(fn ->
      _ = Proposal.delete_all(agent_id)
      _ = IntentStore.clear(agent_id)
    end)

    {:ok, agent_id: agent_id}
  end

  defp ensure_durable_store do
    case Process.whereis(:arbor_memory_durable) do
      nil ->
        start_supervised!(
          {BufferedStore, name: :arbor_memory_durable, backend: nil, write_mode: :sync}
        )

      _ ->
        :ok
    end
  end

  describe "Phase 3 proposal types" do
    test "creates :goal proposal", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :goal, %{
          content: "Learn Elixir macros",
          metadata: %{goal_data: %{"type" => "achieve"}}
        })

      assert p.type == :goal
      assert p.content == "Learn Elixir macros"
    end

    test "creates :goal_update proposal", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :goal_update, %{
          content: "Update goal progress to 50%",
          metadata: %{update_data: %{"id" => "g1", "progress" => 0.5}}
        })

      assert p.type == :goal_update
    end

    test "creates :thought proposal", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :thought, %{content: "Interesting pattern detected"})

      assert p.type == :thought
    end

    test "creates :concern proposal", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :concern, %{content: "Memory growing unbounded"})

      assert p.type == :concern
    end

    test "creates :curiosity proposal", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :curiosity, %{content: "What does this function do?"})

      assert p.type == :curiosity
    end

    test "creates :identity proposal", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :identity, %{
          content: "I tend to be thorough in explanations",
          source: "heartbeat"
        })

      assert p.type == :identity
    end

    test "creates :intent proposal", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :intent, %{
          content: "Execute file search",
          metadata: %{decomposition: %{"capability" => "read", "op" => "file"}}
        })

      assert p.type == :intent
    end

    test "creates :cognitive_mode proposal", %{agent_id: agent_id} do
      {:ok, p} =
        Proposal.create(agent_id, :cognitive_mode, %{
          content: "Switch to goal_pursuit mode",
          metadata: %{from: "reflection", to: "goal_pursuit"}
        })

      assert p.type == :cognitive_mode
    end
  end

  describe "dedup across new types" do
    test "deduplicates :thought proposals with similar content", %{agent_id: agent_id} do
      {:ok, p1} =
        Proposal.create(agent_id, :thought, %{
          content: "This is a recurring observation about the system behavior and architecture"
        })

      {:ok, p2} =
        Proposal.create(agent_id, :thought, %{
          content: "This is a recurring observation about the system behavior and architecture"
        })

      assert p1.id == p2.id
    end

    test "different types are not deduped against each other", %{agent_id: agent_id} do
      {:ok, p1} = Proposal.create(agent_id, :thought, %{content: "Observation A"})
      {:ok, p2} = Proposal.create(agent_id, :concern, %{content: "Observation A"})

      assert p1.id != p2.id
    end
  end

  describe "node type mapping for new types" do
    test ":thought accepts to :observation node", %{agent_id: agent_id} do
      {:ok, p} = Proposal.create(agent_id, :thought, %{content: "Test thought"})
      {:ok, node_id} = Proposal.accept(agent_id, p.id)

      {:ok, graph} = GraphOps.get_graph(agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      assert node.type == :observation
    end

    test ":concern accepts to :observation node", %{agent_id: agent_id} do
      {:ok, p} = Proposal.create(agent_id, :concern, %{content: "Test concern"})
      {:ok, node_id} = Proposal.accept(agent_id, p.id)

      {:ok, graph} = GraphOps.get_graph(agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      assert node.type == :observation
    end

    test ":identity accepts to :trait node", %{agent_id: agent_id} do
      {:ok, p} = Proposal.create(agent_id, :identity, %{content: "Trait insight"})
      {:ok, node_id} = Proposal.accept(agent_id, p.id)

      {:ok, graph} = GraphOps.get_graph(agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      assert node.type == :trait
    end
  end

  describe "stats include new types" do
    test "by_type tracks Phase 3 types", %{agent_id: agent_id} do
      {:ok, _} = Proposal.create(agent_id, :thought, %{content: "T1"})
      {:ok, _} = Proposal.create(agent_id, :concern, %{content: "C1"})
      {:ok, _} = Proposal.create(agent_id, :goal, %{content: "G1"})

      stats = Proposal.stats(agent_id)
      assert stats.by_type[:thought] == 1
      assert stats.by_type[:concern] == 1
      assert stats.by_type[:goal] == 1
      assert stats.pending == 3
    end
  end
end
