defmodule Arbor.Security.AuditJournalCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Security.AuditJournalCore, as: Core
  alias Arbor.Security.Contracts.AuditJournal

  @digest String.duplicate("ab", 32)
  @prepared_at "2026-08-20T12:00:00Z"
  @t1 "2026-08-20T12:00:01Z"
  @t2 "2026-08-20T12:00:02Z"

  describe "new/show/capacity" do
    test "starts empty" do
      assert {:ok, state} = Core.new()

      assert Core.show(state) == %{
               "version" => 1,
               "entry_count" => 0,
               "byte_count" => 0,
               "operations" => []
             }

      cap = Core.capacity(state)
      assert cap["used_entries"] == 0
      assert cap["used_bytes"] == 0
      assert cap["soft_entry_cap"] == 32
      assert cap["hard_entry_cap"] == 48
      assert cap["reserve_entries"] == 16
    end
  end

  describe "legal transitions" do
    test "prepared -> effect_applied -> delivered" do
      {prepared, applied, delivered} = grant_lifecycle()
      assert {:ok, state} = Core.fold([prepared, applied, delivered])
      shown = Core.show(state)
      assert shown["entry_count"] == 3
      assert hd(shown["operations"])["status"] == "delivered"
      assert hd(shown["operations"])["effect_class"] == "authority_increase"
    end

    test "prepared -> effect_rejected" do
      {:ok, intent} = AuditJournal.admit_intent(revoke_facts(1))
      prepared = prepared_record(intent)
      rejected = rejected_record(intent, @t1)
      assert {:ok, state} = Core.fold([prepared, rejected])
      assert hd(Core.show(state)["operations"])["status"] == "effect_rejected"
    end
  end

  describe "duplicate and conflict" do
    test "identical canonical record bytes are idempotent and do not consume capacity" do
      {prepared, applied, _delivered} = grant_lifecycle()
      assert {:ok, state} = Core.fold([prepared])
      used = Core.capacity(state)
      assert {:ok, ^state, :idempotent} = Core.append(state, prepared)
      assert Core.capacity(state) == used

      assert {:ok, state} = Core.fold([prepared, applied])
      assert {:ok, ^state, :idempotent} = Core.append(state, applied)
    end

    test "same record identity with different bytes is operation_conflict" do
      {prepared, applied, delivered} = grant_lifecycle()
      assert {:ok, state} = Core.fold([prepared, applied])

      other_applied = Map.put(applied, "occurred_at", "2026-08-20T12:00:09Z")
      assert {:error, :operation_conflict} = Core.append(state, other_applied)

      assert {:ok, delivered_state} = Core.append(state, delivered)
      other_delivered = Map.put(delivered, "occurred_at", "2026-08-20T12:00:09Z")
      assert {:error, :operation_conflict} = Core.append(delivered_state, other_delivered)
    end
  end

  describe "illegal transitions" do
    test "non-prepared records without an operation are out_of_order" do
      {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
      {:ok, empty} = Core.new()

      assert {:error, :out_of_order} = Core.append(empty, applied_record(intent, @t1))
      assert {:error, :out_of_order} = Core.append(empty, rejected_record(intent, @t1))
      assert {:error, :out_of_order} = Core.append(empty, delivered_record(intent, @t2))
    end

    test "delivered while prepared is illegal_transition" do
      {prepared, _applied, delivered} = grant_lifecycle()
      assert {:ok, state} = Core.fold([prepared])
      assert {:error, :illegal_transition} = Core.append(state, delivered)
    end

    test "rejected while applied is illegal_transition" do
      {prepared, applied, _delivered} = grant_lifecycle()
      {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
      assert {:ok, state} = Core.fold([prepared, applied])
      assert {:error, :illegal_transition} = Core.append(state, rejected_record(intent, @t2))
    end

    test "post-terminal new types fail closed; stored identity still idempotent" do
      {:ok, intent} = AuditJournal.admit_intent(revoke_facts(1))
      prepared = prepared_record(intent)
      rejected = rejected_record(intent, @t1)
      assert {:ok, state} = Core.fold([prepared, rejected])
      snapshot = Core.show(state)

      assert {:error, :post_terminal} = Core.append(state, applied_record(intent, @t2))
      assert {:error, :post_terminal} = Core.append(state, delivered_record(intent, @t2))
      assert {:ok, ^state, :idempotent} = Core.append(state, prepared)
      assert {:ok, ^state, :idempotent} = Core.append(state, rejected)
      assert Core.show(state) == snapshot

      {prepared2, applied2, delivered2} = grant_lifecycle()
      assert {:ok, done} = Core.fold([prepared2, applied2, delivered2])
      {:ok, grant_intent} = AuditJournal.admit_intent(grant_facts(1))
      assert {:error, :post_terminal} = Core.append(done, rejected_record(grant_intent, @t2))
      assert {:ok, ^done, :idempotent} = Core.append(done, applied2)
    end

    test "applied after_fingerprint mismatch is malformed" do
      {prepared, applied, _delivered} = grant_lifecycle()
      mismatch = put_in(applied, ["observation", "after_fingerprint", "generation"], 9)
      assert {:ok, state} = Core.fold([prepared])
      assert {:error, :malformed} = Core.append(state, mismatch)
    end

    test "indeterminate observation never invents a transition" do
      {prepared, _applied, _delivered} = grant_lifecycle()
      {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))
      assert {:ok, state} = Core.fold([prepared])
      snapshot = Core.show(state)

      bad =
        applied_record(intent, @t1)
        |> put_in(["observation", "kind"], "unavailable")

      assert {:error, :malformed} = Core.append(state, bad)
      assert Core.show(state) == snapshot
    end

    test "cross_operation is not mapped to malformed" do
      {prepared, _applied, _delivered} = grant_lifecycle()
      other = String.duplicate("c", 64)
      assert {:ok, empty} = Core.new()

      assert {:error, :cross_operation} =
               Core.append(empty, Map.put(prepared, "operation_id", other))
    end

    test "malformed members fail the whole fold without keeping a prefix" do
      {prepared, applied, _delivered} = grant_lifecycle()
      assert {:error, :malformed} = Core.fold([prepared, %{"nope" => true}, applied])
      assert {:error, :malformed} = Core.fold([prepared | :tail])
    end

    test "fold is single-pass and bounded at the raw record-batch limit" do
      {prepared, _applied, _delivered} = grant_lifecycle()
      max_records = AuditJournal.limits().max_fold_records

      assert max_records == AuditJournal.limits().hard_entry_cap
      assert {:ok, exact} = Core.fold(List.duplicate(prepared, max_records))
      assert Core.capacity(exact)["used_entries"] == 1

      assert {:error, :malformed} =
               Core.fold(List.duplicate(prepared, max_records + 1))

      malformed_head = [%{"nope" => true} | List.duplicate(prepared, max_records + 1)]
      assert {:error, :malformed} = Core.fold(malformed_head)
    end
  end

  describe "capacity static floor" do
    test "static floor: 32 grant prepares exhaust soft entries; revoke and convergence still admit until hard cap" do
      {:ok, state} = Core.new()

      state =
        Enum.reduce(1..32, state, fn n, acc ->
          {:ok, intent} = AuditJournal.admit_intent(grant_facts(n))
          assert {:ok, next} = Core.append(acc, prepared_record(intent))
          next
        end)

      cap = Core.capacity(state)
      assert cap["used_entries"] == 32
      assert cap["remaining_soft_entries"] == 0

      {:ok, extra_grant} = AuditJournal.admit_intent(grant_facts(33))

      assert {:error, :soft_capacity_exhausted} =
               Core.append(state, prepared_record(extra_grant))

      {:ok, revoke_intent} = AuditJournal.admit_intent(revoke_facts(40))
      assert {:ok, state} = Core.append(state, prepared_record(revoke_intent))
      assert {:ok, state} = Core.append(state, rejected_record(revoke_intent, @t1))

      {:ok, first_grant} = AuditJournal.admit_intent(grant_facts(1))
      assert {:ok, state} = Core.append(state, applied_record(first_grant, @t1))
      assert {:ok, state} = Core.append(state, delivered_record(first_grant, @t2))

      # 32 grants + 1 revoke prepare + 1 rejected + 1 applied + 1 delivered = 36
      assert Core.capacity(state)["used_entries"] == 36

      state =
        Enum.reduce(41..52, state, fn n, acc ->
          {:ok, intent} = AuditJournal.admit_intent(revoke_facts(n))
          {:ok, next} = Core.append(acc, prepared_record(intent))
          next
        end)

      # 36 + 12 = 48 hard entry cap
      assert Core.capacity(state)["used_entries"] == 48

      {:ok, overflow} = AuditJournal.admit_intent(revoke_facts(99))
      assert {:error, :capacity_exhausted} = Core.append(state, prepared_record(overflow))

      {:ok, grant2} = AuditJournal.admit_intent(grant_facts(2))
      assert {:error, :capacity_exhausted} = Core.append(state, applied_record(grant2, @t1))
    end

    test "large grant prepares hit soft_byte_cap before the entry cap" do
      {:ok, state} = Core.new()
      limits = AuditJournal.limits()

      {state, count} =
        Enum.reduce_while(1..32, {state, 0}, fn n, {acc, used} ->
          {:ok, intent} = AuditJournal.admit_intent(large_grant_facts(n))
          record = prepared_record(intent)

          case Core.append(acc, record) do
            {:ok, next} ->
              {:cont, {next, used + 1}}

            {:error, :soft_capacity_exhausted} ->
              {:halt, {acc, used}}
          end
        end)

      cap = Core.capacity(state)
      assert count < 32
      assert cap["used_bytes"] <= limits.soft_byte_cap
      assert cap["used_entries"] < limits.soft_entry_cap

      {:ok, next_grant} = AuditJournal.admit_intent(large_grant_facts(count + 1))
      assert {:error, :soft_capacity_exhausted} = Core.append(state, prepared_record(next_grant))

      {:ok, revoke_intent} = AuditJournal.admit_intent(revoke_facts(200))
      assert {:ok, _state} = Core.append(state, prepared_record(revoke_intent))
    end

    test "replay accounting is deterministic and idempotent replays do not bump counts" do
      records =
        Enum.map(1..3, fn n ->
          {:ok, intent} = AuditJournal.admit_intent(grant_facts(n))
          prepared_record(intent)
        end)

      assert {:ok, a} = Core.fold(records)
      assert {:ok, b} = Core.fold(records)
      assert Core.show(a) == Core.show(b)
      assert Core.capacity(a) == Core.capacity(b)

      assert {:ok, ^a, :idempotent} = Core.append(a, hd(records))
      assert Core.capacity(a)["used_entries"] == 3
    end

    test "security regression: pending_operations/1 fail-open projector is not exported" do
      Code.ensure_loaded!(Core)
      refute function_exported?(Core, :pending_operations, 1)
    end

    test "pending_summary empty is zero count and zero age" do
      assert {:ok, state} = Core.new()

      assert {:ok,
              %{
                "pending_count" => 0,
                "oldest_pending_age_seconds" => 0,
                "operations" => []
              }} = Core.pending_summary(state, @prepared_at)
    end

    test "pending_summary ages from injected now and excludes terminals" do
      {prepared, applied, delivered} = grant_lifecycle()
      assert {:ok, prepared_state} = Core.fold([prepared])

      assert {:ok, summary} = Core.pending_summary(prepared_state, "2026-08-20T12:00:10Z")
      assert summary["pending_count"] == 1
      assert summary["oldest_pending_age_seconds"] == 10
      assert hd(summary["operations"])["status"] == "prepared"

      assert {:ok, zero} = Core.pending_summary(prepared_state, "2026-08-20T11:00:00Z")
      assert zero["oldest_pending_age_seconds"] == 0

      assert {:ok, capped} = Core.pending_summary(prepared_state, "9999-12-31T23:59:59Z")
      assert capped["oldest_pending_age_seconds"] == 31_536_000

      assert {:ok, applied_state} = Core.append(prepared_state, applied)
      assert {:ok, applied_summary} = Core.pending_summary(applied_state, "2026-08-20T12:00:10Z")
      assert applied_summary["pending_count"] == 1
      assert hd(applied_summary["operations"])["status"] == "effect_applied"

      assert {:ok, delivered_state} = Core.append(applied_state, delivered)
      assert {:ok, done} = Core.pending_summary(delivered_state, "2026-08-20T12:00:10Z")
      assert done["pending_count"] == 0
      assert done["oldest_pending_age_seconds"] == 0
      assert done["operations"] == []

      {:ok, intent} = AuditJournal.admit_intent(revoke_facts(1))
      rejected = rejected_record(intent, @t1)
      assert {:ok, rejected_state} = Core.fold([prepared_record(intent), rejected])
      assert {:ok, rejected_summary} = Core.pending_summary(rejected_state, "2026-08-20T12:00:10Z")
      assert rejected_summary["pending_count"] == 0
      assert rejected_summary["operations"] == []
    end

    test "pending_summary malformed now fails closed without changing fold semantics" do
      {prepared, _applied, _delivered} = grant_lifecycle()
      assert {:ok, state} = Core.fold([prepared])
      snapshot = Core.show(state)
      cap = Core.capacity(state)

      assert {:error, :malformed} = Core.pending_summary(state, "nope")
      assert {:error, :malformed} = Core.pending_summary(state, 12)
      assert {:error, :malformed} = Core.pending_summary(%{"version" => 2}, @prepared_at)
      assert Core.show(state) == snapshot
      assert Core.capacity(state) == cap
    end

    test "purity: production modules contain no impure calls" do
      forbidden = [
        ~r/DateTime\.utc_now/,
        ~r/System\.(monotonic|os|system)_time/,
        ~r/:rand\./,
        ~r/:erlang\.unique_integer/,
        ~r/\bmake_ref\s*\(/,
        ~r/Application\.get_env/,
        ~r/GenServer\.(call|cast|start)/,
        ~r/\bRepo\./,
        ~r/:ets\./,
        ~r/\bLogger\./,
        ~r/\bFile\.(read|write|open|rm|ls)/,
        ~r/\bProcess\.send/,
        ~r/Arbor\.Signals/,
        ~r/Historian/,
        ~r/Arbor\.Security\.(grant|revoke)\b/
      ]

      files = [
        Path.expand("../../../lib/arbor/security/audit_journal_core.ex", __DIR__),
        Path.expand("../../../lib/arbor/security/contracts/audit_journal.ex", __DIR__)
      ]

      for path <- files, regex <- forbidden do
        src = File.read!(path)
        refute Regex.match?(regex, src), "#{Path.basename(path)} matched #{inspect(regex)}"
      end
    end
  end

  describe "compact and restore" do
    @now "2026-08-20T12:00:10Z"

    test "round-trips mixed delivered, rejected, prepared, and effect_applied" do
      {state, delivered, rejected, prepared_pending, applied_pending} = mixed_journal()
      pre_show = Core.show(state)
      assert {:ok, pre_pending} = Core.pending_summary(state, @now)

      assert {:ok, compacted, snapshot, pending} = Core.compact(state, snapshot_source(8, 99))
      assert {:ok, restored} = Core.restore(snapshot, pending)

      assert Core.show(compacted)["operations"] == pre_show["operations"]
      assert Core.show(restored)["operations"] == pre_show["operations"]
      assert {:ok, ^pre_pending} = Core.pending_summary(compacted, @now)
      assert {:ok, ^pre_pending} = Core.pending_summary(restored, @now)

      cap = Core.capacity(restored)
      assert cap["used_entries"] == 1 + length(pending)
      assert length(pending) == 3
      assert cap["used_bytes"] == restored["snapshot_bytes"] + pending_byte_size(pending)

      refute Map.has_key?(
               restored["operations"][delivered["operation_id"]],
               "records"
             )

      assert is_binary(
               compacted["operations"][prepared_pending["operation_id"]]["records"]["prepared"]
             )

      assert {:ok, bytes} = AuditJournal.canonical_snapshot_bytes(snapshot)
      assert byte_size(bytes) <= AuditJournal.limits().max_record_bytes

      assert rejected["record_type"] == "effect_rejected"
      assert applied_pending["record_type"] == "effect_applied"
    end

    test "terminal retries stay idempotent or conflict after restore" do
      {state, delivered, rejected, prepared_pending, applied_pending} = mixed_journal()
      assert {:ok, _compacted, snapshot, pending} = Core.compact(state, snapshot_source(8, 99))
      assert {:ok, restored} = Core.restore(snapshot, pending)
      used = Core.capacity(restored)

      assert {:ok, ^restored, :idempotent} = Core.append(restored, delivered)
      assert {:ok, ^restored, :idempotent} = Core.append(restored, rejected)
      assert Core.capacity(restored) == used

      other_delivered = Map.put(delivered, "occurred_at", "2026-08-20T12:00:09Z")
      assert {:error, :operation_conflict} = Core.append(restored, other_delivered)

      {:ok, revoke_intent} = AuditJournal.admit_intent(revoke_facts(1))
      assert {:error, :post_terminal} = Core.append(restored, applied_record(revoke_intent, @t2))

      {:ok, pending_intent} = AuditJournal.admit_intent(grant_facts(2))
      assert {:error, :illegal_transition} =
               Core.append(restored, delivered_record(pending_intent, @t2))

      other_applied = Map.put(applied_pending, "occurred_at", "2026-08-20T12:00:09Z")
      assert {:error, :operation_conflict} = Core.append(restored, other_applied)
      assert {:ok, ^restored, :idempotent} = Core.append(restored, prepared_pending)
    end

    test "restore rejects every retained-set mismatch class" do
      {state, _delivered, _rejected, _prepared_pending, _applied_pending} = mixed_journal()
      assert {:ok, compacted, snapshot, pending} = Core.compact(state, snapshot_source(8, 99))
      shown = Core.show(compacted)
      [first, second, third] = pending

      assert {:error, :pending_mismatch} = Core.restore(snapshot, Enum.drop(pending, -1))

      {:ok, extra_intent} = AuditJournal.admit_intent(grant_facts(8))
      extra = prepared_record(extra_intent)
      assert {:error, :pending_mismatch} = Core.restore(snapshot, pending ++ [extra])
      assert {:error, :pending_mismatch} = Core.restore(snapshot, [second, first, third])

      substituted =
        Enum.map(pending, fn
          %{"record_type" => "effect_applied"} = record ->
            Map.put(record, "occurred_at", "2026-08-20T12:00:09Z")

          record ->
            record
        end)

      assert {:error, :pending_mismatch} = Core.restore(snapshot, substituted)
      assert {:error, :pending_mismatch} = Core.restore(snapshot, [first, first, second, third])
      assert {:error, :malformed} = Core.restore(snapshot, [%{"nope" => true} | tl(pending)])

      unavailable = %{
        "version" => 1,
        "kind" => AuditJournal.record_kind(),
        "record_type" => "effect_applied",
        "operation_id" => first["operation_id"],
        "occurred_at" => @t1,
        "observation" => %{
          "kind" => "unavailable",
          "after_fingerprint" => %{"kind" => "absent"}
        }
      }

      assert {:error, :malformed} = Core.restore(snapshot, [unavailable | tl(pending)])
      assert Core.show(compacted) == shown

      {:ok, other_intent} = AuditJournal.admit_intent(grant_facts(9))
      foreign = prepared_record(other_intent)
      assert {:error, :cross_operation} = Core.restore(snapshot, [foreign, second, third])

      forged = Map.put(first, "operation_id", String.duplicate("c", 64))
      assert {:error, :cross_operation} = Core.restore(snapshot, [forged, second, third])
    end

    test "empty compact binds source and restores occupancy 1" do
      assert {:ok, empty} = Core.new()
      source = snapshot_source(0, 0)
      assert {:ok, compacted, snapshot, []} = Core.compact(empty, source)
      assert snapshot["source"] == source
      assert Core.capacity(compacted)["used_entries"] == 1
      assert {:ok, restored} = Core.restore(snapshot, [])
      assert Core.show(restored)["operations"] == []
    end
  end

  describe "compacted capacity" do
    test "reclaims terminal occupancy and preserves the authority-reduction reserve" do
      {:ok, state} = Core.new()

      state =
        Enum.reduce(1..32, state, fn n, acc ->
          {:ok, intent} = AuditJournal.admit_intent(grant_facts(n))
          {:ok, next} = Core.append(acc, prepared_record(intent))
          next
        end)

      state =
        Enum.reduce(1..8, state, fn n, acc ->
          {:ok, intent} = AuditJournal.admit_intent(grant_facts(n))
          {:ok, acc} = Core.append(acc, applied_record(intent, @t1))
          {:ok, acc} = Core.append(acc, delivered_record(intent, @t2))
          acc
        end)

      assert Core.capacity(state)["used_entries"] == 48
      pre = Core.show(state)

      assert {:ok, compacted, snapshot, pending} = Core.compact(state, snapshot_source(48, 1))
      assert {:ok, bytes} = AuditJournal.canonical_snapshot_bytes(snapshot)
      assert byte_size(bytes) <= 32_768
      assert length(pending) == 24

      cap = Core.capacity(compacted)
      assert cap["used_entries"] == 25
      assert cap["remaining_hard_entries"] - cap["remaining_soft_entries"] == 16
      assert Core.show(compacted)["operations"] == pre["operations"]

      {:ok, extra} = AuditJournal.admit_intent(grant_facts(33))
      assert {:ok, compacted} = Core.append(compacted, prepared_record(extra))

      compacted =
        Enum.reduce(34..39, compacted, fn n, acc ->
          {:ok, intent} = AuditJournal.admit_intent(grant_facts(n))
          {:ok, next} = Core.append(acc, prepared_record(intent))
          next
        end)

      assert Core.capacity(compacted)["used_entries"] == 32
      {:ok, overflow_grant} = AuditJournal.admit_intent(grant_facts(40))

      assert {:error, :soft_capacity_exhausted} =
               Core.append(compacted, prepared_record(overflow_grant))

      {:ok, revoke_intent} = AuditJournal.admit_intent(revoke_facts(100))
      assert {:ok, compacted} = Core.append(compacted, prepared_record(revoke_intent))

      compacted =
        Enum.reduce(101..115, compacted, fn n, acc ->
          {:ok, intent} = AuditJournal.admit_intent(revoke_facts(n))
          {:ok, next} = Core.append(acc, prepared_record(intent))
          next
        end)

      assert Core.capacity(compacted)["used_entries"] == 48
      {:ok, overflow_revoke} = AuditJournal.admit_intent(revoke_facts(200))
      assert {:error, :capacity_exhausted} = Core.append(compacted, prepared_record(overflow_revoke))
    end

    test "oversized snapshot fails closed without restore" do
      oversized = String.duplicate("x", 32_768) <> <<0xFF>>

      snapshot =
        %{
          "version" => 1,
          "kind" => AuditJournal.snapshot_kind(),
          "source" => snapshot_source(0, 0),
          "pending_manifest" => %{},
          "terminals" => %{"x" => oversized}
        }

      assert {:error, :record_too_large} = Core.restore(snapshot, [])
    end

    test "restore rejects occupancy above the hard entry cap" do
      records =
        Enum.map(1..48, fn n ->
          {:ok, intent} = AuditJournal.admit_intent(grant_facts(n))
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
        "source" => snapshot_source(48, 0),
        "pending_manifest" => manifest,
        "terminals" => %{}
      }

      assert {:ok, _} = AuditJournal.admit_snapshot(snapshot)
      assert {:error, :capacity_exhausted} = Core.restore(snapshot, records)
    end

    test "fails closed when occupancy cannot fit the snapshot" do
      {:ok, state} = Core.new()

      state =
        Enum.reduce(1..32, state, fn n, acc ->
          {:ok, intent} = AuditJournal.admit_intent(grant_facts(n))
          {:ok, next} = Core.append(acc, prepared_record(intent))
          next
        end)

      state =
        Enum.reduce(40..55, state, fn n, acc ->
          {:ok, intent} = AuditJournal.admit_intent(revoke_facts(n))
          {:ok, next} = Core.append(acc, prepared_record(intent))
          next
        end)

      assert Core.capacity(state)["used_entries"] == 48
      pre = Core.show(state)
      assert {:error, :capacity_exhausted} = Core.compact(state, snapshot_source(48, 1))
      assert Core.show(state) == pre
    end
  end

  describe "compaction_reclaims_occupancy?" do
    test "empty and pending-only journals do not reclaim" do
      assert {:ok, empty} = Core.new()
      refute Core.compaction_reclaims_occupancy?(empty)

      state =
        Enum.reduce(1..32, empty, fn n, acc ->
          {:ok, intent} = AuditJournal.admit_intent(grant_facts(n))
          {:ok, next} = Core.append(acc, prepared_record(intent))
          next
        end)

      refute Core.compaction_reclaims_occupancy?(state)

      state =
        Enum.reduce(33..48, state, fn n, acc ->
          {:ok, intent} = AuditJournal.admit_intent(revoke_facts(n))
          {:ok, next} = Core.append(acc, prepared_record(intent))
          next
        end)

      assert Core.capacity(state)["used_entries"] == 48
      refute Core.compaction_reclaims_occupancy?(state)
    end

    test "delivered terminals at the soft cap reclaim" do
      {:ok, state} = Core.new()

      state =
        Enum.reduce(1..8, state, fn n, acc ->
          {:ok, intent} = AuditJournal.admit_intent(grant_facts(n))
          {:ok, acc} = Core.append(acc, prepared_record(intent))
          {:ok, acc} = Core.append(acc, applied_record(intent, @t1))
          {:ok, acc} = Core.append(acc, delivered_record(intent, @t2))
          acc
        end)

      state =
        Enum.reduce(9..16, state, fn n, acc ->
          {:ok, intent} = AuditJournal.admit_intent(grant_facts(n))
          {:ok, next} = Core.append(acc, prepared_record(intent))
          next
        end)

      assert Core.capacity(state)["used_entries"] == 32
      assert Core.compaction_reclaims_occupancy?(state)
    end

    test "delivered terminals filling the hard cap reclaim" do
      {:ok, state} = Core.new()

      state =
        Enum.reduce(1..32, state, fn n, acc ->
          {:ok, intent} = AuditJournal.admit_intent(grant_facts(n))
          {:ok, next} = Core.append(acc, prepared_record(intent))
          next
        end)

      state =
        Enum.reduce(1..8, state, fn n, acc ->
          {:ok, intent} = AuditJournal.admit_intent(grant_facts(n))
          {:ok, acc} = Core.append(acc, applied_record(intent, @t1))
          {:ok, acc} = Core.append(acc, delivered_record(intent, @t2))
          acc
        end)

      assert Core.capacity(state)["used_entries"] == 48
      assert Core.compaction_reclaims_occupancy?(state)
    end

    test "rejected reserve terminals filling the hard cap reclaim" do
      {:ok, state} = Core.new()

      state =
        Enum.reduce(1..16, state, fn n, acc ->
          {:ok, intent} = AuditJournal.admit_intent(revoke_facts(n))
          {:ok, acc} = Core.append(acc, prepared_record(intent))
          {:ok, acc} = Core.append(acc, rejected_record(intent, @t1))
          acc
        end)

      state =
        Enum.reduce(1..16, state, fn n, acc ->
          {:ok, intent} = AuditJournal.admit_intent(grant_facts(n))
          {:ok, next} = Core.append(acc, prepared_record(intent))
          next
        end)

      assert Core.capacity(state)["used_entries"] == 48
      assert Core.compaction_reclaims_occupancy?(state)
    end

    test "already compacted state does not reclaim again" do
      {state, _delivered, _rejected, _prepared_pending, _applied_pending} = mixed_journal()
      assert Core.compaction_reclaims_occupancy?(state)
      assert {:ok, compacted, _snapshot, _pending} = Core.compact(state, snapshot_source(8, 99))
      refute Core.compaction_reclaims_occupancy?(compacted)
    end

    test "malformed pending with inflated occupancy does not reclaim" do
      state = %{
        "version" => 1,
        "operations" => %{"x" => %{"status" => "prepared"}},
        "entry_count" => 10,
        "byte_count" => 0
      }

      refute Core.compaction_reclaims_occupancy?(state)
    end

    test "malformed terminal with inflated occupancy does not reclaim" do
      state = %{
        "version" => 1,
        "operations" => %{
          "x" => %{"status" => "delivered", "effect_class" => "authority_increase"}
        },
        "entry_count" => 10,
        "byte_count" => 0
      }

      refute Core.compaction_reclaims_occupancy?(state)
    end

    test "tampered pending or terminal in an otherwise reclaimable journal does not reclaim" do
      {state, _delivered, _rejected, prepared_pending, _applied_pending} = mixed_journal()
      assert Core.compaction_reclaims_occupancy?(state)

      pending_id = prepared_pending["operation_id"]
      bad_pending = put_in(state, ["operations", pending_id], %{"status" => "prepared"})
      refute Core.compaction_reclaims_occupancy?(bad_pending)

      {delivered_id, _op} =
        Enum.find(state["operations"], fn {_id, op} -> op["status"] == "delivered" end)

      bad_terminal =
        put_in(state, ["operations", delivered_id], %{
          "status" => "delivered",
          "effect_class" => "authority_increase"
        })

      refute Core.compaction_reclaims_occupancy?(bad_terminal)
    end
  end

  defp snapshot_source(frames, offset) do
    %{
      "committed_digest" => String.duplicate("ab", 32),
      "committed_frames" => frames,
      "committed_offset" => offset
    }
  end

  defp mixed_journal do
    {:ok, grant1} = AuditJournal.admit_intent(grant_facts(1))
    {:ok, revoke1} = AuditJournal.admit_intent(revoke_facts(1))
    {:ok, grant2} = AuditJournal.admit_intent(grant_facts(2))
    {:ok, revoke2} = AuditJournal.admit_intent(revoke_facts(2))

    delivered = delivered_record(grant1, @t2)
    rejected = rejected_record(revoke1, @t1)
    prepared_pending = prepared_record(grant2)
    applied_pending = applied_record(revoke2, @t1)

    records = [
      prepared_record(grant1),
      applied_record(grant1, @t1),
      delivered,
      prepared_record(revoke1),
      rejected,
      prepared_pending,
      prepared_record(revoke2),
      applied_pending
    ]

    {:ok, state} = Core.fold(records)
    {state, delivered, rejected, prepared_pending, applied_pending}
  end

  defp pending_byte_size(records) do
    Enum.reduce(records, 0, fn record, acc ->
      {:ok, bytes} = AuditJournal.canonical_record_bytes(record)
      acc + byte_size(bytes)
    end)
  end

  defp grant_lifecycle do
    {:ok, intent} = AuditJournal.admit_intent(grant_facts(1))

    {prepared_record(intent), applied_record(intent, @t1), delivered_record(intent, @t2)}
  end

  defp grant_facts(n) do
    cap_id = cap_id(n)

    %{
      "version" => 1,
      "kind" => AuditJournal.intent_kind(),
      "operation" => "capability_grant",
      "effect_class" => "authority_increase",
      "authority_namespace" => "capability",
      "authority_key" => cap_id,
      "before_fence" => %{"kind" => "absent"},
      "after_fingerprint" => live_fp(1),
      "audit" => %{
        "event_type" => "capability_granted",
        "data" => %{
          "capability_id" => cap_id,
          "principal_id" => "agent_a",
          "resource_uri" => "arbor://fs/read/x"
        }
      },
      "prepared_at" => @prepared_at
    }
  end

  defp large_grant_facts(n) do
    grant_facts(n)
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

  defp revoke_facts(n) do
    cap_id = cap_id(n)

    %{
      "version" => 1,
      "kind" => AuditJournal.intent_kind(),
      "operation" => "capability_revoke",
      "effect_class" => "authority_reduce",
      "authority_namespace" => "capability",
      "authority_key" => cap_id,
      "before_fence" => live_fp(3),
      "after_fingerprint" => %{"kind" => "tombstone", "generation" => 3},
      "audit" => %{
        "event_type" => "capability_revoked",
        "data" => %{
          "capability_id" => cap_id,
          "principal_id" => "agent_a",
          "resource_uri" => "arbor://fs/read/x"
        }
      },
      "prepared_at" => @prepared_at
    }
  end

  defp live_fp(generation) do
    %{
      "kind" => "live",
      "record_id" => "rec_1",
      "generation" => generation,
      "revision" => 1,
      "capability_digest" => @digest
    }
  end

  defp cap_id(n) do
    hex =
      n
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(32, "0")

    "cap_" <> hex
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

  defp applied_record(intent, occurred_at) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "effect_applied",
      "operation_id" => intent["operation_id"],
      "occurred_at" => occurred_at,
      "observation" => %{
        "kind" => "applied",
        "after_fingerprint" => intent["after_fingerprint"]
      }
    }
  end

  defp rejected_record(intent, occurred_at) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "effect_rejected",
      "operation_id" => intent["operation_id"],
      "occurred_at" => occurred_at,
      "observation" => %{"kind" => "rejected", "reason" => "before_mismatch"}
    }
  end

  defp delivered_record(intent, occurred_at) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "delivered",
      "operation_id" => intent["operation_id"],
      "occurred_at" => occurred_at
    }
  end
end
