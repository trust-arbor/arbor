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
    ensure_durable_store!()

    uid = System.unique_integer([:positive])
    target = "agent_a_#{uid}"
    child = "agent_a_#{uid}_child"
    survivor = "agent_b_#{uid}"

    for agent <- [target, child, survivor] do
      _ = WorkingMemoryStore.delete_working_memory(agent)
      _ = Provenance.delete_agent(agent)
    end

    on_exit(fn ->
      # Never call start_supervised!/2 from on_exit — ExUnit already stopped
      # supervised children. Restore durable store only from the test process.
      # Sidecar cleanup is independent of durable availability.
      for agent <- [target, child, survivor] do
        _ = Provenance.delete_agent(agent)
      end

      if MemoryStore.available?() do
        for agent <- [target, child, survivor] do
          _ = WorkingMemoryStore.delete_working_memory(agent)
        end
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

  @delete_errors [
    :invalid_agent_id,
    :delete_failed,
    :outcome_unknown,
    :durable_unavailable,
    :insufficient_durability,
    :invalid_record,
    :ambiguous_record,
    :conflict,
    :inventory_limit_exceeded,
    :transition_busy,
    :transition_failed,
    :ets_failed,
    :store_unavailable
  ]

  @absence_errors [
    :invalid_agent_id,
    :absence_uncertain,
    :durable_unavailable,
    :insufficient_durability,
    :invalid_record,
    :ambiguous_record,
    :transition_busy,
    :transition_failed,
    :store_unavailable
  ]

  test "invalid agent id fails closed with flat atoms" do
    assert {:error, :invalid_agent_id} = WorkingMemoryStore.delete_agent_content("")

    assert {:error, :invalid_agent_id} =
             WorkingMemoryStore.agent_content_absent?(String.duplicate("z", 300))
  end

  test "cleanup public errors are always closed atoms" do
    assert {:error, del_reason} = WorkingMemoryStore.delete_agent_content("")
    assert del_reason in @delete_errors
    refute is_tuple(del_reason)

    assert {:error, abs_reason} = WorkingMemoryStore.agent_content_absent?("")
    assert abs_reason in @absence_errors
    refute is_tuple(abs_reason)
  end

  test "malformed bare durable row fails closed without success or absence", %{target: target} do
    taint = taint(:trusted, "wm_bare_malformed")
    wm = put_thought(new_wm(target), "t1", "thought")
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(target, wm, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:working_memory_thought, target)

    # Remove namespaced authority, leave only a non-Record bare key.
    assert :ok = MemoryStore.delete_tainted_authoritative("working_memory", target)
    true = :ets.delete(@ets_table, target)

    bare = %{"not" => "a_record", "agent" => target}

    assert {:ok, ^bare} =
             Arbor.Persistence.buffered_store_acknowledged_put(@store_name, target, bare)

    # Shared MemoryStore bare classification must fail closed with exact reviewed atoms.
    assert {:error, :invalid_record} = WorkingMemoryStore.delete_agent_content(target)

    # Never report true absence while malformed bare authority remains.
    assert {:error, abs_reason} = WorkingMemoryStore.agent_content_absent?(target)

    assert abs_reason in [
             :invalid_record,
             :absence_uncertain,
             :store_unavailable,
             :durable_unavailable
           ]

    refute abs_reason == :not_found
    refute is_tuple(abs_reason)

    assert {:ok, ^bare} =
             Arbor.Persistence.buffered_store_authoritative_get(@store_name, target)

    assert {:ok, ^ids_before} = Provenance.list_item_ids(:working_memory_thought, target)
  end

  test "public cleanup when durable store is stopped returns closed flat atoms", %{
    target: target
  } do
    taint = taint(:trusted, "wm_store_stopped")
    wm = put_thought(new_wm(target), "stop-me", "store stopped thought")
    assert :ok = WorkingMemoryStore.save_working_memory_tainted(target, wm, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:working_memory_thought, target)
    assert "stop-me" in ids_before

    # Deterministic ExUnit stop (not Process.exit/:kill).
    assert :ok = stop_supervised(BufferedStore)
    refute MemoryStore.available?()

    assert {:error, del_reason} = WorkingMemoryStore.delete_agent_content(target)
    assert del_reason in @delete_errors
    refute is_tuple(del_reason)
    refute del_reason == :not_found

    assert {:error, abs_reason} = WorkingMemoryStore.agent_content_absent?(target)
    assert abs_reason in @absence_errors
    refute is_tuple(abs_reason)
    refute abs_reason == :not_found

    ensure_durable_store!()
    assert MemoryStore.available?()
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:working_memory_thought, target)
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
