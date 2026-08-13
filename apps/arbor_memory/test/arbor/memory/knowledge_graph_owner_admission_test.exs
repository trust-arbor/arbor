defmodule Arbor.Memory.KnowledgeGraphOwnerAdmissionTest do
  @moduledoc """
  KnowledgeGraphStore owner-root acknowledgement and live-upgrade tests
  (VP-05D2C3I1B1D).
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{Taint, TaintedValue}
  alias Arbor.Memory.KnowledgeGraph
  alias Arbor.Memory.KnowledgeGraphStore
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.MutationAdmission.OwnerRoots
  alias Arbor.Memory.Provenance
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B1D"

  @store_name :arbor_memory_durable
  @graph_ets :arbor_memory_graphs
  @namespace "knowledge_graph"
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
    assert {:ok, %{durability: :node_restart}} = MutationAdmission.readiness()
    :ok
  end

  test "coalesced deferred roots block drain until successful convergence" do
    agent_id = unique_agent("coal")
    taint = taint(:trusted, :internal, "kg_owner_coal")
    assert :ok = KnowledgeGraphStore.save_graph_tainted(agent_id, empty_graph(agent_id), taint)
    await_idle_roots!(agent_id)

    drain_task =
      with_provenance_unregistered(fn ->
        assert {:ok, _} = add_node!(agent_id, "first miss", taint)
        assert {:ok, _} = add_node!(agent_id, "second miss", taint)
        assert OwnerRoots.held_count(owner_roots(), agent_id) == 2
        assert Map.has_key?(:sys.get_state(KnowledgeGraphStore).pending_projection, agent_id)

        task = Task.async(fn -> MutationAdmission.drain(agent_id, timeout_ms: 5_000) end)

        assert eventually(fn ->
                 match?({:ok, %{gate: :draining}}, MutationAdmission.status(agent_id)) and
                   OwnerRoots.held_count(owner_roots(), agent_id) == 2
               end)

        task
      end)

    assert eventually(fn ->
             state = :sys.get_state(KnowledgeGraphStore)

             not Map.has_key?(state.pending_projection, agent_id) and
               OwnerRoots.held_count(owner_roots(), agent_id) == 0
           end)

    assert {:ok, _fence} = Task.await(drain_task, 5_000)
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    await_idle_roots!(agent_id)
    assert :ok = KnowledgeGraphStore.delete_agent_content(agent_id)
  end

  test "bounded exhaustion settles coalesced roots" do
    agent_id = unique_agent("exh")
    taint = taint(:trusted, :internal, "kg_owner_exh")
    assert :ok = KnowledgeGraphStore.save_graph_tainted(agent_id, empty_graph(agent_id), taint)
    await_idle_roots!(agent_id)

    with_provenance_unregistered(fn ->
      assert {:ok, _} = add_node!(agent_id, "exhaust first", taint)
      assert {:ok, _} = add_node!(agent_id, "exhaust second", taint)

      assert eventually(
               fn ->
                 state = :sys.get_state(KnowledgeGraphStore)

                 not Map.has_key?(state.pending_projection, agent_id) and
                   OwnerRoots.held_count(owner_roots(), agent_id) == 0
               end,
               160
             )
    end)

    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    await_idle_roots!(agent_id)
    assert :ok = KnowledgeGraphStore.delete_agent_content(agent_id)
  end

  test "immediate success and validation leave no root; transient backend failure retains then settles" do
    agent_id = unique_agent("imm")
    assert :ok = KnowledgeGraphStore.save_graph(agent_id, empty_graph(agent_id))
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    await_idle_roots!(agent_id)

    assert {:error, :invalid_graph} = KnowledgeGraphStore.save_graph(agent_id, :not_a_graph)
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert {:error, :invalid_graph} =
             KnowledgeGraphStore.add_node(agent_id, "bad", %{type: :not_a_type, content: "x"})

    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0

    stopped? =
      case stop_supervised(BufferedStore) do
        :ok -> true
        {:ok, _} -> true
        _ -> false
      end

    if stopped? do
      refute MemoryStore.available?()

      try do
        assert {:error, reason} =
                 KnowledgeGraphStore.add_node(agent_id, "backend_down", %{
                   type: :fact,
                   content: "backend down",
                   skip_dedup: true
                 })

        assert reason in [:store_unavailable, :outcome_unknown]
        assert OwnerRoots.held_count(owner_roots(), agent_id) >= 1
        assert Map.has_key?(:sys.get_state(KnowledgeGraphStore).pending_projection, agent_id)

        assert match?(
                 {:ok, %{active_roots: n}} when n >= 1,
                 MutationAdmission.status(agent_id)
               )
      after
        ensure_durable_store!()
      end

      await_idle_roots!(agent_id)
      assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
      refute Map.has_key?(:sys.get_state(KnowledgeGraphStore).pending_projection, agent_id)
    end

    assert :ok = KnowledgeGraphStore.delete_agent_content(agent_id)
  end

  test "failed projection retains a root before the retry timer is observable" do
    agent_id = unique_agent("timer")
    taint = taint(:trusted, :internal, "kg_owner_timer")
    assert :ok = KnowledgeGraphStore.save_graph_tainted(agent_id, empty_graph(agent_id), taint)
    await_idle_roots!(agent_id)

    with_provenance_unregistered(fn ->
      assert {:ok, _} = add_node!(agent_id, "timer arm", taint)
      state = :sys.get_state(KnowledgeGraphStore)
      assert Map.has_key?(state.pending_projection, agent_id)
      assert OwnerRoots.held_count(owner_roots(), agent_id) >= 1
      assert match?({:ok, %{active_roots: n}} when n >= 1, MutationAdmission.status(agent_id))
    end)

    assert :ok = KnowledgeGraphStore.delete_agent_content(agent_id)
  end

  test "authoritative absence on a deferred retry settles coalesced roots" do
    agent_id = unique_agent("abs")
    taint = taint(:trusted, :internal, "kg_owner_abs")
    assert :ok = KnowledgeGraphStore.save_graph_tainted(agent_id, empty_graph(agent_id), taint)
    await_idle_roots!(agent_id)

    attempt =
      with_provenance_unregistered(fn ->
        assert {:ok, _} = add_node!(agent_id, "arm absence", taint)
        assert OwnerRoots.held_count(owner_roots(), agent_id) >= 1
        Map.fetch!(:sys.get_state(KnowledgeGraphStore).pending_projection, agent_id)
      end)

    assert :ok = MemoryStore.delete_tainted_authoritative(@namespace, agent_id)
    send(Process.whereis(KnowledgeGraphStore), {:converge_projection, agent_id, attempt})
    _ = :sys.get_state(KnowledgeGraphStore)

    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    refute Map.has_key?(:sys.get_state(KnowledgeGraphStore).pending_projection, agent_id)
    await_idle_roots!(agent_id)
    assert :ok = KnowledgeGraphStore.delete_agent_content(agent_id)
  end

  test "malformed durable authority on a deferred retry settles roots" do
    agent_id = unique_agent("malf")
    taint = taint(:trusted, :internal, "kg_owner_malf")
    assert :ok = KnowledgeGraphStore.save_graph_tainted(agent_id, empty_graph(agent_id), taint)
    await_idle_roots!(agent_id)

    attempt =
      with_provenance_unregistered(fn ->
        assert {:ok, _} = add_node!(agent_id, "arm malformed", taint)
        Map.fetch!(:sys.get_state(KnowledgeGraphStore).pending_projection, agent_id)
      end)

    {:ok, %TaintedValue{taint: outer}, _status, observed, _location} =
      MemoryStore.load_tainted_authoritative_with_status(@namespace, agent_id)

    malformed = %{"not" => "a_wrapper"}

    assert {:ok, %Record{}} =
             MemoryStore.compare_and_swap_tainted(
               @namespace,
               agent_id,
               observed,
               malformed,
               taint: outer
             )

    send(Process.whereis(KnowledgeGraphStore), {:converge_projection, agent_id, attempt})
    _ = :sys.get_state(KnowledgeGraphStore)

    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    refute Map.has_key?(:sys.get_state(KnowledgeGraphStore).pending_projection, agent_id)
    await_idle_roots!(agent_id)
    assert :ok = KnowledgeGraphStore.delete_agent_content(agent_id)
  end

  test "open-gate legacy migration projects and settles its root" do
    agent_id = unique_agent("mig")
    assert :ok = seed_legacy_durable!(agent_id, "legacy open migrate")
    before = durable_snapshot!(agent_id)
    refute wrapper_shaped?(before.data)

    assert {:ok, graph} = KnowledgeGraphStore.get_graph(agent_id)
    assert graph.agent_id == agent_id
    assert [{^agent_id, _projected}] = :ets.lookup(@graph_ets, agent_id)

    after_mig = durable_snapshot!(agent_id)
    assert wrapper_shaped?(after_mig.data)
    assert after_mig.revision >= before.revision
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    refute Map.has_key?(:sys.get_state(KnowledgeGraphStore).pending_projection, agent_id)
    await_idle_roots!(agent_id)
    assert :ok = KnowledgeGraphStore.delete_agent_content(agent_id)
  end

  test "content-only cleanup disarms retries, settles roots, and retains sidecars" do
    agent_id = unique_agent("clean")
    taint = taint(:trusted, :internal, "kg_owner_clean")
    graph = graph_with_node(agent_id, "cleanup target")
    assert :ok = KnowledgeGraphStore.save_graph_tainted(agent_id, graph, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:knowledge_node, agent_id)

    with_provenance_unregistered(fn ->
      assert {:ok, _} = add_node!(agent_id, "arm cleanup", taint)
    end)

    assert OwnerRoots.held_count(owner_roots(), agent_id) > 0
    assert {:ok, false} = KnowledgeGraphStore.agent_content_absent?(agent_id)

    assert :ok = KnowledgeGraphStore.delete_agent_content(agent_id)
    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0

    state = :sys.get_state(KnowledgeGraphStore)
    refute Map.has_key?(state.pending_projection, agent_id)
    await_idle_roots!(agent_id)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:knowledge_node, agent_id)

    send(Process.whereis(KnowledgeGraphStore), {:converge_projection, agent_id, 1})
    _ = :sys.get_state(KnowledgeGraphStore)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:knowledge_node, agent_id)
    assert {:ok, true} = KnowledgeGraphStore.agent_content_absent?(agent_id)
  end

  test "owner loss returns closed errors without caller-side ETS or Provenance mutation" do
    agent_id = unique_agent("od")
    taint = taint(:trusted, :internal, "kg_owner_od")
    graph = graph_with_node(agent_id, "owner down")
    assert :ok = KnowledgeGraphStore.save_graph_tainted(agent_id, graph, taint)
    await_idle_roots!(agent_id)
    assert [{^agent_id, _}] = :ets.lookup(@graph_ets, agent_id)
    assert {:ok, ids_before} = Provenance.list_item_ids(:knowledge_node, agent_id)
    ets_before = :erlang.term_to_binary(:ets.lookup(@graph_ets, agent_id))

    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, KnowledgeGraphStore)
    assert Process.whereis(KnowledgeGraphStore) == nil

    assert {:error, :store_unavailable} = KnowledgeGraphStore.get_graph(agent_id)

    assert {:error, :outcome_unknown} =
             KnowledgeGraphStore.save_graph(agent_id, empty_graph(agent_id))

    assert {:error, :outcome_unknown} = KnowledgeGraphStore.delete_graph(agent_id)

    assert :erlang.term_to_binary(:ets.lookup(@graph_ets, agent_id)) == ets_before
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:knowledge_node, agent_id)

    ensure_kg!()
    assert :ok = KnowledgeGraphStore.delete_agent_content(agent_id)
  end

  test "format_status exposes only per-agent held counts" do
    agent_id = unique_agent("fmt")
    taint = taint(:trusted, :internal, "kg_owner_fmt")
    assert :ok = KnowledgeGraphStore.save_graph_tainted(agent_id, empty_graph(agent_id), taint)
    await_idle_roots!(agent_id)

    with_provenance_unregistered(fn ->
      assert {:ok, _} = add_node!(agent_id, "fmt arm", taint)
      dump = inspect(:sys.get_status(KnowledgeGraphStore), limit: :infinity)
      refute dump =~ "Arbor.Memory.MutationAdmission.Lease"
      refute dump =~ "%Arbor.Memory.MutationAdmission.OwnerRoots"
    end)

    assert :ok = KnowledgeGraphStore.delete_agent_content(agent_id)
  end

  test "code_change normalizes legacy state missing new fields" do
    pid = Process.whereis(KnowledgeGraphStore)
    original = :sys.get_state(pid)

    :sys.replace_state(pid, fn state ->
      state
      |> Map.delete(:owner_roots)
      |> Map.delete(:pending_projection)
    end)

    assert {:ok, normalized} = KnowledgeGraphStore.code_change(1, :sys.get_state(pid), [])
    assert %OwnerRoots{} = normalized.owner_roots
    assert normalized.pending_projection == %{}

    :sys.replace_state(pid, fn _ -> original end)
  end

  test "legacy state with an open gate acquires a fresh deferred root before repair" do
    agent_id = unique_agent("upgrade")
    taint = taint(:trusted, :internal, "kg_owner_upgrade")
    graph = graph_with_node(agent_id, "legacy open repair")
    assert :ok = KnowledgeGraphStore.save_graph_tainted(agent_id, graph, taint)
    await_idle_roots!(agent_id)

    assert true == :ets.delete(@graph_ets, agent_id)

    Enum.each(@projection_domains, fn domain ->
      assert :ok = Provenance.delete_domain_agent(domain, agent_id)
    end)

    pid = Process.whereis(KnowledgeGraphStore)

    :sys.replace_state(pid, fn state ->
      pending = Map.get(state, :pending_projection, %{})

      state
      |> Map.delete(:owner_roots)
      |> Map.put(:pending_projection, Map.put(pending, agent_id, 1))
    end)

    send(pid, {:converge_projection, agent_id, 1})
    _ = :sys.get_state(pid)

    assert eventually(fn ->
             match?([{^agent_id, _}], :ets.lookup(@graph_ets, agent_id))
           end)

    assert OwnerRoots.held_count(owner_roots(), agent_id) == 0
    await_idle_roots!(agent_id)
    assert :ok = KnowledgeGraphStore.delete_agent_content(agent_id)
  end

  test "roots and drain on one agent do not block another" do
    agent_a = unique_agent("iso_a")
    agent_b = unique_agent("iso_b")
    taint = taint(:trusted, :internal, "kg_owner_iso")

    assert :ok = KnowledgeGraphStore.save_graph_tainted(agent_a, empty_graph(agent_a), taint)
    await_idle_roots!(agent_a)
    assert {:ok, _fence} = MutationAdmission.drain(agent_a)

    assert :ok = KnowledgeGraphStore.save_graph_tainted(agent_b, empty_graph(agent_b), taint)
    assert {:ok, loaded} = KnowledgeGraphStore.get_graph(agent_b)
    assert loaded.agent_id == agent_b

    assert {:error, :store_unavailable} =
             KnowledgeGraphStore.save_graph(agent_a, empty_graph(agent_a))

    assert :ok = KnowledgeGraphStore.delete_agent_content(agent_a)
    assert :ok = KnowledgeGraphStore.delete_agent_content(agent_b)
  end

  defp owner_roots do
    case :sys.get_state(KnowledgeGraphStore) do
      %{owner_roots: %OwnerRoots{} = roots} -> roots
      _ -> OwnerRoots.new()
    end
  end

  defp unique_agent(label), do: "kg_own_#{label}_#{System.unique_integer([:positive])}"

  defp empty_graph(agent_id), do: KnowledgeGraph.new(agent_id, auto_embed: false)

  defp graph_with_node(agent_id, content) do
    graph = empty_graph(agent_id)

    assert {:ok, graph, _node_id} =
             KnowledgeGraph.add_node(graph, %{
               type: :fact,
               content: content,
               skip_dedup: true
             })

    graph
  end

  defp add_node!(agent_id, content, taint) do
    KnowledgeGraphStore.add_node_tainted(
      agent_id,
      "op_#{System.unique_integer([:positive])}",
      %{type: :fact, content: content, skip_dedup: true},
      taint
    )
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

  defp durable_snapshot!(agent_id) do
    assert {:ok, value, _status, record, _location} =
             MemoryStore.load_tainted_authoritative_with_status(@namespace, agent_id)

    %{data: value.value, revision: record.revision}
  end

  defp await_idle_roots!(agent_id) do
    assert eventually(fn ->
             match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id))
           end)
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
