defmodule Arbor.Security.AuditJournalCoreSecurityRegressionTest do
  @moduledoc """
  Exact-parent security regression for P1C-B1/B2C1 audit-journal contract,
  reducer, and pure snapshot compact/restore.

  Parent (modules absent) fails to load/call these APIs. Candidate must pass.
  """

  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.AuditJournalCore, as: Core
  alias Arbor.Security.Contracts.AuditJournal

  @digest String.duplicate("ab", 32)
  @cap_id "cap_" <> String.duplicate("a", 32)
  @prepared_at "2026-08-20T12:00:00Z"

  test "security regression: exact parent-generation successor for grant-after-tombstone" do
    assert {:ok, _} = AuditJournal.admit_intent(grant_absent())

    tombstone_ok =
      grant_absent()
      |> Map.put("before_fence", %{"kind" => "tombstone", "generation" => 4})
      |> put_in(["after_fingerprint", "generation"], 5)

    assert {:ok, _} = AuditJournal.admit_intent(tombstone_ok)

    for bad_gen <- [4, 6] do
      bad =
        grant_absent()
        |> Map.put("before_fence", %{"kind" => "tombstone", "generation" => 4})
        |> put_in(["after_fingerprint", "generation"], bad_gen)

      assert {:error, :before_after_incompatible} = AuditJournal.admit_intent(bad)
    end
  end

  test "security regression: Capability struct and nested capability/metadata/bearer are rejected" do
    capability =
      struct!(Capability,
        id: @cap_id,
        resource_uri: "arbor://fs/read/x",
        principal_id: "agent_a",
        granted_at: ~U[2026-08-20 12:00:00Z]
      )

    assert {:error, :struct_not_allowed} = AuditJournal.admit_intent(capability)

    assert {:error, :forbidden_content} =
             AuditJournal.admit_intent(
               put_in(grant_absent(), ["audit", "data", "capability"], %{"id" => @cap_id})
             )

    assert {:error, :forbidden_content} =
             AuditJournal.admit_intent(
               put_in(grant_absent(), ["before_fence", "metadata"], %{"note" => "x"})
             )

    assert {:error, :forbidden_content} =
             grant_absent()
             |> pop_in(["after_fingerprint", "capability_digest"])
             |> elem(1)
             |> put_in(["after_fingerprint", "bearer"], "secret-token")
             |> AuditJournal.admit_intent()
  end

  test "security regression: unavailable observation never invents a transition" do
    {:ok, intent} = AuditJournal.admit_intent(grant_absent())
    prepared = prepared_record(intent)
    assert {:ok, state} = Core.fold([prepared])
    snapshot = Core.show(state)

    applied = %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "effect_applied",
      "operation_id" => intent["operation_id"],
      "occurred_at" => "2026-08-20T12:00:01Z",
      "observation" => %{
        "kind" => "unavailable",
        "after_fingerprint" => intent["after_fingerprint"]
      }
    }

    assert {:error, :malformed} = Core.append(state, applied)
    assert Core.show(state) == snapshot
  end

  test "security regression: same operation_id different canonical effect_applied bytes is operation_conflict" do
    {:ok, intent} = AuditJournal.admit_intent(grant_absent())
    prepared = prepared_record(intent)
    assert {:ok, state} = Core.fold([prepared, applied_record(intent)])
    snapshot = Core.show(state)

    other_applied =
      applied_record(intent)
      |> Map.put("occurred_at", "2026-08-20T12:00:09Z")

    assert {:error, :operation_conflict} = Core.append(state, other_applied)
    assert Core.show(state) == snapshot
  end

  test "security regression: tampered stored prepared bytes conflict with valid prepared replay" do
    {:ok, intent} = AuditJournal.admit_intent(grant_absent())
    prepared = prepared_record(intent)
    assert {:ok, state} = Core.fold([prepared])

    operation_id = intent["operation_id"]
    stored = get_in(state, ["operations", operation_id, "records", "prepared"])
    refute stored in [nil, ""]

    tampered =
      put_in(state, ["operations", operation_id, "records", "prepared"], stored <> "x")

    snapshot = Core.show(tampered)
    assert {:error, :operation_conflict} = Core.append(tampered, prepared)
    assert Core.show(tampered) == snapshot
    assert tampered["entry_count"] == state["entry_count"]
    assert tampered["byte_count"] == state["byte_count"]
  end

  test "security regression: prepared nested intent operation_id disagreement is cross_operation" do
    {:ok, intent} = AuditJournal.admit_intent(grant_absent())
    other = String.duplicate("c", 64)
    prepared = Map.put(prepared_record(intent), "operation_id", other)

    assert {:ok, empty} = Core.new()
    assert {:error, :cross_operation} = Core.append(empty, prepared)
    refute match?({:error, :malformed}, Core.append(empty, prepared))
  end

  test "security regression: cross-operation identity wins when occurred_at also mismatches" do
    {:ok, intent} = AuditJournal.admit_intent(grant_absent())

    prepared =
      intent
      |> prepared_record()
      |> Map.put("operation_id", String.duplicate("c", 64))
      |> Map.put("occurred_at", "2026-08-20T12:00:01Z")

    assert {:error, :cross_operation} = AuditJournal.admit_record(prepared)

    assert {:ok, empty} = Core.new()
    assert {:error, :cross_operation} = Core.append(empty, prepared)
  end

  test "security regression: malformed collection work respects frozen structural bounds" do
    max_nodes = AuditJournal.limits().max_nodes
    exact_nested = %{"x" => List.duplicate("x", max_nodes - 2)}
    over_nested = %{"x" => List.duplicate("x", max_nodes - 1)}

    assert {:error, :invalid_field} = AuditJournal.admit_intent(exact_nested)
    assert {:error, :malformed} = AuditJournal.admit_intent(over_nested)
  end

  test "security regression: raw record batches stop at the hard entry cap" do
    {:ok, intent} = AuditJournal.admit_intent(grant_absent())
    prepared = prepared_record(intent)
    max_records = AuditJournal.limits().hard_entry_cap

    assert {:ok, _state} = Core.fold(List.duplicate(prepared, max_records))
    assert {:error, :malformed} = Core.fold(List.duplicate(prepared, max_records + 1))
  end

  test "security regression: compact restore rejects substituted and cross-operation pending" do
    {:ok, grant} = AuditJournal.admit_intent(grant_absent())
    {:ok, revoke} = AuditJournal.admit_intent(revoke_facts())
    prepared_grant = prepared_record(grant)
    applied_grant = applied_record(grant)
    delivered = delivered_record(grant)
    prepared_revoke = prepared_record(revoke)
    applied_revoke = applied_record(revoke)

    assert {:ok, state} =
             Core.fold([
               prepared_grant,
               applied_grant,
               delivered,
               prepared_revoke,
               applied_revoke
             ])

    source = %{
      "committed_digest" => String.duplicate("ab", 32),
      "committed_frames" => 5,
      "committed_offset" => 10
    }

    assert {:ok, compacted, snapshot, pending} = Core.compact(state, source)
    assert length(pending) == 2

    substituted =
      Enum.map(pending, fn
        %{"record_type" => "effect_applied"} = record ->
          Map.put(record, "occurred_at", "2026-08-20T12:00:09Z")

        record ->
          record
      end)

    assert {:error, :pending_mismatch} = Core.restore(snapshot, substituted)

    {:ok, other} = AuditJournal.admit_intent(other_grant())
    assert {:error, :cross_operation} =
             Core.restore(snapshot, [prepared_record(other) | tl(pending)])

    assert {:ok, restored} = Core.restore(snapshot, pending)
    assert {:ok, ^restored, :idempotent} = Core.append(restored, delivered)

    other_delivered = Map.put(delivered, "occurred_at", "2026-08-20T12:00:09Z")
    assert {:error, :operation_conflict} = Core.append(restored, other_delivered)

    pre = Core.show(compacted)
    bad_source = Map.put(source, "committed_digest", :not_hex)
    assert {:error, :malformed} = Core.compact(compacted, bad_source)
    assert Core.show(compacted) == pre
  end

  test "security regression: compact of 48 pending fails closed without dropping identity" do
    {:ok, state} = Core.new()

    state =
      Enum.reduce(1..32, state, fn n, acc ->
        {:ok, intent} = AuditJournal.admit_intent(grant_n(n))
        {:ok, next} = Core.append(acc, prepared_record(intent))
        next
      end)

    state =
      Enum.reduce(40..55, state, fn n, acc ->
        {:ok, intent} = AuditJournal.admit_intent(revoke_n(n))
        {:ok, next} = Core.append(acc, prepared_record(intent))
        next
      end)

    assert Core.capacity(state)["used_entries"] == 48
    pre = Core.show(state)

    source = %{
      "committed_digest" => String.duplicate("ab", 32),
      "committed_frames" => 48,
      "committed_offset" => 1
    }

    assert {:error, :capacity_exhausted} = Core.compact(state, source)
    assert Core.show(state) == pre
  end

  test "security regression: extra terminal evidence fails closed" do
    {:ok, grant} = AuditJournal.admit_intent(grant_absent())
    {:ok, revoke} = AuditJournal.admit_intent(revoke_facts())

    assert {:ok, state} =
             Core.fold([prepared_record(grant), applied_record(grant), delivered_record(grant)])

    {:ok, extra_bytes} = AuditJournal.canonical_record_bytes(prepared_record(revoke))
    oid = grant["operation_id"]

    tampered =
      put_in(state, ["operations", oid, "records", "effect_rejected"], extra_bytes)

    pre = Core.show(tampered)
    source = compact_source(3, 10)
    assert {:error, :malformed} = Core.compact(tampered, source)
    assert Core.show(tampered) == pre
  end

  test "security regression: terminal and pending cross-operation state keys fail closed" do
    {:ok, grant} = AuditJournal.admit_intent(grant_absent())
    {:ok, other} = AuditJournal.admit_intent(other_grant())

    assert {:ok, state} =
             Core.fold([
               prepared_record(grant),
               applied_record(grant),
               delivered_record(grant),
               prepared_record(other)
             ])

    {:ok, foreign_prepared} = AuditJournal.canonical_record_bytes(prepared_record(other))
    {:ok, grant_prepared} = AuditJournal.canonical_record_bytes(prepared_record(grant))
    grant_oid = grant["operation_id"]
    other_oid = other["operation_id"]
    source = compact_source(4, 10)

    terminal_tampered =
      put_in(state, ["operations", grant_oid, "records", "prepared"], foreign_prepared)

    terminal_pre = Core.show(terminal_tampered)
    assert {:error, :cross_operation} = Core.compact(terminal_tampered, source)
    assert Core.show(terminal_tampered) == terminal_pre

    pending_tampered =
      put_in(state, ["operations", other_oid, "records", "prepared"], grant_prepared)

    pending_pre = Core.show(pending_tampered)
    assert {:error, :cross_operation} = Core.compact(pending_tampered, source)
    assert Core.show(pending_tampered) == pending_pre
  end

  test "security regression: restore of 48 pending records exceeds hard occupancy" do
    records =
      Enum.map(1..48, fn n ->
        {:ok, intent} = AuditJournal.admit_intent(grant_n(n))
        prepared_record(intent)
      end)

    manifest =
      Map.new(records, fn record ->
        {:ok, bytes} = AuditJournal.canonical_record_bytes(record)
        {:ok, fingerprint} = AuditJournal.record_fingerprint(bytes)
        {record["operation_id"], "prepared:" <> fingerprint}
      end)

    snapshot = %{
      "version" => 1,
      "kind" => AuditJournal.snapshot_kind(),
      "source" => compact_source(48, 0),
      "pending_manifest" => manifest,
      "terminals" => %{}
    }

    assert {:ok, _} = AuditJournal.admit_snapshot(snapshot)
    assert {:error, :capacity_exhausted} = Core.restore(snapshot, records)
  end

  test "security regression: empty compact and restore store a bounded integer snapshot size" do
    assert {:ok, empty} = Core.new()
    source = compact_source(0, 0)
    assert {:ok, compacted, snapshot, []} = Core.compact(empty, source)
    assert is_integer(compacted["snapshot_bytes"])
    assert compacted["snapshot_bytes"] >= 0
    assert {:ok, bytes} = AuditJournal.canonical_snapshot_bytes(snapshot)
    assert compacted["snapshot_bytes"] == byte_size(bytes)
    assert compacted["snapshot_bytes"] <= AuditJournal.limits().max_snapshot_bytes

    cap = Core.capacity(compacted)
    assert cap["used_entries"] == 1
    assert cap["used_bytes"] == compacted["snapshot_bytes"]

    assert {:ok, restored} = Core.restore(snapshot, [])
    assert is_integer(restored["snapshot_bytes"])
    assert restored["snapshot_bytes"] == compacted["snapshot_bytes"]
    assert Core.capacity(restored)["used_entries"] == 1
    assert Core.capacity(restored)["used_bytes"] == restored["snapshot_bytes"]
    assert Core.show(restored)["operations"] == []
  end

  test "security regression: non-empty compact and restore use integer snapshot size once" do
    {:ok, grant} = AuditJournal.admit_intent(grant_absent())
    {:ok, revoke} = AuditJournal.admit_intent(revoke_facts())
    prepared_grant = prepared_record(grant)
    applied_grant = applied_record(grant)
    delivered = delivered_record(grant)
    prepared_revoke = prepared_record(revoke)
    applied_revoke = applied_record(revoke)

    assert {:ok, state} =
             Core.fold([
               prepared_grant,
               applied_grant,
               delivered,
               prepared_revoke,
               applied_revoke
             ])

    source = compact_source(5, 10)
    assert {:ok, compacted, snapshot, pending} = Core.compact(state, source)
    assert length(pending) == 2
    assert is_integer(compacted["snapshot_bytes"])
    assert compacted["snapshot_bytes"] >= 0
    assert {:ok, bytes} = AuditJournal.canonical_snapshot_bytes(snapshot)
    assert compacted["snapshot_bytes"] == byte_size(bytes)

    pending_bytes = pending_byte_size(pending)
    assert Core.capacity(compacted)["used_bytes"] == compacted["snapshot_bytes"] + pending_bytes
    assert Core.capacity(compacted)["used_entries"] == 1 + length(pending)

    assert {:ok, restored} = Core.restore(snapshot, pending)
    assert is_integer(restored["snapshot_bytes"])
    assert restored["snapshot_bytes"] == compacted["snapshot_bytes"]
    assert Core.capacity(restored)["used_bytes"] == restored["snapshot_bytes"] + pending_bytes
    assert Core.capacity(restored)["used_entries"] == 1 + length(pending)
  end

  test "security regression: prepared-only compact expands pending entries for restore" do
    {:ok, intent} = AuditJournal.admit_intent(grant_absent())
    prepared = prepared_record(intent)
    assert {:ok, state} = Core.fold([prepared])
    source = compact_source(1, 0)
    assert {:ok, compacted, snapshot, pending} = Core.compact(state, source)
    assert length(pending) == 1
    assert hd(pending)["record_type"] == "prepared"

    entries = AuditJournal.snapshot_pending_entries(snapshot)
    assert length(entries) == 1
    assert hd(entries)["operation_id"] == intent["operation_id"]
    assert hd(entries)["record_type"] == "prepared"
    assert is_binary(hd(entries)["sha256"])
    assert byte_size(hd(entries)["sha256"]) == 64

    assert {:ok, restored} = Core.restore(snapshot, pending)
    assert is_integer(restored["snapshot_bytes"])
    assert restored["snapshot_bytes"] >= 0
    assert Core.capacity(restored)["used_entries"] == 2
    assert Core.show(restored)["operations"] == Core.show(compacted)["operations"]
    assert {:ok, ^restored, :idempotent} = Core.append(restored, prepared)
  end

  test "security regression: restore hard occupancy precedes retained-set mismatch" do
    records =
      Enum.map(1..48, fn n ->
        {:ok, intent} = AuditJournal.admit_intent(grant_n(n))
        prepared_record(intent)
      end)

    snapshot = %{
      "version" => 1,
      "kind" => AuditJournal.snapshot_kind(),
      "source" => compact_source(0, 0),
      "pending_manifest" => %{},
      "terminals" => %{}
    }

    assert {:ok, _} = AuditJournal.admit_snapshot(snapshot)
    assert {:error, :capacity_exhausted} = Core.restore(snapshot, records)
    refute match?({:error, :pending_mismatch}, Core.restore(snapshot, records))
    refute match?({:error, :malformed}, Core.restore(snapshot, records))
    refute match?({:error, :cross_operation}, Core.restore(snapshot, records))
  end

  test "security regression: restore occupancy does not bypass malformed or duplicate-record admission" do
    snapshot = %{
      "version" => 1,
      "kind" => AuditJournal.snapshot_kind(),
      "source" => compact_source(0, 0),
      "pending_manifest" => %{},
      "terminals" => %{}
    }

    malformed = List.duplicate(%{"nope" => true}, 48)
    assert {:error, :malformed} = Core.restore(snapshot, malformed)
    refute match?({:error, :capacity_exhausted}, Core.restore(snapshot, malformed))

    {:ok, intent} = AuditJournal.admit_intent(grant_n(1))
    prepared = prepared_record(intent)
    duplicates = List.duplicate(prepared, 48)
    assert {:error, :pending_mismatch} = Core.restore(snapshot, duplicates)
    refute match?({:error, :capacity_exhausted}, Core.restore(snapshot, duplicates))

    cross =
      Enum.map(1..48, fn n ->
        {:ok, member_intent} = AuditJournal.admit_intent(grant_n(n))
        Map.put(prepared_record(member_intent), "operation_id", String.duplicate("c", 64))
      end)

    assert {:error, :cross_operation} = Core.restore(snapshot, cross)
    refute match?({:error, :capacity_exhausted}, Core.restore(snapshot, cross))
  end

  test "security regression: restore hard byte occupancy precedes retained-set mismatch" do
    limits = AuditJournal.limits()

    snapshot = %{
      "version" => 1,
      "kind" => AuditJournal.snapshot_kind(),
      "source" => compact_source(0, 0),
      "pending_manifest" => %{},
      "terminals" => %{}
    }

    assert {:ok, admitted} = AuditJournal.admit_snapshot(snapshot)
    assert {:ok, snap_bytes} = AuditJournal.canonical_snapshot_bytes(admitted)
    snap_size = byte_size(snap_bytes)

    {records, used_bytes} =
      Enum.reduce_while(1..(limits.hard_entry_cap - 1), {[], snap_size}, fn n, {acc, used} ->
        {:ok, intent} = AuditJournal.admit_intent(large_grant_n(n))
        record = prepared_record(intent)
        {:ok, bytes} = AuditJournal.canonical_record_bytes(record)
        next_used = used + byte_size(bytes)
        next_acc = acc ++ [record]

        if next_used > limits.hard_byte_cap do
          {:halt, {next_acc, next_used}}
        else
          {:cont, {next_acc, next_used}}
        end
      end)

    assert used_bytes > limits.hard_byte_cap
    assert 1 + length(records) <= limits.hard_entry_cap
    assert {:error, :capacity_exhausted} = Core.restore(snapshot, records)
    refute match?({:error, :pending_mismatch}, Core.restore(snapshot, records))
  end

  test "security regression: byte caps precede UTF-8 and grammar scans" do
    assert {:ok, _intent} = AuditJournal.admit_intent(grant_absent())

    oversized_invalid_utf8 = String.duplicate("x", 36) <> <<0xFF>>

    assert {:error, :invalid_field} =
             grant_absent()
             |> Map.put("authority_key", oversized_invalid_utf8)
             |> AuditJournal.admit_intent()
  end

  defp compact_source(frames, offset) do
    %{
      "committed_digest" => String.duplicate("ab", 32),
      "committed_frames" => frames,
      "committed_offset" => offset
    }
  end

  defp grant_absent do
    %{
      "version" => 1,
      "kind" => AuditJournal.intent_kind(),
      "operation" => "capability_grant",
      "effect_class" => "authority_increase",
      "authority_namespace" => "capability",
      "authority_key" => @cap_id,
      "before_fence" => %{"kind" => "absent"},
      "after_fingerprint" => %{
        "kind" => "live",
        "record_id" => "rec_1",
        "generation" => 1,
        "revision" => 1,
        "capability_digest" => @digest
      },
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

  defp prepared_record(intent) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "prepared",
      "operation_id" => intent["operation_id"],
      "occurred_at" => intent["prepared_at"],
      "intent" => intent
    }
  end

  defp applied_record(intent) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "effect_applied",
      "operation_id" => intent["operation_id"],
      "occurred_at" => "2026-08-20T12:00:01Z",
      "observation" => %{
        "kind" => "applied",
        "after_fingerprint" => intent["after_fingerprint"]
      }
    }
  end

  defp delivered_record(intent) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "delivered",
      "operation_id" => intent["operation_id"],
      "occurred_at" => "2026-08-20T12:00:02Z"
    }
  end

  defp revoke_facts do
    %{
      "version" => 1,
      "kind" => AuditJournal.intent_kind(),
      "operation" => "capability_revoke",
      "effect_class" => "authority_reduce",
      "authority_namespace" => "capability",
      "authority_key" => @cap_id,
      "before_fence" => %{
        "kind" => "live",
        "record_id" => "rec_1",
        "generation" => 3,
        "revision" => 1,
        "capability_digest" => @digest
      },
      "after_fingerprint" => %{"kind" => "tombstone", "generation" => 3},
      "audit" => %{
        "event_type" => "capability_revoked",
        "data" => %{
          "capability_id" => @cap_id,
          "principal_id" => "agent_a",
          "resource_uri" => "arbor://fs/read/x"
        }
      },
      "prepared_at" => @prepared_at
    }
  end

  defp other_grant do
    grant_absent()
    |> Map.put("authority_key", "cap_" <> String.duplicate("b", 32))
    |> put_in(["audit", "data", "capability_id"], "cap_" <> String.duplicate("b", 32))
  end

  defp grant_n(n) do
    cap_id = cap_id(n)

    grant_absent()
    |> Map.put("authority_key", cap_id)
    |> put_in(["audit", "data", "capability_id"], cap_id)
  end

  defp large_grant_n(n) do
    grant_n(n)
    |> put_in(["audit", "data", "resource_uri"], String.duplicate("r", 2048))
    |> put_in(["audit", "data", "principal_id"], String.duplicate("p", 256))
    |> Map.merge(%{
      "actor_id" => String.duplicate("a", 256),
      "task_id" => String.duplicate("t", 256),
      "session_id" => String.duplicate("s", 256),
      "correlation_id" => String.duplicate("c", 128),
      "causation_id" => String.duplicate("d", 128)
    })
    |> put_in(["after_fingerprint", "record_id"], String.duplicate("i", 128))
  end

  defp pending_byte_size(records) do
    Enum.reduce(records, 0, fn record, acc ->
      {:ok, bytes} = AuditJournal.canonical_record_bytes(record)
      acc + byte_size(bytes)
    end)
  end

  defp revoke_n(n) do
    cap_id = cap_id(n)

    revoke_facts()
    |> Map.put("authority_key", cap_id)
    |> put_in(["audit", "data", "capability_id"], cap_id)
  end

  defp cap_id(n) do
    hex =
      n
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(32, "0")

    "cap_" <> hex
  end
end
