defmodule Arbor.Memory.KnowledgeGraphStoreTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{Taint, TaintedValue, TaintEnvelope}

  alias Arbor.Memory.{Events, KnowledgeGraph, KnowledgeGraphStore, MemoryStore, Provenance}
  alias Arbor.Memory.KnowledgeGraph.{Codec, Operation}
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @store_name :arbor_memory_durable
  @graph_ets :arbor_memory_graphs
  @projection_domains [
    :knowledge_graph_base,
    :knowledge_graph_aggregate,
    :knowledge_node,
    :knowledge_pending_fact,
    :knowledge_pending_learning,
    :knowledge_maintenance_effect
  ]

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

  defmodule InjectConflictBackend do
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
      injected =
        Agent.get_and_update(Keyword.fetch!(opts, :control), fn state ->
          case state do
            %{inject: %Arbor.Contracts.Persistence.Record{} = external} ->
              {external, %{state | inject: nil, injections: state.injections + 1}}

            _ ->
              {nil, state}
          end
        end)

      if injected do
        {:ok, _stored} = ETS.compare_and_swap(key, expected, injected, opts)
      end

      ETS.compare_and_swap(key, expected, replacement, opts)
    end

    @impl true
    def compare_and_delete(key, expected, opts), do: ETS.compare_and_delete(key, expected, opts)

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule PostDeleteAmbiguityBackend do
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
    def compare_and_swap(key, expected, replacement, opts),
      do: ETS.compare_and_swap(key, expected, replacement, opts)

    @impl true
    def compare_and_delete(key, expected, opts) do
      result = ETS.compare_and_delete(key, expected, opts)

      ambiguous? =
        Agent.get_and_update(Keyword.fetch!(opts, :control), fn state ->
          if state.armed and result == :ok do
            {true, %{state | armed: false, calls: state.calls + 1}}
          else
            {false, %{state | calls: state.calls + 1}}
          end
        end)

      if ambiguous?, do: raise("simulated post-delete transport failure")
      result
    end

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule DelayOnceBackend do
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
      delay =
        Agent.get_and_update(Keyword.fetch!(opts, :control), fn state ->
          if state.delay do
            {{state.test_pid, state.delay_ms}, %{state | delay: false, calls: state.calls + 1}}
          else
            {nil, %{state | calls: state.calls + 1}}
          end
        end)

      if delay do
        {test_pid, delay_ms} = delay
        send(test_pid, :knowledge_graph_cas_delayed)
        Process.sleep(delay_ms)
      end

      ETS.compare_and_swap(key, expected, replacement, opts)
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

  test "legacy import security regression cannot replace verified durable authority", %{
    agent_id: agent_id
  } do
    original = graph_with_node(agent_id, "verified", "verified durable authority")
    replacement = graph_with_node(agent_id, "legacy", "caller-controlled legacy fallback")

    assert :ok =
             KnowledgeGraphStore.save_graph_tainted(
               agent_id,
               original,
               trusted_taint("verified_authority")
             )

    assert {:error, :conflict} =
             KnowledgeGraphStore.import_legacy_graph(
               agent_id,
               KnowledgeGraph.to_map(replacement)
             )

    assert {:error, :conflict} = KnowledgeGraphStore.save_graph(agent_id, replacement)

    assert {:ok, initialize_operation} = Operation.initialize(replacement)

    assert {:error, :invalid_graph} =
             GenServer.call(
               KnowledgeGraphStore,
               {:operate, agent_id, initialize_operation, Codec.missing_taint(),
                System.monotonic_time(:millisecond) + 1_000},
               :infinity
             )

    assert {:ok, ^original} = KnowledgeGraphStore.get_graph(agent_id)
  end

  test "typed authority exports no retryable caller closure API" do
    exports = KnowledgeGraphStore.__info__(:functions)
    refute {:mutate, 2} in exports
    refute {:mutate_tainted, 3} in exports

    facade_exports = Arbor.Memory.__info__(:functions)
    refute {:mutate_knowledge_graph, 2} in facade_exports
    refute {:mutate_knowledge_graph_tainted, 3} in facade_exports

    source =
      __DIR__
      |> Path.join("../../../lib/arbor/memory/knowledge_graph_store.ex")
      |> Path.expand()
      |> File.read!()

    refute source =~ "is_function(operation"
    refute source =~ "operation.("

    facade_source =
      __DIR__
      |> Path.join("../../../lib/arbor/memory.ex")
      |> Path.expand()
      |> File.read!()

    refute facade_source =~ "KnowledgeGraphStore.mutate"
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

  test "authoritative decode failure evicts stale graph and every provenance sidecar", %{
    agent_id: agent_id
  } do
    graph = graph_with_node(agent_id, "stale", "must not survive authority corruption")
    assert :ok = KnowledgeGraphStore.save_graph(agent_id, graph)
    assert {:ok, snapshot} = KnowledgeGraphStore.get_snapshot(agent_id)
    assert_projection_present(agent_id)

    assert {:ok, %TaintedValue{value: wrapper, taint: outer}, _status, observed, _location} =
             MemoryStore.load_tainted_authoritative_with_status("knowledge_graph", agent_id)

    malformed = Map.delete(wrapper, "provenance")

    assert {:ok, %Record{}} =
             MemoryStore.compare_and_swap_tainted(
               "knowledge_graph",
               agent_id,
               observed,
               malformed,
               taint: outer
             )

    assert {:error, :invalid_provenance} = KnowledgeGraphStore.get_graph(agent_id)
    assert_projection_empty(agent_id)

    assert {:ok, missing, :legacy_unlabeled} =
             Provenance.resolve(
               :knowledge_graph_aggregate,
               agent_id,
               "aggregate",
               snapshot.payload
             )

    assert missing == TaintEnvelope.missing_fallback()
  end

  test "backend outage evicts stale projections and never treats absence as not_found", %{
    agent_id: agent_id
  } do
    stop_supervised!(BufferedStore)
    backend_name = unique_name(:kg_stale_outage_backend)
    control = unique_name(:kg_stale_outage_control)

    start_supervised!({Arbor.Persistence.QueryableStore.ETS, name: backend_name})

    start_supervised!(%{
      id: control,
      start: {Agent, :start_link, [fn -> true end, [name: control]]}
    })

    start_supervised!(
      {BufferedStore,
       name: @store_name,
       backend: SwitchableNodeRestartBackend,
       backend_opts: [control: control],
       collection: backend_name,
       write_mode: :sync}
    )

    graph = graph_with_node(agent_id, "outage", "stale during outage")
    assert :ok = KnowledgeGraphStore.save_graph(agent_id, graph)
    assert {:ok, ^graph} = KnowledgeGraphStore.get_graph(agent_id)
    assert_projection_present(agent_id)

    Agent.update(control, fn _ -> false end)

    assert {:error, :store_unavailable} = KnowledgeGraphStore.get_snapshot(agent_id)
    assert_projection_empty(agent_id)
    assert {:error, :store_unavailable} = KnowledgeGraphStore.delete_graph(agent_id)
    assert_projection_empty(agent_id)

    Agent.update(control, fn _ -> true end)
    assert :ok = KnowledgeGraphStore.converge_projection(agent_id)
    assert {:ok, ^graph} = KnowledgeGraphStore.get_graph(agent_id)
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
    stop_supervised!(BufferedStore)
    backend_name = unique_name(:kg_conflict_backend)
    control = unique_name(:kg_conflict_control)

    start_supervised!({Arbor.Persistence.QueryableStore.ETS, name: backend_name})

    start_supervised!(%{
      id: control,
      start: {Agent, :start_link, [fn -> %{inject: nil, injections: 0} end, [name: control]]}
    })

    start_supervised!(
      {BufferedStore,
       name: @store_name,
       backend: InjectConflictBackend,
       backend_opts: [control: control],
       collection: backend_name,
       write_mode: :sync}
    )

    assert :ok =
             KnowledgeGraphStore.save_graph(
               agent_id,
               KnowledgeGraph.new(agent_id, auto_embed: false)
             )

    assert {:ok, %TaintedValue{value: wrapper, taint: outer}, status, observed, _location} =
             MemoryStore.load_tainted_authoritative_with_status("knowledge_graph", agent_id)

    assert {:ok, snapshot, :current} = Codec.decode(agent_id, wrapper, outer, status)
    externally_updated = put_node(snapshot.graph, "external", "competing writer")

    assert {:ok, external_snapshot} =
             Codec.reconcile(agent_id, externally_updated, snapshot, trusted_taint("external"))

    assert {:ok, external_wrapper} = Codec.encode(external_snapshot)

    external_record =
      authoritative_replacement(observed, external_wrapper, external_snapshot.aggregate.taint)

    Agent.update(control, &%{&1 | inject: external_record})

    assert {:ok, local_id} =
             KnowledgeGraphStore.add_node(agent_id, "operation_local", %{
               type: :fact,
               content: "owner mutation",
               skip_dedup: true
             })

    assert {:ok, final} = KnowledgeGraphStore.get_graph(agent_id)
    assert Map.keys(final.nodes) |> Enum.sort() == ["external", local_id]
    assert %{injections: 1} = Agent.get(control, & &1)
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

  test "stable operation identity replays an ambiguous committed add without another effect", %{
    agent_id: agent_id
  } do
    stop_supervised!(BufferedStore)
    backend_name = unique_name(:kg_idempotent_backend)
    control = unique_name(:kg_idempotent_control)

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
             KnowledgeGraphStore.save_graph(
               agent_id,
               KnowledgeGraph.new(agent_id, auto_embed: false)
             )

    Agent.update(control, &%{&1 | armed: true})

    node_data = %{
      type: :fact,
      content: "idempotent effect",
      relevance: 0.4,
      skip_dedup: true
    }

    assert {:error, :outcome_unknown} =
             KnowledgeGraphStore.add_node(agent_id, "stable_add_operation", node_data)

    assert {:ok, committed} = KnowledgeGraphStore.get_graph(agent_id)
    [node_id] = Map.keys(committed.nodes)
    assert committed.nodes[node_id].relevance == 0.4
    calls_after_commit = Agent.get(control, & &1.calls)
    revision_after_commit = authoritative_revision(agent_id)

    assert {:ok, ^node_id} =
             KnowledgeGraphStore.add_node(agent_id, "stable_add_operation", node_data)

    assert authoritative_revision(agent_id) == revision_after_commit
    assert Agent.get(control, & &1.calls) == calls_after_commit
    assert {:ok, replayed} = KnowledgeGraphStore.get_graph(agent_id)
    assert replayed.nodes[node_id].relevance == 0.4
  end

  test "receipt horizon stays writable and proposal replay survives generic eviction", %{
    agent_id: agent_id
  } do
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)

    assert {:ok, graph, pending_id} =
             KnowledgeGraph.add_pending_fact(graph, %{
               content: "durable proposal identity",
               source: "test"
             })

    assert :ok = KnowledgeGraphStore.save_graph(agent_id, graph)
    assert {:ok, node_id} = KnowledgeGraphStore.approve_pending(agent_id, pending_id)

    Enum.each(1..(Operation.receipt_horizon() + 1), fn index ->
      assert {:ok, _node} =
               KnowledgeGraphStore.reinforce(agent_id, "reinforce_#{index}", node_id)
    end)

    assert {:ok, after_rollover} = KnowledgeGraphStore.get_graph(agent_id)
    assert map_size(after_rollover.operation_receipts) == Operation.receipt_horizon()
    assert length(after_rollover.operation_receipt_order) == Operation.receipt_horizon()
    assert after_rollover.nodes[node_id].access_count == Operation.receipt_horizon() + 1

    revision_before_replay = authoritative_revision(agent_id)
    assert {:ok, ^node_id} = KnowledgeGraphStore.approve_pending(agent_id, pending_id)
    assert authoritative_revision(agent_id) == revision_before_replay
  end

  test "approval receipt precedence security regression rejects a reused operation id", %{
    agent_id: agent_id
  } do
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)

    assert {:ok, graph, pending_id} =
             KnowledgeGraph.add_pending_fact(graph, %{
               content: "receipt-bound proposal",
               source: "test"
             })

    assert :ok = KnowledgeGraphStore.save_graph(agent_id, graph)

    reused_operation_id = "operation_already_bound_to_tainted_add"
    trusted = trusted_taint("receipt_source")

    assert {:ok, unrelated_node_id} =
             KnowledgeGraphStore.add_node_tainted(
               agent_id,
               reused_operation_id,
               %{type: :fact, content: "unrelated mutation", skip_dedup: true},
               trusted
             )

    assert {:ok, accepted_node_id} = KnowledgeGraphStore.approve_pending(agent_id, pending_id)
    revision_after_accept = authoritative_revision(agent_id)

    assert {:ok, ^accepted_node_id} = KnowledgeGraphStore.approve_pending(agent_id, pending_id)
    assert authoritative_revision(agent_id) == revision_after_accept

    assert {:ok, generated_approval} = Operation.approve_pending(pending_id)
    reused_id_approval = put_elem(generated_approval, 1, reused_operation_id)
    assert {:ok, committed} = KnowledgeGraphStore.get_graph(agent_id)

    assert {:error, :operation_id_conflict} =
             Operation.apply(reused_id_approval, committed, Codec.missing_taint())

    assert {:error, :operation_id_conflict} =
             KnowledgeGraphStore.approve_pending(
               agent_id,
               reused_operation_id,
               pending_id
             )

    assert authoritative_revision(agent_id) == revision_after_accept
    assert {:ok, unchanged} = KnowledgeGraphStore.get_graph(agent_id)
    assert Map.has_key?(unchanged.nodes, unrelated_node_id)
    assert Map.has_key?(unchanged.nodes, accepted_node_id)
    assert map_size(unchanged.nodes) == 2
  end

  test "typed E3 mutations persist metadata, pending learning, and maintenance exactly once", %{
    agent_id: agent_id
  } do
    graph = graph_with_node(agent_id, "maintenance", "archive after durable commit")
    graph = put_in(graph.nodes["maintenance"].relevance, 0.05)
    assert :ok = KnowledgeGraphStore.save_graph(agent_id, graph)

    blocked_at = ~U[2026-08-05 13:00:00Z]

    assert {:ok, %{metadata: metadata}} =
             KnowledgeGraphStore.merge_node_metadata(
               agent_id,
               "metadata_operation",
               "maintenance",
               %{promotion_blocked: true, blocked_at: blocked_at}
             )

    assert metadata.promotion_blocked
    assert metadata.blocked_at == blocked_at

    assert {:ok, pending_id} =
             KnowledgeGraphStore.add_pending_learning(
               agent_id,
               "pending_learning_operation",
               %{
                 content: "bounded pending learning",
                 confidence: 0.8,
                 source: "test",
                 metadata: %{pattern_type: :repeated_sequence}
               }
             )

    assert {:ok, updated, result} =
             KnowledgeGraphStore.consolidate(
               agent_id,
               "basic_maintenance_operation",
               :basic,
               prune_threshold: 0.1
             )

    assert updated.nodes == %{}
    assert Enum.map(updated.pending_learnings, & &1.id) == [pending_id]
    assert result.metrics.pruned_count == 1
    assert result.metrics.archived_count == 1
    assert [%{node: %{id: "maintenance"}, reason: :low_relevance}] = result.archive_entries
    refute result.replayed

    revision_after_commit = authoritative_revision(agent_id)

    assert {:ok, ^updated, replay} =
             KnowledgeGraphStore.consolidate(
               agent_id,
               "basic_maintenance_operation",
               :basic,
               prune_threshold: 0.1
             )

    assert replay.replayed
    assert replay.archive_entries == result.archive_entries
    assert authoritative_revision(agent_id) == revision_after_commit

    assert :ok =
             KnowledgeGraphStore.acknowledge_maintenance_effect(
               agent_id,
               "basic_maintenance_operation"
             )

    assert {:ok, nil} = KnowledgeGraphStore.pending_maintenance_effect(agent_id)

    assert {:ok, _graph, drained} =
             KnowledgeGraphStore.consolidate(
               agent_id,
               "basic_maintenance_operation",
               :basic,
               prune_threshold: 0.1
             )

    assert drained.drained
    assert drained.metrics == result.metrics
    assert drained.archive_entries == []
  end

  test "tainted typed operations bind source labels into immutable receipt identity", %{
    agent_id: agent_id
  } do
    assert :ok =
             KnowledgeGraphStore.save_graph(
               agent_id,
               KnowledgeGraph.new(agent_id, auto_embed: false)
             )

    trusted = trusted_taint("typed_source")
    hostile = hostile_taint("different_source")
    node_data = %{type: :fact, content: "labelled node", skip_dedup: true}

    assert {:ok, node_id} =
             KnowledgeGraphStore.add_node_tainted(
               agent_id,
               "taint_bound_node",
               node_data,
               trusted
             )

    revision = authoritative_revision(agent_id)

    assert {:ok, ^node_id} =
             KnowledgeGraphStore.add_node_tainted(
               agent_id,
               "taint_bound_node",
               node_data,
               trusted
             )

    assert authoritative_revision(agent_id) == revision

    assert {:error, :operation_id_conflict} =
             KnowledgeGraphStore.add_node_tainted(
               agent_id,
               "taint_bound_node",
               node_data,
               hostile
             )

    assert {:ok, snapshot} = KnowledgeGraphStore.get_snapshot(agent_id)
    assert snapshot.nodes[node_id].label == %{taint: trusted, status: :verified}
    assert authoritative_revision(agent_id) == revision

    pending_data = %{content: "labelled pending", source: "test"}

    for {kind, add} <- [
          {:fact, &KnowledgeGraphStore.add_pending_fact_tainted/4},
          {:learning, &KnowledgeGraphStore.add_pending_learning_tainted/4}
        ] do
      operation_id = "taint_bound_pending_#{kind}"
      assert {:ok, pending_id} = add.(agent_id, operation_id, pending_data, trusted)
      assert {:ok, ^pending_id} = add.(agent_id, operation_id, pending_data, trusted)

      assert {:error, :operation_id_conflict} =
               add.(agent_id, operation_id, pending_data, hostile)
    end
  end

  test "typed batches commit atomically and replay without duplicate effects", %{
    agent_id: agent_id
  } do
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)

    assert {:ok, graph, first_id} =
             KnowledgeGraph.add_node(graph, %{
               type: :insight,
               content: "first batch node",
               skip_dedup: true
             })

    assert {:ok, graph, second_id} =
             KnowledgeGraph.add_node(graph, %{
               type: :insight,
               content: "second batch node",
               skip_dedup: true
             })

    assert :ok = KnowledgeGraphStore.save_graph(agent_id, graph)

    assert {:error, :not_found} =
             KnowledgeGraphStore.merge_node_metadata_batch(
               agent_id,
               "metadata_batch_rejected",
               [{first_id, %{promotion_blocked: true}}, {"missing", %{promotion_blocked: true}}]
             )

    assert {:ok, unchanged} = KnowledgeGraphStore.get_graph(agent_id)
    refute unchanged.nodes[first_id].metadata[:promotion_blocked]

    updates = [
      {first_id, %{promotion_blocked: true}},
      {second_id, %{promotion_blocked: true}}
    ]

    assert :ok =
             KnowledgeGraphStore.merge_node_metadata_batch(
               agent_id,
               "metadata_batch_committed",
               updates
             )

    revision = authoritative_revision(agent_id)

    assert :ok =
             KnowledgeGraphStore.merge_node_metadata_batch(
               agent_id,
               "metadata_batch_committed",
               updates
             )

    assert authoritative_revision(agent_id) == revision

    learning_data = [
      %{content: "first pending batch item", source: "test"},
      %{content: "second pending batch item", source: "test"}
    ]

    assert {:ok, pending_ids} =
             KnowledgeGraphStore.add_pending_learning_batch(
               agent_id,
               "pending_learning_batch",
               learning_data
             )

    assert length(pending_ids) == 2
    pending_revision = authoritative_revision(agent_id)

    assert {:ok, ^pending_ids} =
             KnowledgeGraphStore.add_pending_learning_batch(
               agent_id,
               "pending_learning_batch",
               learning_data
             )

    assert authoritative_revision(agent_id) == pending_revision
    assert {:ok, current} = KnowledgeGraphStore.get_graph(agent_id)
    assert Enum.map(current.pending_learnings, & &1.id) |> Enum.sort() == Enum.sort(pending_ids)
  end

  test "security regression accepted labels transfer only from typed operation authority", %{
    agent_id: agent_id
  } do
    assert :ok =
             KnowledgeGraphStore.save_graph(
               agent_id,
               KnowledgeGraph.new(agent_id, auto_embed: false)
             )

    trusted = trusted_taint("pending_origin")
    hostile = hostile_taint("forged_node")
    pending_data = %{content: "pending authority", confidence: 0.9, source: "review"}

    assert {:ok, pending_id} =
             KnowledgeGraphStore.add_pending_fact_tainted(
               agent_id,
               "labelled_pending",
               pending_data,
               trusted
             )

    forged = %{
      type: :fact,
      content: pending_data.content,
      skip_dedup: true,
      metadata: %{"$arbor_accepted_proposal_id" => pending_id}
    }

    assert {:error, :invalid_graph} =
             KnowledgeGraphStore.add_node_tainted(
               agent_id,
               "forged_acceptance",
               forged,
               hostile
             )

    assert {:ok, node_id} = KnowledgeGraphStore.approve_pending(agent_id, pending_id)
    assert {:ok, snapshot} = KnowledgeGraphStore.get_snapshot(agent_id)
    assert snapshot.nodes[node_id].label == %{taint: trusted, status: :verified}
    refute Map.has_key?(snapshot.pending_facts, pending_id)

    restart_child(KnowledgeGraphStore)

    assert {:ok, restarted} = KnowledgeGraphStore.get_snapshot(agent_id)
    assert restarted.nodes[node_id].label == %{taint: trusted, status: :verified}
  end

  test "response-loss maintenance replay archives once with exact provenance before fenced ack",
       %{
         agent_id: agent_id
       } do
    stop_supervised!(BufferedStore)
    backend_name = unique_name(:kg_maintenance_ambiguity_backend)
    control = unique_name(:kg_maintenance_ambiguity_control)

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

    source_taint = trusted_taint("archive_origin")
    graph = graph_with_node(agent_id, "archive-me", "durably labelled archive content")
    graph = put_in(graph.nodes["archive-me"].relevance, 0.05)
    assert :ok = KnowledgeGraphStore.save_graph_tainted(agent_id, graph, source_taint)

    Agent.update(control, &%{&1 | armed: true})

    assert {:error, :outcome_unknown} =
             KnowledgeGraphStore.consolidate(
               agent_id,
               "ambiguous_maintenance",
               :basic,
               prune_threshold: 0.1
             )

    restart_child(KnowledgeGraphStore)

    assert {:ok, pending_effect} = KnowledgeGraphStore.pending_maintenance_effect(agent_id)
    assert pending_effect.operation_id == "ambiguous_maintenance"
    assert [pending_entry] = pending_effect.archive_entries
    assert pending_entry.taint == source_taint
    assert pending_entry.provenance_status == :verified

    revision_after_commit = authoritative_revision(agent_id)

    assert {:ok, _graph, replayed_effect} =
             KnowledgeGraphStore.consolidate(
               agent_id,
               "ambiguous_maintenance",
               :basic,
               prune_threshold: 0.1
             )

    assert replayed_effect.replayed
    assert replayed_effect.archive_entries == pending_effect.archive_entries
    assert authoritative_revision(agent_id) == revision_after_commit

    assert :ok =
             Events.archive_knowledge_once(
               agent_id,
               pending_entry,
               pending_effect.occurred_at
             )

    assert :ok =
             Events.archive_knowledge_once(
               agent_id,
               pending_entry,
               pending_effect.occurred_at
             )

    assert {:ok, [archive_event]} = Events.get_by_type(agent_id, :knowledge_archived)
    assert archive_event.data["provenance_status"] == "verified"

    assert {:ok, archive_envelope} =
             TaintEnvelope.verify(
               archive_event.data["archive"],
               pending_entry.archive_payload
             )

    assert archive_envelope.taint == source_taint

    assert {:ok, before_ack} = KnowledgeGraphStore.get_snapshot(agent_id)

    assert :ok =
             KnowledgeGraphStore.acknowledge_maintenance_effect(
               agent_id,
               "ambiguous_maintenance"
             )

    assert {:ok, after_ack} = KnowledgeGraphStore.get_snapshot(agent_id)
    assert after_ack.base == before_ack.base
    assert after_ack.aggregate == before_ack.aggregate
    assert after_ack.maintenance_effects == %{}
    assert {:ok, nil} = KnowledgeGraphStore.pending_maintenance_effect(agent_id)

    ack_revision = authoritative_revision(agent_id)

    assert :ok =
             KnowledgeGraphStore.acknowledge_maintenance_effect(
               agent_id,
               "ambiguous_maintenance"
             )

    assert authoritative_revision(agent_id) == ack_revision
    assert {:ok, [_archive_event]} = Events.get_by_type(agent_id, :knowledge_archived)
  end

  test "expired queued mutation cannot start after a delayed authoritative call", %{
    agent_id: agent_id
  } do
    stop_supervised!(BufferedStore)
    backend_name = unique_name(:kg_delayed_backend)
    control = unique_name(:kg_delayed_control)
    test_pid = self()

    start_supervised!({Arbor.Persistence.QueryableStore.ETS, name: backend_name})

    start_supervised!(%{
      id: control,
      start:
        {Agent, :start_link,
         [
           fn -> %{delay: false, delay_ms: 100, test_pid: test_pid, calls: 0} end,
           [name: control]
         ]}
    })

    start_supervised!(
      {BufferedStore,
       name: @store_name,
       backend: DelayOnceBackend,
       backend_opts: [control: control],
       collection: backend_name,
       write_mode: :sync}
    )

    assert :ok =
             KnowledgeGraphStore.save_graph(
               agent_id,
               KnowledgeGraph.new(agent_id, auto_embed: false)
             )

    Agent.update(control, &%{&1 | delay: true})

    first =
      Task.async(fn ->
        KnowledgeGraphStore.add_node(agent_id, "first_delayed", %{
          type: :fact,
          content: "first",
          skip_dedup: true
        })
      end)

    assert_receive :knowledge_graph_cas_delayed, 1_000

    assert {:ok, queued_operation} =
             Operation.add_node("expired_queued", %{
               type: :fact,
               content: "must not commit",
               skip_dedup: true
             })

    deadline = System.monotonic_time(:millisecond) + 10

    queued =
      Task.async(fn ->
        GenServer.call(
          KnowledgeGraphStore,
          {:operate, agent_id, queued_operation, Codec.missing_taint(), deadline},
          :infinity
        )
      end)

    assert {:ok, first_id} = Task.await(first, 2_000)
    assert {:error, :request_expired} = Task.await(queued, 2_000)
    assert {:ok, final} = KnowledgeGraphStore.get_graph(agent_id)
    assert Map.keys(final.nodes) == [first_id]
    assert Agent.get(control, & &1.calls) == 2
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

  test "ambiguous committed delete evicts graph and provenance before reconciliation", %{
    agent_id: agent_id
  } do
    stop_supervised!(BufferedStore)
    backend_name = unique_name(:kg_delete_ambiguity_backend)
    control = unique_name(:kg_delete_ambiguity_control)

    start_supervised!({Arbor.Persistence.QueryableStore.ETS, name: backend_name})

    start_supervised!(%{
      id: control,
      start: {Agent, :start_link, [fn -> %{armed: true, calls: 0} end, [name: control]]}
    })

    start_supervised!(
      {BufferedStore,
       name: @store_name,
       backend: PostDeleteAmbiguityBackend,
       backend_opts: [control: control],
       collection: backend_name,
       write_mode: :sync}
    )

    graph = graph_with_node(agent_id, "delete-ambiguous", "delete exactly once")
    assert :ok = KnowledgeGraphStore.save_graph(agent_id, graph)
    assert_projection_present(agent_id)

    assert {:error, :outcome_unknown} = KnowledgeGraphStore.delete_graph(agent_id)
    assert_projection_empty(agent_id)
    assert %{armed: false, calls: 1} = Agent.get(control, & &1)

    assert {:error, :not_found} =
             Arbor.Persistence.QueryableStore.ETS.get(
               "knowledge_graph:#{agent_id}",
               name: backend_name
             )
  end

  defp authoritative_replacement(observed, wrapper, taint) do
    assert {:ok, envelope} = Arbor.Signals.Taint.bind_durable_provenance(wrapper, taint)
    metadata = Map.put(observed.metadata, "taint", envelope)
    Record.update(observed, wrapper, metadata: metadata)
  end

  defp authoritative_revision(agent_id) do
    assert {:ok, %TaintedValue{}, _status, %Record{revision: revision}, _location} =
             MemoryStore.load_tainted_authoritative_with_status("knowledge_graph", agent_id)

    revision
  end

  defp assert_projection_present(agent_id) do
    assert [{^agent_id, _graph}] = :ets.lookup(@graph_ets, agent_id)
    assert {:ok, [_]} = Provenance.list_item_ids(:knowledge_graph_base, agent_id)
    assert {:ok, [_]} = Provenance.list_item_ids(:knowledge_graph_aggregate, agent_id)
    assert {:ok, [_ | _]} = Provenance.list_item_ids(:knowledge_node, agent_id)
  end

  defp assert_projection_empty(agent_id) do
    assert [] = :ets.lookup(@graph_ets, agent_id)

    Enum.each(@projection_domains, fn domain ->
      assert {:ok, []} = Provenance.list_item_ids(domain, agent_id)
    end)
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

  defp hostile_taint(source) do
    %Taint{
      level: :hostile,
      sensitivity: :restricted,
      sanitizations: 0,
      confidence: :unverified,
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
