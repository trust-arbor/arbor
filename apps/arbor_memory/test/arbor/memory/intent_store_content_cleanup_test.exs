defmodule Arbor.Memory.IntentStoreContentCleanupTest do
  @moduledoc """
  Content-only IntentStore cleanup primitives (VP-05D2C3I0C1).
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Memory.Intent
  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.{IntentStore, MemoryStore, Provenance}
  alias Arbor.Persistence.BufferedStore

  require Supervisor

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0C1"
  @store_name :arbor_memory_durable
  @ets_table :arbor_memory_intents

  @delete_errors [
    :invalid_request,
    :store_unavailable,
    :commit_outcome_unknown,
    :projection_failed
  ]

  @absence_errors [
    :invalid_request,
    :store_unavailable,
    :absence_uncertain
  ]

  setup do
    ensure_durable_store!()
    ensure_intent_store!()
    ensure_provenance!()

    uid = System.unique_integer([:positive])
    target = "agent_a_#{uid}"
    child = "agent_a_#{uid}_child"
    survivor = "agent_b_#{uid}"

    for agent <- [target, child, survivor] do
      _ = IntentStore.clear(agent)
      _ = Provenance.delete_agent(agent)
    end

    on_exit(fn ->
      # Never call start_supervised!/2 from on_exit — ExUnit already stopped
      # supervised children. Restore durable store only from the test process.
      ensure_provenance!()
      ensure_intent_store!()

      # Sidecar cleanup is independent of durable availability.
      for agent <- [target, child, survivor] do
        _ = Provenance.delete_agent(agent)
      end

      if MemoryStore.available?() do
        for agent <- [target, child, survivor] do
          _ = IntentStore.clear(agent)
        end
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

    assert [] = :ets.lookup(@ets_table, target)

    assert {:error, :not_found} =
             MemoryStore.load_tainted_authoritative_with_status("intents", target)

    assert [%{id: id}] = IntentStore.recent_intents(child)
    assert id == child_intent.id
    assert [%{id: sid}] = IntentStore.recent_intents(survivor)
    assert sid == survivor_intent.id
    assert {:ok, false} = IntentStore.agent_content_absent?(child)

    assert {:ok, ^intent_ids_before} = Provenance.list_item_ids(:intent, target)

    hostile_payload = %{"id" => "hostile-intent", "text" => "x"}
    hostile = taint(:hostile, :restricted, "hostile_intent_sidecar")
    assert :ok = Provenance.put(:intent, target, "hostile-intent", hostile_payload, hostile)
    assert :ok = IntentStore.delete_agent_content(target)

    assert {:ok, ^hostile, :verified} =
             Provenance.resolve(:intent, target, "hostile-intent", hostile_payload)
  end

  test "public cleanup disarms real pending; stale converge keeps provenance", %{target: target} do
    taint = taint(:trusted, :internal, "intent_stale_converge")
    intent = Intent.think("stale converge intent")
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(target, intent, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:intent, target)

    # Real projection miss arms pending_projection (no manual pre-clear).
    # Unregister (do not terminate) Provenance so ETS sidecars survive.
    with_provenance_unregistered(fn ->
      extra = Intent.think("arm pending while sidecar down")
      assert {:ok, ^extra} = IntentStore.record_intent_tainted(target, extra, taint)
      assert Map.has_key?(:sys.get_state(IntentStore).pending_projection, target)
    end)

    assert :ok = IntentStore.delete_agent_content(target)
    refute Map.has_key?(:sys.get_state(IntentStore).pending_projection, target)

    pid = Process.whereis(IntentStore)
    send(pid, {:converge_projection, target})
    _ = :sys.get_state(pid)

    assert {:ok, true} = IntentStore.agent_content_absent?(target)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:intent, target)
  end

  test "public cleanup with malformed durable authority keeps pending disarmed and provenance",
       %{
         target: target
       } do
    taint = taint(:trusted, :internal, "intent_durable_fail")
    intent = Intent.think("durable fail intent")
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(target, intent, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:intent, target)

    with_provenance_unregistered(fn ->
      extra = Intent.think("pending before durable fail")
      assert {:ok, ^extra} = IntentStore.record_intent_tainted(target, extra, taint)
      assert Map.has_key?(:sys.get_state(IntentStore).pending_projection, target)
    end)

    # Malformed bare authority fails closed on delete (not success/absence).
    bare = %{"not" => "a_record", "agent" => target}

    assert {:ok, ^bare} =
             Arbor.Persistence.buffered_store_acknowledged_put(@store_name, target, bare)

    assert {:error, del_reason} = IntentStore.delete_agent_content(target)
    assert del_reason in @delete_errors
    refute Map.has_key?(:sys.get_state(IntentStore).pending_projection, target)

    send(Process.whereis(IntentStore), {:converge_projection, target})
    _ = :sys.get_state(IntentStore)

    assert {:ok, ^ids_before} = Provenance.list_item_ids(:intent, target)
    assert {:ok, ^bare} = Arbor.Persistence.buffered_store_authoritative_get(@store_name, target)
  end

  test "owner process down returns closed mutation/read errors", %{target: target} do
    taint = taint(:trusted, :internal, "intent_owner_down")
    intent = Intent.think("owner down")
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(target, intent, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:intent, target)

    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, IntentStore)
    assert Process.whereis(IntentStore) == nil

    assert {:error, del_reason} = IntentStore.delete_agent_content(target)
    assert del_reason in @delete_errors

    assert {:error, abs_reason} = IntentStore.agent_content_absent?(target)
    assert abs_reason in @absence_errors

    ensure_intent_store!()
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:intent, target)
  end

  test "public cleanup when durable store is stopped returns closed errors", %{target: target} do
    taint = taint(:trusted, :internal, "intent_store_stopped")
    intent = Intent.think("store stopped")
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(target, intent, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:intent, target)

    # Deterministic ExUnit stop — not Process.exit/:kill (permanent child can restart).
    assert :ok = stop_supervised(BufferedStore)
    refute MemoryStore.available?()

    assert {:error, del_reason} = IntentStore.delete_agent_content(target)
    assert del_reason in @delete_errors

    assert {:error, abs_reason} = IntentStore.agent_content_absent?(target)
    assert abs_reason in @absence_errors

    ensure_durable_store!()
    assert MemoryStore.available?()
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:intent, target)
  end

  test "cleanup public errors are always closed atoms" do
    assert {:error, del_reason} = IntentStore.delete_agent_content("")
    assert del_reason in @delete_errors

    assert {:error, abs_reason} = IntentStore.agent_content_absent?(String.duplicate("x", 300))
    assert abs_reason in @absence_errors
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

  defp ensure_provenance! do
    case Process.whereis(Provenance) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _}} -> :ok
          other -> flunk("failed to restart Provenance: #{inspect(other)}")
        end
    end
  end

  defp ensure_intent_store! do
    case Process.whereis(IntentStore) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, IntentStore) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _}} ->
            :ok

          {:error, :not_found} ->
            assert {:ok, _pid} =
                     Supervisor.start_child(Arbor.Memory.Supervisor, {IntentStore, []})

            :ok

          other ->
            flunk("failed to restart IntentStore: #{inspect(other)}")
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
