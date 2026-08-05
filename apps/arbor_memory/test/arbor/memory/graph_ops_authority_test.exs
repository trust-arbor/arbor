defmodule Arbor.Memory.GraphOpsAuthorityTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory
  alias Arbor.Memory.{KnowledgeGraph, KnowledgeGraphStore}
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @store_name :arbor_memory_durable
  @graph_ets :arbor_memory_graphs

  defmodule PostCommitAmbiguityBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Persistence.QueryableStore.ETS

    @impl true
    def put(key, value, opts), do: ETS.put(key, value, opts)

    @impl true
    def get(key, opts), do: ETS.get(key, opts)

    @impl true
    def delete(key, opts), do: ETS.delete(key, opts)

    @impl true
    def list(opts), do: ETS.list(opts)

    @impl true
    def query(filter, opts), do: ETS.query(filter, opts)

    @impl true
    def compare_and_swap(key, expected, replacement, opts) do
      result = ETS.compare_and_swap(key, expected, replacement, opts)

      ambiguous? =
        Agent.get_and_update(Keyword.fetch!(opts, :control), fn state ->
          if state.armed and match?({:ok, _record}, result) do
            {true, %{state | armed: false, calls: state.calls + 1}}
          else
            {false, %{state | calls: state.calls + 1}}
          end
        end)

      if ambiguous?, do: raise("simulated post-commit transport failure")
      result
    end

    @impl true
    def compare_and_delete(key, expected, opts), do: ETS.compare_and_delete(key, expected, opts)

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  setup do
    start_supervised!({BufferedStore, name: @store_name, backend: nil, write_mode: :sync})

    agent_id = "agent_graph_ops_authority_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = KnowledgeGraphStore.delete_graph(agent_id)
      :ets.delete(@graph_ets, agent_id)
      ensure_store_running()
    end)

    %{agent_id: agent_id}
  end

  test "public writers mutate durable authority and survive owner restart", %{agent_id: agent_id} do
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)

    assert {:ok, graph, approve_id} =
             KnowledgeGraph.add_pending_fact(graph, %{
               content: "approve this proposal",
               source: "test"
             })

    assert {:ok, graph, reject_id} =
             KnowledgeGraph.add_pending_learning(graph, %{
               content: "reject this proposal",
               source: "test"
             })

    assert :ok = Memory.import_knowledge_graph(agent_id, KnowledgeGraph.to_map(graph))

    true =
      :ets.insert(
        @graph_ets,
        {agent_id, KnowledgeGraph.new(agent_id, auto_embed: false)}
      )

    assert {:ok, first_id} =
             Memory.add_knowledge(agent_id, %{
               type: :fact,
               content: "first durable node",
               relevance: 0.4,
               skip_dedup: true
             })

    assert {:ok, second_id} =
             Memory.add_knowledge(agent_id, %{
               type: :fact,
               content: "second durable node",
               skip_dedup: true
             })

    assert :ok = Memory.link_knowledge(agent_id, first_id, second_id, :supports)
    assert {:ok, %{access_count: 1}} = Memory.reinforce_knowledge(agent_id, first_id)
    assert {:ok, _stats} = Memory.cascade_recall(agent_id, first_id, 0.1)
    assert {:ok, approved_node_id} = Memory.approve_pending(agent_id, approve_id)
    assert :ok = Memory.reject_pending(agent_id, reject_id)

    restart_store()
    :ets.delete(@graph_ets, agent_id)

    assert {:ok, exported} = Memory.export_knowledge_graph(agent_id)
    restored = KnowledgeGraph.from_map(exported)

    assert Map.keys(restored.nodes) |> Enum.sort() ==
             Enum.sort([first_id, second_id, approved_node_id])

    assert restored.nodes[first_id].access_count == 1
    assert restored.pending_facts == []
    assert restored.pending_learnings == []

    assert Enum.any?(restored.edges[first_id], fn edge ->
             edge.target_id == second_id and edge.relationship == :supports
           end)
  end

  test "public import is create-only and preserves existing authority", %{agent_id: agent_id} do
    original = graph_with_node(agent_id, "original authority")
    replacement = graph_with_node(agent_id, "replacement attempt")

    assert :ok = Memory.import_knowledge_graph(agent_id, KnowledgeGraph.to_map(original))

    assert {:error, :conflict} =
             Memory.import_knowledge_graph(agent_id, KnowledgeGraph.to_map(replacement))

    assert {:ok, exported} = Memory.export_knowledge_graph(agent_id)
    assert KnowledgeGraph.from_map(exported) == original
  end

  test "public writer reconciles a post-commit ambiguity with the same operation identity", %{
    agent_id: agent_id
  } do
    stop_supervised!(BufferedStore)
    backend_name = unique_name(:graph_ops_ambiguity_backend)
    control = unique_name(:graph_ops_ambiguity_control)

    start_supervised!({Arbor.Persistence.QueryableStore.ETS, name: backend_name})

    start_supervised!(%{
      id: control,
      start: {Agent, :start_link, [fn -> %{armed: false, calls: 0} end, [name: control]]}
    })

    start_supervised!(
      {BufferedStore,
       name: @store_name,
       backend: PostCommitAmbiguityBackend,
       backend_opts: [control: control],
       collection: backend_name,
       write_mode: :sync}
    )

    assert :ok =
             Arbor.Memory.GraphOps.save_graph(
               agent_id,
               KnowledgeGraph.new(agent_id, auto_embed: false)
             )

    calls_before = Agent.get(control, & &1.calls)
    Agent.update(control, &%{&1 | armed: true})

    assert {:ok, node_id} =
             Memory.add_knowledge(agent_id, %{
               type: :fact,
               content: "one ambiguous public effect",
               relevance: 0.4,
               skip_dedup: true
             })

    assert Agent.get(control, & &1.calls) == calls_before + 1
    assert {:ok, exported} = Memory.export_knowledge_graph(agent_id)
    graph = KnowledgeGraph.from_map(exported)
    assert Map.keys(graph.nodes) == [node_id]
    assert graph.nodes[node_id].relevance == 0.4
  end

  defp graph_with_node(agent_id, content) do
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)

    assert {:ok, graph, _node_id} =
             KnowledgeGraph.add_node(graph, %{
               type: :fact,
               content: content,
               skip_dedup: true
             })

    graph
  end

  defp restart_store do
    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, KnowledgeGraphStore)
    assert {:ok, _pid} = Supervisor.restart_child(Arbor.Memory.Supervisor, KnowledgeGraphStore)
  end

  defp ensure_store_running do
    case Process.whereis(KnowledgeGraphStore) do
      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, KnowledgeGraphStore) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, :running} -> :ok
          {:error, _reason} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp unique_name(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end
