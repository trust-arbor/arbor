defmodule Arbor.Memory.KnowledgeGraphContentCleanupTest do
  @moduledoc """
  Content-only KnowledgeGraphStore cleanup primitives (VP-05D2C3I0C1).
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.{KnowledgeGraph, KnowledgeGraphStore, MemoryStore, Provenance}
  alias Arbor.Memory.Test.DurableGraphAuthority

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

  setup do
    DurableGraphAuthority.start!()

    uid = System.unique_integer([:positive])
    target = "agent_a_#{uid}"
    child = "agent_a_#{uid}_child"
    survivor = "agent_b_#{uid}"

    for agent <- [target, child, survivor] do
      _ = KnowledgeGraphStore.delete_graph(agent)
      _ = Provenance.delete_agent(agent)
    end

    on_exit(fn ->
      for agent <- [target, child, survivor] do
        _ = KnowledgeGraphStore.delete_graph(agent)
        _ = Provenance.delete_agent(agent)
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

    # Prove content gone without rehydrate paths that may rewrite live labels.
    assert [] = :ets.lookup(@graph_ets, target)

    assert {:error, :not_found} =
             MemoryStore.load_tainted_authoritative_with_status("knowledge_graph", target)

    assert {:ok, child_loaded} = KnowledgeGraphStore.get_graph(child)
    assert Map.has_key?(child_loaded.nodes, "n_child")
    assert {:ok, survivor_loaded} = KnowledgeGraphStore.get_graph(survivor)
    assert Map.has_key?(survivor_loaded.nodes, "n_surv")
    assert {:ok, false} = KnowledgeGraphStore.agent_content_absent?(child)

    # Provenance retained for all projection domains after content deletion
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

  test "pending projection makes absence false until cleared", %{target: target} do
    assert {:ok, true} = KnowledgeGraphStore.agent_content_absent?(target)

    :sys.replace_state(KnowledgeGraphStore, fn state ->
      pending = Map.put(state.pending_projection, target, 1)
      %{state | pending_projection: pending}
    end)

    assert {:ok, false} = KnowledgeGraphStore.agent_content_absent?(target)
    assert :ok = KnowledgeGraphStore.delete_agent_content(target)
    assert {:ok, true} = KnowledgeGraphStore.agent_content_absent?(target)
  end

  test "stale converge_projection after content-only delete does not purge provenance", %{
    target: target
  } do
    taint = taint(:trusted, :internal, "kg_stale_converge")
    graph = graph_with_node(target, "n_stale", "stale converge node")
    assert :ok = KnowledgeGraphStore.save_graph_tainted(target, graph, taint)

    assert {:ok, node_ids_before} = Provenance.list_item_ids(:knowledge_node, target)
    assert "n_stale" in node_ids_before

    pid = Process.whereis(KnowledgeGraphStore)
    assert is_pid(pid)

    # Arm matching pending attempt, queue message, then clear pending under suspend
    # so the handler sees a mismatch after content-only cleanup.
    :sys.replace_state(pid, fn state ->
      %{state | pending_projection: Map.put(state.pending_projection, target, 1)}
    end)

    :sys.suspend(pid)
    send(pid, {:converge_projection, target, 1})

    assert :ok = MemoryStore.delete_tainted_authoritative("knowledge_graph", target)
    true = :ets.delete(@graph_ets, target)

    :sys.replace_state(pid, fn state ->
      %{state | pending_projection: Map.delete(state.pending_projection, target)}
    end)

    :sys.resume(pid)
    _ = :sys.get_state(pid)

    assert {:ok, true} = KnowledgeGraphStore.agent_content_absent?(target)
    assert {:ok, ^node_ids_before} = Provenance.list_item_ids(:knowledge_node, target)

    send(pid, {:converge_projection, target, 1})
    _ = :sys.get_state(pid)

    assert {:ok, ^node_ids_before} = Provenance.list_item_ids(:knowledge_node, target)
    assert {:ok, true} = KnowledgeGraphStore.agent_content_absent?(target)
  end

  test "invalid agent id fails closed" do
    assert {:error, :invalid_graph} = KnowledgeGraphStore.delete_agent_content("")

    assert {:error, :invalid_graph} =
             KnowledgeGraphStore.agent_content_absent?(String.duplicate("k", 300))
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
