defmodule Arbor.Memory.IntentStoreContentCleanupTest do
  @moduledoc """
  Content-only IntentStore cleanup primitives (VP-05D2C3I0C1).
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Memory.Intent
  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.{IntentStore, MemoryStore, Provenance}
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0C1"
  @store_name :arbor_memory_durable
  @ets_table :arbor_memory_intents

  setup do
    start_supervised!({BufferedStore, name: @store_name, backend: nil, write_mode: :sync})

    uid = System.unique_integer([:positive])
    target = "agent_a_#{uid}"
    child = "agent_a_#{uid}_child"
    survivor = "agent_b_#{uid}"

    for agent <- [target, child, survivor] do
      _ = IntentStore.clear(agent)
      _ = Provenance.delete_agent(agent)
    end

    on_exit(fn ->
      for agent <- [target, child, survivor] do
        _ = IntentStore.clear(agent)
        _ = Provenance.delete_agent(agent)
      end
    end)

    %{target: target, child: child, survivor: survivor}
  end

  test "delete_agent_content is exact-agent, retains provenance, and is idempotent", %{
    target: target,
    child: child,
    survivor: survivor
  } do
    taint = taint(:trusted, :internal, "intent_content_cleanup")

    target_intent = Intent.think("target intent")
    child_intent = Intent.think("child intent")
    survivor_intent = Intent.think("survivor intent")

    assert {:ok, ^target_intent} =
             IntentStore.record_intent_tainted(target, target_intent, taint)

    assert {:ok, ^child_intent} = IntentStore.record_intent_tainted(child, child_intent, taint)

    assert {:ok, ^survivor_intent} =
             IntentStore.record_intent_tainted(survivor, survivor_intent, taint)

    assert {:ok, intent_ids_before} = Provenance.list_item_ids(:intent, target)
    assert target_intent.id in intent_ids_before

    assert {:ok, false} = IntentStore.agent_content_absent?(target)

    assert :ok = IntentStore.delete_agent_content(target)
    assert {:ok, true} = IntentStore.agent_content_absent?(target)
    assert :ok = IntentStore.delete_agent_content(target)
    assert {:ok, true} = IntentStore.agent_content_absent?(target)

    # Prove content gone without compatibility reads that rehydrate/purge sidecars.
    assert [] = :ets.lookup(@ets_table, target)

    assert {:error, :not_found} =
             MemoryStore.load_tainted_authoritative_with_status("intents", target)

    assert [%{id: id}] = IntentStore.recent_intents(child)
    assert id == child_intent.id
    assert [%{id: sid}] = IntentStore.recent_intents(survivor)
    assert sid == survivor_intent.id
    assert {:ok, false} = IntentStore.agent_content_absent?(child)

    # Provenance retained after content deletion (before any rehydrate path)
    assert {:ok, ^intent_ids_before} = Provenance.list_item_ids(:intent, target)

    hostile_payload = %{"id" => "hostile-intent", "text" => "x"}
    hostile = taint(:hostile, :restricted, "hostile_intent_sidecar")
    assert :ok = Provenance.put(:intent, target, "hostile-intent", hostile_payload, hostile)
    assert :ok = IntentStore.delete_agent_content(target)

    assert {:ok, ^hostile, :verified} =
             Provenance.resolve(:intent, target, "hostile-intent", hostile_payload)
  end

  test "pending projection makes absence false until cleared", %{target: target} do
    assert {:ok, true} = IntentStore.agent_content_absent?(target)

    :sys.replace_state(IntentStore, fn state ->
      pending = Map.put(state.pending_projection, target, 1)
      %{state | pending_projection: pending}
    end)

    assert {:ok, false} = IntentStore.agent_content_absent?(target)
    assert :ok = IntentStore.delete_agent_content(target)
    assert {:ok, true} = IntentStore.agent_content_absent?(target)
  end

  test "stale converge_projection after content-only delete does not purge provenance", %{
    target: target
  } do
    taint = taint(:trusted, :internal, "intent_stale_converge")
    intent = Intent.think("stale converge intent")
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(target, intent, taint)

    assert {:ok, ids_before} = Provenance.list_item_ids(:intent, target)
    assert intent.id in ids_before

    pid = Process.whereis(IntentStore)
    assert is_pid(pid)

    # Arm pending retry, then queue the converge message before deletion while
    # suspended so it cannot run until after content-only cleanup clears pending.
    :sys.replace_state(pid, fn state ->
      %{state | pending_projection: Map.put(state.pending_projection, target, 1)}
    end)

    :sys.suspend(pid)
    send(pid, {:converge_projection, target})

    # Perform content-only cleanup effects under suspension (call would block).
    assert :ok = MemoryStore.delete_tainted_authoritative("intents", target)
    true = :ets.delete(@ets_table, target)

    :sys.replace_state(pid, fn state ->
      %{state | pending_projection: Map.delete(state.pending_projection, target)}
    end)

    :sys.resume(pid)
    _ = :sys.get_state(pid)

    assert {:ok, true} = IntentStore.agent_content_absent?(target)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:intent, target)

    # Post-cleanup delivery also no-ops.
    send(pid, {:converge_projection, target})
    _ = :sys.get_state(pid)

    assert {:ok, ^ids_before} = Provenance.list_item_ids(:intent, target)
    assert {:ok, true} = IntentStore.agent_content_absent?(target)
  end

  test "invalid agent id fails closed" do
    assert {:error, :invalid_request} = IntentStore.delete_agent_content("")

    assert {:error, :invalid_request} =
             IntentStore.agent_content_absent?(String.duplicate("x", 300))
  end

  test "compatibility clear still purges provenance", %{target: target} do
    taint = taint(:trusted, :internal, "intent_clear_compat")
    intent = Intent.think("clear me")
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(target, intent, taint)
    assert {:ok, ids} = Provenance.list_item_ids(:intent, target)
    assert intent.id in ids

    assert :ok = IntentStore.clear(target)
    assert [] = IntentStore.recent_intents(target)
    assert {:ok, after_ids} = Provenance.list_item_ids(:intent, target)
    refute intent.id in after_ids
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
