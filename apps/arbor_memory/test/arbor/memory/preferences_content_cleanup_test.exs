defmodule Arbor.Memory.PreferencesContentCleanupTest do
  @moduledoc """
  Content-only PreferencesStore cleanup primitives (VP-05D2C3I0C2 / VOICE-17).
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.{MemoryStore, Preferences, PreferencesStore, Provenance}
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag spec: "VOICE-17"
  @moduletag voice_packet: "VP-05D2C3I0C2"
  @store_name :arbor_memory_durable
  @ets_table :arbor_preferences
  @namespace "preferences"

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
    :inventory_limit_exceeded,
    :store_unavailable
  ]

  setup do
    ensure_durable_store!()
    ensure_preferences_ets!()
    ensure_provenance!()

    uid = System.unique_integer([:positive])
    target = "agent_a_#{uid}"
    child = "agent_a_#{uid}_child"
    survivor = "agent_b_#{uid}"

    for agent <- [target, child, survivor] do
      _ = PreferencesStore.delete_agent_content(agent)
      _ = Provenance.delete_agent(agent)
      true = :ets.delete(@ets_table, agent)
    end

    on_exit(fn ->
      ensure_provenance!()

      for agent <- [target, child, survivor] do
        _ = Provenance.delete_agent(agent)
      end

      if MemoryStore.available?() do
        for agent <- [target, child, survivor] do
          _ = PreferencesStore.delete_agent_content(agent)
          true = :ets.delete(@ets_table, agent)
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
    target_prefs = Preferences.new(target)
    child_prefs = Preferences.new(child)
    survivor_prefs = Preferences.new(survivor)

    assert :ok = PreferencesStore.save_preferences(target, target_prefs)
    assert :ok = PreferencesStore.save_preferences(child, child_prefs)
    assert :ok = PreferencesStore.save_preferences(survivor, survivor_prefs)

    await_durable!(@namespace, target)
    await_durable!(@namespace, child)
    await_durable!(@namespace, survivor)

    assert {:ok, _, _, _, _} =
             child_durable_before =
             MemoryStore.load_tainted_authoritative_with_status(@namespace, child)

    assert {:ok, _, _, _, _} =
             survivor_durable_before =
             MemoryStore.load_tainted_authoritative_with_status(@namespace, survivor)

    payload = Preferences.serialize(target_prefs)
    taint = taint(:trusted, :internal, "preferences_content_cleanup")
    assert :ok = Provenance.put(:preference, target, "prefs", payload, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:preference, target)
    assert "prefs" in ids_before

    assert {:ok, false} = PreferencesStore.agent_content_absent?(target)

    assert :ok = PreferencesStore.delete_agent_content(target)
    assert {:ok, true} = PreferencesStore.agent_content_absent?(target)
    assert :ok = PreferencesStore.delete_agent_content(target)
    assert {:ok, true} = PreferencesStore.agent_content_absent?(target)

    assert [] = :ets.lookup(@ets_table, target)

    assert {:error, :not_found} =
             MemoryStore.load_tainted_authoritative_with_status(@namespace, target)

    assert %Preferences{agent_id: ^child} = PreferencesStore.get_preferences(child)
    assert %Preferences{agent_id: ^survivor} = PreferencesStore.get_preferences(survivor)
    assert {:ok, false} = PreferencesStore.agent_content_absent?(child)
    assert {:ok, false} = PreferencesStore.agent_content_absent?(survivor)

    assert ^child_durable_before =
             MemoryStore.load_tainted_authoritative_with_status(@namespace, child)

    assert ^survivor_durable_before =
             MemoryStore.load_tainted_authoritative_with_status(@namespace, survivor)

    assert {:ok, ^ids_before} = Provenance.list_item_ids(:preference, target)
    assert {:ok, ^taint, :verified} = Provenance.resolve(:preference, target, "prefs", payload)

    hostile_payload = %{"hostile" => true}
    hostile = taint(:hostile, :restricted, "hostile_pref")
    assert :ok = Provenance.put(:preference, target, "hostile-pref", hostile_payload, hostile)
    assert :ok = PreferencesStore.delete_agent_content(target)

    assert {:ok, ^hostile, :verified} =
             Provenance.resolve(:preference, target, "hostile-pref", hostile_payload)
  end

  test "mixed durable/projection presence never reports true absence", %{target: target} do
    prefs = Preferences.new(target)
    assert :ok = PreferencesStore.save_preferences(target, prefs)
    await_durable!(@namespace, target)

    # Durable present, ETS empty.
    true = :ets.delete(@ets_table, target)
    assert {:ok, false} = PreferencesStore.agent_content_absent?(target)

    # Durable absent, ETS present.
    assert :ok = MemoryStore.delete_tainted_authoritative(@namespace, target)
    true = :ets.insert(@ets_table, {target, prefs})
    assert {:ok, false} = PreferencesStore.agent_content_absent?(target)

    true = :ets.delete(@ets_table, target)
    assert {:ok, true} = PreferencesStore.agent_content_absent?(target)
  end

  test "malformed bare durable row fails closed without success or absence", %{target: target} do
    prefs = Preferences.new(target)
    assert :ok = PreferencesStore.save_preferences(target, prefs)
    await_durable!(@namespace, target)

    payload = Preferences.serialize(prefs)
    taint = taint(:trusted, :internal, "pref_bare_malformed")
    assert :ok = Provenance.put(:preference, target, "prefs", payload, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:preference, target)

    assert :ok = MemoryStore.delete_tainted_authoritative(@namespace, target)
    true = :ets.delete(@ets_table, target)

    bare = %{"not" => "a_record", "agent" => target}

    assert {:ok, ^bare} =
             Arbor.Persistence.buffered_store_acknowledged_put(@store_name, target, bare)

    assert {:error, :invalid_record} = PreferencesStore.delete_agent_content(target)
    assert {:error, abs_reason} = PreferencesStore.agent_content_absent?(target)

    assert abs_reason in [
             :invalid_record,
             :absence_uncertain,
             :store_unavailable,
             :durable_unavailable
           ]

    refute abs_reason == :not_found

    assert {:ok, ^bare} =
             Arbor.Persistence.buffered_store_authoritative_get(@store_name, target)

    assert {:ok, ^ids_before} = Provenance.list_item_ids(:preference, target)
  end

  test "public cleanup when durable store is stopped returns closed flat atoms", %{
    target: target
  } do
    prefs = Preferences.new(target)
    assert :ok = PreferencesStore.save_preferences(target, prefs)
    await_durable!(@namespace, target)

    payload = Preferences.serialize(prefs)
    taint = taint(:trusted, :internal, "pref_store_stopped")
    assert :ok = Provenance.put(:preference, target, "prefs", payload, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:preference, target)

    assert :ok = stop_supervised(BufferedStore)
    refute MemoryStore.available?()

    assert {:error, del_reason} = PreferencesStore.delete_agent_content(target)
    assert del_reason in @delete_errors
    refute is_tuple(del_reason)

    assert {:error, abs_reason} = PreferencesStore.agent_content_absent?(target)
    assert abs_reason in @absence_errors
    refute is_tuple(abs_reason)

    ensure_durable_store!()
    assert MemoryStore.available?()
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:preference, target)
  end

  test "cleanup public errors are always closed atoms" do
    assert {:error, del_reason} = PreferencesStore.delete_agent_content("")
    assert del_reason in @delete_errors
    refute is_tuple(del_reason)

    assert {:error, abs_reason} =
             PreferencesStore.agent_content_absent?(String.duplicate("z", 300))

    assert abs_reason in @absence_errors
    refute is_tuple(abs_reason)
  end

  test "compatibility save/get still works after content cleanup", %{target: target} do
    prefs = Preferences.new(target)
    assert :ok = PreferencesStore.save_preferences(target, prefs)
    await_durable!(@namespace, target)
    assert :ok = PreferencesStore.delete_agent_content(target)

    refreshed = Preferences.new(target)
    assert :ok = PreferencesStore.save_preferences(target, refreshed)
    assert %Preferences{agent_id: ^target} = PreferencesStore.get_preferences(target)
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

  defp ensure_preferences_ets! do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :public, :set])
    end

    :ok
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

  defp await_durable!(namespace, key) do
    assert eventually(fn ->
             match?(
               {:ok, _, _, _, _},
               MemoryStore.load_tainted_authoritative_with_status(namespace, key)
             )
           end)
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

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
