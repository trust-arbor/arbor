defmodule Arbor.Memory.KnowledgeGraphStoreTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{Taint, TaintedValue, TaintEnvelope}

  alias Arbor.Memory.{KnowledgeGraph, KnowledgeGraphStore, MemoryStore, Provenance}
  alias Arbor.Memory.KnowledgeGraph.Codec
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @store_name :arbor_memory_durable
  @graph_ets :arbor_memory_graphs

  defmodule SwitchableNodeRestartBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Persistence.QueryableStore.ETS

    @impl true
    def put(key, value, opts), do: available_call(opts, fn -> ETS.put(key, value, opts) end)

    @impl true
    def get(key, opts), do: available_call(opts, fn -> ETS.get(key, opts) end)

    @impl true
    def delete(key, opts), do: available_call(opts, fn -> ETS.delete(key, opts) end)

    @impl true
    def list(opts), do: available_call(opts, fn -> ETS.list(opts) end)

    @impl true
    def query(filter, opts), do: available_call(opts, fn -> ETS.query(filter, opts) end)

    @impl true
    def compare_and_swap(key, expected, replacement, opts) do
      available_call(opts, fn -> ETS.compare_and_swap(key, expected, replacement, opts) end)
    end

    @impl true
    def compare_and_delete(key, expected, opts) do
      available_call(opts, fn -> ETS.compare_and_delete(key, expected, opts) end)
    end

    @impl true
    def durability_class(_opts), do: :node_restart

    defp available_call(opts, operation) do
      if Agent.get(Keyword.fetch!(opts, :control), & &1),
        do: operation.(),
        else: {:error, :forced_failure}
    end
  end

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

    agent_id = "agent_kg_store_#{System.unique_integer([:positive])}"
    :ok = KnowledgeGraphStore.delete_graph(agent_id)

    on_exit(fn ->
      _ = KnowledgeGraphStore.delete_graph(agent_id)
      _ = Provenance.delete_agent(agent_id)
      :ets.delete(@graph_ets, agent_id)
      ensure_child_running(Provenance)
      ensure_child_running(KnowledgeGraphStore)
    end)

    %{agent_id: agent_id}
  end

  test "exact durable roundtrip survives owner restart and ignores forged ETS", %{
    agent_id: agent_id
  } do
    graph = graph_with_node(agent_id, "durable", "durable truth")

    assert :ok = KnowledgeGraphStore.save_graph(agent_id, graph)
    assert {:ok, ^graph} = KnowledgeGraphStore.get_graph(agent_id)

    forged = graph_with_node(agent_id, "forged", "caller-controlled projection")
    true = :ets.insert(@graph_ets, {agent_id, forged})
    assert {:ok, ^graph} = KnowledgeGraphStore.get_graph(agent_id)

    restart_child(KnowledgeGraphStore)
    :ets.delete(@graph_ets, agent_id)

    assert {:ok, ^graph} = KnowledgeGraphStore.get_graph(agent_id)
    assert [{^agent_id, ^graph}] = :ets.lookup(@graph_ets, agent_id)

    assert {:ok, %TaintedValue{value: wrapper}, :verified, %Record{}, :namespaced} =
             MemoryStore.load_tainted_authoritative_with_status("knowledge_graph", agent_id)

    assert wrapper["kind"] == Codec.kind()
    assert wrapper["version"] == Codec.version()
    assert wrapper["agent_id"] == agent_id
  end

  test "raw compatibility saves receive conservative exact projection labels", %{
    agent_id: agent_id
  } do
    graph = graph_with_node(agent_id, "missing-label", "unlabelled raw input")
    assert :ok = KnowledgeGraphStore.save_graph(agent_id, graph)
    assert {:ok, snapshot} = KnowledgeGraphStore.get_snapshot(agent_id)

    missing = TaintEnvelope.missing_fallback()

    assert {:ok, ^missing, :verified} =
             Provenance.resolve(
               :knowledge_graph_base,
               agent_id,
               "base",
               snapshot.base_payload
             )

    assert {:ok, ^missing, :verified} =
             Provenance.resolve(
               :knowledge_graph_aggregate,
               agent_id,
               "aggregate",
               snapshot.payload
             )

    assert {:ok, ^missing, :verified} =
             Provenance.resolve(
               :knowledge_node,
               agent_id,
               "missing-label",
               snapshot.nodes["missing-label"].payload
             )
  end

  test "wrapper-shaped corruption and agent mismatch fail closed without projection", %{
    agent_id: agent_id
  } do
    source_id = agent_id <> "_source"
    graph = graph_with_node(source_id, "strict", "strict wrapper")
    wrapper = encoded_wrapper(source_id, graph)

    cases = [
      {agent_id <> "_unknown", %{wrapper | "version" => Codec.version() + 1}},
      {agent_id <> "_mismatch", wrapper},
      {agent_id <> "_malformed", Map.delete(wrapper, "provenance")}
    ]

    for {target_id, persisted} <- cases do
      assert {:ok, %Record{}} =
               MemoryStore.compare_and_swap_tainted(
                 "knowledge_graph",
                 target_id,
                 :not_found,
                 persisted,
                 taint: TaintEnvelope.missing_fallback()
               )

      assert {:error, :invalid_provenance} = KnowledgeGraphStore.get_graph(target_id)
      assert [] = :ets.lookup(@graph_ets, target_id)
      assert :ok = KnowledgeGraphStore.delete_graph(target_id)
    end
  end

  test "configured backend outage is distinct from not_found and cannot initialize empty", %{
    agent_id: agent_id
  } do
    stop_supervised!(BufferedStore)
    backend_name = unique_name(:kg_outage_backend)
    control = unique_name(:kg_outage_control)

    start_supervised!({Arbor.Persistence.QueryableStore.ETS, name: backend_name})

    start_supervised!(%{
      id: control,
      start: {Agent, :start_link, [fn -> false end, [name: control]]}
    })

    start_supervised!(
      {BufferedStore,
       name: @store_name,
       backend: SwitchableNodeRestartBackend,
       backend_opts: [control: control],
       collection: backend_name,
       write_mode: :sync}
    )

    empty = KnowledgeGraph.new(agent_id, auto_embed: false)

    assert {:error, :store_unavailable} = KnowledgeGraphStore.get_graph(agent_id)
    assert {:error, :store_unavailable} = KnowledgeGraphStore.save_graph(agent_id, empty)
    assert [] = :ets.lookup(@graph_ets, agent_id)

    Agent.update(control, fn _ -> true end)

    assert {:error, :not_found} =
             Arbor.Persistence.QueryableStore.ETS.get(
               "knowledge_graph:#{agent_id}",
               name: backend_name
             )

    assert {:error, :graph_not_initialized} = KnowledgeGraphStore.get_graph(agent_id)
  end

  test "a fresh CAS retry preserves a concurrent authoritative node", %{agent_id: agent_id} do
    assert :ok =
             KnowledgeGraphStore.save_graph(
               agent_id,
               KnowledgeGraph.new(agent_id, auto_embed: false)
             )

    test_pid = self()

    operation = fn graph ->
      send(test_pid, {:mutation_observed, self(), Map.keys(graph.nodes)})

      unless Map.has_key?(graph.nodes, "external") do
        receive do
          :release_mutation -> :ok
        after
          2_000 -> exit(:mutation_release_timeout)
        end
      end

      {:ok, put_node(graph, "local", "owner mutation"), :local}
    end

    task = Task.async(fn -> KnowledgeGraphStore.mutate(agent_id, operation) end)

    assert_receive {:mutation_observed, owner_pid, []}, 1_000

    assert {:ok, %TaintedValue{value: wrapper, taint: outer}, status, observed, _location} =
             MemoryStore.load_tainted_authoritative_with_status("knowledge_graph", agent_id)

    assert {:ok, snapshot, :current} = Codec.decode(agent_id, wrapper, outer, status)
    externally_updated = put_node(snapshot.graph, "external", "competing writer")

    assert {:ok, external_snapshot} =
             Codec.reconcile(agent_id, externally_updated, snapshot, trusted_taint("external"))

    assert {:ok, external_wrapper} = Codec.encode(external_snapshot)

    assert {:ok, %Record{}} =
             MemoryStore.compare_and_swap_tainted(
               "knowledge_graph",
               agent_id,
               observed,
               external_wrapper,
               taint: external_snapshot.aggregate.taint
             )

    send(owner_pid, :release_mutation)

    assert_receive {:mutation_observed, ^owner_pid, ["external"]}, 1_000
    assert {:ok, :local} = Task.await(task, 2_000)

    assert {:ok, final} = KnowledgeGraphStore.get_graph(agent_id)
    assert Map.keys(final.nodes) |> Enum.sort() == ["external", "local"]
  end

  test "post-effect CAS ambiguity returns outcome_unknown without retry", %{agent_id: agent_id} do
    stop_supervised!(BufferedStore)
    backend_name = unique_name(:kg_ambiguity_backend)
    control = unique_name(:kg_ambiguity_control)

    start_supervised!({Arbor.Persistence.QueryableStore.ETS, name: backend_name})

    start_supervised!(%{
      id: control,
      start: {Agent, :start_link, [fn -> %{armed: true, calls: 0} end, [name: control]]}
    })

    start_supervised!(
      {BufferedStore,
       name: @store_name,
       backend: PostCommitAmbiguityBackend,
       backend_opts: [control: control],
       collection: backend_name,
       write_mode: :sync}
    )

    graph = graph_with_node(agent_id, "ambiguous", "possibly committed")

    assert {:error, :outcome_unknown} = KnowledgeGraphStore.save_graph(agent_id, graph)
    assert %{armed: false, calls: 1} = Agent.get(control, & &1)
    assert [] = :ets.lookup(@graph_ets, agent_id)

    assert {:ok, %Record{data: wrapper, revision: 1}} =
             Arbor.Persistence.QueryableStore.ETS.get(
               "knowledge_graph:#{agent_id}",
               name: backend_name
             )

    assert wrapper["kind"] == Codec.kind()
    assert {:ok, ^graph} = KnowledgeGraphStore.get_graph(agent_id)
    assert %{calls: 1} = Agent.get(control, & &1)
  end

  test "projection failure cannot reverse durable success and later converges", %{
    agent_id: agent_id
  } do
    graph = graph_with_node(agent_id, "converge", "durable before projection")
    :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Provenance)

    assert :ok = KnowledgeGraphStore.save_graph_tainted(agent_id, graph, trusted_taint("save"))
    assert [] = :ets.lookup(@graph_ets, agent_id)

    assert {:ok, %TaintedValue{value: wrapper}, :verified, %Record{}, :namespaced} =
             MemoryStore.load_tainted_authoritative_with_status("knowledge_graph", agent_id)

    assert wrapper["payload"]["nodes"]["converge"]["content"] ==
             "durable before projection"

    assert {:ok, _pid} = Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance)

    assert eventually(fn ->
             case :ets.lookup(@graph_ets, agent_id) do
               [{^agent_id, ^graph}] -> true
               _ -> false
             end
           end)
  end

  test "authoritative compare-delete removes durable state and every projection", %{
    agent_id: agent_id
  } do
    graph = graph_with_node(agent_id, "delete", "delete me")
    assert :ok = KnowledgeGraphStore.save_graph(agent_id, graph)
    assert [{^agent_id, ^graph}] = :ets.lookup(@graph_ets, agent_id)

    assert :ok = KnowledgeGraphStore.delete_graph(agent_id)
    assert [] = :ets.lookup(@graph_ets, agent_id)

    assert {:error, :graph_not_initialized} = KnowledgeGraphStore.get_graph(agent_id)

    assert {:ok, missing, :legacy_unlabeled} =
             Provenance.resolve(:knowledge_node, agent_id, "delete", %{})

    assert missing == TaintEnvelope.missing_fallback()
  end

  defp encoded_wrapper(agent_id, graph) do
    assert {:ok, snapshot} =
             Codec.reconcile(agent_id, graph, nil, TaintEnvelope.missing_fallback())

    assert {:ok, wrapper} = Codec.encode(snapshot)
    wrapper
  end

  defp graph_with_node(agent_id, node_id, content) do
    agent_id
    |> KnowledgeGraph.new(auto_embed: false)
    |> put_node(node_id, content)
  end

  defp put_node(graph, node_id, content) do
    now = ~U[2026-08-05 12:00:00Z]

    node = %{
      id: node_id,
      type: :fact,
      content: content,
      relevance: 1.0,
      confidence: 0.8,
      access_count: 0,
      created_at: now,
      last_accessed: now,
      metadata: %{},
      pinned: false,
      embedding: nil,
      cached_tokens: 4,
      referenced_date: nil
    }

    %{graph | nodes: Map.put(graph.nodes, node_id, node)}
  end

  defp trusted_taint(source) do
    %Taint{
      level: :trusted,
      sensitivity: :public,
      sanitizations: 0,
      confidence: :verified,
      source: source,
      chain: []
    }
  end

  defp restart_child(module) do
    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, module)
    assert {:ok, _pid} = Supervisor.restart_child(Arbor.Memory.Supervisor, module)
  end

  defp ensure_child_running(module) do
    case Process.whereis(module) do
      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, module) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, :running} -> :ok
          {:error, _reason} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp eventually(operation, attempts \\ 100)
  defp eventually(_operation, 0), do: false

  defp eventually(operation, attempts) do
    if operation.() do
      true
    else
      Process.sleep(10)
      eventually(operation, attempts - 1)
    end
  end

  defp unique_name(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end
