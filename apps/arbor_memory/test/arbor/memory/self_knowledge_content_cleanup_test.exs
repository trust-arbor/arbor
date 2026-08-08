defmodule Arbor.Memory.SelfKnowledgeContentCleanupTest do
  @moduledoc """
  Content-only IdentityConsolidator self-knowledge cleanup (VP-05D2C3I0C2 / VOICE-17).
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.{IdentityConsolidator, MemoryStore, Provenance, SelfKnowledge}
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag spec: "VOICE-17"
  @moduletag voice_packet: "VP-05D2C3I0C2"
  @store_name :arbor_memory_durable
  @ets_table :arbor_self_knowledge
  @rate_limit_ets :arbor_identity_rate_limits
  @consolidation_state_ets :arbor_consolidation_state
  @namespace "self_knowledge"

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
    ensure_self_knowledge_tables!()
    ensure_provenance!()

    uid = System.unique_integer([:positive])
    target = "agent_a_#{uid}"
    child = "agent_a_#{uid}_child"
    survivor = "agent_b_#{uid}"

    for agent <- [target, child, survivor] do
      _ = IdentityConsolidator.delete_agent_content(agent)
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
          _ = IdentityConsolidator.delete_agent_content(agent)
          true = :ets.delete(@ets_table, agent)
        end
      end
    end)

    %{target: target, child: child, survivor: survivor}
  end

  test "delete_agent_content removes durable and ETS content, keeps sidecars and other tables",
       %{
         target: target,
         child: child,
         survivor: survivor
       } do
    target_sk =
      target
      |> SelfKnowledge.new()
      |> SelfKnowledge.add_capability("elixir", 0.8, "tests")

    child_sk = SelfKnowledge.new(child)
    survivor_sk = SelfKnowledge.new(survivor)

    assert :ok = IdentityConsolidator.save_self_knowledge(target, target_sk)
    assert :ok = IdentityConsolidator.save_self_knowledge(child, child_sk)
    assert :ok = IdentityConsolidator.save_self_knowledge(survivor, survivor_sk)

    await_durable!(@namespace, target)
    await_durable!(@namespace, child)
    await_durable!(@namespace, survivor)

    assert {:ok, _, _, _, _} =
             child_durable_before =
             MemoryStore.load_tainted_authoritative_with_status(@namespace, child)

    assert {:ok, _, _, _, _} =
             survivor_durable_before =
             MemoryStore.load_tainted_authoritative_with_status(@namespace, survivor)

    # Plant non-content state that must survive cleanup.
    true = :ets.insert(@rate_limit_ets, {target, [System.monotonic_time(:millisecond)]})

    true =
      :ets.insert(
        @consolidation_state_ets,
        {target, %{consolidation_count: 2, last_consolidation_at: DateTime.utc_now()}}
      )

    payload = SelfKnowledge.serialize(target_sk)
    taint = taint(:trusted, :internal, "self_knowledge_content_cleanup")
    assert :ok = Provenance.put(:self_knowledge, target, "identity", payload, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:self_knowledge, target)
    assert "identity" in ids_before

    assert {:ok, false} = IdentityConsolidator.agent_content_absent?(target)

    assert :ok = IdentityConsolidator.delete_agent_content(target)
    assert {:ok, true} = IdentityConsolidator.agent_content_absent?(target)
    assert :ok = IdentityConsolidator.delete_agent_content(target)
    assert {:ok, true} = IdentityConsolidator.agent_content_absent?(target)

    assert [] = :ets.lookup(@ets_table, target)

    assert {:error, :not_found} =
             MemoryStore.load_tainted_authoritative_with_status(@namespace, target)

    assert %SelfKnowledge{agent_id: ^child} = IdentityConsolidator.get_self_knowledge(child)

    assert %SelfKnowledge{agent_id: ^survivor} =
             IdentityConsolidator.get_self_knowledge(survivor)

    assert {:ok, false} = IdentityConsolidator.agent_content_absent?(child)
    assert {:ok, false} = IdentityConsolidator.agent_content_absent?(survivor)

    assert ^child_durable_before =
             MemoryStore.load_tainted_authoritative_with_status(@namespace, child)

    assert ^survivor_durable_before =
             MemoryStore.load_tainted_authoritative_with_status(@namespace, survivor)

    # Rate-limit / consolidation state retained for the target agent.
    assert [{^target, _}] = :ets.lookup(@rate_limit_ets, target)
    assert [{^target, %{consolidation_count: 2}}] = :ets.lookup(@consolidation_state_ets, target)

    assert {:ok, ^ids_before} = Provenance.list_item_ids(:self_knowledge, target)

    assert {:ok, ^taint, :verified} =
             Provenance.resolve(:self_knowledge, target, "identity", payload)

    hostile_payload = %{"hostile" => true}
    hostile = taint(:hostile, :restricted, "hostile_sk")
    assert :ok = Provenance.put(:self_knowledge, target, "hostile-sk", hostile_payload, hostile)
    assert :ok = IdentityConsolidator.delete_agent_content(target)

    assert {:ok, ^hostile, :verified} =
             Provenance.resolve(:self_knowledge, target, "hostile-sk", hostile_payload)
  end

  test "mixed durable/projection presence never reports true absence", %{target: target} do
    sk = SelfKnowledge.new(target)
    assert :ok = IdentityConsolidator.save_self_knowledge(target, sk)
    await_durable!(@namespace, target)

    true = :ets.delete(@ets_table, target)
    assert {:ok, false} = IdentityConsolidator.agent_content_absent?(target)

    assert :ok = MemoryStore.delete_tainted_authoritative(@namespace, target)
    true = :ets.insert(@ets_table, {target, sk})
    assert {:ok, false} = IdentityConsolidator.agent_content_absent?(target)

    true = :ets.delete(@ets_table, target)
    assert {:ok, true} = IdentityConsolidator.agent_content_absent?(target)
  end

  test "malformed bare durable row fails closed without success or absence", %{target: target} do
    sk = SelfKnowledge.new(target)
    assert :ok = IdentityConsolidator.save_self_knowledge(target, sk)
    await_durable!(@namespace, target)

    payload = SelfKnowledge.serialize(sk)
    taint = taint(:trusted, :internal, "sk_bare_malformed")
    assert :ok = Provenance.put(:self_knowledge, target, "identity", payload, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:self_knowledge, target)

    assert :ok = MemoryStore.delete_tainted_authoritative(@namespace, target)
    true = :ets.delete(@ets_table, target)

    bare = %{"not" => "a_record", "agent" => target}

    assert {:ok, ^bare} =
             Arbor.Persistence.buffered_store_acknowledged_put(@store_name, target, bare)

    assert {:error, :invalid_record} = IdentityConsolidator.delete_agent_content(target)
    assert {:error, abs_reason} = IdentityConsolidator.agent_content_absent?(target)

    assert abs_reason in [
             :invalid_record,
             :absence_uncertain,
             :store_unavailable,
             :durable_unavailable
           ]

    assert {:ok, ^ids_before} = Provenance.list_item_ids(:self_knowledge, target)
  end

  test "public cleanup when durable store is stopped returns closed flat atoms", %{
    target: target
  } do
    sk = SelfKnowledge.new(target)
    assert :ok = IdentityConsolidator.save_self_knowledge(target, sk)
    await_durable!(@namespace, target)

    payload = SelfKnowledge.serialize(sk)
    taint = taint(:trusted, :internal, "sk_store_stopped")
    assert :ok = Provenance.put(:self_knowledge, target, "identity", payload, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:self_knowledge, target)

    assert :ok = stop_supervised(BufferedStore)
    refute MemoryStore.available?()

    assert {:error, del_reason} = IdentityConsolidator.delete_agent_content(target)
    assert del_reason in @delete_errors

    assert {:error, abs_reason} = IdentityConsolidator.agent_content_absent?(target)
    assert abs_reason in @absence_errors

    ensure_durable_store!()
    assert MemoryStore.available?()
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:self_knowledge, target)
  end

  test "cleanup public errors are always closed atoms" do
    assert {:error, del_reason} = IdentityConsolidator.delete_agent_content("")
    assert del_reason in @delete_errors

    assert {:error, abs_reason} =
             IdentityConsolidator.agent_content_absent?(String.duplicate("z", 300))

    assert abs_reason in @absence_errors
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

  defp ensure_self_knowledge_tables! do
    for table <- [@ets_table, @rate_limit_ets, @consolidation_state_ets] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
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
