defmodule Arbor.Memory.KnowledgeGraphContentCleanupTest do
  @moduledoc """
  Content-only KnowledgeGraphStore cleanup primitives (VP-05D2C3I0C1).
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.{KnowledgeGraph, KnowledgeGraphStore, MemoryStore, Provenance}
  alias Arbor.Memory.Test.DurableGraphAuthority

  require Supervisor

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0C1"
  @graph_ets :arbor_memory_graphs
  @projection_domains [
    :knowledge_graph_base,
    :knowledge_graph_aggregate,
    :knowledge_node,
    :knowledge_pending_fact,
    :knowledge_pending_learning,
    :knowledge_maintenance_effect
  ]

  @cleanup_errors [
    :invalid_graph,
    :store_unavailable,
    :outcome_unknown,
    :conflict,
    :invalid_provenance,
    :graph_limit_exceeded,
    :request_expired
  ]

  setup do
    DurableGraphAuthority.start!()
    ensure_kg!()
    ensure_provenance!()

    uid = System.unique_integer([:positive])
    target = "agent_a_#{uid}"
    child = "agent_a_#{uid}_child"
    survivor = "agent_b_#{uid}"

    for agent <- [target, child, survivor] do
      _ = KnowledgeGraphStore.delete_graph(agent)
      _ = Provenance.delete_agent(agent)
    end

    on_exit(fn ->
      ensure_provenance!()
      ensure_kg!()

      # Sidecar cleanup is independent of durable availability.
      for agent <- [target, child, survivor] do
        _ = Provenance.delete_agent(agent)
      end

      for agent <- [target, child, survivor] do
        _ = KnowledgeGraphStore.delete_graph(agent)
        :ets.delete(@graph_ets, agent)
      end
    end)

    %{target: target, child: child, survivor: survivor}
  end

  test "delete_agent_content removes durable/projection/deferred and retains provenance", %{
    target: target,
    child: child,
    survivor: survivor
  } do
    taint = taint(:trusted, :internal, "kg_content_cleanup")

    target_graph = graph_with_node(target, "n_target", "target node")
    child_graph = graph_with_node(child, "n_child", "child node")
    survivor_graph = graph_with_node(survivor, "n_surv", "survivor node")

    assert :ok = KnowledgeGraphStore.save_graph_tainted(target, target_graph, taint)
    assert :ok = KnowledgeGraphStore.save_graph_tainted(child, child_graph, taint)
    assert :ok = KnowledgeGraphStore.save_graph_tainted(survivor, survivor_graph, taint)

    assert {:ok, node_ids_before} = Provenance.list_item_ids(:knowledge_node, target)
    assert "n_target" in node_ids_before
    assert {:ok, false} = KnowledgeGraphStore.agent_content_absent?(target)

    assert :ok = KnowledgeGraphStore.delete_agent_content(target)
    assert {:ok, true} = KnowledgeGraphStore.agent_content_absent?(target)
    assert :ok = KnowledgeGraphStore.delete_agent_content(target)
    assert {:ok, true} = KnowledgeGraphStore.agent_content_absent?(target)

    assert [] = :ets.lookup(@graph_ets, target)

    assert {:error, :not_found} =
             MemoryStore.load_tainted_authoritative_with_status("knowledge_graph", target)

    assert {:ok, child_loaded} = KnowledgeGraphStore.get_graph(child)
    assert Map.has_key?(child_loaded.nodes, "n_child")
    assert {:ok, survivor_loaded} = KnowledgeGraphStore.get_graph(survivor)
    assert Map.has_key?(survivor_loaded.nodes, "n_surv")
    assert {:ok, false} = KnowledgeGraphStore.agent_content_absent?(child)

    assert {:ok, ^node_ids_before} = Provenance.list_item_ids(:knowledge_node, target)

    for domain <- @projection_domains do
      assert {:ok, _ids} = Provenance.list_item_ids(domain, target)
    end

    assert {:ok, aggregate_ids} =
             Provenance.list_item_ids(:knowledge_graph_aggregate, target)

    assert "aggregate" in aggregate_ids

    hostile_payload = %{"node" => "hostile"}
    hostile = taint(:hostile, :restricted, "hostile_kg")

    assert :ok =
             Provenance.put(:knowledge_node, target, "hostile-node", hostile_payload, hostile)

    assert :ok = KnowledgeGraphStore.delete_agent_content(target)

    assert {:ok, ^hostile, :verified} =
             Provenance.resolve(:knowledge_node, target, "hostile-node", hostile_payload)
  end

  test "public cleanup disarms real pending; stale converge keeps provenance", %{
    target: target
  } do
    taint = taint(:trusted, :internal, "kg_stale_converge")
    graph = graph_with_node(target, "n_stale", "stale converge node")
    assert :ok = KnowledgeGraphStore.save_graph_tainted(target, graph, taint)
    assert {:ok, node_ids_before} = Provenance.list_item_ids(:knowledge_node, target)

    # save_graph_tainted only initializes an absent graph; arm pending via a
    # real existing-graph mutation while Provenance is temporarily unregistered.
    attempt =
      with_provenance_unregistered(fn ->
        op_id = "op_arm_#{System.unique_integer([:positive])}"

        assert {:ok, _node_id} =
                 KnowledgeGraphStore.add_node_tainted(
                   target,
                   op_id,
                   %{type: :fact, content: "arm pending", skip_dedup: true},
                   taint
                 )

        assert Map.has_key?(:sys.get_state(KnowledgeGraphStore).pending_projection, target)
        Map.fetch!(:sys.get_state(KnowledgeGraphStore).pending_projection, target)
      end)

    assert :ok = KnowledgeGraphStore.delete_agent_content(target)
    refute Map.has_key?(:sys.get_state(KnowledgeGraphStore).pending_projection, target)

    pid = Process.whereis(KnowledgeGraphStore)
    send(pid, {:converge_projection, target, attempt})
    _ = :sys.get_state(pid)

    assert {:ok, true} = KnowledgeGraphStore.agent_content_absent?(target)
    assert {:ok, ^node_ids_before} = Provenance.list_item_ids(:knowledge_node, target)
  end

  test "malformed durable with pending armed: public cleanup fails closed", %{
    target: target
  } do
    taint = taint(:trusted, :internal, "kg_malformed")
    graph = graph_with_node(target, "n_malf", "malformed")
    assert :ok = KnowledgeGraphStore.save_graph_tainted(target, graph, taint)
    assert {:ok, node_ids_before} = Provenance.list_item_ids(:knowledge_node, target)

    attempt =
      with_provenance_unregistered(fn ->
        op_id = "op_pending_#{System.unique_integer([:positive])}"

        assert {:ok, _node_id} =
                 KnowledgeGraphStore.add_node_tainted(
                   target,
                   op_id,
                   %{type: :fact, content: "pending", skip_dedup: true},
                   taint
                 )

        assert Map.has_key?(:sys.get_state(KnowledgeGraphStore).pending_projection, target)
        Map.fetch!(:sys.get_state(KnowledgeGraphStore).pending_projection, target)
      end)

    bare = %{"not" => "a_record", "agent" => target}

    assert {:ok, ^bare} =
             Arbor.Persistence.buffered_store_acknowledged_put(
               :arbor_memory_durable,
               target,
               bare
             )

    assert {:error, del_reason} = KnowledgeGraphStore.delete_agent_content(target)
    assert del_reason in @cleanup_errors
    refute Map.has_key?(:sys.get_state(KnowledgeGraphStore).pending_projection, target)

    send(Process.whereis(KnowledgeGraphStore), {:converge_projection, target, attempt})
    _ = :sys.get_state(KnowledgeGraphStore)

    assert {:ok, ^node_ids_before} = Provenance.list_item_ids(:knowledge_node, target)
  end

  test "owner process down returns closed mutation/read errors", %{target: target} do
    taint = taint(:trusted, :internal, "kg_owner_down")
    graph = graph_with_node(target, "n_od", "owner down")
    assert :ok = KnowledgeGraphStore.save_graph_tainted(target, graph, taint)
    assert {:ok, node_ids_before} = Provenance.list_item_ids(:knowledge_node, target)

    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, KnowledgeGraphStore)
    assert Process.whereis(KnowledgeGraphStore) == nil

    assert {:error, del_reason} = KnowledgeGraphStore.delete_agent_content(target)
    assert del_reason in @cleanup_errors

    assert {:error, abs_reason} = KnowledgeGraphStore.agent_content_absent?(target)
    assert abs_reason in @cleanup_errors

    ensure_kg!()
    assert {:ok, ^node_ids_before} = Provenance.list_item_ids(:knowledge_node, target)
  end

  test "cleanup public errors are always closed atoms" do
    assert {:error, del_reason} = KnowledgeGraphStore.delete_agent_content("")
    assert del_reason in @cleanup_errors
    refute del_reason == :graph_not_initialized

    assert {:error, abs_reason} =
             KnowledgeGraphStore.agent_content_absent?(String.duplicate("k", 300))

    assert abs_reason in @cleanup_errors
  end

  test "compatibility delete_graph still purges provenance", %{target: target} do
    taint = taint(:trusted, :internal, "kg_clear_compat")
    graph = graph_with_node(target, "clear-node", "clear me")
    assert :ok = KnowledgeGraphStore.save_graph_tainted(target, graph, taint)
    assert {:ok, ids} = Provenance.list_item_ids(:knowledge_node, target)
    assert "clear-node" in ids

    assert :ok = KnowledgeGraphStore.delete_graph(target)
    assert {:ok, after_ids} = Provenance.list_item_ids(:knowledge_node, target)
    refute "clear-node" in after_ids
  end

  defp graph_with_node(agent_id, node_id, content) do
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

    graph = KnowledgeGraph.new(agent_id, auto_embed: false)
    %{graph | nodes: Map.put(graph.nodes, node_id, node)}
  end

  # Induce a name-resolution projection failure while retaining exact ETS sidecars.
  # Never terminate Provenance here — that destroys its owned table.
  defp with_provenance_unregistered(fun) when is_function(fun, 0) do
    pid = Process.whereis(Provenance)
    assert is_pid(pid)
    assert Process.unregister(Provenance)

    try do
      fun.()
    after
      restore_provenance_registration!(pid)
    end
  end

  defp restore_provenance_registration!(pid) when is_pid(pid) do
    case Process.whereis(Provenance) do
      ^pid ->
        :ok

      nil ->
        unless Process.alive?(pid) do
          flunk("captured Provenance pid died while unregistered: #{inspect(pid)}")
        end

        Process.register(pid, Provenance)

      other ->
        flunk(
          "Provenance name owned by unexpected process #{inspect(other)}; " <>
            "expected captured pid #{inspect(pid)}"
        )
    end

    assert Process.whereis(Provenance) == pid
  end

  defp ensure_provenance! do
    case Process.whereis(Provenance) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          other -> flunk("failed to restart Provenance: #{inspect(other)}")
        end
    end
  end

  defp ensure_kg! do
    case Process.whereis(KnowledgeGraphStore) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, KnowledgeGraphStore) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          other -> flunk("failed to restart KnowledgeGraphStore: #{inspect(other)}")
        end
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
