defmodule Arbor.Memory.KnowledgeGraphAuthorityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory
  alias Arbor.Memory.KnowledgeGraph
  alias Arbor.Memory.Test.DurableGraphAuthority

  @moduletag :fast
  @graph_ets :arbor_memory_graphs

  setup do
    DurableGraphAuthority.start!()

    agent_id = "agent_public_graph_authority_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = Memory.cleanup_for_agent(agent_id)
      :ets.delete(@graph_ets, agent_id)
    end)

    %{agent_id: agent_id}
  end

  test "public API security regression ignores a caller-forged ETS graph", %{
    agent_id: agent_id
  } do
    assert {:ok, nil} =
             Memory.init_for_agent(agent_id,
               index_enabled: false,
               graph_enabled: true,
               auto_embed: false
             )

    assert {:ok, durable_node_id} =
             Memory.add_knowledge(agent_id, %{
               type: :fact,
               content: "durable authority",
               skip_dedup: true
             })

    forged =
      agent_id
      |> KnowledgeGraph.new(auto_embed: false)
      |> add_node!("forged projection one")
      |> add_node!("forged projection two")

    true = :ets.insert(@graph_ets, {agent_id, forged})

    assert {:ok, %{node_count: 1}} = Memory.knowledge_stats(agent_id)
    assert {:ok, exported} = Memory.export_knowledge_graph(agent_id)
    assert Map.keys(exported.nodes) == [durable_node_id]
  end

  test "create-only conflict security regression removes a forged projection", %{
    agent_id: agent_id
  } do
    assert {:ok, nil} =
             Memory.init_for_agent(agent_id,
               index_enabled: false,
               graph_enabled: true,
               auto_embed: false
             )

    assert {:ok, durable_node_id} =
             Memory.add_knowledge(agent_id, %{
               type: :fact,
               content: "durable authority before create conflict",
               skip_dedup: true
             })

    forged =
      agent_id
      |> KnowledgeGraph.new(auto_embed: false)
      |> add_node!("forged projection survives conflict")

    replacement =
      agent_id
      |> KnowledgeGraph.new(auto_embed: false)
      |> add_node!("create-only replacement")

    true = :ets.insert(@graph_ets, {agent_id, forged})

    assert {:error, :conflict} =
             Memory.import_knowledge_graph(agent_id, KnowledgeGraph.to_map(replacement))

    case :ets.lookup(@graph_ets, agent_id) do
      [] ->
        :ok

      [{^agent_id, projected}] ->
        refute projected == forged
        assert Map.keys(projected.nodes) == [durable_node_id]
    end

    assert {:ok, exported} = Memory.export_knowledge_graph(agent_id)
    assert Map.keys(exported.nodes) == [durable_node_id]
  end

  defp add_node!(graph, content) do
    assert {:ok, graph, _node_id} =
             KnowledgeGraph.add_node(graph, %{
               type: :fact,
               content: content,
               skip_dedup: true
             })

    graph
  end
end
