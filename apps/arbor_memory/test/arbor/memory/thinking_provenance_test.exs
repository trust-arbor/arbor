defmodule Arbor.Memory.ThinkingProvenanceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{Taint, TaintedValue, TaintEnvelope}
  alias Arbor.Memory.{MemoryStore, Provenance, Thinking, ThinkingCodec}
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @store_name :arbor_memory_durable

  defmodule FailingNodeRestartBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    @impl true
    def put(_key, _value, _opts), do: {:error, :forced_failure}

    @impl true
    def get(_key, _opts), do: {:error, :forced_failure}

    @impl true
    def delete(_key, _opts), do: {:error, :forced_failure}

    @impl true
    def list(_opts), do: {:error, :forced_failure}

    @impl true
    def compare_and_swap(_key, _expected, _replacement, _opts),
      do: {:error, :forced_failure}

    @impl true
    def compare_and_delete(_key, _expected, _opts), do: {:error, :forced_failure}

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule ConflictInjectingNodeRestartBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Persistence.QueryableStore.ETS

    @impl true
    def put(key, value, opts) do
      inject_competitor_once(key, opts)
      ETS.put(key, value, opts)
    end

    @impl true
    def get(key, opts), do: ETS.get(key, opts)

    @impl true
    def delete(key, opts), do: ETS.delete(key, opts)

    @impl true
    def list(opts), do: ETS.list(opts)

    @impl true
    def query(filter, opts), do: ETS.query(filter, opts)

    @impl true
    def compare_and_swap(key, expected, replacement, opts) do
      inject_competitor_once(key, opts)
      ETS.compare_and_swap(key, expected, replacement, opts)
    end

    @impl true
    def compare_and_delete(key, expected, opts),
      do: ETS.compare_and_delete(key, expected, opts)

    @impl true
    def durability_class(_opts), do: :node_restart

    defp inject_competitor_once(key, opts) do
      control = Keyword.fetch!(opts, :control)

      competitor =
        Agent.get_and_update(control, fn state ->
          if state.target_key == key and not state.injected? do
            {state.competitor, %{state | injected?: true}}
          else
            {nil, state}
          end
        end)

      if competitor do
        {:ok, _stored} = ETS.compare_and_swap(key, :not_found, competitor, opts)
      end

      :ok
    end
  end

  setup do
    start_supervised!({BufferedStore, name: @store_name, backend: nil, write_mode: :sync})
    agent_id = "thinking_provenance_#{System.unique_integer([:positive])}"
    :ok = Thinking.clear(agent_id)
    on_exit(fn -> Thinking.clear(agent_id) end)
    %{agent_id: agent_id}
  end

  test "security regression: raw compatibility is conservative and logs no content", %{
    agent_id: agent_id
  } do
    secret = "raw-private-thinking-#{System.unique_integer([:positive])}"
    parent = self()

    assert {:ok, subscription_id} =
             Arbor.Signals.subscribe("memory.thinking_recorded", fn signal ->
               send(parent, {:thinking_signal, signal})
               :ok
             end)

    on_exit(fn -> Arbor.Signals.unsubscribe(subscription_id) end)

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, _entry} = Thinking.record_thinking(agent_id, secret)
      end)

    refute log =~ secret
    assert_receive {:thinking_signal, signal}
    refute inspect(signal.data) =~ secret
    assert signal.data.text_bytes == byte_size(secret)
    refute Map.has_key?(signal.data, :text_preview)

    assert {:ok, [{%TaintedValue{value: %{text: ^secret}, taint: taint}, status}]} =
             Thinking.recent_thinking_tainted(agent_id)

    assert status == :legacy_unlabeled
    assert taint.level == :untrusted
    assert taint.sensitivity == :restricted
    assert taint.confidence == :unverified
    assert taint.source == "legacy_unlabeled"
  end

  test "security regression: legacy public thinking signal helper emits no content", %{
    agent_id: agent_id
  } do
    secret = "legacy-helper-secret-#{System.unique_integer([:positive])}"
    parent = self()

    assert {:ok, subscription_id} =
             Arbor.Signals.subscribe("memory.thinking_recorded", fn signal ->
               send(parent, {:legacy_thinking_signal, signal})
               :ok
             end)

    on_exit(fn -> Arbor.Signals.unsubscribe(subscription_id) end)

    assert :ok = Arbor.Memory.Signals.Lifecycle.emit_thinking_recorded(agent_id, secret)
    assert_receive {:legacy_thinking_signal, signal}
    refute inspect(signal.data) =~ secret
    refute Map.has_key?(signal.data, :text_preview)
    assert signal.data.text_bytes == byte_size(secret)
  end

  test "security regression: absent shared store is not replaced by live ETS authority", %{
    agent_id: agent_id
  } do
    label = %Taint{level: :hostile, sensitivity: :restricted, source: "store_owner_required"}

    assert {:ok, entry} =
             Thinking.record_thinking_tainted(agent_id, "owner-backed entry", label)

    assert :ok = stop_supervised(BufferedStore)
    refute MemoryStore.available?()

    assert Thinking.recent_thinking(agent_id) == []
    assert {:error, :store_unavailable} = Thinking.recent_thinking_tainted(agent_id)

    assert {:error, :store_unavailable} =
             Thinking.record_thinking_tainted(agent_id, "must not land", %Taint{})

    assert Thinking.recent_thinking(agent_id) == []
    assert is_binary(entry.id)

    start_supervised!({BufferedStore, name: @store_name, backend: nil, write_mode: :sync})
  end

  test "security regression: configured backend failure never falls back to forged ETS", %{
    agent_id: agent_id
  } do
    restart_memory_store(FailingNodeRestartBackend, collection: :thinking_failing_backend)

    forged = %{
      id: "thk_forged_backend_fallback",
      agent_id: agent_id,
      text: "forged projection content",
      significant: false,
      created_at: DateTime.utc_now(),
      metadata: %{}
    }

    true = :ets.insert(:arbor_memory_thinking, {agent_id, [forged]})

    cached =
      Record.new("thinking:#{agent_id}", %{"entries" => []}, id: "memory:thinking:#{agent_id}")

    true = :ets.insert(@store_name, {"thinking:#{agent_id}", cached})

    assert Thinking.recent_thinking(agent_id) == []
    assert {:error, :store_unavailable} = Thinking.recent_thinking_tainted(agent_id)

    assert {:error, :store_unavailable} =
             Thinking.record_thinking_tainted(
               agent_id,
               "must not enter failed authority",
               %Taint{}
             )
  end

  test "security regression: CAS conflict reloads fresh authority without losing either writer",
       %{
         agent_id: agent_id
       } do
    competing_label = %Taint{
      level: :hostile,
      sensitivity: :restricted,
      source: "competing_writer"
    }

    competing_entry = %{
      id: "thk_competing_writer",
      agent_id: agent_id,
      text: "concurrent durable thought",
      significant: false,
      created_at: DateTime.utc_now(),
      metadata: %{}
    }

    assert {:ok, competing_aggregate, competing_outer} =
             ThinkingCodec.encode_aggregate([{competing_entry, competing_label}])

    assert {:ok, competing_envelope} =
             TaintEnvelope.new(competing_aggregate, competing_outer)

    assert {:ok, competing_envelope_map} = TaintEnvelope.to_map(competing_envelope)

    physical_key = "thinking:#{agent_id}"

    competing_record =
      Record.new(physical_key, competing_aggregate,
        id: "memory:#{physical_key}",
        metadata: %{"taint" => competing_envelope_map}
      )

    backend_name = :thinking_conflict_backend_store

    start_supervised!(
      {Arbor.Persistence.QueryableStore.ETS, name: backend_name},
      id: backend_name
    )

    control =
      start_supervised!(
        {Agent,
         fn ->
           %{
             target_key: physical_key,
             competitor: competing_record,
             injected?: false
           }
         end},
        id: :thinking_conflict_control
      )

    restart_memory_store(ConflictInjectingNodeRestartBackend,
      collection: backend_name,
      backend_opts: [control: control]
    )

    local_label = %Taint{level: :derived, sensitivity: :internal, source: "local_writer"}

    assert {:ok, local_entry} =
             Thinking.record_thinking_tainted(agent_id, "local durable thought", local_label)

    assert Agent.get(control, & &1.injected?)
    assert {:ok, items} = Thinking.recent_thinking_tainted(agent_id, limit: 10)

    assert_taints_by_id(items, %{
      local_entry.id => local_label,
      competing_entry.id => competing_label
    })

    assert Enum.map(items, fn {value, _status} -> value.value.id end) == [
             local_entry.id,
             competing_entry.id
           ]
  end

  test "mixed labels remain item-specific across exact durable reload", %{agent_id: agent_id} do
    first_taint = %Taint{
      level: :derived,
      sensitivity: :internal,
      sanitizations: 0b00010011,
      confidence: :verified,
      source: "first_source"
    }

    second_taint = %Taint{
      level: :untrusted,
      sensitivity: :confidential,
      sanitizations: 0b00000011,
      confidence: :plausible,
      source: "second_source"
    }

    assert {:ok, first} =
             Thinking.record_thinking_tainted(agent_id, "first durable thought", first_taint)

    assert {:ok, second} =
             Thinking.record_thinking_tainted(agent_id, "second durable thought", second_taint)

    assert {:ok, %Record{data: aggregate, metadata: %{"taint" => outer_envelope}}} =
             BufferedStore.get("thinking:#{agent_id}", name: @store_name)

    assert aggregate["version"] == 1
    assert length(aggregate["entries"]) == 2
    assert {:ok, verified_outer} = TaintEnvelope.verify(outer_envelope, aggregate)
    assert {:ok, expected_outer} = Taint.join_many([second_taint, first_taint])
    assert verified_outer.taint == expected_outer

    assert :ok = Thinking.reload_from_durable()

    assert {:ok, items} = Thinking.recent_thinking_tainted(agent_id, limit: 10)

    by_text =
      Map.new(items, fn {%TaintedValue{value: entry, taint: taint}, status} ->
        {entry.text, {entry.id, taint, status}}
      end)

    assert by_text["first durable thought"] == {first.id, first_taint, :verified}
    assert by_text["second durable thought"] == {second.id, second_taint, :verified}
  end

  test "reload truncation validates the complete persisted aggregate before retaining exact labels",
       %{
         agent_id: agent_id
       } do
    first_taint = %Taint{level: :trusted, sensitivity: :public, source: "truncated_first"}

    second_taint = %Taint{
      level: :untrusted,
      sensitivity: :confidential,
      source: "truncated_second"
    }

    assert {:ok, _first} =
             Thinking.record_thinking_tainted(agent_id, "older persisted item", first_taint)

    assert {:ok, second} =
             Thinking.record_thinking_tainted(agent_id, "newer persisted item", second_taint)

    assert {:ok, %Record{data: aggregate, metadata: %{"taint" => outer_envelope}}} =
             BufferedStore.get("thinking:#{agent_id}", name: @store_name)

    assert length(aggregate["entries"]) == 2
    assert {:ok, verified_outer} = TaintEnvelope.verify(outer_envelope, aggregate)

    assert {:ok, [{decoded, decoded_taint, :verified}]} =
             ThinkingCodec.decode_aggregate(
               agent_id,
               aggregate,
               verified_outer.taint,
               :verified,
               1
             )

    assert decoded.id == second.id
    assert decoded.text == "newer persisted item"
    assert decoded_taint == second_taint
  end

  test "security regression: missing outer metadata cannot lower valid hostile item taint", %{
    agent_id: agent_id
  } do
    hostile = %Taint{
      level: :hostile,
      sensitivity: :confidential,
      confidence: :plausible,
      source: "inner_hostile"
    }

    payload = entry_payload(agent_id, "hostile inner envelope", "thk_inner_hostile")
    assert {:ok, envelope} = TaintEnvelope.new(payload, hostile)
    assert {:ok, persisted_envelope} = TaintEnvelope.to_map(envelope)

    aggregate = %{
      "version" => 1,
      "entries" => [%{"payload" => payload, "provenance" => persisted_envelope}]
    }

    missing = TaintEnvelope.missing_fallback()
    assert {:ok, expected} = Taint.join(hostile, missing)

    assert {:ok, [{decoded, decoded_taint, :legacy_unlabeled}]} =
             ThinkingCodec.decode_aggregate(
               agent_id,
               aggregate,
               missing,
               :legacy_unlabeled,
               10
             )

    assert decoded.id == "thk_inner_hostile"
    assert decoded_taint == expected
    assert decoded_taint.level == :hostile
    assert decoded_taint.sensitivity == :restricted
    assert decoded_taint.confidence == :unverified

    put_raw("thinking:#{agent_id}", aggregate, %{})
    assert :ok = Thinking.reload_from_durable()

    assert {:ok,
            [
              {%TaintedValue{value: %{id: "thk_inner_hostile"}, taint: ^expected},
               :legacy_unlabeled}
            ]} = Thinking.recent_thinking_tainted(agent_id)

    appended_taint = %Taint{level: :trusted, sensitivity: :public, source: "status_append"}

    assert {:ok, appended} =
             Thinking.record_thinking_tainted(
               agent_id,
               "append without upgrading retained status",
               appended_taint
             )

    assert {:ok, reread} = Thinking.recent_thinking_tainted(agent_id, limit: 10)

    statuses =
      Map.new(reread, fn {%TaintedValue{value: entry, taint: taint}, status} ->
        {entry.id, {taint, status}}
      end)

    assert statuses["thk_inner_hostile"] == {expected, :legacy_unlabeled}
    assert statuses[appended.id] == {appended_taint, :verified}
  end

  test "security regression: taint-aware read restores a deleted whole ETS row", %{
    agent_id: agent_id
  } do
    hostile = %Taint{
      level: :hostile,
      sensitivity: :restricted,
      source: "whole_row_hostile"
    }

    trusted = %Taint{level: :trusted, sensitivity: :public, source: "whole_row_trusted"}

    assert {:ok, hostile_entry} =
             Thinking.record_thinking_tainted(agent_id, "whole row hostile", hostile)

    assert {:ok, trusted_entry} =
             Thinking.record_thinking_tainted(agent_id, "whole row trusted", trusted)

    true = :ets.delete(:arbor_memory_thinking, agent_id)

    assert Enum.map(Thinking.recent_thinking(agent_id), & &1.id) ==
             [trusted_entry.id, hostile_entry.id]

    assert {:ok, items} = Thinking.recent_thinking_tainted(agent_id, limit: 10)
    assert_taints_by_id(items, %{hostile_entry.id => hostile, trusted_entry.id => trusted})

    assert Enum.map(Thinking.recent_thinking(agent_id), & &1.id) ==
             [trusted_entry.id, hostile_entry.id]

    true = :ets.delete(:arbor_memory_thinking, agent_id)
    appended_taint = %Taint{level: :derived, sensitivity: :internal, source: "row_append"}

    assert {:ok, appended} =
             Thinking.record_thinking_tainted(
               agent_id,
               "append after row deletion",
               appended_taint
             )

    assert {:ok, items_after_mutation} = Thinking.recent_thinking_tainted(agent_id, limit: 10)

    assert_taints_by_id(items_after_mutation, %{
      appended.id => appended_taint,
      hostile_entry.id => hostile,
      trusted_entry.id => trusted
    })
  end

  test "security regression: taint-aware read restores one deleted hostile ETS item", %{
    agent_id: agent_id
  } do
    hostile = %Taint{
      level: :hostile,
      sensitivity: :restricted,
      source: "single_item_hostile"
    }

    trusted = %Taint{level: :trusted, sensitivity: :public, source: "single_item_trusted"}

    assert {:ok, hostile_entry} =
             Thinking.record_thinking_tainted(agent_id, "single item hostile", hostile)

    assert {:ok, trusted_entry} =
             Thinking.record_thinking_tainted(agent_id, "single item trusted", trusted)

    [{^agent_id, [newest, _deleted]}] = :ets.lookup(:arbor_memory_thinking, agent_id)
    true = :ets.insert(:arbor_memory_thinking, {agent_id, [newest]})

    assert Enum.map(Thinking.recent_thinking(agent_id), & &1.id) ==
             [trusted_entry.id, hostile_entry.id]

    assert {:ok, items} = Thinking.recent_thinking_tainted(agent_id, limit: 10)
    assert_taints_by_id(items, %{hostile_entry.id => hostile, trusted_entry.id => trusted})

    assert Enum.map(Thinking.recent_thinking(agent_id), & &1.id) ==
             [trusted_entry.id, hostile_entry.id]

    [{^agent_id, [newest, _deleted]}] = :ets.lookup(:arbor_memory_thinking, agent_id)
    true = :ets.insert(:arbor_memory_thinking, {agent_id, [newest]})
    appended_taint = %Taint{level: :derived, sensitivity: :internal, source: "item_append"}

    assert {:ok, appended} =
             Thinking.record_thinking_tainted(
               agent_id,
               "append after item deletion",
               appended_taint
             )

    assert {:ok, items_after_mutation} = Thinking.recent_thinking_tainted(agent_id, limit: 10)

    assert_taints_by_id(items_after_mutation, %{
      appended.id => appended_taint,
      hostile_entry.id => hostile,
      trusted_entry.id => trusted
    })
  end

  test "security regression: altered public ETS is repaired for reads and mutations", %{
    agent_id: agent_id
  } do
    label = %Taint{level: :derived, sensitivity: :internal, source: "live_source"}
    assert {:ok, entry} = Thinking.record_thinking_tainted(agent_id, "original", label)

    [{^agent_id, entries}] = :ets.lookup(:arbor_memory_thinking, agent_id)
    mutated = Map.put(entry, :text, "mutated")
    true = :ets.insert(:arbor_memory_thinking, {agent_id, [mutated | tl(entries)]})

    assert [%{text: "original"}] = Thinking.recent_thinking(agent_id, limit: 1)

    assert {:ok, [{%TaintedValue{value: %{text: "original"}, taint: ^label}, :verified}]} =
             Thinking.recent_thinking_tainted(agent_id, limit: 1)

    true = :ets.insert(:arbor_memory_thinking, {agent_id, [mutated]})
    appended_taint = %Taint{level: :trusted, sensitivity: :public, source: "altered_append"}

    assert {:ok, appended} =
             Thinking.record_thinking_tainted(
               agent_id,
               "append after altered projection",
               appended_taint
             )

    assert {:ok, items} = Thinking.recent_thinking_tainted(agent_id, limit: 10)
    assert_taints_by_id(items, %{entry.id => label, appended.id => appended_taint})
  end

  test "security regression: extra public ETS entries are discarded for reads and mutations", %{
    agent_id: agent_id
  } do
    durable_taint = %Taint{
      level: :hostile,
      sensitivity: :restricted,
      source: "extra_durable"
    }

    extra_taint = %Taint{level: :trusted, sensitivity: :public, source: "extra_forged"}

    assert {:ok, durable_entry} =
             Thinking.record_thinking_tainted(agent_id, "durable authority", durable_taint)

    extra_entry = %{
      durable_entry
      | id: "thk_public_extra",
        text: "projection-only extra",
        created_at: DateTime.utc_now()
    }

    assert {:ok, extra_payload} = ThinkingCodec.entry_payload(extra_entry)

    assert :ok =
             Provenance.put(
               :thinking_entry,
               agent_id,
               extra_entry.id,
               extra_payload,
               extra_taint
             )

    true = :ets.insert(:arbor_memory_thinking, {agent_id, [extra_entry, durable_entry]})

    assert {:ok, items} = Thinking.recent_thinking_tainted(agent_id, limit: 10)
    assert_taints_by_id(items, %{durable_entry.id => durable_taint})
    assert Enum.map(Thinking.recent_thinking(agent_id), & &1.id) == [durable_entry.id]

    assert {:ok, cleared_extra, :legacy_unlabeled} =
             Provenance.resolve(:thinking_entry, agent_id, extra_entry.id, extra_payload)

    assert cleared_extra.source == "legacy_unlabeled"

    assert :ok =
             Provenance.put(
               :thinking_entry,
               agent_id,
               extra_entry.id,
               extra_payload,
               extra_taint
             )

    true = :ets.insert(:arbor_memory_thinking, {agent_id, [extra_entry, durable_entry]})
    appended_taint = %Taint{level: :derived, sensitivity: :internal, source: "extra_append"}

    assert {:ok, appended} =
             Thinking.record_thinking_tainted(
               agent_id,
               "append after extra projection",
               appended_taint
             )

    assert {:ok, items_after_mutation} = Thinking.recent_thinking_tainted(agent_id, limit: 10)

    assert_taints_by_id(items_after_mutation, %{
      appended.id => appended_taint,
      durable_entry.id => durable_taint
    })
  end

  test "security regression: wrong-shape ETS rows repair from authority without crashing the owner",
       %{
         agent_id: agent_id
       } do
    label = %Taint{level: :hostile, sensitivity: :restricted, source: "shape_authority"}
    assert {:ok, entry} = Thinking.record_thinking_tainted(agent_id, "durable shape", label)
    owner = Process.whereis(Thinking)
    assert is_pid(owner)

    true = :ets.insert(:arbor_memory_thinking, {agent_id, :not_a_projection, :extra_field})
    assert Enum.map(Thinking.recent_thinking(agent_id), & &1.id) == [entry.id]
    assert Process.alive?(owner)

    assert {:ok, [{%TaintedValue{value: repaired, taint: ^label}, :verified}]} =
             Thinking.recent_thinking_tainted(agent_id)

    assert repaired.id == entry.id
    assert Process.alive?(owner)

    true = :ets.insert(:arbor_memory_thinking, {agent_id, [entry | :improper_tail]})
    assert Enum.map(Thinking.recent_thinking(agent_id), & &1.id) == [entry.id]
    assert :ok = Thinking.clear(agent_id)
    assert Process.alive?(owner)
    assert :ets.lookup(:arbor_memory_thinking, agent_id) == []
  end

  test "security regression: cross-agent ETS tamper cannot launder retained provenance", %{
    agent_id: agent_id
  } do
    other_agent_id = "#{agent_id}_other"
    :ok = Thinking.clear(other_agent_id)
    on_exit(fn -> Thinking.clear(other_agent_id) end)

    original_taint = %Taint{
      level: :untrusted,
      sensitivity: :confidential,
      source: "original_owner"
    }

    forged_taint = %Taint{
      level: :trusted,
      sensitivity: :public,
      confidence: :verified,
      source: "forged_other_owner"
    }

    assert {:ok, entry} =
             Thinking.record_thinking_tainted(agent_id, "owner-bound entry", original_taint)

    copied_entry = %{entry | agent_id: other_agent_id}
    assert {:ok, copied_payload} = ThinkingCodec.entry_payload(copied_entry)

    assert :ok =
             Provenance.put(
               :thinking_entry,
               other_agent_id,
               copied_entry.id,
               copied_payload,
               forged_taint
             )

    on_exit(fn ->
      Provenance.delete(:thinking_entry, other_agent_id, copied_entry.id)
    end)

    true = :ets.insert(:arbor_memory_thinking, {agent_id, [copied_entry]})

    assert {:ok, [{%TaintedValue{value: repaired_entry, taint: ^original_taint}, :verified}]} =
             Thinking.recent_thinking_tainted(agent_id)

    assert repaired_entry.agent_id == agent_id

    true = :ets.insert(:arbor_memory_thinking, {agent_id, [copied_entry]})
    appended_taint = %Taint{level: :derived, sensitivity: :internal, source: "owner_append"}

    assert {:ok, appended} =
             Thinking.record_thinking_tainted(
               agent_id,
               "owner-authoritative append",
               appended_taint
             )

    assert {:ok, items} = Thinking.recent_thinking_tainted(agent_id, limit: 10)
    assert_taints_by_id(items, %{entry.id => original_taint, appended.id => appended_taint})

    assert {:ok, %Record{data: persisted}} =
             BufferedStore.get("thinking:#{agent_id}", name: @store_name)

    assert persisted_payloads = Enum.map(persisted["entries"], & &1["payload"])
    assert Enum.all?(persisted_payloads, &(&1["agent_id"] == agent_id))
    assert Enum.any?(persisted_payloads, &(&1["text"] == "owner-bound entry"))
    assert Enum.any?(persisted_payloads, &(&1["text"] == "owner-authoritative append"))

    assert Enum.all?(Thinking.recent_thinking(agent_id), &(&1.agent_id == agent_id))
  end

  test "security regression: provenance restart cannot weaken hostile durable history", %{
    agent_id: agent_id
  } do
    hostile = %Taint{
      level: :hostile,
      sensitivity: :restricted,
      confidence: :unverified,
      source: "durable_hostile_history"
    }

    assert {:ok, hostile_entry} =
             Thinking.record_thinking_tainted(agent_id, "hostile retained item", hostile)

    on_exit(&ensure_provenance_started/0)
    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Provenance)
    ensure_provenance_started()

    assert {:ok, [{%TaintedValue{value: %{id: hostile_id}, taint: ^hostile}, :verified}]} =
             Thinking.recent_thinking_tainted(agent_id)

    assert hostile_id == hostile_entry.id

    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Provenance)
    ensure_provenance_started()

    assert {:ok, _raw_entry} = Thinking.record_thinking(agent_id, "new raw item")

    assert {:ok, items} = Thinking.recent_thinking_tainted(agent_id, limit: 10)

    by_id =
      Map.new(items, fn {%TaintedValue{value: entry, taint: taint}, status} ->
        {entry.id, {taint, status}}
      end)

    assert by_id[hostile_entry.id] == {hostile, :verified}

    assert {:ok, %Record{data: aggregate, metadata: %{"taint" => outer_envelope}}} =
             BufferedStore.get("thinking:#{agent_id}", name: @store_name)

    persisted_taints =
      Map.new(aggregate["entries"], fn item ->
        assert {:ok, envelope} = TaintEnvelope.verify(item["provenance"], item["payload"])
        {item["payload"]["id"], envelope.taint}
      end)

    assert persisted_taints[hostile_entry.id] == hostile
    assert {:ok, outer} = TaintEnvelope.verify(outer_envelope, aggregate)
    assert outer.taint.level == :hostile
    assert outer.taint.sensitivity == :restricted
  end

  test "legacy aggregate and missing item envelope remain conservative", %{agent_id: agent_id} do
    payload = entry_payload(agent_id, "legacy durable thought", "thk_legacy")
    put_raw("thinking:#{agent_id}", %{"entries" => [payload]}, %{})

    assert :ok = Thinking.reload_from_durable()
    assert_legacy_item(agent_id, "legacy durable thought")

    aggregate = %{
      "version" => 1,
      "entries" => [%{"payload" => payload}]
    }

    missing = TaintEnvelope.missing_fallback()
    assert :ok = MemoryStore.persist("thinking", agent_id, aggregate, taint: missing)
    assert :ok = Thinking.reload_from_durable()
    assert_legacy_item(agent_id, "legacy durable thought")
  end

  test "payload-mismatched item envelope reloads as hostile", %{agent_id: agent_id} do
    original = entry_payload(agent_id, "original durable text", "thk_mismatch")
    changed = Map.put(original, "text", "changed durable text")
    label = %Taint{level: :trusted, sensitivity: :public, confidence: :verified}
    {:ok, envelope} = TaintEnvelope.new(original, label)
    {:ok, envelope_map} = TaintEnvelope.to_map(envelope)

    aggregate = %{
      "version" => 1,
      "entries" => [%{"payload" => changed, "provenance" => envelope_map}]
    }

    assert :ok =
             MemoryStore.persist("thinking", agent_id, aggregate,
               taint: TaintEnvelope.invalid_fallback()
             )

    assert :ok = Thinking.reload_from_durable()

    assert {:ok, [{%TaintedValue{value: %{text: "changed durable text"}, taint: taint}, status}]} =
             Thinking.recent_thinking_tainted(agent_id)

    assert status == :invalid_durable_provenance
    assert taint.level == :hostile
    assert taint.source == "invalid_durable_provenance"
  end

  test "streaming chunks join all label dimensions monotonically", %{agent_id: agent_id} do
    first = %Taint{
      level: :derived,
      sensitivity: :internal,
      sanitizations: 0b00010111,
      confidence: :verified,
      source: "stream_first"
    }

    second = %Taint{
      level: :untrusted,
      sensitivity: :confidential,
      sanitizations: 0b00000111,
      confidence: :plausible,
      source: "stream_second"
    }

    final = %Taint{
      level: :trusted,
      sensitivity: :public,
      sanitizations: 0b00000011,
      confidence: :corroborated,
      source: "stream_final"
    }

    assert :ok = Thinking.process_stream_chunk_tainted(agent_id, "mixed ", first)
    assert :ok = Thinking.process_stream_chunk_tainted(agent_id, "stream", second)

    assert {:ok, %{text: "mixed stream"}} =
             Thinking.process_stream_chunk_tainted(agent_id, "", final, complete: true)

    assert {:ok, [{%TaintedValue{taint: actual}, :verified}]} =
             Thinking.recent_thinking_tainted(agent_id)

    assert {:ok, expected} = Taint.join_many([first, second, final])
    assert actual == expected
  end

  test "stream accumulation checks byte bounds before concatenation", %{agent_id: agent_id} do
    max_bytes = ThinkingCodec.max_text_bytes()
    label = %Taint{level: :derived, sensitivity: :internal, source: "stream_boundary"}
    prefix = String.duplicate("x", max_bytes - 1)

    assert :ok = Thinking.process_stream_chunk_tainted(agent_id, prefix, label)
    assert :ok = Thinking.process_stream_chunk_tainted(agent_id, "y", label)

    stream = :sys.get_state(Thinking).streams[agent_id]
    assert byte_size(stream.text) == max_bytes

    assert {:error, :invalid_payload} =
             Thinking.process_stream_chunk_tainted(agent_id, "z", label)

    assert byte_size(:sys.get_state(Thinking).streams[agent_id].text) == max_bytes

    oversized_agent = "#{agent_id}_oversized"

    assert {:error, :invalid_payload} =
             Thinking.process_stream_chunk_tainted(
               oversized_agent,
               String.duplicate("o", max_bytes + 1),
               label
             )

    refute Map.has_key?(:sys.get_state(Thinking).streams, oversized_agent)

    assert {:ok, entry} =
             Thinking.process_stream_chunk_tainted(agent_id, "", label, complete: true)

    assert byte_size(entry.text) == max_bytes

    assert {:ok, [{%TaintedValue{taint: ^label}, :verified}]} =
             Thinking.recent_thinking_tainted(agent_id)
  end

  test "incomplete streams are capped while existing streams can finish and clear", %{
    agent_id: agent_id
  } do
    limit = Thinking.active_stream_limit()
    stream_ids = Enum.map(1..limit, &"#{agent_id}_stream_#{&1}")
    on_exit(fn -> Thinking.reload_from_durable() end)

    Enum.each(stream_ids, fn stream_id ->
      assert :ok = Thinking.process_stream_chunk(stream_id, "partial")
    end)

    assert map_size(:sys.get_state(Thinking).streams) == limit
    overflow = "#{agent_id}_overflow"
    assert {:error, :stream_capacity} = Thinking.process_stream_chunk(overflow, "blocked")

    first = hd(stream_ids)
    assert {:ok, %{text: "partial"}} = Thinking.process_stream_chunk(first, "", complete: true)

    assert {:ok, [{%TaintedValue{taint: raw_stream_taint}, :legacy_unlabeled}]} =
             Thinking.recent_thinking_tainted(first)

    assert raw_stream_taint.source == "legacy_unlabeled"
    assert :ok = Thinking.process_stream_chunk(overflow, "now admitted")

    second = Enum.at(stream_ids, 1)
    assert :ok = Thinking.clear(second)
    replacement = "#{agent_id}_replacement"
    assert :ok = Thinking.process_stream_chunk(replacement, "admitted after clear")
    assert map_size(:sys.get_state(Thinking).streams) == limit

    assert :ok = Thinking.reload_from_durable()
    assert :sys.get_state(Thinking).streams == %{}
  end

  test "reload provenance failure clears partial replacement and reports an error", %{
    agent_id: agent_id
  } do
    label = %Taint{level: :untrusted, sensitivity: :confidential, source: "reload_source"}
    assert {:ok, _entry} = Thinking.record_thinking_tainted(agent_id, "reload me", label)

    on_exit(&ensure_provenance_started/0)
    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Provenance)
    assert Process.whereis(Provenance) == nil

    assert {:error, :store_unavailable} = Thinking.reload_from_durable()
    assert Thinking.recent_thinking(agent_id) == []

    ensure_provenance_started()
    assert :ok = Thinking.reload_from_durable()

    assert {:ok, [{%TaintedValue{value: %{text: "reload me"}, taint: ^label}, :verified}]} =
             Thinking.recent_thinking_tainted(agent_id)
  end

  test "security regression: reload cleanup uses bounded owned inventory", %{
    agent_id: agent_id
  } do
    label = %Taint{level: :derived, sensitivity: :internal, source: "owned_inventory"}
    assert {:ok, entry} = Thinking.record_thinking_tainted(agent_id, "owned row", label)

    attacker_ids =
      Enum.map(1..(Thinking.loaded_agent_limit() * 2), fn index ->
        "attacker_projection_#{agent_id}_#{index}"
      end)

    on_exit(fn ->
      Enum.each(attacker_ids, &:ets.delete(:arbor_memory_thinking, &1))
    end)

    attacker_rows = Enum.map(attacker_ids, &{&1, :wrong_shape})
    true = :ets.insert(:arbor_memory_thinking, attacker_rows)

    assert :ok = Thinking.reload_from_durable()
    owner_state = :sys.get_state(Thinking)
    assert owner_state.owned_agents == MapSet.new([agent_id])
    assert MapSet.size(owner_state.owned_agents) <= Thinking.loaded_agent_limit()

    assert [{_, :wrong_shape}] =
             :ets.lookup(:arbor_memory_thinking, List.first(attacker_ids))

    assert [{_, :wrong_shape}] =
             :ets.lookup(:arbor_memory_thinking, List.last(attacker_ids))

    assert {:ok, [{%TaintedValue{value: reloaded, taint: ^label}, :verified}]} =
             Thinking.recent_thinking_tainted(agent_id)

    assert reloaded.id == entry.id
    assert Process.alive?(Process.whereis(Thinking))

    Enum.each(attacker_ids, &:ets.delete(:arbor_memory_thinking, &1))
  end

  test "security regression: known durable commit survives projection failure and reloads", %{
    agent_id: agent_id
  } do
    label = %Taint{level: :derived, sensitivity: :internal, source: "install_recovery"}
    on_exit(&ensure_provenance_started/0)

    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Provenance)
    assert Process.whereis(Provenance) == nil

    assert {:ok, accepted_entry} =
             Thinking.record_thinking_tainted(agent_id, "recoverable projection", label)

    assert accepted_entry.text == "recoverable projection"

    assert Thinking.recent_thinking(agent_id) == []

    # backend:nil is the deliberate process-lifetime authority mode. Its CAS
    # receipt is definitive even though the post-commit projection failed.
    assert {:ok, %Record{data: cached_snapshot}} =
             BufferedStore.get("thinking:#{agent_id}", name: @store_name)

    assert [cached_item] = cached_snapshot["entries"]
    assert cached_item["payload"]["text"] == "recoverable projection"

    ensure_provenance_started()
    assert :ok = Thinking.reload_from_durable()

    assert {:ok,
            [{%TaintedValue{value: %{text: "recoverable projection"}, taint: ^label}, :verified}]} =
             Thinking.recent_thinking_tainted(agent_id)
  end

  test "security regression: owner death after durable commit returns outcome unknown", %{
    agent_id: agent_id
  } do
    label = %Taint{level: :hostile, sensitivity: :restricted, source: "owner_death"}
    provenance_owner = Process.whereis(Provenance)
    thinking_owner = Process.whereis(Thinking)
    assert is_pid(provenance_owner)
    assert is_pid(thinking_owner)

    on_exit(fn ->
      resume_if_suspended(provenance_owner)
      ensure_provenance_started()
      wait_until(fn -> is_pid(Process.whereis(Thinking)) end)
    end)

    assert :ok = :sys.suspend(provenance_owner)

    task =
      Task.async(fn ->
        Thinking.record_thinking_tainted(agent_id, "committed before owner death", label)
      end)

    assert wait_until(fn ->
             case BufferedStore.get("thinking:#{agent_id}", name: @store_name) do
               {:ok, %Record{data: %{"entries" => [item | _rest]}}} ->
                 get_in(item, ["payload", "text"]) == "committed before owner death"

               _ ->
                 false
             end
           end)

    monitor = Process.monitor(thinking_owner)
    Process.exit(thinking_owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^thinking_owner, _reason}, 1_000
    resume_if_suspended(provenance_owner)

    assert {:error, :outcome_unknown} = Task.await(task, 5_000)

    assert wait_until(fn ->
             case Process.whereis(Thinking) do
               owner when is_pid(owner) -> owner != thinking_owner and Process.alive?(owner)
               _ -> false
             end
           end)

    assert {:ok,
            [
              {%TaintedValue{value: %{text: "committed before owner death"}, taint: ^label},
               :verified}
            ]} = Thinking.recent_thinking_tainted(agent_id)
  end

  test "security regression: durable clear succeeds when sidecar cleanup is unavailable", %{
    agent_id: agent_id
  } do
    label = %Taint{level: :derived, sensitivity: :internal, source: "clear_cleanup"}
    assert {:ok, _entry} = Thinking.record_thinking_tainted(agent_id, "clear me", label)

    on_exit(&ensure_provenance_started/0)
    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Provenance)
    assert Process.whereis(Provenance) == nil

    assert :ok = Thinking.clear(agent_id)

    assert {:error, :not_found} =
             MemoryStore.load_tainted_authoritative_with_status("thinking", agent_id)

    assert :ets.lookup(:arbor_memory_thinking, agent_id) == []

    ensure_provenance_started()
    assert Thinking.recent_thinking(agent_id) == []
  end

  test "security regression: clear removes only Thinking-owned provenance sidecars", %{
    agent_id: agent_id
  } do
    thinking_payload = %{"content" => "orphan thinking label"}
    goal_payload = %{"content" => "unrelated goal label"}
    label = %Taint{level: :hostile, sensitivity: :restricted, source: "domain_scope"}

    on_exit(fn -> Provenance.delete(:goal, agent_id, "goal_unrelated") end)

    assert :ok =
             Provenance.put(
               :thinking_entry,
               agent_id,
               "thk_orphan_sidecar",
               thinking_payload,
               label
             )

    assert :ok = Provenance.put(:goal, agent_id, "goal_unrelated", goal_payload, label)
    assert :ok = Thinking.clear(agent_id)

    assert {:ok, thinking_taint, :legacy_unlabeled} =
             Provenance.resolve(
               :thinking_entry,
               agent_id,
               "thk_orphan_sidecar",
               thinking_payload
             )

    assert thinking_taint.source == "legacy_unlabeled"

    assert {:ok, ^label, :verified} =
             Provenance.resolve(:goal, agent_id, "goal_unrelated", goal_payload)
  end

  test "configured maximum fits C0 and byte-heavy aggregates evict the oldest tail", %{
    agent_id: agent_id
  } do
    max_entries = Thinking.max_entries()
    assert max_entries == ThinkingCodec.max_entries()
    original_buffer_size = :sys.get_state(Thinking).buffer_size

    on_exit(fn ->
      if Process.whereis(Thinking) do
        :sys.replace_state(Thinking, &%{&1 | buffer_size: original_buffer_size})
      end
    end)

    :sys.replace_state(Thinking, &%{&1 | buffer_size: max_entries})
    full_chain = Enum.map(1..Taint.max_chain_entries(), &"capacity_chain_#{&1}")
    label = %Taint{level: :derived, source: "capacity_source", chain: full_chain}
    timestamp = DateTime.utc_now()

    labelled_entries =
      Enum.map(1..max_entries, fn index ->
        entry = %{
          id: "thk_capacity_#{index}",
          agent_id: agent_id,
          text: "capacity item #{index}",
          significant: false,
          created_at: timestamp,
          metadata: %{}
        }

        {entry, label}
      end)

    assert {:ok, aggregate, outer_taint} = ThinkingCodec.encode_aggregate(labelled_entries)
    assert length(aggregate["entries"]) == max_entries
    assert :ok = MemoryStore.persist("thinking", agent_id, aggregate, taint: outer_taint)
    assert :ok = Thinking.reload_from_durable()
    assert {:ok, loaded} = Thinking.recent_thinking_tainted(agent_id, limit: max_entries)
    assert length(loaded) == max_entries

    evicted_entry = labelled_entries |> List.last() |> elem(0)
    assert {:ok, evicted_payload} = ThinkingCodec.entry_payload(evicted_entry)

    assert {:ok, newest} =
             Thinking.record_thinking_tainted(agent_id, "protected newest", label)

    assert {:ok, after_count_eviction} =
             Thinking.recent_thinking_tainted(agent_id, limit: max_entries)

    assert length(after_count_eviction) == max_entries
    assert Enum.any?(after_count_eviction, fn {value, _status} -> value.value.id == newest.id end)

    refute Enum.any?(after_count_eviction, fn {value, _status} ->
             value.value.id == evicted_entry.id
           end)

    assert {:ok, evicted_taint, :legacy_unlabeled} =
             Provenance.resolve(
               :thinking_entry,
               agent_id,
               evicted_entry.id,
               evicted_payload
             )

    assert evicted_taint.source == "legacy_unlabeled"
    assert :ok = Thinking.clear(agent_id)

    maximum_text = String.duplicate("b", ThinkingCodec.max_text_bytes())
    assert {:ok, first} = Thinking.record_thinking_tainted(agent_id, maximum_text, label)
    assert {:ok, second} = Thinking.record_thinking_tainted(agent_id, maximum_text, label)
    assert {:ok, third} = Thinking.record_thinking_tainted(agent_id, maximum_text, label)
    assert {:ok, first_payload} = ThinkingCodec.entry_payload(first)

    assert {:ok, byte_fitted} = Thinking.recent_thinking_tainted(agent_id, limit: max_entries)

    assert Enum.map(byte_fitted, fn {value, _status} -> value.value.id end) == [
             third.id,
             second.id
           ]

    assert {:ok, removed_taint, :legacy_unlabeled} =
             Provenance.resolve(:thinking_entry, agent_id, first.id, first_payload)

    assert removed_taint.source == "legacy_unlabeled"
  end

  test "eviction and clear remove owned sidecars and durable aggregate", %{agent_id: agent_id} do
    evicted_label = %Taint{
      level: :hostile,
      sensitivity: :restricted,
      confidence: :unverified,
      source: "evicted_source"
    }

    retained_label = %Taint{
      level: :derived,
      sensitivity: :internal,
      confidence: :verified,
      source: "retained_source"
    }

    assert {:ok, oldest} =
             Thinking.record_thinking_tainted(
               agent_id,
               "eviction thought 1",
               evicted_label
             )

    entries =
      for i <- 2..51 do
        assert {:ok, entry} =
                 Thinking.record_thinking_tainted(
                   agent_id,
                   "eviction thought #{i}",
                   retained_label
                 )

        entry
      end

    newest = List.last(entries)
    {:ok, oldest_payload} = ThinkingCodec.entry_payload(oldest)
    {:ok, newest_payload} = ThinkingCodec.entry_payload(newest)

    assert {:ok, oldest_taint, :legacy_unlabeled} =
             Provenance.resolve(:thinking_entry, agent_id, oldest.id, oldest_payload)

    assert oldest_taint.source == "legacy_unlabeled"

    assert {:ok, ^retained_label, :verified} =
             Provenance.resolve(:thinking_entry, agent_id, newest.id, newest_payload)

    assert {:ok, %Record{data: aggregate, metadata: %{"taint" => outer_envelope}}} =
             BufferedStore.get("thinking:#{agent_id}", name: @store_name)

    item_taints =
      Enum.map(aggregate["entries"], fn item ->
        assert {:ok, envelope} = TaintEnvelope.verify(item["provenance"], item["payload"])
        envelope.taint
      end)

    assert {:ok, expected_outer} = Taint.join_many(item_taints)
    assert {:ok, outer} = TaintEnvelope.verify(outer_envelope, aggregate)
    assert outer.taint == expected_outer
    assert outer.taint == retained_label
    refute Enum.any?(aggregate["entries"], &(&1["payload"]["id"] == oldest.id))

    true = :ets.delete(:arbor_memory_thinking, agent_id)
    assert :ok = Thinking.clear(agent_id)
    assert {:error, :not_found} = BufferedStore.get("thinking:#{agent_id}", name: @store_name)

    assert {:ok, cleared_taint, :legacy_unlabeled} =
             Provenance.resolve(:thinking_entry, agent_id, newest.id, newest_payload)

    assert cleared_taint.source == "legacy_unlabeled"
  end

  test "malformed, unknown-version, oversized, and improper durable values are total", %{
    agent_id: agent_id
  } do
    payload = entry_payload(agent_id, "bounded", "thk_bounded")
    improper = [payload | :improper_tail]
    put_raw("thinking:#{agent_id}", %{"entries" => improper}, %{})

    assert :ok = Thinking.reload_from_durable()
    assert Thinking.recent_thinking(agent_id) == []

    unknown = %{"version" => 99, "entries" => [%{"payload" => payload}]}
    assert :ok = MemoryStore.persist("thinking", agent_id, unknown, taint: %Taint{})
    assert :ok = Thinking.reload_from_durable()
    assert Thinking.recent_thinking(agent_id) == []

    oversized = entry_payload(agent_id, String.duplicate("x", 65_537), "thk_oversized")
    put_raw("thinking:#{agent_id}", %{"entries" => [oversized]}, %{})
    assert :ok = Thinking.reload_from_durable()
    assert Thinking.recent_thinking(agent_id) == []

    bad_opts = [{:metadata, %{}} | :improper_tail]
    assert {:error, :invalid_request} = Thinking.record_thinking(agent_id, "bounded", bad_opts)
    assert {:error, :invalid_request} = Thinking.recent_thinking_tainted(agent_id, bad_opts)

    duplicate_opts = [significant: false, significant: true]

    assert {:error, :invalid_request} =
             Thinking.record_thinking(agent_id, "bounded", duplicate_opts)

    too_many_opts = [limit: 1, since: nil, significant_only: false, limit: 2]

    assert {:error, :invalid_request} =
             Thinking.recent_thinking_tainted(agent_id, too_many_opts)
  end

  defp assert_legacy_item(agent_id, text) do
    assert {:ok, [{%TaintedValue{value: %{text: ^text}, taint: taint}, status}]} =
             Thinking.recent_thinking_tainted(agent_id)

    assert status == :legacy_unlabeled
    assert taint.level == :untrusted
    assert taint.sensitivity == :restricted
    assert taint.source == "legacy_unlabeled"
  end

  defp assert_taints_by_id(items, expected) do
    actual =
      Map.new(items, fn {%TaintedValue{value: entry, taint: taint}, status} ->
        assert status == :verified
        {entry.id, taint}
      end)

    assert actual == expected
  end

  defp entry_payload(agent_id, text, id) do
    %{
      "id" => id,
      "agent_id" => agent_id,
      "text" => text,
      "significant" => false,
      "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "metadata" => %{}
    }
  end

  defp put_raw(key, data, metadata) do
    record = Record.new(key, data, id: "memory:#{key}", metadata: metadata)
    assert :ok = BufferedStore.put(key, record, name: @store_name)
  end

  defp restart_memory_store(backend, opts) do
    assert :ok = stop_supervised(BufferedStore)

    store_opts =
      [name: @store_name, backend: backend, write_mode: :sync]
      |> Keyword.merge(opts)

    assert is_pid(start_supervised!({BufferedStore, store_opts}))
    :ok
  end

  defp wait_until(fun, attempts \\ 200)

  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp resume_if_suspended(pid) when is_pid(pid) do
    :sys.resume(pid)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp ensure_provenance_started do
    if Process.whereis(Provenance) == nil do
      case Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, :running} -> :ok
      end
    else
      :ok
    end
  end
end
