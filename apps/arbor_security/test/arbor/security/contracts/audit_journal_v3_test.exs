defmodule Arbor.Security.Contracts.AuditJournalV3Test do
  @moduledoc """
  Contract tests for audit-journal terminal-identity retirement (Floor-and-Ledger
  v3): intent v3, snapshot v3 with its exact `retirement` object, and the
  retirement batch payload of one cold ledger frame.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Security.AuditJournalFileCore
  alias Arbor.Security.Contracts.AuditJournal

  @cap_id "cap_" <> String.duplicate("a", 32)
  @prepared_at "2026-09-28T12:00:00Z"
  @digest String.duplicate("ab", 32)
  @source %{
    "committed_digest" => String.duplicate("ef", 32),
    "committed_frames" => 3,
    "committed_offset" => 900
  }

  describe "intent v3" do
    test "admits version 3 only under the v3 kind; version 4 is unsupported" do
      assert AuditJournal.intent_kind(3) == "arbor.security.authority_mutation_intent.v3"
      assert AuditJournal.intent_kind(2) == "arbor.security.authority_mutation_intent.v2"
      assert AuditJournal.intent_kind(1) == AuditJournal.intent_kind()

      assert {:ok, intent} = AuditJournal.admit_intent(facts(3))
      assert intent["version"] == 3
      assert intent["kind"] == AuditJournal.intent_kind(3)

      assert {:error, {:invalid_field, "kind"}} =
               AuditJournal.admit_intent(Map.put(facts(3), "kind", AuditJournal.intent_kind(2)))

      assert {:error, :unsupported_version} =
               AuditJournal.admit_intent(
                 facts(3)
                 |> Map.put("version", 4)
                 |> Map.put("kind", "arbor.security.authority_mutation_intent.v4")
               )
    end

    test "v3 identity hashes the v2 facts under its own domain" do
      assert {:ok, v3} = AuditJournal.admit_intent(facts(3))
      assert {:ok, v2} = AuditJournal.admit_intent(facts(2))
      refute v3["operation_id"] == v2["operation_id"]

      facts_only =
        v3
        |> Map.drop(["operation_id", "prepared_at"])
        |> ordered(~w(version kind operation effect_class authority_namespace authority_key
          before_fence after_fingerprint audit))

      expected =
        :crypto.hash(
          :sha256,
          "arbor.security.authority_mutation_intent.v3" <> <<0>> <> facts_only
        )
        |> Base.encode16(case: :lower)

      assert v3["operation_id"] == expected

      lineage =
        facts(3)
        |> Map.put("prepared_at", "2026-09-28T13:14:15Z")
        |> Map.put("actor_id", "agent_other")
        |> Map.put("correlation_id", "corr-1")

      assert {:ok, retry} = AuditJournal.admit_intent(lineage)
      assert retry["operation_id"] == v3["operation_id"]
    end

    test "legacy_alias_operation_id/1 answers the v2 identity of identical v3 facts only" do
      assert {:ok, v3} = AuditJournal.admit_intent(facts(3))
      assert {:ok, v2} = AuditJournal.admit_intent(facts(2))
      assert {:ok, alias_id} = AuditJournal.legacy_alias_operation_id(v3)
      assert alias_id == v2["operation_id"]

      # Lineage and observation time never change the alias.
      assert {:ok, ^alias_id} =
               AuditJournal.legacy_alias_operation_id(
                 v3
                 |> Map.delete("operation_id")
                 |> Map.put("prepared_at", "2026-09-28T23:00:00Z")
               )

      assert {:error, :unsupported_version} = AuditJournal.legacy_alias_operation_id(v2)

      assert {:error, :unsupported_version} =
               AuditJournal.legacy_alias_operation_id(facts(1))

      assert {:error, _} = AuditJournal.legacy_alias_operation_id(%{"version" => 3})
      assert {:error, _} = AuditJournal.legacy_alias_operation_id(:nope)
    end

    test "v3 grants keep the v2 live-to-live revision successor rule" do
      successor =
        facts(3)
        |> Map.put("before_fence", live(1, 4))
        |> Map.put("after_fingerprint", live(1, 5))

      assert {:ok, _} = AuditJournal.admit_intent(successor)

      assert {:error, :before_after_incompatible} =
               AuditJournal.admit_intent(Map.put(successor, "after_fingerprint", live(1, 7)))

      assert {:error, :before_after_incompatible} =
               AuditJournal.admit_intent(
                 successor
                 |> Map.put("version", 1)
                 |> Map.put("kind", AuditJournal.intent_kind(1))
               )
    end
  end

  describe "snapshot v3" do
    test "round-trips the exact seven keys with canonical key order" do
      snapshot = v3_snapshot()
      assert {:ok, admitted} = AuditJournal.admit_snapshot(snapshot)
      assert admitted == snapshot
      assert AuditJournal.snapshot_profile(admitted) == :operational
      assert AuditJournal.snapshot_kind(3) == "arbor.security.audit_journal_snapshot.v3"
      assert AuditJournal.snapshot_kind(3) in AuditJournal.snapshot_kinds()

      assert {:ok, bytes} = AuditJournal.canonical_snapshot_bytes(snapshot)
      assert {:ok, ^bytes} = AuditJournal.canonical_snapshot_bytes(reverse(snapshot))

      assert String.starts_with?(
               bytes,
               ~s({"version":3,"kind":"arbor.security.audit_journal_snapshot.v3","source":)
             )

      assert String.ends_with?(
               bytes,
               ~s("capacity_profile":"operational","retirement":{"retired_total":0,) <>
                 ~s("ledger":{"frames":0,"tip_offset":0,"tip_len":0,"tip_digest":") <>
                 AuditJournal.ledger_genesis_binding()["tip_digest"] <> ~s("}}})
             )

      assert {:ok, ^admitted} = AuditJournal.admit_snapshot(Jason.decode!(bytes))
      assert AuditJournal.limits().max_keys.snapshot_v3 == 7
    end

    test "the genesis ledger binding is the journal genesis digest" do
      genesis = AuditJournal.ledger_genesis_binding()

      assert genesis["tip_digest"] ==
               Base.encode16(AuditJournalFileCore.genesis_digest(), case: :lower)

      assert genesis == %{
               "frames" => 0,
               "tip_offset" => 0,
               "tip_len" => 0,
               "tip_digest" => genesis["tip_digest"]
             }

      assert AuditJournal.snapshot_retirement(v3_snapshot()) ==
               %{"retired_total" => 0, "ledger" => genesis}

      assert AuditJournal.snapshot_retirement(nil) == %{"retired_total" => 0, "ledger" => genesis}

      bound = v3_snapshot(retirement(4096, binding(1, 0, 1234)))

      assert AuditJournal.snapshot_retirement(bound) ==
               %{"retired_total" => 4096, "ledger" => binding(1, 0, 1234)}
    end

    test "exact keys: missing, extra and forbidden keys are refused" do
      assert {:error, :missing_field} =
               AuditJournal.admit_snapshot(Map.delete(v3_snapshot(), "retirement"))

      assert {:error, :missing_field} =
               AuditJournal.admit_snapshot(
                 put_in(v3_snapshot(), ["retirement"], %{"retired_total" => 0})
               )

      assert {:error, :missing_field} =
               AuditJournal.admit_snapshot(
                 update_in(v3_snapshot(), ["retirement", "ledger"], &Map.delete(&1, "tip_len"))
               )

      assert {:error, :unknown_field} =
               AuditJournal.admit_snapshot(
                 v3_snapshot()
                 |> Map.delete("terminals")
                 |> Map.put("extra", %{})
               )

      assert {:error, :unknown_field} =
               AuditJournal.admit_snapshot(
                 put_in(v3_snapshot(), ["retirement", "epoch"], 1)
                 |> update_in(["retirement"], &Map.delete(&1, "retired_total"))
               )

      assert {:error, :forbidden_content} =
               AuditJournal.admit_snapshot(
                 v3_snapshot()
                 |> Map.delete("terminals")
                 |> Map.put("metadata", %{})
               )

      assert {:error, :malformed} =
               AuditJournal.admit_snapshot(Map.put(v3_snapshot(), "extra", 1))

      assert {:error, {:invalid_field, "capacity_profile"}} =
               AuditJournal.admit_snapshot(Map.put(v3_snapshot(), "capacity_profile", "small"))

      assert {:error, {:invalid_field, "kind"}} =
               AuditJournal.admit_snapshot(
                 Map.put(v3_snapshot(), "kind", AuditJournal.operational_snapshot_kind())
               )

      assert {:error, :unsupported_version} =
               AuditJournal.admit_snapshot(
                 empty_v1()
                 |> Map.put("version", 4)
               )
    end

    test "a newer snapshot version is unsupported whatever its shape, never malformed" do
      v2_shaped = v3_snapshot() |> Map.delete("retirement") |> Map.put("version", 4)

      for snapshot <- [
            Map.put(v3_snapshot(), "version", 4),
            v3_snapshot()
            |> Map.put("version", 4)
            |> Map.put("kind", "arbor.security.audit_journal_snapshot.v4"),
            v3_snapshot()
            |> Map.put("version", 4)
            |> Map.put("terminals", delivered_map(4096)),
            v2_shaped,
            v3_snapshot() |> Map.put("version", 4) |> Map.put("future_field", %{}),
            Map.put(v3_snapshot(), "version", 0)
          ] do
        assert {:error, :unsupported_version} = AuditJournal.admit_snapshot(snapshot),
               "expected version #{snapshot["version"]} with keys " <>
                 "#{inspect(Map.keys(snapshot))} to be unsupported"

        assert {:error, :unsupported_version} = AuditJournal.canonical_snapshot_bytes(snapshot)
      end

      max = AuditJournal.limits().max_json_safe_int

      assert {:error, :integer_out_of_range} =
               AuditJournal.admit_snapshot(Map.put(v3_snapshot(), "version", max + 1))

      assert {:error, :integer_out_of_range} =
               AuditJournal.admit_snapshot(Map.put(v3_snapshot(), "version", -1))

      # A non-integer version is not a version at all.
      assert {:error, :malformed} =
               AuditJournal.admit_snapshot(Map.put(v3_snapshot(), "version", "3"))
    end

    test "ledger_bound_size/1 is the end of the bound tip frame" do
      assert AuditJournalFileCore.header_size() == 72
      assert {:ok, 0} = AuditJournal.ledger_bound_size(AuditJournal.ledger_genesis_binding())
      assert {:ok, 772} = AuditJournal.ledger_bound_size(binding(1, 0, 700))

      assert AuditJournal.ledger_bound_size(binding(4, 900, 5)) ==
               {:ok, 900 + AuditJournalFileCore.header_size() + 5}

      assert {:error, :malformed} = AuditJournal.ledger_bound_size(binding(1, 0, 0))
      assert {:error, :malformed} = AuditJournal.ledger_bound_size(binding(1, -1, 5))
      assert {:error, :malformed} = AuditJournal.ledger_bound_size(%{"frames" => 1})
      assert {:error, :malformed} = AuditJournal.ledger_bound_size(:nope)
    end

    test "ledger frames are bounded by the JSON-safe range, not the 4096 journal frame bound" do
      for frames <- [4097, 10_000_000] do
        snapshot = v3_snapshot(retirement(frames, binding(frames, 99_999, 512)))
        assert {:ok, _} = AuditJournal.admit_snapshot(snapshot)
      end

      max = AuditJournal.limits().max_json_safe_int
      at_max = v3_snapshot(retirement(max, binding(max, max, 1)))
      assert {:ok, _} = AuditJournal.admit_snapshot(at_max)

      assert {:error, :integer_out_of_range} =
               AuditJournal.admit_snapshot(v3_snapshot(retirement(max + 1, binding(1, 0, 1))))

      assert {:error, :integer_out_of_range} =
               AuditJournal.admit_snapshot(v3_snapshot(retirement(5, binding(1, 0, -1))))

      assert {:error, :integer_out_of_range} =
               AuditJournal.admit_snapshot(
                 v3_snapshot(
                   retirement(5, binding(1, 0, AuditJournalFileCore.max_payload_bytes() + 1))
                 )
               )

      assert {:ok, _} =
               AuditJournal.admit_snapshot(
                 v3_snapshot(
                   retirement(5, binding(1, 0, AuditJournalFileCore.max_payload_bytes()))
                 )
               )

      assert {:error, :float_not_allowed} =
               AuditJournal.admit_snapshot(
                 put_in(v3_snapshot(), ["retirement", "retired_total"], 1.0)
               )

      # The source binding keeps its journal-file frame bound.
      assert {:error, {:invalid_field, "committed_frames"}} =
               AuditJournal.admit_snapshot(
                 put_in(v3_snapshot(), ["source", "committed_frames"], 4097)
               )
    end

    test "genesis has one representation and a bound tip is never genesis" do
      genesis_digest = AuditJournal.ledger_genesis_binding()["tip_digest"]

      bad = [
        binding(0, 0, 0) |> Map.put("tip_digest", @digest),
        binding(0, 0, 1) |> Map.put("tip_digest", genesis_digest),
        binding(0, 5, 0) |> Map.put("tip_digest", genesis_digest),
        binding(1, 0, 10) |> Map.put("tip_digest", genesis_digest),
        binding(1, 0, 0),
        binding(1, 73, 10),
        binding(2, 0, 10)
      ]

      for ledger <- bad do
        assert {:error, {:invalid_field, "ledger"}} =
                 AuditJournal.admit_snapshot(v3_snapshot(retirement(10, ledger))),
               "expected #{inspect(ledger)} to be refused"
      end

      assert {:error, :invalid_field} =
               AuditJournal.admit_snapshot(
                 v3_snapshot(retirement(10, Map.put(binding(1, 0, 3), "tip_digest", "AB")))
               )

      # Every ledger frame retires at least one operation.
      assert {:error, {:invalid_field, "retired_total"}} =
               AuditJournal.admit_snapshot(v3_snapshot(retirement(2, binding(3, 200, 10))))

      assert {:ok, _} =
               AuditJournal.admit_snapshot(v3_snapshot(retirement(3, binding(3, 200, 10))))

      # In-memory (ledgerless) retirement keeps the genesis binding.
      assert {:ok, _} =
               AuditJournal.admit_snapshot(
                 v3_snapshot(retirement(700, AuditJournal.ledger_genesis_binding()))
               )
    end

    test "admits a 4096-terminal manifest (no 64-node budget) and refuses 4097" do
      terminals = delivered_map(4096)
      snapshot = Map.put(v3_snapshot(), "terminals", terminals)
      assert {:ok, admitted} = AuditJournal.admit_snapshot(snapshot)
      assert map_size(admitted["terminals"]) == 4096

      assert {:error, :malformed} =
               AuditJournal.admit_snapshot(
                 Map.put(v3_snapshot(), "terminals", delivered_map(4097))
               )
    end
  end

  describe "retirement batch" do
    test "admits 4096 delivered entries and bounds canonical bytes by the payload limit" do
      batch = batch(delivered_map(4096))
      assert {:ok, admitted} = AuditJournal.admit_retirement_batch(batch)
      assert admitted == batch
      assert AuditJournal.retirement_batch_kind() == "arbor.security.audit_retirement_batch.v1"

      assert {:ok, bytes} = AuditJournal.canonical_retirement_batch_bytes(batch)
      assert {:ok, ^bytes} = AuditJournal.canonical_retirement_batch_bytes(reverse(batch))
      assert byte_size(bytes) <= AuditJournalFileCore.max_payload_bytes()

      assert String.starts_with?(
               bytes,
               ~s({"version":1,"kind":"arbor.security.audit_retirement_batch.v1","source":{) <>
                 ~s("committed_digest":")
             )

      assert {:ok, ^admitted} = AuditJournal.admit_retirement_batch(Jason.decode!(bytes))

      # Sorted by operation id.
      [first_id | _] = batch["retired"] |> Map.keys() |> Enum.sort()
      assert :binary.match(bytes, ~s("retired":{") <> first_id) != :nomatch
    end

    test "refuses empty, oversized, non-delivered and malformed batches" do
      assert {:error, {:invalid_field, "retired"}} =
               AuditJournal.admit_retirement_batch(batch(%{}))

      assert {:error, :malformed} =
               AuditJournal.admit_retirement_batch(batch(delivered_map(4097)))

      oid = sha("rejected")

      rejected =
        "effect_rejected|authority_reduce|#{sha(1)}|prepared:#{sha(2)}|effect_rejected:#{sha(3)}"

      assert {:error, :invalid_field} =
               AuditJournal.admit_retirement_batch(batch(%{oid => rejected}))

      assert {:error, :invalid_field} =
               AuditJournal.admit_retirement_batch(batch(%{oid => "prepared:" <> sha(1)}))

      assert {:error, :invalid_field} =
               AuditJournal.admit_retirement_batch(batch(%{"not-hex" => delivered(1)}))

      assert {:error, :missing_field} =
               AuditJournal.admit_retirement_batch(Map.delete(batch(delivered_map(1)), "source"))

      assert {:error, :unknown_field} =
               AuditJournal.admit_retirement_batch(
                 batch(delivered_map(1))
                 |> Map.delete("source")
                 |> Map.put("epoch", 1)
               )

      assert {:error, :unsupported_version} =
               AuditJournal.admit_retirement_batch(Map.put(batch(delivered_map(1)), "version", 2))

      assert {:error, {:invalid_field, "kind"}} =
               AuditJournal.admit_retirement_batch(
                 Map.put(batch(delivered_map(1)), "kind", AuditJournal.snapshot_kind(3))
               )

      assert {:error, {:invalid_field, "committed_frames"}} =
               AuditJournal.admit_retirement_batch(
                 put_in(batch(delivered_map(1)), ["source", "committed_frames"], 4097)
               )

      assert {:error, :invalid_field} =
               AuditJournal.admit_retirement_batch(Map.put(batch(%{}), "retired", ["x"]))

      assert {:error, :struct_not_allowed} = AuditJournal.admit_retirement_batch(%URI{})
      assert {:error, :invalid_object} = AuditJournal.admit_retirement_batch(:nope)
      assert AuditJournal.limits().max_keys.retirement_batch == 4
    end
  end

  describe "limits" do
    test "retire_batch is a frozen operational constant" do
      assert AuditJournal.limits(:operational).retire_batch == 512
      refute Map.has_key?(AuditJournal.limits(:small), :retire_batch)
      assert AuditJournal.limits(:operational).hard_entry_cap == 4096
      assert AuditJournal.limits(:operational).soft_entry_cap == 3072
    end
  end

  # ---------------------------------------------------------------------------

  defp facts(version) do
    kind = AuditJournal.intent_kind(version)

    %{
      "version" => version,
      "kind" => kind,
      "operation" => "capability_grant",
      "effect_class" => "authority_increase",
      "authority_namespace" => "capability",
      "authority_key" => @cap_id,
      "before_fence" => %{"kind" => "absent"},
      "after_fingerprint" => live(1, 1),
      "audit" => %{
        "event_type" => "capability_granted",
        "data" => %{
          "capability_id" => @cap_id,
          "principal_id" => "agent_a",
          "resource_uri" => "arbor://fs/read/x"
        }
      },
      "prepared_at" => @prepared_at
    }
  end

  defp live(generation, revision) do
    %{
      "kind" => "live",
      "record_id" => "rec_1",
      "generation" => generation,
      "revision" => revision,
      "capability_digest" => @digest
    }
  end

  defp ordered(map, order) do
    order
    |> Enum.map(fn key -> {key, canonical_value(key, Map.fetch!(map, key))} end)
    |> Jason.OrderedObject.new()
    |> Jason.encode!()
  end

  defp canonical_value("before_fence", %{"kind" => "absent"}),
    do: Jason.OrderedObject.new([{"kind", "absent"}])

  defp canonical_value("after_fingerprint", value) do
    ~w(kind record_id generation revision capability_digest)
    |> Enum.map(&{&1, Map.fetch!(value, &1)})
    |> Jason.OrderedObject.new()
  end

  defp canonical_value("audit", value) do
    data =
      ~w(capability_id principal_id resource_uri)
      |> Enum.map(&{&1, Map.fetch!(value["data"], &1)})
      |> Jason.OrderedObject.new()

    Jason.OrderedObject.new([{"event_type", value["event_type"]}, {"data", data}])
  end

  defp canonical_value(_key, value), do: value

  defp empty_v1 do
    %{
      "version" => 1,
      "kind" => AuditJournal.snapshot_kind(),
      "source" => @source,
      "pending_manifest" => %{},
      "terminals" => %{}
    }
  end

  defp v3_snapshot(retirement \\ retirement(0, AuditJournal.ledger_genesis_binding())) do
    %{
      "version" => 3,
      "kind" => AuditJournal.snapshot_kind(3),
      "source" => @source,
      "pending_manifest" => %{},
      "terminals" => %{},
      "capacity_profile" => "operational",
      "retirement" => retirement
    }
  end

  defp retirement(total, ledger), do: %{"retired_total" => total, "ledger" => ledger}

  defp binding(frames, offset, len) do
    %{"frames" => frames, "tip_offset" => offset, "tip_len" => len, "tip_digest" => @digest}
  end

  defp batch(retired) do
    %{
      "version" => 1,
      "kind" => AuditJournal.retirement_batch_kind(),
      "source" => @source,
      "retired" => retired
    }
  end

  defp delivered_map(count) do
    Map.new(1..count, fn n -> {sha({:op, n}), delivered(n)} end)
  end

  defp delivered(n) do
    "delivered|authority_reduce|#{sha({:i, n})}|prepared:#{sha({:p, n})}|" <>
      "effect_applied:#{sha({:a, n})}|delivered:#{sha({:d, n})}"
  end

  defp sha(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  defp reverse(map) when is_map(map) do
    map
    |> Enum.reverse()
    |> Map.new(fn
      {key, value} when is_map(value) -> {key, reverse(value)}
      pair -> pair
    end)
  end
end
