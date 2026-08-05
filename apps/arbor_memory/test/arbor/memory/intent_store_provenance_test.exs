defmodule Arbor.Memory.IntentStoreProvenanceTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Memory.{Intent, Percept}
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Memory.{IntentStore, Provenance}
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @store_name :arbor_memory_durable

  defmodule ProjectionFailureBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Persistence.Store.Revision

    def arm(table, test_pid) do
      true = :ets.insert(table, {:fail_next_put, test_pid})
      :ok
    end

    @impl true
    def durability_class(_opts), do: :node_restart

    @impl true
    def put(key, value, opts) do
      table = Keyword.fetch!(opts, :table)
      true = :ets.insert(table, {key, value})

      case :ets.take(table, :fail_next_put) do
        [{:fail_next_put, test_pid}] ->
          send(test_pid, {:backend_committed, key})
          :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Arbor.Memory.Provenance)

        [] ->
          :ok
      end

      :ok
    end

    @impl true
    def get(key, opts) do
      case :ets.lookup(Keyword.fetch!(opts, :table), key) do
        [{^key, value}] -> {:ok, value}
        [] -> {:error, :not_found}
      end
    end

    @impl true
    def delete(key, opts) do
      true = :ets.delete(Keyword.fetch!(opts, :table), key)
      :ok
    end

    @impl true
    def list(opts) do
      keys =
        opts
        |> Keyword.fetch!(:table)
        |> :ets.tab2list()
        |> Enum.flat_map(fn
          {key, _value} when is_binary(key) -> [key]
          _control -> []
        end)

      {:ok, keys}
    end

    @impl true
    def compare_and_swap(key, expected, replacement, opts) do
      table = Keyword.fetch!(opts, :table)

      result =
        case {:ets.lookup(table, key), expected} do
          {[], :not_found} ->
            stored = Revision.advance_cas_insert(replacement)
            true = :ets.insert(table, {key, stored})
            {:ok, stored}

          {[{^key, current}], {:value, expected_value}} ->
            if Revision.cas_matches?(current, expected_value) do
              case Revision.advance_cas_update(current, replacement) do
                {:ok, stored} ->
                  true = :ets.insert(table, {key, stored})
                  {:ok, stored}

                {:error, _reason} = error ->
                  error
              end
            else
              {:error, :conflict}
            end

          _ ->
            {:error, :conflict}
        end

      case result do
        {:ok, _stored} -> maybe_fail_projection(table, key)
        _ -> :ok
      end

      result
    end

    @impl true
    def compare_and_delete(key, expected, opts) do
      table = Keyword.fetch!(opts, :table)

      case :ets.lookup(table, key) do
        [{^key, current}] ->
          if Revision.cas_matches?(current, expected) do
            true = :ets.delete(table, key)
            :ok
          else
            {:error, :conflict}
          end

        [] ->
          {:error, :conflict}
      end
    end

    defp maybe_fail_projection(table, key) do
      case :ets.take(table, :fail_next_put) do
        [{:fail_next_put, test_pid}] ->
          send(test_pid, {:backend_committed, key})
          :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Arbor.Memory.Provenance)

        [] ->
          :ok
      end
    end
  end

  setup do
    start_supervised!({BufferedStore, name: @store_name, backend: nil, write_mode: :sync})

    agent_id = "intent_provenance_#{System.unique_integer([:positive])}"
    :ok = IntentStore.clear(agent_id)

    on_exit(fn ->
      IntentStore.clear(agent_id)
      Provenance.delete_agent(agent_id)
    end)

    %{agent_id: agent_id}
  end

  test "security regression: mixed labels remain item-specific in a verified aggregate", %{
    agent_id: agent_id
  } do
    intent = Intent.think("retain intent provenance")
    percept = Percept.success(intent.id, %{"result" => "retain percept provenance"})

    intent_taint =
      taint(:trusted, :internal, 0b0011, :verified, "intent_source")

    percept_taint =
      taint(:untrusted, :confidential, 0b0001, :plausible, "percept_source")

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, intent_taint)
    assert {:ok, ^percept} = IntentStore.record_percept_tainted(agent_id, percept, percept_taint)

    assert {:ok, [{intent_value, :verified}]} =
             IntentStore.recent_intents_tainted(agent_id)

    assert intent_value.value == intent
    assert intent_value.taint == intent_taint

    assert {:ok, [{percept_value, :verified}]} =
             IntentStore.recent_percepts_tainted(agent_id)

    assert percept_value.value == percept
    assert percept_value.taint == percept_taint

    assert {:ok, %Record{data: aggregate, metadata: %{"taint" => outer}}} =
             BufferedStore.get("intents:#{agent_id}", name: @store_name)

    assert aggregate["version"] == 1
    assert {:ok, _json} = Jason.encode(aggregate)

    [persisted_intent] = aggregate["intents"]
    [persisted_percept] = aggregate["percepts"]

    assert {:ok, intent_envelope} =
             TaintEnvelope.verify(
               persisted_intent["provenance"],
               persisted_intent["payload"]
             )

    assert intent_envelope.taint == intent_taint

    assert {:ok, percept_envelope} =
             TaintEnvelope.verify(
               persisted_percept["provenance"],
               persisted_percept["payload"]
             )

    assert percept_envelope.taint == percept_taint

    assert {:ok, joined} = Taint.join_many([intent_taint, percept_taint])
    assert joined.sanitizations == 0b0001
    assert {:ok, aggregate_envelope} = TaintEnvelope.verify(outer, aggregate)
    assert aggregate_envelope.taint == joined
  end

  test "raw compatibility writes receive a conservative item label", %{agent_id: agent_id} do
    intent = Intent.think("raw compatibility")

    assert {:ok, ^intent} = IntentStore.record_intent(agent_id, intent)
    assert {:ok, [{value, :legacy_unlabeled}]} = IntentStore.recent_intents_tainted(agent_id)

    assert value.value == intent
    assert value.taint == TaintEnvelope.missing_fallback()
  end

  test "security regression: raw failure content taints the durable aggregate", %{
    agent_id: agent_id
  } do
    intent = Intent.think("trusted intent")
    trusted = taint(:trusted, :public, 0xFF, :verified, "trusted_intent")
    fallback = TaintEnvelope.missing_fallback()

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, trusted)
    assert verified_outer_taint(durable_record(agent_id)) == trusted

    assert {:ok, 1} = IntentStore.fail_intent(agent_id, intent.id, "raw failure content")

    failed_record = durable_record(agent_id)
    failed_status = failed_record.data["statuses"][intent.id]

    assert failed_status["payload"]["intent_id"] == intent.id
    assert failed_status["payload"]["last_failure_reason"] == "raw failure content"

    assert {:ok, status_envelope} =
             TaintEnvelope.verify(failed_status["provenance"], failed_status["payload"])

    assert {:ok, expected_status} = Taint.join_many([trusted, fallback])
    assert status_envelope.taint == expected_status
    assert {:ok, expected_outer} = Taint.join_many([trusted, expected_status])
    assert verified_outer_taint(failed_record) == expected_outer
    refute expected_outer == trusted
    assert expected_outer.level == :untrusted
    assert expected_outer.sensitivity == :restricted
    assert expected_outer.confidence == :unverified

    assert {:ok, ^intent} = IntentStore.lock_intent(agent_id, intent.id)
    assert :ok = IntentStore.complete_intent(agent_id, intent.id)

    completed_record = durable_record(agent_id)
    completed_status = completed_record.data["statuses"][intent.id]
    refute Map.has_key?(completed_status["payload"], "last_failure_reason")

    assert {:ok, completed_envelope} =
             TaintEnvelope.verify(completed_status["provenance"], completed_status["payload"])

    assert completed_envelope.taint == expected_status
    assert verified_outer_taint(completed_record) == expected_outer
  end

  test "strengthening an intent monotonically strengthens its existing status label", %{
    agent_id: agent_id
  } do
    intent = Intent.think("strengthen linked status")
    weak = taint(:trusted, :public, 0xFF, :verified, "weak_intent")
    strong = taint(:hostile, :restricted, 0b0011, :unverified, "strong_intent")

    assert {:ok, strengthened_intent} = Taint.join(weak, strong)
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, weak)
    assert {:ok, ^intent} = IntentStore.lock_intent(agent_id, intent.id)

    locked = durable_record(agent_id)
    locked_status_taint = verified_nested_taint(locked.data["statuses"][intent.id])

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, strong)

    strengthened = durable_record(agent_id)
    strengthened_status = strengthened.data["statuses"][intent.id]

    assert {:ok, expected_strengthened_status} =
             Taint.join_many([strengthened_intent, locked_status_taint])

    assert verified_nested_taint(strengthened_status) == expected_strengthened_status
    assert expected_strengthened_status.level == :hostile
    assert expected_strengthened_status.sensitivity == :restricted
    assert expected_strengthened_status.sanitizations == 0b0011
    assert expected_strengthened_status.confidence == :unverified

    assert :ok = IntentStore.complete_intent(agent_id, intent.id)

    completed = durable_record(agent_id)
    completed_status = verified_nested_taint(completed.data["statuses"][intent.id])

    assert {:ok, expected_completed_status} =
             Taint.join_many([strengthened_intent, expected_strengthened_status])

    assert completed_status == expected_completed_status
    assert completed_status.level == :hostile
    assert completed_status.sensitivity == :restricted
    assert completed_status.sanitizations == 0b0011
    assert completed_status.confidence == :unverified
  end

  test "security regression: decoded status provenance must include its linked intent", %{
    agent_id: base_agent_id
  } do
    Enum.each([:verified_outer, :missing_outer], fn outer_mode ->
      agent_id = "#{base_agent_id}_#{outer_mode}"
      on_exit(fn -> IntentStore.clear(agent_id) end)

      intent = Intent.think("linked status dominance #{outer_mode}")
      weak = taint(:trusted, :public, 0xFF, :verified, "weak_linked_intent")
      stronger = taint(:hostile, :restricted, 0b0011, :unverified, "strong_linked_intent")

      assert {:ok, current_intent_taint} = Taint.join(weak, stronger)
      assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, weak)
      assert {:ok, ^intent} = IntentStore.lock_intent(agent_id, intent.id)

      record = durable_record(agent_id)
      [persisted_intent] = record.data["intents"]
      persisted_status = record.data["statuses"][intent.id]
      weak_status_taint = verified_nested_taint(persisted_status)

      strengthened_intent =
        nested_entry_with_taint(persisted_intent["payload"], current_intent_taint)

      data = put_in(record.data, ["intents"], [strengthened_intent])
      assert {:ok, aggregate_taint} = Taint.join_many([current_intent_taint, weak_status_taint])

      metadata =
        case outer_mode do
          :verified_outer -> outer_metadata(data, aggregate_taint)
          :missing_outer -> %{}
        end

      put_durable(agent_id, data, metadata)
      assert :ok = IntentStore.reload_for_agent(agent_id)

      assert {:ok, [{value, :invalid_durable_provenance}]} =
               IntentStore.recent_intents_tainted(agent_id)

      assert value.value.id == intent.id
      assert value.taint == TaintEnvelope.invalid_fallback()
    end)
  end

  test "security regression: public status ETS mutation cannot persist forged trusted provenance",
       %{agent_id: agent_id} do
    intent = Intent.think("trusted status")
    trusted = taint(:trusted, :public, 0xFF, :verified, "trusted_status")

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, trusted)
    assert {:ok, ^intent} = IntentStore.lock_intent(agent_id, intent.id)

    durable_before = durable_record(agent_id)
    status_payload = get_in(durable_before.data, ["statuses", intent.id, "payload"])

    [{^agent_id, data}] = :ets.lookup(:arbor_memory_intents, agent_id)
    forged_reason = "forged public ETS failure"
    forged_status = Map.put(data.statuses[intent.id], :last_failure_reason, forged_reason)

    forged_data =
      data
      |> put_in([:statuses, intent.id], forged_status)
      |> Map.put(:status_taints, %{intent.id => trusted})

    true = :ets.insert(:arbor_memory_intents, {agent_id, forged_data})

    forged_payload = Map.put(status_payload, "last_failure_reason", forged_reason)

    percept = Percept.success(intent.id, %{"result" => "must not commit"})

    assert {:ok, ^percept} =
             IntentStore.record_percept_tainted(agent_id, percept, trusted)

    durable_after = durable_record(agent_id)

    assert get_in(durable_after.data, ["statuses", intent.id, "payload"]) == status_payload
    refute durable_after == durable_before
    assert IntentStore.recent_percepts(agent_id) == [percept]

    assert {:ok, hostile, :invalid_durable_provenance} =
             Provenance.resolve(:intent_status, agent_id, intent.id, forged_payload)

    assert hostile == TaintEnvelope.invalid_fallback()

    assert {:ok, ^trusted, :verified} =
             Provenance.resolve(:intent_status, agent_id, intent.id, status_payload)
  end

  test "security regression: deleting a hostile status cannot weaken its next transition", %{
    agent_id: agent_id
  } do
    intent = Intent.think("hostile status predecessor")
    trusted = taint(:trusted, :public, 0xFF, :verified, "trusted_intent")
    hostile = taint(:hostile, :restricted, 0, :unverified, "hostile_reason")

    assert {:ok, expected} = Taint.join(trusted, hostile)
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, trusted)
    assert {:ok, ^intent} = IntentStore.lock_intent(agent_id, intent.id)

    assert {:ok, 1} =
             IntentStore.fail_intent_tainted(agent_id, intent.id, "hostile failure", hostile)

    failed = durable_record(agent_id)
    assert verified_nested_taint(failed.data["statuses"][intent.id]) == expected

    [{^agent_id, data}] = :ets.lookup(:arbor_memory_intents, agent_id)
    deleted_status = %{data | statuses: Map.delete(data.statuses, intent.id)}
    true = :ets.insert(:arbor_memory_intents, {agent_id, deleted_status})

    assert {:ok, ^intent} = IntentStore.lock_intent(agent_id, intent.id)

    locked = durable_record(agent_id)
    assert verified_nested_taint(locked.data["statuses"][intent.id]) == expected
    assert verified_outer_taint(locked) == expected

    assert :ok = IntentStore.complete_intent(agent_id, intent.id)
    completed = durable_record(agent_id)
    assert verified_nested_taint(completed.data["statuses"][intent.id]) == expected
    assert verified_outer_taint(completed) == expected
  end

  test "security regression: deleting and reinserting an item cannot weaken its label", %{
    agent_id: agent_id
  } do
    intent = Intent.think("stable hostile intent")
    percept = Percept.success(intent.id, %{"result" => "stable hostile percept"})
    hostile = taint(:hostile, :restricted, 0, :unverified, "hostile_item")
    weaker = taint(:trusted, :public, 0xFF, :verified, "weaker_reinsert")

    assert {:ok, expected} = Taint.join(hostile, weaker)
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, hostile)
    assert {:ok, ^percept} = IntentStore.record_percept_tainted(agent_id, percept, hostile)

    [{^agent_id, data}] = :ets.lookup(:arbor_memory_intents, agent_id)
    without_intent = %{data | intents: Enum.reject(data.intents, &(&1.id == intent.id))}
    true = :ets.insert(:arbor_memory_intents, {agent_id, without_intent})

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, weaker)

    after_intent = durable_record(agent_id)

    persisted_intent =
      Enum.find(after_intent.data["intents"], &(&1["payload"]["id"] == intent.id))

    assert verified_nested_taint(persisted_intent) == expected

    [{^agent_id, data}] = :ets.lookup(:arbor_memory_intents, agent_id)
    without_percept = %{data | percepts: Enum.reject(data.percepts, &(&1.id == percept.id))}
    true = :ets.insert(:arbor_memory_intents, {agent_id, without_percept})

    assert {:ok, ^percept} = IntentStore.record_percept_tainted(agent_id, percept, weaker)

    after_percept = durable_record(agent_id)

    persisted_percept =
      Enum.find(after_percept.data["percepts"], &(&1["payload"]["id"] == percept.id))

    assert verified_nested_taint(persisted_percept) == expected
    assert verified_outer_taint(after_percept) == expected
  end

  test "security regression: taint-aware inventory survives public ETS item and row deletion", %{
    agent_id: agent_id
  } do
    hostile_intent = Intent.think("hostile durable inventory")
    trusted_intent = Intent.think("trusted durable inventory")
    hostile_percept = Percept.success(hostile_intent.id, %{"result" => "hostile"})
    trusted_percept = Percept.success(trusted_intent.id, %{"result" => "trusted"})

    hostile = taint(:hostile, :restricted, 0, :unverified, "hostile_inventory")
    trusted = taint(:trusted, :public, 0xFF, :verified, "trusted_inventory")

    assert {:ok, ^hostile_intent} =
             IntentStore.record_intent_tainted(agent_id, hostile_intent, hostile)

    assert {:ok, ^trusted_intent} =
             IntentStore.record_intent_tainted(agent_id, trusted_intent, trusted)

    assert {:ok, ^hostile_percept} =
             IntentStore.record_percept_tainted(agent_id, hostile_percept, hostile)

    assert {:ok, ^trusted_percept} =
             IntentStore.record_percept_tainted(agent_id, trusted_percept, trusted)

    [{^agent_id, data}] = :ets.lookup(:arbor_memory_intents, agent_id)

    projected = %{
      data
      | intents: Enum.reject(data.intents, &(&1.id == hostile_intent.id)),
        percepts: Enum.reject(data.percepts, &(&1.id == hostile_percept.id))
    }

    true = :ets.insert(:arbor_memory_intents, {agent_id, projected})

    assert Enum.map(IntentStore.recent_intents(agent_id, limit: 10), & &1.id) == [
             trusted_intent.id,
             hostile_intent.id
           ]

    assert Enum.map(IntentStore.recent_percepts(agent_id, limit: 10), & &1.id) == [
             trusted_percept.id,
             hostile_percept.id
           ]

    assert_tainted_inventory(agent_id, :intent, [
      {trusted_intent.id, trusted},
      {hostile_intent.id, hostile}
    ])

    assert_tainted_inventory(agent_id, :percept, [
      {trusted_percept.id, trusted},
      {hostile_percept.id, hostile}
    ])

    true = :ets.delete(:arbor_memory_intents, agent_id)

    assert Enum.map(IntentStore.recent_intents(agent_id, limit: 10), & &1.id) == [
             trusted_intent.id,
             hostile_intent.id
           ]

    assert Enum.map(IntentStore.recent_percepts(agent_id, limit: 10), & &1.id) == [
             trusted_percept.id,
             hostile_percept.id
           ]

    assert_tainted_inventory(agent_id, :intent, [
      {trusted_intent.id, trusted},
      {hostile_intent.id, hostile}
    ])

    assert_tainted_inventory(agent_id, :percept, [
      {trusted_percept.id, trusted},
      {hostile_percept.id, hostile}
    ])
  end

  test "invalid failure labels and non-closed imports are rejected atomically", %{
    agent_id: agent_id
  } do
    existing = Intent.think("existing trusted")
    trusted = taint(:trusted, :internal, 0xFF, :verified, "existing")

    assert {:ok, ^existing} =
             IntentStore.record_intent_tainted(agent_id, existing, trusted)

    ets_before = :ets.lookup(:arbor_memory_intents, agent_id)
    durable_before = durable_record(agent_id)

    invalid_taint = %Taint{level: :unknown_level}

    assert {:error, :invalid_provenance} =
             IntentStore.fail_intent_tainted(
               agent_id,
               existing.id,
               "must not be persisted",
               invalid_taint
             )

    imported = Intent.think("must not be imported")

    valid_import =
      imported
      |> intent_payload()
      |> Map.put("status", "pending")
      |> Map.put("retry_count", 0)

    invalid_import = Map.put(valid_import, "type", "unknown_intent_type")

    assert {:error, :invalid_request} =
             IntentStore.import_intents(agent_id, [valid_import, invalid_import])

    assert {:error, :invalid_request} =
             IntentStore.import_intents(agent_id, [Map.put(valid_import, "unknown_field", true)])

    assert :ets.lookup(:arbor_memory_intents, agent_id) == ets_before
    assert durable_record(agent_id) == durable_before
    assert {:error, :not_found} = IntentStore.get_intent(agent_id, imported.id)
  end

  test "security regression: compatibility and taint-aware reads reject a forged public ETS item",
       %{
         agent_id: agent_id
       } do
    intent = Intent.think("original")
    supplied = taint(:trusted, :public, 0, :verified, "trusted_input")

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, supplied)

    [{^agent_id, data}] = :ets.lookup(:arbor_memory_intents, agent_id)
    [stored] = data.intents
    mutated = %{stored | reasoning: "mutated after labeling"}
    true = :ets.insert(:arbor_memory_intents, {agent_id, %{data | intents: [mutated]}})

    assert [^intent] = IntentStore.recent_intents(agent_id)

    assert {:ok, [{value, :verified}]} =
             IntentStore.recent_intents_tainted(agent_id)

    assert value.value == intent
    assert value.taint == supplied

    assert [{^agent_id, repaired}] = :ets.lookup(:arbor_memory_intents, agent_id)
    assert repaired.intents == [intent]
  end

  test "security regression: taint-aware read reconciliation is serialized with mutations", %{
    agent_id: agent_id
  } do
    intent = Intent.think("serialized durable read")
    trusted = taint(:trusted, :public, 0xFF, :verified, "serialized_read")
    hostile = taint(:hostile, :restricted, 0, :unverified, "queued_mutation")

    assert {:ok, expected} = Taint.join(trusted, hostile)
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, trusted)

    owner = Process.whereis(IntentStore)
    :ok = :sys.suspend(owner)

    {read_task, mutation_task} =
      try do
        read_task = Task.async(fn -> IntentStore.recent_intents_tainted(agent_id) end)

        assert wait_until(fn ->
                 owner_call_queued?(owner, fn
                   {:recent_tainted, :intent, ^agent_id, []} -> true
                   _ -> false
                 end)
               end)

        assert Task.yield(read_task, 0) == nil

        mutation_task =
          Task.async(fn -> IntentStore.record_intent_tainted(agent_id, intent, hostile) end)

        assert Task.yield(mutation_task, 100) == nil
        {read_task, mutation_task}
      after
        :ok = :sys.resume(owner)
      end

    assert {:ok, [{read_value, :verified}]} = Task.await(read_task)
    assert read_value.value == intent
    assert read_value.taint == trusted
    assert {:ok, ^intent} = Task.await(mutation_task)

    assert {:ok, ^expected, :verified} =
             Provenance.resolve(:intent, agent_id, intent.id, intent_payload(intent))

    assert verified_nested_taint(hd(durable_record(agent_id).data["intents"])) == expected
  end

  test "invalid supplied labels are rejected before live, durable, sidecar, or embedding effects",
       %{
         agent_id: agent_id
       } do
    existing = Intent.think("existing")
    assert {:ok, ^existing} = IntentStore.record_intent(agent_id, existing)

    ets_before = :ets.lookup(:arbor_memory_intents, agent_id)
    durable_before = durable_record(agent_id)
    test_pid = self()
    original_state = :sys.get_state(IntentStore)

    :sys.replace_state(IntentStore, fn state ->
      %{state | embedding_fun: fn _, _, _, _ -> send(test_pid, :embedded) end}
    end)

    on_exit(fn -> restore_intent_store_state(original_state) end)

    rejected = Intent.think("sensitive-invalid-write")
    invalid_taint = %Taint{level: :not_a_level}

    error = IntentStore.record_intent_tainted(agent_id, rejected, invalid_taint)
    assert error == {:error, :invalid_provenance}
    refute inspect(error) =~ "sensitive-invalid-write"
    assert Process.alive?(Process.whereis(IntentStore))
    assert :ets.lookup(:arbor_memory_intents, agent_id) == ets_before
    assert durable_record(agent_id) == durable_before
    refute_received :embedded

    assert {:ok, fallback, :legacy_unlabeled} =
             Provenance.resolve(:intent, agent_id, rejected.id, intent_payload(rejected))

    assert fallback == TaintEnvelope.missing_fallback()
  end

  test "missing supervised ephemeral authority rejects taint-aware reads writes and clear", %{
    agent_id: agent_id
  } do
    existing = Intent.think("ephemeral authority predecessor")
    rejected = Intent.think("must not become live")
    supplied = taint(:untrusted, :restricted, 0, :verified, "ephemeral_authority")

    assert {:ok, ^existing} =
             IntentStore.record_intent_tainted(agent_id, existing, supplied)

    ets_before = :ets.lookup(:arbor_memory_intents, agent_id)
    stop_supervised!(BufferedStore)
    assert Process.whereis(@store_name) == nil

    assert {:error, :store_unavailable} = IntentStore.recent_intents_tainted(agent_id)

    assert {:error, :store_unavailable} =
             IntentStore.record_intent_tainted(agent_id, rejected, supplied)

    assert {:error, :store_unavailable} = IntentStore.complete_intent(agent_id, existing.id)
    assert {:error, :store_unavailable} = IntentStore.clear(agent_id)
    assert :ets.lookup(:arbor_memory_intents, agent_id) == ets_before

    assert {:ok, ^supplied, :verified} =
             Provenance.resolve(:intent, agent_id, existing.id, intent_payload(existing))

    assert_missing_sidecar(:intent, agent_id, rejected)
  end

  test "status mutations persist across restart without changing item provenance", %{
    agent_id: agent_id
  } do
    intent = Intent.think("durable status")
    supplied = taint(:untrusted, :restricted, 0b1010, :plausible, "status_source")

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, supplied)
    assert {:ok, ^intent} = IntentStore.lock_intent(agent_id, intent.id)
    Process.sleep(2)
    assert 1 = IntentStore.unlock_stale_intents(agent_id, 1)
    assert {:ok, 1} = IntentStore.fail_intent(agent_id, intent.id, "bounded failure")
    assert {:ok, ^intent} = IntentStore.lock_intent(agent_id, intent.id)
    assert :ok = IntentStore.complete_intent(agent_id, intent.id)

    before_restart = durable_record(agent_id)
    status_payload = get_in(before_restart.data, ["statuses", intent.id, "payload"])
    status_taint = verified_nested_taint(before_restart.data["statuses"][intent.id])

    assert {:ok, ^status_taint, :verified} =
             Provenance.resolve(:intent_status, agent_id, intent.id, status_payload)

    restart_intent_store()

    assert {:ok, restored, status} = IntentStore.get_intent(agent_id, intent.id)
    assert restored.id == intent.id
    assert status.status == :completed
    assert status.retry_count == 1
    assert %DateTime{} = status.completed_at

    assert {:ok, [{value, :verified}]} = IntentStore.recent_intents_tainted(agent_id)
    assert value.taint == supplied

    assert {:ok, ^status_taint, :verified} =
             Provenance.resolve(:intent_status, agent_id, intent.id, status_payload)
  end

  test "restart with a smaller buffer verifies the full aggregate before consistent truncation",
       %{
         agent_id: agent_id
       } do
    original_state = :sys.get_state(IntentStore)
    :sys.replace_state(IntentStore, &%{&1 | buffer_size: 3})

    on_exit(fn ->
      if Process.whereis(IntentStore), do: restart_intent_store()
    end)

    first = Intent.think("oldest durable intent")
    second = Intent.think("middle durable intent")
    newest = Intent.think("newest durable intent")

    first_taint = taint(:trusted, :internal, 0b1111, :verified, "oldest")
    second_taint = taint(:derived, :confidential, 0b0111, :corroborated, "middle")
    newest_taint = taint(:hostile, :restricted, 0, :unverified, "newest")

    assert {:ok, ^first} = IntentStore.record_intent_tainted(agent_id, first, first_taint)
    assert {:ok, ^second} = IntentStore.record_intent_tainted(agent_id, second, second_taint)
    assert {:ok, ^newest} = IntentStore.record_intent_tainted(agent_id, newest, newest_taint)
    assert {:ok, ^first} = IntentStore.lock_intent(agent_id, first.id)
    assert {:ok, ^newest} = IntentStore.lock_intent(agent_id, newest.id)

    durable_before = durable_record(agent_id)
    assert length(durable_before.data["intents"]) == 3
    assert map_size(durable_before.data["statuses"]) == 2
    verified_outer_taint(durable_before)

    newest_status = durable_before.data["statuses"][newest.id]
    newest_status_taint = verified_nested_taint(newest_status)
    first_status_payload = durable_before.data["statuses"][first.id]["payload"]

    restart_provenance()
    restart_intent_store(buffer_size: 1)

    assert :sys.get_state(IntentStore).buffer_size == 1
    assert Enum.map(IntentStore.recent_intents(agent_id, limit: 10), & &1.id) == [newest.id]

    assert {:ok, [{tainted_newest, :verified}]} =
             IntentStore.recent_intents_tainted(agent_id, limit: 10)

    assert tainted_newest.value == newest
    assert tainted_newest.taint == newest_taint
    assert {:ok, ^newest, %{status: :locked}} = IntentStore.get_intent(agent_id, newest.id)
    assert {:error, :not_found} = IntentStore.get_intent(agent_id, first.id)
    assert {:error, :not_found} = IntentStore.get_intent(agent_id, second.id)

    [{^agent_id, restored}] = :ets.lookup(:arbor_memory_intents, agent_id)
    assert Map.keys(restored.statuses) == [newest.id]
    assert durable_record(agent_id) == durable_before

    assert {:ok, ^newest_taint, :verified} =
             Provenance.resolve(:intent, agent_id, newest.id, intent_payload(newest))

    assert {:ok, ^newest_status_taint, :verified} =
             Provenance.resolve(
               :intent_status,
               agent_id,
               newest.id,
               newest_status["payload"]
             )

    assert_missing_sidecar(:intent, agent_id, first)
    assert_missing_status_sidecar(agent_id, first.id, first_status_payload)

    restart_intent_store(buffer_size: original_state.buffer_size)
  end

  test "missing status sidecar is rebound from the verified durable mutation baseline", %{
    agent_id: agent_id
  } do
    intent = Intent.think("status sidecar reload")
    supplied = taint(:trusted, :internal, 0b1100, :verified, "status_reload")

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, supplied)
    assert {:ok, ^intent} = IntentStore.lock_intent(agent_id, intent.id)

    durable_before = durable_record(agent_id)
    status_payload = get_in(durable_before.data, ["statuses", intent.id, "payload"])
    status_taint = verified_nested_taint(durable_before.data["statuses"][intent.id])

    assert :ok = Provenance.delete(:intent_status, agent_id, intent.id)
    assert_missing_status_sidecar(agent_id, intent.id, status_payload)

    assert :ok = IntentStore.complete_intent(agent_id, intent.id)

    completed = durable_record(agent_id)
    completed_payload = get_in(completed.data, ["statuses", intent.id, "payload"])

    assert {:ok, ^status_taint, :verified} =
             Provenance.resolve(:intent_status, agent_id, intent.id, completed_payload)

    assert completed_payload["status"] == "completed"
    assert completed != durable_before
  end

  test "post-persist live install failure returns committed success and reloads the aggregate", %{
    agent_id: agent_id
  } do
    intent = Intent.think("install after persistence")
    supplied = taint(:untrusted, :restricted, 0, :verified, "install_failure")

    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Provenance)

    on_exit(fn ->
      if Process.whereis(Provenance) == nil do
        Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance)
      end
    end)

    assert {:ok, ^intent} =
             IntentStore.record_intent_tainted(agent_id, intent, supplied)

    assert IntentStore.recent_intents(agent_id) == [intent]

    persisted = durable_record(agent_id)
    assert get_in(persisted.data, ["intents", Access.at(0), "payload", "id"]) == intent.id

    assert {:ok, pid} = Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance)
    assert Process.alive?(pid)
    assert :ok = IntentStore.reload_for_agent(agent_id)

    assert {:ok, [{restored, :verified}]} = IntentStore.recent_intents_tainted(agent_id)
    assert restored.value == intent
    assert restored.taint == supplied
  end

  test "security regression: committed fail projection error cannot trigger a double increment",
       %{
         agent_id: agent_id
       } do
    stop_supervised!(BufferedStore)
    backend_table = :ets.new(:intent_projection_failure_backend, [:set, :public])

    start_supervised!(
      {BufferedStore,
       name: @store_name,
       backend: ProjectionFailureBackend,
       backend_opts: [table: backend_table],
       write_mode: :sync,
       ack_mode: :backend}
    )

    intent = Intent.think("single committed failure")
    supplied = taint(:untrusted, :restricted, 0, :verified, "single_failure")

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, supplied)
    assert :ok = ProjectionFailureBackend.arm(backend_table, self())

    first_result =
      IntentStore.fail_intent_tainted(agent_id, intent.id, "commit once", supplied)

    assert_receive {:backend_committed, "intents:" <> ^agent_id}
    assert Process.whereis(Provenance) == nil

    assert {:ok, pid} = Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance)
    assert Process.alive?(pid)
    assert :ok = IntentStore.reload_for_agent(agent_id)

    caller_result =
      case first_result do
        {:ok, _retry_count} = success ->
          success

        {:error, _reason} ->
          IntentStore.fail_intent_tainted(agent_id, intent.id, "commit once", supplied)
      end

    assert caller_result == {:ok, 1}

    persisted_status = durable_record(agent_id).data["statuses"][intent.id]["payload"]
    assert persisted_status["retry_count"] == 1
    assert persisted_status["last_failure_reason"] == "commit once"
  end

  @tag :slow
  test "owner call waits past the default timeout for its definitive mutation reply", %{
    agent_id: agent_id
  } do
    test_pid = self()
    original_state = :sys.get_state(IntentStore)

    :sys.replace_state(IntentStore, fn state ->
      %{
        state
        | embedding_fun: fn _namespace, _key, _content, _opts ->
            send(test_pid, :mutation_installed)
            Process.sleep(5_100)
            :ok
          end
      }
    end)

    on_exit(fn -> restore_intent_store_state(original_state) end)

    intent = Intent.think("definitive owner reply")
    supplied = taint(:untrusted, :restricted, 0, :verified, "slow_owner")

    task =
      Task.async(fn ->
        IntentStore.record_intent_tainted(agent_id, intent, supplied)
      end)

    assert_receive :mutation_installed
    assert {:ok, ^intent} = Task.await(task, 7_000)
    assert [^intent] = IntentStore.recent_intents(agent_id)
  end

  test "ring eviction and pruning remove only deleted sidecars", %{agent_id: agent_id} do
    original_state = :sys.get_state(IntentStore)
    :sys.replace_state(IntentStore, &%{&1 | buffer_size: 2})
    on_exit(fn -> restore_intent_store_state(original_state) end)

    first = Intent.think("first")
    second = Intent.think("second")
    third = Intent.think("third")

    first_taint = taint(:trusted, :internal, 0b1111, :verified, "first")
    second_taint = taint(:derived, :confidential, 0b0111, :corroborated, "second")
    third_taint = taint(:untrusted, :restricted, 0b0011, :plausible, "third")

    assert {:ok, ^first} = IntentStore.record_intent_tainted(agent_id, first, first_taint)
    assert {:ok, ^first} = IntentStore.lock_intent(agent_id, first.id)

    first_status_payload =
      get_in(durable_record(agent_id).data, ["statuses", first.id, "payload"])

    assert {:ok, ^second} = IntentStore.record_intent_tainted(agent_id, second, second_taint)
    assert {:ok, ^third} = IntentStore.record_intent_tainted(agent_id, third, third_taint)

    assert Enum.map(IntentStore.recent_intents(agent_id, limit: 10), & &1.id) == [
             third.id,
             second.id
           ]

    assert_missing_sidecar(:intent, agent_id, first)
    assert_missing_status_sidecar(agent_id, first.id, first_status_payload)

    assert {:ok, values} = IntentStore.recent_intents_tainted(agent_id, limit: 10)

    assert Enum.map(values, fn {value, status} -> {value.value.id, value.taint, status} end) == [
             {third.id, third_taint, :verified},
             {second.id, second_taint, :verified}
           ]

    old = Intent.think("prune", created_at: ~U[2020-01-01 00:00:00Z])
    old_taint = taint(:hostile, :restricted, 0, :unverified, "old")
    assert {:ok, ^old} = IntentStore.record_intent_tainted(agent_id, old, old_taint)

    assert {:ok, 1} =
             IntentStore.fail_intent_tainted(agent_id, old.id, "old failure", old_taint)

    old_status_payload = get_in(durable_record(agent_id).data, ["statuses", old.id, "payload"])
    assert 1 = IntentStore.prune_stale(agent_id, 1_000)
    assert_missing_sidecar(:intent, agent_id, old)
    assert_missing_status_sidecar(agent_id, old.id, old_status_payload)

    assert {:ok, [{survivor, :verified}]} =
             IntentStore.recent_intents_tainted(agent_id, limit: 10)

    assert survivor.value.id == third.id
    assert survivor.taint == third_taint

    first_percept = Percept.success(third.id, %{"sequence" => 1})
    second_percept = Percept.success(third.id, %{"sequence" => 2})
    third_percept = Percept.success(third.id, %{"sequence" => 3})

    assert {:ok, ^first_percept} =
             IntentStore.record_percept_tainted(agent_id, first_percept, first_taint)

    assert {:ok, ^second_percept} =
             IntentStore.record_percept_tainted(agent_id, second_percept, second_taint)

    assert {:ok, ^third_percept} =
             IntentStore.record_percept_tainted(agent_id, third_percept, third_taint)

    assert_missing_sidecar(:percept, agent_id, first_percept)

    assert {:ok, percepts} = IntentStore.recent_percepts_tainted(agent_id, limit: 10)

    assert Enum.map(percepts, fn {value, status} -> {value.value.id, value.taint, status} end) ==
             [
               {third_percept.id, third_taint, :verified},
               {second_percept.id, second_taint, :verified}
             ]
  end

  test "clear removes current and stale intent-domain sidecars", %{agent_id: agent_id} do
    intent = Intent.think("clear status sidecar")
    supplied = taint(:derived, :internal, 0b1010, :verified, "clear_status")
    stale_payload = %{"content" => "not present in the live projection"}

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, supplied)
    assert {:ok, ^intent} = IntentStore.lock_intent(agent_id, intent.id)

    assert :ok = Provenance.put(:intent, agent_id, "stale-intent", stale_payload, supplied)
    assert :ok = Provenance.put(:percept, agent_id, "stale-percept", stale_payload, supplied)

    assert :ok =
             Provenance.put(
               :intent_status,
               agent_id,
               "stale-status",
               stale_payload,
               supplied
             )

    status_payload = get_in(durable_record(agent_id).data, ["statuses", intent.id, "payload"])

    assert :ok = IntentStore.clear(agent_id)
    assert_missing_sidecar(:intent, agent_id, intent)
    assert_missing_status_sidecar(agent_id, intent.id, status_payload)
    assert_missing_provenance(:intent, agent_id, "stale-intent", stale_payload)
    assert_missing_provenance(:percept, agent_id, "stale-percept", stale_payload)
    assert_missing_provenance(:intent_status, agent_id, "stale-status", stale_payload)
  end

  test "reload converges live state after the durable aggregate is deleted", %{
    agent_id: agent_id
  } do
    intent = Intent.think("remote delete convergence")
    supplied = taint(:trusted, :internal, 0b1111, :verified, "remote_delete")

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, supplied)
    assert {:ok, ^intent} = IntentStore.lock_intent(agent_id, intent.id)

    status_payload = get_in(durable_record(agent_id).data, ["statuses", intent.id, "payload"])

    assert :ok = BufferedStore.delete("intents:#{agent_id}", name: @store_name)
    assert :ok = IntentStore.reload_for_agent(agent_id)

    assert IntentStore.recent_intents(agent_id) == []
    assert {:error, :not_found} = IntentStore.get_intent(agent_id, intent.id)
    assert_missing_sidecar(:intent, agent_id, intent)
    assert_missing_status_sidecar(agent_id, intent.id, status_payload)
  end

  test "raw import preserves surviving labels and gives imported items an explicit fallback", %{
    agent_id: agent_id
  } do
    existing = Intent.think("existing labeled")
    existing_taint = taint(:derived, :internal, 0b0101, :verified, "existing")
    imported = Intent.think("imported raw")

    assert {:ok, ^existing} =
             IntentStore.record_intent_tainted(agent_id, existing, existing_taint)

    imported_map =
      imported
      |> intent_payload()
      |> Map.put("status", "locked")
      |> Map.put("retry_count", 2)

    assert :ok = IntentStore.import_intents(agent_id, [imported_map])

    assert {:ok, values} = IntentStore.recent_intents_tainted(agent_id, limit: 10)
    by_id = Map.new(values, fn {value, status} -> {value.value.id, {value.taint, status}} end)

    assert by_id[existing.id] == {existing_taint, :verified}
    assert by_id[imported.id] == {TaintEnvelope.missing_fallback(), :legacy_unlabeled}

    assert {:ok, _intent, imported_status} = IntentStore.get_intent(agent_id, imported.id)
    assert imported_status == %{status: :locked, retry_count: 2}

    restart_intent_store()

    assert {:ok, reloaded} = IntentStore.recent_intents_tainted(agent_id, limit: 10)

    reloaded_by_id =
      Map.new(reloaded, fn {value, status} -> {value.value.id, {value.taint, status}} end)

    assert reloaded_by_id[existing.id] == {existing_taint, :verified}
    assert reloaded_by_id[imported.id] == {TaintEnvelope.missing_fallback(), :legacy_unlabeled}
  end

  test "legacy aggregate reload preserves lifecycle status and stays untrusted", %{
    agent_id: agent_id
  } do
    intent = Intent.think("legacy durable")
    locked_at = ~U[2026-08-04 12:00:00Z]

    legacy = %{
      "intents" => [intent_payload(intent)],
      "percepts" => [],
      "statuses" => %{
        intent.id => %{
          "status" => :locked,
          "retry_count" => 3,
          "locked_at" => DateTime.to_iso8601(locked_at)
        }
      }
    }

    put_durable(agent_id, legacy, %{})
    assert :ok = IntentStore.reload_for_agent(agent_id)

    assert {:ok, restored, status} = IntentStore.get_intent(agent_id, intent.id)
    assert restored.id == intent.id
    assert status == %{status: :locked, retry_count: 3, locked_at: locked_at}

    assert {:ok, [{value, :legacy_unlabeled}]} =
             IntentStore.recent_intents_tainted(agent_id)

    assert value.taint == TaintEnvelope.missing_fallback()
  end

  test "malformed, versionless, unknown, mismatched item and aggregate provenance is hostile", %{
    agent_id: base_agent_id
  } do
    cases = [
      :outer_payload_mismatch,
      :malformed_outer,
      :nested_payload_mismatch,
      :malformed_nested,
      :unknown_version,
      :versionless,
      :aggregate_label_mismatch
    ]

    Enum.each(cases, fn case_name ->
      agent_id = "#{base_agent_id}_#{case_name}"
      on_exit(fn -> IntentStore.clear(agent_id) end)

      intent = Intent.think("durable #{case_name}")
      supplied = taint(:untrusted, :confidential, 0b0011, :plausible, "durable")

      assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, supplied)
      original = durable_record(agent_id)
      original_outer = verified_outer_taint(original)

      {data, metadata} = corrupt_record(case_name, original, original_outer)
      put_durable(agent_id, data, metadata)
      assert :ok = IntentStore.reload_for_agent(agent_id)

      assert {:ok, [{value, :invalid_durable_provenance}]} =
               IntentStore.recent_intents_tainted(agent_id)

      assert value.taint == TaintEnvelope.invalid_fallback()
    end)
  end

  test "malformed or payload-mismatched status provenance makes the aggregate hostile", %{
    agent_id: base_agent_id
  } do
    Enum.each([:payload_mismatch, :malformed_envelope], fn case_name ->
      agent_id = "#{base_agent_id}_status_#{case_name}"
      on_exit(fn -> IntentStore.clear(agent_id) end)

      intent = Intent.think("status provenance #{case_name}")
      supplied = taint(:trusted, :internal, 0xFF, :verified, "status_nested")

      assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, supplied)

      assert {:ok, 1} =
               IntentStore.fail_intent_tainted(
                 agent_id,
                 intent.id,
                 "verified failure",
                 supplied
               )

      record = durable_record(agent_id)
      outer_taint = verified_outer_taint(record)

      data =
        case case_name do
          :payload_mismatch ->
            put_in(
              record.data,
              ["statuses", intent.id, "payload", "last_failure_reason"],
              "changed after binding"
            )

          :malformed_envelope ->
            put_in(
              record.data,
              ["statuses", intent.id, "provenance"],
              %{"version" => 1}
            )
        end

      put_durable(agent_id, data, outer_metadata(data, outer_taint))
      assert :ok = IntentStore.reload_for_agent(agent_id)

      assert {:ok, [{value, :invalid_durable_provenance}]} =
               IntentStore.recent_intents_tainted(agent_id)

      assert value.taint == TaintEnvelope.invalid_fallback()

      assert {:ok, _intent, %{status: :completed}} =
               IntentStore.get_intent(agent_id, intent.id)
    end)
  end

  test "an unlabeled outer aggregate never inherits trusted nested provenance", %{
    agent_id: agent_id
  } do
    intent = Intent.think("outer label missing")
    trusted = taint(:trusted, :public, 0xFF, :verified, "trusted_nested")

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, trusted)
    record = durable_record(agent_id)
    put_durable(agent_id, record.data, %{})
    assert {:ok, expected} = Taint.join(trusted, TaintEnvelope.missing_fallback())

    assert :ok = IntentStore.reload_for_agent(agent_id)
    assert {:ok, [{value, :legacy_unlabeled}]} = IntentStore.recent_intents_tainted(agent_id)
    assert value.taint == expected
    assert value.taint.level == :untrusted
    assert value.taint.sensitivity == :restricted
    assert value.taint.sanitizations == 0
    assert value.taint.confidence == :unverified
  end

  test "valid hostile inner labels survive a missing outer aggregate envelope", %{
    agent_id: agent_id
  } do
    intent = Intent.think("hostile nested provenance")
    hostile = taint(:hostile, :restricted, 0, :unverified, "hostile_nested")
    fallback = TaintEnvelope.missing_fallback()

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, hostile)

    assert {:ok, 1} =
             IntentStore.fail_intent_tainted(agent_id, intent.id, "hostile reason", hostile)

    record = durable_record(agent_id)
    inner_item_taint = verified_nested_taint(hd(record.data["intents"]))
    status = record.data["statuses"][intent.id]
    inner_status_taint = verified_nested_taint(status)

    assert {:ok, expected_item_taint} = Taint.join(inner_item_taint, fallback)
    assert {:ok, expected_status_taint} = Taint.join(inner_status_taint, fallback)

    put_durable(agent_id, record.data, %{})
    assert :ok = IntentStore.reload_for_agent(agent_id)

    assert {:ok, [{value, :legacy_unlabeled}]} = IntentStore.recent_intents_tainted(agent_id)
    assert value.value == intent
    assert value.taint == expected_item_taint
    assert value.taint.level == :hostile
    assert value.taint.sensitivity == :restricted
    assert value.taint.sanitizations == 0
    assert value.taint.confidence == :unverified

    assert {:ok, ^expected_status_taint, :verified} =
             Provenance.resolve(
               :intent_status,
               agent_id,
               intent.id,
               status["payload"]
             )
  end

  test "verified durable reader restores the exact hostile item label after sidecar restart", %{
    agent_id: agent_id
  } do
    intent = Intent.think("sidecar restart")
    supplied = taint(:hostile, :restricted, 0, :unverified, "restart_source")
    stale = taint(:trusted, :public, 0xFF, :verified, "stale_sidecar")

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, supplied)

    assert :ok =
             Provenance.put(:intent, agent_id, intent.id, intent_payload(intent), stale)

    assert {:ok, [{reconciled, :verified}]} = IntentStore.recent_intents_tainted(agent_id)
    assert reconciled.taint == supplied

    restart_provenance()

    assert {:ok, [{restored, :verified}]} = IntentStore.recent_intents_tainted(agent_id)
    assert restored.value == intent
    assert restored.taint == supplied

    assert {:ok, ^supplied, :verified} =
             Provenance.resolve(:intent, agent_id, intent.id, intent_payload(intent))
  end

  test "verified durable baseline replaces stale protected item and status labels", %{
    agent_id: agent_id
  } do
    intent = Intent.think("stale protected baseline")
    hostile = taint(:hostile, :restricted, 0, :unverified, "durable_hostile")
    weaker = taint(:trusted, :public, 0xFF, :verified, "stale_weaker")

    assert {:ok, expected_item_taint} = Taint.join(hostile, weaker)
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, hostile)

    assert {:ok, 1} =
             IntentStore.fail_intent_tainted(agent_id, intent.id, "hostile status", hostile)

    failed = durable_record(agent_id)
    status_payload = failed.data["statuses"][intent.id]["payload"]
    status_taint = verified_nested_taint(failed.data["statuses"][intent.id])

    assert :ok = Provenance.put(:intent, agent_id, intent.id, intent_payload(intent), weaker)
    assert :ok = Provenance.put(:intent_status, agent_id, intent.id, status_payload, weaker)

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, weaker)

    after_record = durable_record(agent_id)
    assert verified_nested_taint(hd(after_record.data["intents"])) == expected_item_taint

    assert {:ok, expected_status_after_record} =
             Taint.join_many([expected_item_taint, status_taint])

    assert verified_nested_taint(after_record.data["statuses"][intent.id]) ==
             expected_status_after_record

    current_status_payload = after_record.data["statuses"][intent.id]["payload"]

    assert :ok =
             Provenance.put(:intent_status, agent_id, intent.id, current_status_payload, weaker)

    assert :ok = IntentStore.complete_intent(agent_id, intent.id)
    completed = durable_record(agent_id)

    assert {:ok, expected_completed_status} =
             Taint.join_many([expected_item_taint, expected_status_after_record])

    assert verified_nested_taint(completed.data["statuses"][intent.id]) ==
             expected_completed_status
  end

  test "record and status mutations rebind hostile durable labels after sidecar restart", %{
    agent_id: agent_id
  } do
    intent = Intent.think("hostile durable mutation baseline")
    hostile = taint(:hostile, :restricted, 0, :unverified, "hostile_baseline")
    weaker = taint(:trusted, :public, 0xFF, :verified, "weaker_mutation")

    assert {:ok, expected_item_taint} = Taint.join(hostile, weaker)
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, hostile)

    assert {:ok, 1} =
             IntentStore.fail_intent_tainted(agent_id, intent.id, "hostile failure", hostile)

    status_before = durable_record(agent_id).data["statuses"][intent.id]
    status_taint = verified_nested_taint(status_before)

    restart_provenance()

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, weaker)

    after_record = durable_record(agent_id)
    assert verified_nested_taint(hd(after_record.data["intents"])) == expected_item_taint

    assert {:ok, expected_status_after_record} =
             Taint.join_many([expected_item_taint, status_taint])

    assert verified_nested_taint(after_record.data["statuses"][intent.id]) ==
             expected_status_after_record

    restart_provenance()

    assert :ok = IntentStore.complete_intent(agent_id, intent.id)

    after_complete = durable_record(agent_id)
    completed_status = after_complete.data["statuses"][intent.id]
    assert completed_status["payload"]["status"] == "completed"

    assert {:ok, expected_completed_status} =
             Taint.join_many([expected_item_taint, expected_status_after_record])

    assert verified_nested_taint(completed_status) == expected_completed_status

    assert {:ok, expected_outer_taint} =
             Taint.join_many([expected_item_taint, expected_completed_status])

    assert verified_outer_taint(after_complete) == expected_outer_taint
  end

  test "intent embeddings receive provenance bound to the exact emitted content", %{
    agent_id: agent_id
  } do
    test_pid = self()
    original_state = :sys.get_state(IntentStore)

    probe = fn namespace, key, content, opts ->
      {:ok, envelope} = TaintEnvelope.new(content, Keyword.fetch!(opts, :taint))
      {:ok, persisted} = TaintEnvelope.to_map(envelope)
      send(test_pid, {:embedding, namespace, key, content, persisted, opts})
      :ok
    end

    :sys.replace_state(IntentStore, &%{&1 | embedding_fun: probe})
    on_exit(fn -> restore_intent_store_state(original_state) end)

    intent = Intent.action(:shell_execute, %{"command" => "mix test"})
    supplied = taint(:untrusted, :confidential, 0, :verified, "embedding_source")

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, supplied)

    assert_receive {:embedding, "intents", key, content, envelope, opts}
    assert key == "#{agent_id}:#{intent.id}"
    assert opts[:taint] == supplied
    assert {:ok, verified} = TaintEnvelope.verify(envelope, content)
    assert verified.taint == supplied
    assert {:error, :payload_mismatch} = TaintEnvelope.verify(envelope, content <> " changed")

    weaker = taint(:trusted, :public, 0xFF, :verified, "embedding_rewrite")
    assert {:ok, expected} = Taint.join(supplied, weaker)
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, weaker)

    assert_receive {:embedding, "intents", ^key, ^content, rewritten_envelope, rewritten_opts}
    assert rewritten_opts[:taint] == expected
    assert {:ok, rewritten} = TaintEnvelope.verify(rewritten_envelope, content)
    assert rewritten.taint == expected
  end

  defp durable_record(agent_id) do
    assert {:ok, %Record{} = record} =
             BufferedStore.get("intents:#{agent_id}", name: @store_name)

    record
  end

  defp verified_outer_taint(%Record{data: data, metadata: %{"taint" => persisted}}) do
    assert {:ok, envelope} = TaintEnvelope.verify(persisted, data)
    envelope.taint
  end

  defp verified_nested_taint(%{"payload" => payload, "provenance" => persisted}) do
    assert {:ok, envelope} = TaintEnvelope.verify(persisted, payload)
    envelope.taint
  end

  defp assert_tainted_inventory(agent_id, domain, expected) do
    result =
      case domain do
        :intent -> IntentStore.recent_intents_tainted(agent_id, limit: 10)
        :percept -> IntentStore.recent_percepts_tainted(agent_id, limit: 10)
      end

    assert {:ok, values} = result

    assert Enum.map(values, fn {value, status} -> {value.value.id, value.taint, status} end) ==
             Enum.map(expected, fn {id, taint} -> {id, taint, :verified} end)
  end

  defp corrupt_record(:outer_payload_mismatch, record, _outer_taint) do
    data = mutate_first_intent_payload(record.data)
    {data, record.metadata}
  end

  defp corrupt_record(:malformed_outer, record, _outer_taint) do
    {record.data, %{"taint" => %{"version" => 1}}}
  end

  defp corrupt_record(:nested_payload_mismatch, record, outer_taint) do
    data = mutate_first_intent_payload(record.data)
    {data, outer_metadata(data, outer_taint)}
  end

  defp corrupt_record(:malformed_nested, record, outer_taint) do
    data = put_in(record.data, ["intents", Access.at(0), "provenance"], %{"version" => 1})
    {data, outer_metadata(data, outer_taint)}
  end

  defp corrupt_record(:unknown_version, record, outer_taint) do
    data = Map.put(record.data, "version", 999)
    {data, outer_metadata(data, outer_taint)}
  end

  defp corrupt_record(:versionless, record, outer_taint) do
    data = Map.delete(record.data, "version")
    {data, outer_metadata(data, outer_taint)}
  end

  defp corrupt_record(:aggregate_label_mismatch, record, _outer_taint) do
    mismatched = taint(:trusted, :public, 0xFF, :verified, "forged_aggregate")
    {record.data, outer_metadata(record.data, mismatched)}
  end

  defp mutate_first_intent_payload(data) do
    put_in(
      data,
      ["intents", Access.at(0), "payload", "reasoning"],
      "durable payload changed"
    )
  end

  defp outer_metadata(data, taint) do
    {:ok, envelope} = TaintEnvelope.new(data, taint)
    {:ok, persisted} = TaintEnvelope.to_map(envelope)
    %{"taint" => persisted}
  end

  defp nested_entry_with_taint(payload, taint) do
    {:ok, envelope} = TaintEnvelope.new(payload, taint)
    {:ok, provenance} = TaintEnvelope.to_map(envelope)
    %{"payload" => payload, "provenance" => provenance}
  end

  defp put_durable(agent_id, data, metadata) do
    key = "intents:#{agent_id}"
    record = Record.new(key, data, id: "memory:#{key}", metadata: metadata)
    assert :ok = BufferedStore.put(key, record, name: @store_name)
  end

  defp intent_payload(%Intent{} = intent) do
    intent
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp assert_missing_sidecar(:intent, agent_id, %Intent{} = intent) do
    assert {:ok, taint, :legacy_unlabeled} =
             Provenance.resolve(:intent, agent_id, intent.id, intent_payload(intent))

    assert taint == TaintEnvelope.missing_fallback()
  end

  defp assert_missing_sidecar(:percept, agent_id, %Percept{} = percept) do
    payload = percept |> Jason.encode!() |> Jason.decode!()

    assert {:ok, taint, :legacy_unlabeled} =
             Provenance.resolve(:percept, agent_id, percept.id, payload)

    assert taint == TaintEnvelope.missing_fallback()
  end

  defp assert_missing_status_sidecar(agent_id, intent_id, payload) do
    assert {:ok, taint, :legacy_unlabeled} =
             Provenance.resolve(:intent_status, agent_id, intent_id, payload)

    assert taint == TaintEnvelope.missing_fallback()
  end

  defp assert_missing_provenance(domain, agent_id, item_id, payload) do
    assert {:ok, taint, :legacy_unlabeled} =
             Provenance.resolve(domain, agent_id, item_id, payload)

    assert taint == TaintEnvelope.missing_fallback()
  end

  defp restart_intent_store(opts \\ []) do
    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, IntentStore)
    assert :ok = Supervisor.delete_child(Arbor.Memory.Supervisor, IntentStore)

    assert {:ok, pid} =
             Supervisor.start_child(Arbor.Memory.Supervisor, {IntentStore, opts})

    assert Process.alive?(pid)
  end

  defp restart_provenance do
    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Provenance)
    assert {:ok, pid} = Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance)
    assert Process.alive?(pid)
  end

  defp restore_intent_store_state(original_state) do
    if Process.whereis(IntentStore) do
      :sys.replace_state(IntentStore, fn state ->
        %{
          state
          | buffer_size: original_state.buffer_size,
            embedding_fun: original_state.embedding_fun
        }
      end)
    end
  end

  defp owner_call_queued?(owner, matcher) do
    case Process.info(owner, :messages) do
      {:messages, messages} ->
        Enum.any?(messages, fn
          {:"$gen_call", _from, request} -> matcher.(request)
          _message -> false
        end)

      _ ->
        false
    end
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(5)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: false

  defp taint(level, sensitivity, sanitizations, confidence, source) do
    {:ok, taint} =
      Taint.new(%{
        level: level,
        sensitivity: sensitivity,
        sanitizations: sanitizations,
        confidence: confidence,
        source: source,
        chain: []
      })

    taint
  end
end
