defmodule Arbor.Memory.WorkingMemoryContentCleanupTest do
  @moduledoc """
  Content-only WorkingMemoryStore cleanup primitives (VP-05D2C3I0C1).
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.{MemoryStore, Provenance, WorkingMemory, WorkingMemoryStore}
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0C1"
  @store_name :arbor_memory_durable
  @ets_table :arbor_working_memory
  @timestamp ~U[2026-08-04 12:00:00Z]

  setup do
    start_supervised!({BufferedStore, name: @store_name, backend: nil, write_mode: :sync})

    uid = System.unique_integer([:positive])
    target = "agent_a_#{uid}"
    child = "agent_a_#{uid}_child"
    survivor = "agent_b_#{uid}"

    for agent <- [target, child, survivor] do
      _ = WorkingMemoryStore.delete_working_memory(agent)
      _ = Provenance.delete_agent(agent)
    end

    on_exit(fn ->
      for agent <- [target, child, survivor] do
        _ = WorkingMemoryStore.delete_working_memory(agent)
        _ = Provenance.delete_agent(agent)
      end
    end)

    %{target: target, child: child, survivor: survivor}
  end

  test "delete_agent_content removes durable and ETS content, keeps sidecars", %{
    target: target,
    child: child,
    survivor: survivor
  } do
    taint = taint(:trusted, "wm_content_cleanup")

    target_wm = put_thought(new_wm(target), "t1", "target thought")
    child_wm = put_thought(new_wm(child), "c1", "child thought")
    survivor_wm = put_thought(new_wm(survivor), "s1", "survivor thought")

    assert :ok = WorkingMemoryStore.save_working_memory_tainted(target, target_wm, taint)
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(child, child_wm, taint)
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(survivor, survivor_wm, taint)

    assert {:ok, thought_ids_before} =
             Provenance.list_item_ids(:working_memory_thought, target)

    assert "t1" in thought_ids_before
    assert {:ok, false} = WorkingMemoryStore.agent_content_absent?(target)

    assert :ok = WorkingMemoryStore.delete_agent_content(target)
    assert {:ok, true} = WorkingMemoryStore.agent_content_absent?(target)
    assert :ok = WorkingMemoryStore.delete_agent_content(target)
    assert {:ok, true} = WorkingMemoryStore.agent_content_absent?(target)

    # Prove content gone without rehydrate paths that may rewrite live labels.
    assert [] = :ets.lookup(@ets_table, target)

    assert {:error, :not_found} =
             MemoryStore.load_tainted_authoritative_with_status("working_memory", target)

    assert %WorkingMemory{recent_thoughts: [%{id: "c1"}]} =
             WorkingMemoryStore.get_working_memory(child)

    assert %WorkingMemory{recent_thoughts: [%{id: "s1"}]} =
             WorkingMemoryStore.get_working_memory(survivor)

    assert {:ok, false} = WorkingMemoryStore.agent_content_absent?(child)

    assert {:ok, ^thought_ids_before} =
             Provenance.list_item_ids(:working_memory_thought, target)

    assert {:ok, aggregate_ids} =
             Provenance.list_item_ids(:working_memory_aggregate, target)

    assert "aggregate" in aggregate_ids

    hostile_payload = %{"content" => "hostile"}
    hostile = taint(:hostile, "hostile_wm")

    assert :ok =
             Provenance.put(
               :working_memory_thought,
               target,
               "hostile-thought",
               hostile_payload,
               hostile
             )

    assert :ok = WorkingMemoryStore.delete_agent_content(target)

    assert {:ok, ^hostile, :verified} =
             Provenance.resolve(
               :working_memory_thought,
               target,
               "hostile-thought",
               hostile_payload
             )
  end

  test "invalid agent id fails closed" do
    assert {:error, {:working_memory_store, :invalid_agent_id}} =
             WorkingMemoryStore.delete_agent_content("")

    assert {:error, {:working_memory_store, :invalid_agent_id}} =
             WorkingMemoryStore.agent_content_absent?(String.duplicate("z", 300))
  end

  test "compatibility delete_working_memory still purges sidecars", %{target: target} do
    taint = taint(:trusted, "wm_clear_compat")
    wm = put_thought(new_wm(target), "clear-me", "clear me")
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(target, wm, taint)
    assert {:ok, ids} = Provenance.list_item_ids(:working_memory_thought, target)
    assert "clear-me" in ids

    assert :ok = WorkingMemoryStore.delete_working_memory(target)
    assert {:ok, after_ids} = Provenance.list_item_ids(:working_memory_thought, target)
    refute "clear-me" in after_ids
  end

  defp new_wm(agent_id), do: WorkingMemory.new(agent_id, rebuild_from_signals: false)

  defp put_thought(wm, id, content) do
    thought = %{
      id: id,
      content: content,
      timestamp: @timestamp,
      cached_tokens: 1,
      referenced_date: nil
    }

    %{wm | recent_thoughts: [thought]}
  end

  defp taint(level, source) do
    {:ok, taint} =
      Taint.new(%{
        level: level,
        sensitivity: :internal,
        sanitizations: 0,
        confidence: :verified,
        source: source,
        chain: []
      })

    taint
  end
end
