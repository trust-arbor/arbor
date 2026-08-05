defmodule Arbor.Memory.IntentStoreProvenanceTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Memory.{Intent, Percept}
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Memory.{IntentStore, Provenance}
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @store_name :arbor_memory_durable

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

    assert status_envelope.taint == fallback
    assert {:ok, expected_outer} = Taint.join_many([trusted, fallback])
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

    assert completed_envelope.taint == fallback
    assert verified_outer_taint(completed_record) == expected_outer
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

  test "live payload mutation resolves as hostile instead of retaining its old label", %{
    agent_id: agent_id
  } do
    intent = Intent.think("original")
    supplied = taint(:trusted, :public, 0, :verified, "trusted_input")

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, supplied)

    [{^agent_id, data}] = :ets.lookup(:arbor_memory_intents, agent_id)
    [stored] = data.intents
    mutated = %{stored | reasoning: "mutated after labeling"}
    true = :ets.insert(:arbor_memory_intents, {agent_id, %{data | intents: [mutated]}})

    assert {:ok, [{value, :invalid_durable_provenance}]} =
             IntentStore.recent_intents_tainted(agent_id)

    assert value.value == mutated
    assert value.taint == TaintEnvelope.invalid_fallback()
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

    restart_intent_store()

    assert {:ok, restored, status} = IntentStore.get_intent(agent_id, intent.id)
    assert restored.id == intent.id
    assert status.status == :completed
    assert status.retry_count == 1
    assert %DateTime{} = status.completed_at

    assert {:ok, [{value, :verified}]} = IntentStore.recent_intents_tainted(agent_id)
    assert value.taint == supplied
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
    assert {:ok, ^second} = IntentStore.record_intent_tainted(agent_id, second, second_taint)
    assert {:ok, ^third} = IntentStore.record_intent_tainted(agent_id, third, third_taint)

    assert Enum.map(IntentStore.recent_intents(agent_id, limit: 10), & &1.id) == [
             third.id,
             second.id
           ]

    assert_missing_sidecar(:intent, agent_id, first)

    assert {:ok, values} = IntentStore.recent_intents_tainted(agent_id, limit: 10)

    assert Enum.map(values, fn {value, status} -> {value.value.id, value.taint, status} end) == [
             {third.id, third_taint, :verified},
             {second.id, second_taint, :verified}
           ]

    old = Intent.think("prune", created_at: ~U[2020-01-01 00:00:00Z])
    old_taint = taint(:hostile, :restricted, 0, :unverified, "old")
    assert {:ok, ^old} = IntentStore.record_intent_tainted(agent_id, old, old_taint)
    assert 1 = IntentStore.prune_stale(agent_id, 1_000)
    assert_missing_sidecar(:intent, agent_id, old)

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

    assert :ok = IntentStore.reload_for_agent(agent_id)
    assert {:ok, [{value, :legacy_unlabeled}]} = IntentStore.recent_intents_tainted(agent_id)
    assert value.taint == TaintEnvelope.missing_fallback()
  end

  test "sidecar restart blocks mutation until verified durable reload restores exact labels", %{
    agent_id: agent_id
  } do
    intent = Intent.think("sidecar restart")
    supplied = taint(:untrusted, :restricted, 0b0101, :verified, "restart_source")

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, supplied)
    restart_provenance()

    assert {:ok, [{missing, :legacy_unlabeled}]} = IntentStore.recent_intents_tainted(agent_id)
    assert missing.taint == TaintEnvelope.missing_fallback()
    assert {:error, :store_unavailable} = IntentStore.complete_intent(agent_id, intent.id)
    assert {:ok, _intent, %{status: :pending}} = IntentStore.get_intent(agent_id, intent.id)

    assert :ok = IntentStore.reload_for_agent(agent_id)
    assert {:ok, [{restored, :verified}]} = IntentStore.recent_intents_tainted(agent_id)
    assert restored.taint == supplied
    assert :ok = IntentStore.complete_intent(agent_id, intent.id)
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

  defp restart_intent_store do
    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, IntentStore)
    assert {:ok, pid} = Supervisor.restart_child(Arbor.Memory.Supervisor, IntentStore)
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
