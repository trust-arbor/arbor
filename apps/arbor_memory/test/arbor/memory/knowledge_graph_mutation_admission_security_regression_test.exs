defmodule Arbor.Memory.KnowledgeGraphMutationAdmissionSecurityRegressionTest do
  @moduledoc """
  Public-API security regression for KnowledgeGraphStore mutation admission.

  Uses only APIs present on the immediate parent so parent failure is
  behavioral (missing admission gate), not a compile or setup failure.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.KnowledgeGraph
  alias Arbor.Memory.KnowledgeGraphStore
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.Provenance
  alias Arbor.Memory.Test.MutationAdmissionFakeBackend, as: Fake
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B1D"
  @moduletag security_regression: true

  @store_name :arbor_memory_durable
  @graph_ets :arbor_memory_graphs
  @namespace "knowledge_graph"
  @admission_registry Arbor.Memory.MutationAdmission.Registry
  @guardian_supervisor Arbor.Memory.MutationAdmission.GuardianSupervisor
  @fake_name :kg_sec_ma_fake
  @projection_domains [
    :knowledge_graph_base,
    :knowledge_graph_aggregate,
    :knowledge_node,
    :knowledge_pending_fact,
    :knowledge_pending_learning,
    :knowledge_maintenance_effect
  ]

  setup do
    ensure_durable_store!()
    ensure_kg!()
    ensure_provenance!()
    ensure_default_admission!()
    :ok
  end

  test "post-drain save and compatibility delete are rejected with no durable, ETS, Provenance, pending, or timer effect" do
    agent_id = unique_agent("mut")
    graph = graph_with_node(agent_id, "post-drain mutation")

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert {:error, :store_unavailable} = KnowledgeGraphStore.save_graph(agent_id, graph)
    assert durable_absent?(agent_id)
    assert [] = :ets.lookup(@graph_ets, agent_id)
    assert_projection_domains_empty(agent_id)
    refute Map.has_key?(:sys.get_state(KnowledgeGraphStore).pending_projection, agent_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert {:error, :store_unavailable} = KnowledgeGraphStore.delete_graph(agent_id)
    assert durable_absent?(agent_id)
    assert [] = :ets.lookup(@graph_ets, agent_id)
    assert_projection_domains_empty(agent_id)
    refute Map.has_key?(:sys.get_state(KnowledgeGraphStore).pending_projection, agent_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  test "post-drain graph/snapshot read and explicit convergence cannot rehydrate stripped projections" do
    agent_id = unique_agent("read")
    taint = taint(:trusted, :internal, "kg_sec_read")
    graph = graph_with_node(agent_id, "seed before drain")

    assert :ok = KnowledgeGraphStore.save_graph_tainted(agent_id, graph, taint)
    assert durable_present?(agent_id)
    await_idle_roots!(agent_id)
    before = durable_bytes_and_revision!(agent_id)

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    strip_projection!(agent_id)

    assert {:error, :store_unavailable} = KnowledgeGraphStore.get_graph(agent_id)
    assert {:error, :store_unavailable} = KnowledgeGraphStore.get_snapshot(agent_id)
    assert {:error, :store_unavailable} = KnowledgeGraphStore.converge_projection(agent_id)
    assert [] = :ets.lookup(@graph_ets, agent_id)
    assert_projection_domains_empty(agent_id)
    assert durable_bytes_and_revision!(agent_id) == before
    assert :ok = KnowledgeGraphStore.delete_agent_content(agent_id)
  end

  test "post-drain read cannot perform a legacy migration CAS or projection" do
    agent_id = unique_agent("legacy_mig")
    assert :ok = seed_legacy_durable!(agent_id, "legacy before drain")
    before = durable_bytes_and_revision!(agent_id)
    refute wrapper_shaped?(elem(before, 0))

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert {:error, :store_unavailable} = KnowledgeGraphStore.get_graph(agent_id)
    assert [] = :ets.lookup(@graph_ets, agent_id)
    assert_projection_domains_empty(agent_id)
    assert durable_bytes_and_revision!(agent_id) == before
    assert :ok = KnowledgeGraphStore.delete_agent_content(agent_id)
  end

  test "a retained deferred root does not admit a later public request after drain starts" do
    agent_id = unique_agent("reuse")
    taint = taint(:trusted, :internal, "kg_sec_reuse")
    graph = graph_with_node(agent_id, "arm deferred")
    assert :ok = KnowledgeGraphStore.save_graph_tainted(agent_id, graph, taint)
    await_idle_roots!(agent_id)

    drain_task =
      with_provenance_unregistered(fn ->
        assert {:ok, _node_id} =
                 KnowledgeGraphStore.add_node_tainted(
                   agent_id,
                   "op_arm_#{System.unique_integer([:positive])}",
                   %{type: :fact, content: "arm pending", skip_dedup: true},
                   taint
                 )

        task = Task.async(fn -> MutationAdmission.drain(agent_id, timeout_ms: 10_000) end)

        assert eventually(fn ->
                 match?({:ok, %{gate: :draining}}, MutationAdmission.status(agent_id))
               end)

        later = graph_with_node(agent_id, "later write must not land")
        assert {:error, :store_unavailable} = KnowledgeGraphStore.save_graph(agent_id, later)

        assert {:error, :store_unavailable} =
                 KnowledgeGraphStore.add_node(
                   agent_id,
                   "op_later_#{System.unique_integer([:positive])}",
                   %{type: :fact, content: "later node", skip_dedup: true}
                 )

        refute_live_content(agent_id, "later write must not land")
        refute_live_content(agent_id, "later node")
        task
      end)

    assert :ok = KnowledgeGraphStore.delete_agent_content(agent_id)
    assert {:ok, _fence} = Task.await(drain_task, 10_000)
  end

  test "legacy queued convergence without a retained root cannot project after drain" do
    agent_id = unique_agent("legacy")
    taint = taint(:trusted, :internal, "kg_sec_legacy")
    graph = graph_with_node(agent_id, "legacy converge")
    assert :ok = KnowledgeGraphStore.save_graph_tainted(agent_id, graph, taint)
    assert durable_present?(agent_id)
    await_idle_roots!(agent_id)
    before = durable_bytes_and_revision!(agent_id)

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    strip_projection!(agent_id)

    pid = Process.whereis(KnowledgeGraphStore)

    :sys.replace_state(pid, fn state ->
      pending = Map.get(state, :pending_projection, %{})

      state
      |> Map.delete(:owner_roots)
      |> Map.put(:pending_projection, Map.put(pending, agent_id, 1))
    end)

    send(pid, {:converge_projection, agent_id, 1})
    _ = :sys.get_state(pid)

    assert [] = :ets.lookup(@graph_ets, agent_id)
    assert_projection_domains_empty(agent_id)
    assert durable_bytes_and_revision!(agent_id) == before
    assert :ok = KnowledgeGraphStore.delete_agent_content(agent_id)
  end

  defp unique_agent(label), do: "kg_sec_#{label}_#{System.unique_integer([:positive])}"

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

  defp seed_legacy_durable!(agent_id, content) do
    legacy = KnowledgeGraph.to_map(graph_with_node(agent_id, content))
    key = "knowledge_graph:#{agent_id}"
    record = Record.new(key, legacy, id: "memory:#{key}", metadata: %{})

    case BufferedStore.put(key, record, name: @store_name) do
      :ok -> :ok
      other -> flunk("failed to seed legacy graph: #{inspect(other)}")
    end
  end

  defp wrapper_shaped?(data) when is_map(data),
    do: data["kind"] == "arbor_knowledge_graph" or data[:kind] == "arbor_knowledge_graph"

  defp wrapper_shaped?(_data), do: false

  defp durable_present?(agent_id) do
    match?(
      {:ok, _value, _status, _record, _location},
      MemoryStore.load_tainted_authoritative_with_status(@namespace, agent_id)
    )
  end

  defp durable_absent?(agent_id) do
    match?(
      {:error, :not_found},
      MemoryStore.load_tainted_authoritative_with_status(@namespace, agent_id)
    )
  end

  defp durable_bytes_and_revision!(agent_id) do
    assert {:ok, value, _status, record, _location} =
             MemoryStore.load_tainted_authoritative_with_status(@namespace, agent_id)

    {value.value, record.revision, :erlang.term_to_binary(record.data)}
  end

  defp strip_projection!(agent_id) do
    _ = :ets.delete(@graph_ets, agent_id)

    Enum.each(@projection_domains, fn domain ->
      assert :ok = Provenance.delete_domain_agent(domain, agent_id)
    end)
  end

  defp assert_projection_domains_empty(agent_id) do
    Enum.each(@projection_domains, fn domain ->
      assert {:ok, []} = Provenance.list_item_ids(domain, agent_id)
    end)
  end

  defp refute_live_content(agent_id, content) do
    case :ets.lookup(@graph_ets, agent_id) do
      [] ->
        :ok

      [{^agent_id, graph}] ->
        refute Enum.any?(Map.values(graph.nodes), &(&1.content == content))
    end
  end

  defp await_idle_roots!(agent_id) do
    assert eventually(
             fn ->
               match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id))
             end,
             80
           )
  end

  defp ensure_default_admission! do
    case MutationAdmission.readiness() do
      {:ok, %{durability: :node_restart}} ->
        :ok

      _ ->
        start_parent_admission_stack!()
    end
  end

  defp start_parent_admission_stack! do
    unless Process.whereis(@fake_name) do
      {:ok, _} = Fake.start_link(agent_name: @fake_name)
    end

    unless Process.whereis(@admission_registry) do
      start_supervised!({Registry, keys: :unique, name: @admission_registry})
    end

    unless Process.whereis(@guardian_supervisor) do
      start_supervised!({@guardian_supervisor, []})
    end

    unless Process.whereis(MutationAdmission) do
      start_supervised!(
        {MutationAdmission,
         [
           target: %{
             namespace: :memory_mutation_admission,
             backend: Fake,
             opts: [agent_name: @fake_name]
           }
         ]}
      )
    end

    assert {:ok, %{durability: :node_restart}} = MutationAdmission.readiness()
  end

  defp ensure_durable_store! do
    case Process.whereis(@store_name) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        assert is_pid(
                 start_supervised!(
                   {BufferedStore, name: @store_name, backend: nil, write_mode: :sync}
                 )
               )

        :ok
    end

    assert MemoryStore.available?()
  end

  defp ensure_kg! do
    case Process.whereis(KnowledgeGraphStore) do
      pid when is_pid(pid) ->
        pid

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, KnowledgeGraphStore) do
          {:ok, pid} when is_pid(pid) -> pid
          {:error, {:already_started, pid}} when is_pid(pid) -> pid
          other -> flunk("failed to restart KnowledgeGraphStore: #{inspect(other)}")
        end
    end
  end

  defp ensure_provenance! do
    case Process.whereis(Provenance) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          other -> flunk("failed to restart Provenance: #{inspect(other)}")
        end
    end
  end

  defp with_provenance_unregistered(fun) when is_function(fun, 0) do
    pid = Process.whereis(Provenance)
    assert is_pid(pid)
    assert Process.unregister(Provenance)

    try do
      fun.()
    after
      case Process.whereis(Provenance) do
        ^pid -> :ok
        nil -> Process.register(pid, Provenance)
        other -> flunk("Provenance name owned by #{inspect(other)}")
      end
    end
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(fun, 0), do: fun.() || flunk("condition not met")

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp taint(level, sensitivity, source) do
    {:ok, taint} =
      Taint.new(%{
        level: level,
        sensitivity: sensitivity,
        sanitizations: 0,
        confidence: :verified,
        source: source,
        chain: []
      })

    taint
  end
end
