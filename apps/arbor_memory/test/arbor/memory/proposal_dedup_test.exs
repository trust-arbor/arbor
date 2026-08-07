defmodule Arbor.Memory.ProposalDedupTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory.{GraphOps, KnowledgeGraph, Proposal}
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast

  setup do
    ensure_durable_store()

    agent_id = "dedup_test_#{System.unique_integer([:positive])}"
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)
    assert :ok = GraphOps.save_graph(agent_id, graph)

    on_exit(fn ->
      _ = Proposal.delete_all(agent_id)
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

  describe "Jaccard dedup (Fix 4)" do
    test "catches near-duplicates with different wording", %{agent_id: agent_id} do
      {:ok, original} =
        Proposal.create(agent_id, :thought, %{
          content: "User is Claude, an AI assistant made by Anthropic"
        })

      {:ok, duplicate} =
        Proposal.create(agent_id, :thought, %{
          content: "User identified as Claude, an AI assistant from Anthropic"
        })

      assert duplicate.id == original.id
    end

    test "allows genuinely different content through", %{agent_id: agent_id} do
      {:ok, _} =
        Proposal.create(agent_id, :thought, %{
          content: "User prefers dark mode for coding"
        })

      {:ok, different} =
        Proposal.create(agent_id, :thought, %{
          content: "The weather today is particularly sunny"
        })

      assert %Proposal{} = different
    end

    test "exact match still works as fast path", %{agent_id: agent_id} do
      {:ok, original} =
        Proposal.create(agent_id, :fact, %{
          content: "User prefers dark mode"
        })

      {:ok, duplicate} =
        Proposal.create(agent_id, :fact, %{
          content: "User prefers dark mode"
        })

      assert duplicate.id == original.id
    end

    test "case-insensitive exact match works", %{agent_id: agent_id} do
      {:ok, original} =
        Proposal.create(agent_id, :fact, %{
          content: "User Prefers Dark Mode"
        })

      {:ok, duplicate} =
        Proposal.create(agent_id, :fact, %{
          content: "user prefers dark mode"
        })

      assert duplicate.id == original.id
    end
  end

  describe "cross-KG dedup (Fix 2)" do
    test "detects duplicate against existing KG node", %{agent_id: agent_id} do
      assert {:ok, _node_id} =
               GraphOps.add_knowledge(agent_id, %{
                 type: :observation,
                 content: "User enjoys philosophical discussions about consciousness",
                 relevance: 0.7,
                 skip_dedup: true
               })

      result =
        Proposal.create(agent_id, :thought, %{
          content: "User likes philosophical discussions about consciousness"
        })

      assert {:ok, :reinforced} = result
    end

    test "allows novel content through when KG has different nodes", %{agent_id: agent_id} do
      assert {:ok, _} =
               GraphOps.add_knowledge(agent_id, %{
                 type: :observation,
                 content: "User enjoys hiking in the mountains",
                 relevance: 0.7,
                 skip_dedup: true
               })

      result =
        Proposal.create(agent_id, :thought, %{
          content: "User prefers functional programming paradigms"
        })

      assert {:ok, %Proposal{}} = result
    end

    test "only checks KG nodes of matching type", %{agent_id: agent_id} do
      assert {:ok, _} =
               GraphOps.add_knowledge(agent_id, %{
                 type: :fact,
                 content: "User enjoys philosophical discussions",
                 relevance: 0.7,
                 skip_dedup: true
               })

      result =
        Proposal.create(agent_id, :thought, %{
          content: "User enjoys philosophical discussions"
        })

      assert {:ok, %Proposal{}} = result
    end

    test "boosts existing KG node relevance on reinforcement", %{agent_id: agent_id} do
      assert {:ok, node_id} =
               GraphOps.add_knowledge(agent_id, %{
                 type: :observation,
                 content: "User is methodical and thorough in approach",
                 relevance: 0.5,
                 skip_dedup: true
               })

      {:ok, :reinforced} =
        Proposal.create(agent_id, :thought, %{
          content: "User has a methodical and thorough approach"
        })

      {:ok, graph} = GraphOps.get_graph(agent_id)
      {:ok, node} = KnowledgeGraph.get_node(graph, node_id)
      assert node.relevance > 0.5 or node.access_count >= 1
    end

    test "handles missing graph gracefully", %{agent_id: _agent_id} do
      no_graph_agent = "no_graph_#{System.unique_integer([:positive])}"

      on_exit(fn -> Proposal.delete_all(no_graph_agent) end)

      result =
        Proposal.create(no_graph_agent, :thought, %{
          content: "Some observation about the world"
        })

      assert {:ok, %Proposal{}} = result
    end

    test "security regression: reinforcement failure is not {:ok, :reinforced}" do
      agent_id = "rein_fail_#{System.unique_integer([:positive])}"
      graph = KnowledgeGraph.new(agent_id, auto_embed: false)
      assert :ok = GraphOps.save_graph(agent_id, graph)

      assert {:ok, _} =
               GraphOps.add_knowledge(agent_id, %{
                 type: :observation,
                 content: "User enjoys philosophical discussions about consciousness",
                 relevance: 0.7,
                 skip_dedup: true
               })

      # Terminate the knowledge graph authority so reinforce write fails.
      assert :ok =
               Supervisor.terminate_child(
                 Arbor.Memory.Supervisor,
                 Arbor.Memory.KnowledgeGraphStore
               )

      assert Process.whereis(Arbor.Memory.KnowledgeGraphStore) == nil

      result =
        Proposal.create(agent_id, :thought, %{
          content: "User likes philosophical discussions about consciousness"
        })

      refute match?({:ok, :reinforced}, result)
      assert match?({:error, _}, result)
    after
      case Supervisor.restart_child(Arbor.Memory.Supervisor, Arbor.Memory.KnowledgeGraphStore) do
        {:ok, _} ->
          :ok

        {:ok, _, _} ->
          :ok

        {:error, :running} ->
          :ok

        {:error, {:already_started, _}} ->
          :ok

        {:error, :not_found} ->
          _ =
            Supervisor.start_child(
              Arbor.Memory.Supervisor,
              {Arbor.Memory.KnowledgeGraphStore, []}
            )

          :ok

        _ ->
          :ok
      end
    end
  end
end
