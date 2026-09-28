defmodule Arbor.Security.AuditJournalCoreRetirementTest do
  @moduledoc """
  Pure reducer tests for terminal-identity retirement (Floor-and-Ledger v3,
  slice 1): admission floor, retirement projection helpers, the publication
  relief predicate, capacity and pending status fields, `compact/3` options and
  v3 snapshot replay through the file core.
  """
  use ExUnit.Case, async: true

  alias Arbor.Security.AuditJournalCore, as: Core
  alias Arbor.Security.AuditJournalFileCore, as: FileCore
  alias Arbor.Security.Contracts.AuditJournal

  @moduletag :fast
  @time "2026-09-28T12:00:00Z"
  @source %{
    "committed_digest" => String.duplicate("ab", 32),
    "committed_frames" => 12,
    "committed_offset" => 9_000
  }

  describe "admission floor" do
    test "small profile floor is 1 and admits v1, v2 and v3 prepared records" do
      {:ok, small} = Core.new()
      assert Core.admission_floor(small) == 1

      state =
        fold_all(small, [record(intent(1, 1), "prepared"), record(intent(2, 2), "prepared")])

      state = fold_all(state, [record(intent(3, 3), "prepared")])

      assert {:ok, compacted, snapshot, pending} = Core.compact(state, @source, retire: true)
      assert snapshot["version"] == 1
      assert length(pending) == 3
      assert Core.admission_floor(compacted) == 1
      assert {:ok, _} = Core.append(compacted, record(intent(1, 4), "prepared"))
      assert {:ok, _} = Core.append(compacted, record(intent(2, 5), "prepared"))
      assert {:ok, _} = Core.append(compacted, record(intent(3, 6), "prepared"))
    end

    test "a fresh operational core has floor 1 until its first v3 snapshot" do
      {:ok, fresh} = Core.new(:operational)
      assert Core.admission_floor(fresh) == 1
      assert {:ok, state} = Core.append(fresh, record(intent(2, 1), "prepared"))
      assert {:ok, state} = Core.append(state, record(intent(1, 2), "prepared"))

      assert {:ok, compacted, _snapshot, _pending} = Core.compact(state, @source)
      assert Core.admission_floor(compacted) == 3
    end

    test "a restored v2 operational snapshot has floor 1, a restored v3 snapshot floor 3" do
      {:ok, v2} = Core.restore(v2_snapshot(%{}), [])
      assert Core.admission_floor(v2) == 1
      assert {:ok, _} = Core.append(v2, record(intent(2, 1), "prepared"))

      {:ok, _compacted, v3_snapshot, []} = Core.compact(v2, @source)
      {:ok, v3} = Core.restore(v3_snapshot, [])
      assert Core.admission_floor(v3) == 3
      assert Core.admission_floor(%{}) == 1
      assert Core.admission_floor(nil) == 1
    end
  end

  describe "retirement projection" do
    test "retirable_count, legacy_pending? and retirement_batch follow delivered status" do
      {:ok, op} = Core.new(:operational)
      d1 = intent(2, 1)
      d2 = intent(3, 2)
      rej = revoke_intent(3, 3)
      p2 = intent(2, 4)

      state =
        op
        |> fold_all(lifecycle(d1) ++ lifecycle(d2))
        |> fold_all([record(rej, "prepared"), rejected_record(rej)])

      assert Core.retirable_count(state) == 2
      refute Core.legacy_pending?(state)

      with_legacy = fold_all(state, [record(p2, "prepared")])
      assert Core.legacy_pending?(with_legacy)
      refute Core.legacy_pending?(fold_all(state, [record(intent(3, 5), "prepared")]))

      # The cutover case that matters most: a v2 op applied and waiting for the
      # consumer ACK is still legacy-pending, until it is delivered.
      awaiting_ack = fold_all(with_legacy, [record(p2, "effect_applied")])
      assert Core.legacy_pending?(awaiting_ack)
      refute Core.legacy_pending?(fold_all(awaiting_ack, [record(p2, "delivered")]))

      v1_applied = fold_all(state, [record(intent(1, 6), "prepared")])
      v1_applied = fold_all(v1_applied, [record(intent(1, 6), "effect_applied")])
      assert Core.legacy_pending?(v1_applied)

      assert {:ok, batch} = Core.retirement_batch(state)
      assert Map.keys(batch) |> Enum.sort() == Enum.sort([d1["operation_id"], d2["operation_id"]])

      # Byte-identical to the terminals a non-retiring compaction keeps.
      {:ok, _kept, kept_snapshot, _} = Core.compact(state, @source)
      assert batch == Map.take(kept_snapshot["terminals"], Map.keys(batch))

      assert {:ok, _} =
               AuditJournal.admit_retirement_batch(%{
                 "version" => 1,
                 "kind" => AuditJournal.retirement_batch_kind(),
                 "source" => @source,
                 "retired" => batch
               })

      {:ok, small} = Core.new()
      small = fold_all(small, lifecycle(intent(3, 9)))
      assert Core.retirable_count(small) == 0
      assert {:ok, %{}} = Core.retirement_batch(small)
      assert {:error, :malformed} = Core.retirement_batch(%{"version" => 9})
      assert Core.retirable_count(:nope) == 0
      refute Core.legacy_pending?(:nope)
    end
  end

  describe "publication_relieves?/3" do
    test "true for a soft-refused increase when retiring delivered terminals fits the soft cap" do
      state = restore_terminals(3072, 0)
      raw = record(intent(3, 1), "prepared")
      assert {:error, :soft_capacity_exhausted} = Core.append(state, raw)
      refute Core.compaction_reclaims_occupancy?(state)

      assert Core.publication_relieves?(state, raw, Core.retirable_count(state))
      assert Core.publication_relieves?(state, raw, 1)
      # Clamped to the real retirable count.
      assert Core.publication_relieves?(state, raw, 1_000_000)
    end

    test "false when the non-retirable retained set alone exceeds the class cap" do
      # 3072 rejected (never retirable) + 5 delivered: retiring the 5 still
      # leaves 3073 retained for a new increase.
      state = restore_terminals(5, 3072)
      raw = record(intent(3, 1), "prepared")
      assert {:error, :soft_capacity_exhausted} = Core.append(state, raw)
      refute Core.publication_relieves?(state, raw, Core.retirable_count(state))

      # The reduction class uses the hard cap and does fit.
      reduce = record(revoke_intent(3, 2), "prepared")
      assert Core.publication_relieves?(state, reduce, Core.retirable_count(state))
    end

    test "false when effective retirable is zero (paused ledger) and occupancy does not reclaim" do
      state = restore_terminals(4096, 0)
      raw = record(revoke_intent(3, 1), "prepared")
      assert {:error, :capacity_exhausted} = Core.append(state, raw)
      refute Core.publication_relieves?(state, raw, 0)
      assert Core.publication_relieves?(state, raw, Core.retirable_count(state))

      all_rejected = restore_terminals(0, 4096)
      refute Core.publication_relieves?(all_rejected, raw, 4096)
    end

    test "entry-occupancy relief is independent of the retirement input" do
      {:ok, op} = Core.new(:operational)
      state = fold_all(op, lifecycle(intent(3, 1)))
      assert Core.compaction_reclaims_occupancy?(state)
      raw = record(intent(3, 2), "prepared")
      assert Core.publication_relieves?(state, raw, 0)
    end

    test "false for a refused v1/v2 prepared on the operational profile (the retry would meet floor 3)" do
      # Live shape before cutover: v2 snapshot (floor 1), 4096 delivered.
      {:ok, v2} = Core.restore(v2_snapshot(delivered_terminals(4096)), [])
      assert Core.admission_floor(v2) == 1

      for version <- [1, 2] do
        raw = record(revoke_intent(version, 1), "prepared")
        assert {:error, :capacity_exhausted} = Core.append(v2, raw)
        refute Core.publication_relieves?(v2, raw, 4096)
      end

      # The v3 producer shape is relieved by the same publication ...
      raw = record(revoke_intent(3, 1), "prepared")
      assert {:error, :capacity_exhausted} = Core.append(v2, raw)
      assert Core.publication_relieves?(v2, raw, 4096)

      # ... and the retry really is admitted after it.
      {:ok, published, _snapshot, []} =
        Core.compact(v2, @source, retire: true, ledger: AuditJournal.ledger_genesis_binding())

      assert {:ok, _} = Core.append(published, raw)

      assert {:error, :retired_version} =
               Core.append(published, record(revoke_intent(2, 1), "prepared"))

      # Small-profile publications keep floor 1, so no floor exception applies.
      {:ok, small} = Core.new()
      small = fold_all(small, lifecycle(intent(2, 9)))
      assert Core.publication_relieves?(small, record(intent(2, 10), "prepared"), 0)
    end

    test "false under a pending backlog refused by the entry clause" do
      # Sink outage shape: prepared increases pile up (nothing delivered), the
      # entry dimension (records + reservations) refuses the next increase and
      # a publication cannot reclaim anything.
      backlog = for n <- 1..1023, do: intent(3, n)
      state = restore_pending(backlog, delivered_terminals(0))
      raw = record(intent(3, 5000), "prepared")
      assert {:error, :soft_capacity_exhausted} = Core.append(state, raw)
      assert Core.retirable_count(state) == 0
      refute Core.compaction_reclaims_occupancy?(state)
      refute Core.publication_relieves?(state, raw, 0)
      refute Core.publication_relieves?(state, raw, 4096)

      # Same backlog plus a few ACKed operations: retiring them frees retained
      # slots but no entries, so the retry would still be refused.
      with_delivered = restore_pending(backlog, delivered_terminals(5))
      assert {:error, :soft_capacity_exhausted} = Core.append(with_delivered, raw)
      assert Core.retirable_count(with_delivered) == 5
      refute Core.publication_relieves?(with_delivered, raw, 5)

      {:ok, published, _snapshot, _pending} =
        Core.compact(
          with_delivered,
          @source,
          retire: true,
          ledger: AuditJournal.ledger_genesis_binding()
        )

      assert {:error, :soft_capacity_exhausted} = Core.append(published, raw)
    end

    test "continuation records are relieved only when the publication frees entries, never by retirement alone" do
      # v1 operations reserve nothing, so their continuations can meet the hard
      # entry cap; retiring the one delivered terminal frees a retained slot but
      # no entry, so the single retry would be refused again.
      backlog = for n <- 1..4095, do: intent(1, n)
      state = restore_pending(backlog, delivered_terminals(1))
      raw = record(hd(backlog), "effect_applied")
      assert {:error, :capacity_exhausted} = Core.append(state, raw)
      assert Core.retirable_count(state) == 1
      refute Core.compaction_reclaims_occupancy?(state)
      refute Core.publication_relieves?(state, raw, 1)
    end

    test "small profile never relieves by retirement and malformed inputs are false" do
      {:ok, small} = Core.new()
      raw = record(intent(3, 1), "prepared")
      refute Core.publication_relieves?(small, raw, 5)
      refute Core.publication_relieves?(restore_terminals(3072, 0), %{"nope" => 1}, 5)
      refute Core.publication_relieves?(restore_terminals(3072, 0), raw, -1)
      refute Core.publication_relieves?(%{}, raw, 1)
    end
  end

  describe "capacity and pending status fields" do
    test "fresh operational capacity advertises retirement headroom" do
      {:ok, fresh} = Core.new(:operational)
      cap = Core.capacity(fresh)
      assert cap["retirable_operation_count"] == 0
      assert cap["retired_operation_total"] == 0
      assert cap["retire_batch"] == 512
      assert cap["remaining_increase_admissions"] == 3072

      {:ok, small} = Core.new()
      small_cap = Core.capacity(small)
      assert small_cap["retire_batch"] == 0
      assert small_cap["remaining_increase_admissions"] == 32
    end

    test "remaining_increase_admissions claims retirement headroom only on explicit input" do
      state = restore_terminals(3000, 50)

      # Default (capacity/1, what the slice-1 owner status reports): no
      # retiring publication is known to be reachable, so no headroom is
      # claimed for the 3000 retirable terminals.
      cap = Core.capacity(state)
      assert cap["retained_operation_count"] == 3050
      assert cap["remaining_retained_increase_operations"] == 22
      assert cap["retirable_operation_count"] == 3000
      assert cap["remaining_increase_admissions"] == 22
      assert Core.capacity(state, []) == cap

      live = Core.capacity(state, paused: false)
      assert live["retirable_operation_count"] == 3000
      assert live["remaining_increase_admissions"] == 3072 - 50

      paused = Core.capacity(state, paused: true)
      assert paused["retirable_operation_count"] == 3000
      assert paused["remaining_increase_admissions"] == 22

      assert Core.capacity(state, effective_retirable: 10)["remaining_increase_admissions"] == 32

      assert Core.capacity(state, effective_retirable: 10_000)["remaining_increase_admissions"] ==
               3072 - 50

      assert Core.capacity(state, effective_retirable: -5)["remaining_increase_admissions"] == 22

      # A paused ledger wins over any claimed count.
      assert Core.capacity(state, paused: true, effective_retirable: 3000)[
               "remaining_increase_admissions"
             ] == 22

      # The exhausted live shape reports zero increase headroom by default.
      exhausted = restore_terminals(4096, 0)
      assert Core.capacity(exhausted)["remaining_increase_admissions"] == 0
      assert Core.capacity(exhausted, paused: false)["remaining_increase_admissions"] == 3072
    end

    test "after a retiring compaction the totals and headroom reflect the retirement" do
      state = restore_terminals(40, 2)

      {:ok, retired, _snapshot, []} =
        Core.compact(state, @source, retire: true, ledger: AuditJournal.ledger_genesis_binding())

      cap = Core.capacity(retired)
      assert cap["retired_operation_total"] == 40
      assert cap["retirable_operation_count"] == 0
      assert cap["retained_operation_count"] == 2
      assert cap["remaining_increase_admissions"] == 3070
      assert cap["remaining_soft_entries"] == 3071
    end

    test "pending_summary reports prepared-only count and age from the injected clock" do
      {:ok, op} = Core.new(:operational)
      prepared = intent(3, 1)
      applied = intent(3, 2) |> Map.put("prepared_at", "2026-09-28T11:00:00Z")
      {:ok, applied} = AuditJournal.admit_intent(Map.delete(applied, "operation_id"))

      state =
        fold_all(op, [
          record(prepared, "prepared"),
          record(applied, "prepared"),
          record(applied, "effect_applied")
        ])

      assert {:ok, summary} = Core.pending_summary(state, "2026-09-28T12:00:30Z")
      assert summary["pending_count"] == 2
      assert summary["oldest_pending_age_seconds"] == 3630
      assert summary["prepared_count"] == 1
      assert summary["oldest_prepared_age_seconds"] == 30

      {:ok, empty} = Core.new(:operational)
      assert {:ok, zero} = Core.pending_summary(empty, @time)
      assert zero["prepared_count"] == 0
      assert zero["oldest_prepared_age_seconds"] == 0
    end
  end

  describe "compact/3 options" do
    test "rejects unknown or malformed options" do
      state = restore_terminals(3, 0)
      assert {:error, :malformed} = Core.compact(state, @source, bogus: true)
      assert {:error, :malformed} = Core.compact(state, @source, retire: "yes")
      assert {:error, :malformed} = Core.compact(state, @source, ledger: [])
      assert {:error, :malformed} = Core.compact(state, @source, %{retire: true})
      assert {:error, :malformed} = Core.compact(state, @source, [{"retire", true}])
    end

    test "the ledger binding advances by exactly one frame and only when something retires" do
      state = restore_terminals(3, 1)
      genesis = AuditJournal.ledger_genesis_binding()
      next = binding(1, 0, 700)

      # Retiring requires an explicit binding: no silent ledgerless default.
      assert {:error, :malformed} = Core.compact(state, @source, retire: true)

      assert {:ok, bound, snapshot, []} =
               Core.compact(state, @source, retire: true, ledger: next)

      assert snapshot["retirement"] == %{"retired_total" => 3, "ledger" => next}
      assert {:ok, ^bound} = Core.restore(snapshot, [])

      # In-memory retirement from genesis keeps genesis, but only explicitly.
      assert {:ok, _, genesis_snapshot, []} =
               Core.compact(state, @source, retire: true, ledger: genesis)

      assert genesis_snapshot["retirement"]["ledger"] == genesis

      # Non-retiring or nothing-to-retire compactions must carry the binding.
      assert {:error, :malformed} = Core.compact(state, @source, ledger: next)
      assert {:error, :malformed} = Core.compact(state, @source, retire: false, ledger: next)
      assert Core.retirable_count(bound) == 0

      assert {:error, :malformed} =
               Core.compact(bound, @source, retire: true, ledger: binding(2, 772, 5))

      assert {:ok, _, carried, []} = Core.compact(bound, @source)
      assert carried["retirement"]["ledger"] == next
      assert {:ok, _, ^carried, []} = Core.compact(bound, @source, retire: true)
      assert {:ok, _, ^carried, []} = Core.compact(bound, @source, retire: true, ledger: next)

      # Skipping a frame, a rewound offset or an inadmissible binding is refused.
      assert {:error, :malformed} =
               Core.compact(state, @source, retire: true, ledger: binding(2, 50, 5))

      assert {:error, :malformed} =
               Core.compact(state, @source, retire: true, ledger: binding(1, 5, 700))

      assert {:error, :malformed} =
               Core.compact(
                 state,
                 @source,
                 retire: true,
                 ledger: Map.put(next, "tip_digest", genesis["tip_digest"])
               )

      # Small profile ignores retirement and never embeds a binding.
      {:ok, small} = Core.new()
      small = fold_all(small, lifecycle(intent(3, 7)))
      assert {:ok, _, small_snapshot, []} = Core.compact(small, @source, retire: true)
      assert small_snapshot["version"] == 1
      refute Map.has_key?(small_snapshot, "retirement")
      assert {:error, :malformed} = Core.compact(small, @source, retire: true, ledger: next)
    end

    test "a journal bound to a real ledger can never retire without advancing it contiguously" do
      genesis = AuditJournal.ledger_genesis_binding()
      first = binding(1, 0, 700)

      {:ok, bound, _snapshot, []} =
        Core.compact(restore_terminals(2, 0), @source, retire: true, ledger: first)

      more = fold_all(bound, lifecycle(intent(3, 1)))
      assert Core.retirable_count(more) == 1
      {:ok, bound_size} = AuditJournal.ledger_bound_size(first)
      assert bound_size == 0 + FileCore.header_size() + 700

      # Omitted, unchanged, reset-to-genesis, rewound, gapped or same-digest
      # bindings would drop the new terminal from the hot set with no ledger
      # frame recording it.
      fresh = fn frames, offset, len ->
        Map.put(binding(frames, offset, len), "tip_digest", String.duplicate("7e", 32))
      end

      for ledger <- [
            nil,
            first,
            genesis,
            fresh.(2, 5, 1),
            fresh.(2, bound_size + 1, 10),
            fresh.(2, bound_size - 1, 10),
            fresh.(3, bound_size, 10),
            binding(2, bound_size, 10)
          ] do
        opts = if ledger, do: [retire: true, ledger: ledger], else: [retire: true]

        assert {:error, :malformed} = Core.compact(more, @source, opts),
               "expected #{inspect(ledger)} to be refused"
      end

      second = fresh.(2, bound_size, 410)

      assert {:ok, advanced, snapshot, []} =
               Core.compact(more, @source, retire: true, ledger: second)

      assert snapshot["retirement"] == %{"retired_total" => 3, "ledger" => second}
      assert {:ok, ^advanced} = Core.restore(snapshot, [])
      assert AuditJournal.ledger_bound_size(second) == {:ok, 772 + 72 + 410}

      # Non-retiring publications of a bound journal carry it unchanged.
      assert {:ok, _, kept, []} = Core.compact(more, @source)
      assert kept["retirement"] == %{"retired_total" => 2, "ledger" => first}
    end

    test "compact refuses more than 4096 retained operations unless retirement relieves them" do
      # 97 pending + 3999 delivered + one injected rejected terminal: each
      # manifest is admissible on its own, only the retained total exceeds the
      # operational bound (a shape no append can reach; it pins the
      # profile-derived retained bound on the compaction path).
      full = restore_pending(for(n <- 1..97, do: intent(1, n)), delivered_terminals(3999))
      assert map_size(full["operations"]) == 4096
      rejected = restore_terminals(0, 1)
      over = Map.update!(full, "operations", &Map.merge(&1, rejected["operations"]))
      assert map_size(over["operations"]) == 4097

      assert {:error, :capacity_exhausted} = Core.compact(over, @source)
      assert {:error, :capacity_exhausted} = Core.compact(over, @source, retire: false)

      assert {:ok, relieved, snapshot, pending} =
               Core.compact(over, @source,
                 retire: true,
                 ledger: AuditJournal.ledger_genesis_binding()
               )

      assert snapshot["retirement"]["retired_total"] == 3999
      assert map_size(relieved["operations"]) == 98
      assert length(pending) == 97
    end

    test "restore still refuses more than 4096 retained operations (profile-derived bound)" do
      terminals = delivered_terminals(4096)
      pending = intent(3, 1)
      prepared = record(pending, "prepared")
      {:ok, bytes} = AuditJournal.canonical_record_bytes(prepared)
      {:ok, sha} = AuditJournal.record_fingerprint(bytes)
      manifest = %{pending["operation_id"] => "prepared:" <> sha}

      v2 = v2_snapshot(terminals) |> Map.put("pending_manifest", manifest)
      assert {:error, :capacity_exhausted} = Core.restore(v2, [prepared])

      v3 =
        v2
        |> Map.merge(%{
          "version" => 3,
          "kind" => AuditJournal.snapshot_kind(3),
          "retirement" => %{
            "retired_total" => 0,
            "ledger" => AuditJournal.ledger_genesis_binding()
          }
        })

      assert {:error, :capacity_exhausted} = Core.restore(v3, [prepared])

      assert {:ok, _} =
               Core.restore(Map.put(v3, "terminals", delivered_terminals(4095)), [prepared])
    end
  end

  describe "file replay" do
    test "a v3 operational snapshot frame replays as a snapshot with its pending prefix" do
      {:ok, op} = Core.new(:operational)
      pending = intent(3, 2)

      state =
        op
        |> fold_all(lifecycle(intent(3, 1)))
        |> fold_all([record(pending, "prepared")])

      {:ok, compacted, snapshot, pending_records} =
        Core.compact(state, @source, retire: true, ledger: AuditJournal.ledger_genesis_binding())

      assert {:ok, bytes, replay} = FileCore.encode_compacted(snapshot, pending_records)
      assert FileCore.core_match?(replay.core, compacted)
      assert replay.frames == 2
      assert Core.admission_floor(replay.core) == 3

      assert {:error, :retired_version} =
               Core.append(replay.core, record(intent(2, 3), "prepared"))

      {:ok, empty} = FileCore.new()
      assert {:ok, again} = FileCore.consume(empty, bytes)
      assert FileCore.core_match?(again.core, compacted)
    end
  end

  describe "mixed snapshots at replay" do
    test "a v1/v2 prepared frame after a v3 snapshot fails the open closed with :retired_version" do
      {:ok, v3_snapshot_frame, v3_replay} = FileCore.encode_compacted(restore_snapshot(%{}), [])
      assert Core.admission_floor(v3_replay.core) == 3

      for version <- [1, 2] do
        tail = frame(record(intent(version, 1), "prepared"), v3_replay.digest)
        {:ok, empty} = FileCore.new()

        assert {:error, :retired_version} =
                 FileCore.consume(empty, v3_snapshot_frame <> tail)
      end

      # A v3 tail frame folds at floor 3.
      tail = frame(record(intent(3, 1), "prepared"), v3_replay.digest)
      {:ok, empty} = FileCore.new()
      assert {:ok, replay} = FileCore.consume(empty, v3_snapshot_frame <> tail)
      assert replay.frames == 2
      assert Core.capacity(replay.core)["retained_operation_count"] == 1

      # A pre-cutover v2 snapshot still folds legacy tails at floor 1.
      {:ok, v2_frame, v2_replay} = FileCore.encode_compacted(v2_snapshot(%{}), [])
      tail = frame(record(intent(2, 1), "prepared"), v2_replay.digest)
      {:ok, empty} = FileCore.new()
      assert {:ok, legacy} = FileCore.consume(empty, v2_frame <> tail)
      assert Core.admission_floor(legacy.core) == 1
      assert Core.capacity(legacy.core)["retained_operation_count"] == 1
    end

    test "a v1 operation pending across the v3 cutover completes by id and replays idempotently" do
      {:ok, op} = Core.new(:operational)
      v1 = intent(1, 1)
      v2 = intent(2, 2)
      state = fold_all(op, [record(v1, "prepared"), record(v2, "prepared")])

      {:ok, compacted, snapshot, pending} = Core.compact(state, @source)
      assert snapshot["version"] == 3
      assert {:ok, restored} = Core.restore(snapshot, pending)
      assert Core.admission_floor(restored) == 3
      assert Core.legacy_pending?(restored)

      # Exact re-append of the retained prepared bytes is idempotent, not a
      # floor refusal; a new v1/v2 identity is refused.
      assert {:ok, ^restored, :idempotent} = Core.append(restored, record(v1, "prepared"))
      assert {:ok, ^compacted, :idempotent} = Core.append(compacted, record(v2, "prepared"))
      assert {:error, :retired_version} = Core.append(restored, record(intent(1, 3), "prepared"))

      done =
        fold_all(restored, [
          record(v1, "effect_applied"),
          record(v1, "delivered"),
          record(v2, "effect_applied"),
          record(v2, "delivered")
        ])

      refute Core.legacy_pending?(done)
      assert Core.retirable_count(done) == 2
      assert {:ok, ^done, :idempotent} = Core.append(done, record(v1, "prepared"))
    end
  end

  describe "v3 identity at the record boundary" do
    test "a v3 intent can never claim its v2 twin's identity" do
      v3 = intent(3, 1)
      v2 = intent(2, 1)
      {:ok, alias_id} = AuditJournal.legacy_alias_operation_id(v3)
      assert alias_id == v2["operation_id"]

      # Supplied operation_id mismatch at the intent contract.
      assert {:error, :operation_id_mismatch} =
               AuditJournal.admit_intent(Map.put(facts(3, 1), "operation_id", alias_id))

      {:ok, state} = Core.new(:operational)
      {:ok, state} = Core.append(state, record(v2, "prepared"))

      # A record under the v2 identity wrapping the v3 intent (with or without
      # the intent also claiming it) is cross-operation, never a continuation
      # or duplicate of the pending v2 operation.
      wrapped = Map.put(record(v3, "prepared"), "operation_id", alias_id)
      assert {:error, :cross_operation} = Core.append(state, wrapped)

      forged = put_in(wrapped, ["intent", "operation_id"], alias_id)
      assert {:error, :cross_operation} = Core.append(state, forged)

      # A v3 record whose intent claims a different v3 identity.
      other = intent(3, 2)

      forged_v3 =
        put_in(record(v3, "prepared"), ["intent", "operation_id"], other["operation_id"])

      assert {:error, :cross_operation} = Core.append(state, forged_v3)

      # Version/kind mismatch inside the wrapped intent is malformed.
      mixed = put_in(record(v3, "prepared"), ["intent", "kind"], AuditJournal.intent_kind(2))
      assert {:error, :malformed} = Core.append(state, mixed)

      # The genuine v3 record is a new operation next to the v2 one.
      assert {:ok, both} = Core.append(state, record(v3, "prepared"))
      assert Core.capacity(both)["retained_operation_count"] == 2
    end
  end

  describe "reservation accounting" do
    @reservation_keys ["reserved_entries", "reserved_bytes"]

    test "the maintained reservation equals a from-scratch derivation through every transition, compaction and restore" do
      {:ok, fresh} = Core.new(:operational)

      steps =
        Enum.flat_map(1..24, fn n ->
          version = Enum.at([1, 2, 3], rem(n, 3))
          grant = intent(version, n)
          revoke = revoke_intent(max(version, 2), 100 + n)

          case rem(n, 4) do
            0 -> lifecycle(grant)
            1 -> [record(grant, "prepared")]
            2 -> [record(grant, "prepared"), record(grant, "effect_applied")]
            3 -> [record(revoke, "prepared"), rejected_record(revoke)]
          end
        end)

      state =
        Enum.reduce(steps, fresh, fn step, acc ->
          next = fold_all(acc, [step])
          assert reservation(next) == derived_reservation(next)
          next
        end)

      assert reservation(state) != {0, 0}

      for opts <- [[retire: false], [retire: true, ledger: binding(1, 0, 900)]] do
        assert {:ok, compacted, snapshot, pending} = Core.compact(state, @source, opts)
        assert reservation(compacted) == derived_reservation(compacted)
        assert reservation(compacted) == reservation(state)
        assert {:ok, restored} = Core.restore(snapshot, pending)
        assert FileCore.core_match?(restored, compacted)
      end
    end

    # The admission check used to re-derive every pending operation's
    # remaining cost (canonical record encodes) on every append, so a fold or
    # a publication re-fold under a delivery backlog was quadratic in the
    # pending count (a ~10 s first publication after a sink outage).
    test "an admission costs the same number of canonical encodes whatever the pending count" do
      small = encodes_for_next_append(8)
      large = encodes_for_next_append(400)
      assert small > 0
      assert large == small
    end
  end

  describe "readiness projection" do
    test "increase_headroom? flips exactly when the next increase is refused by the entry clause" do
      {:ok, fresh} = Core.new()
      # A rejected operation first: each prepared-only increase lowers
      # `remaining_soft_entries - reserved_entries` by 3, and the rejection
      # shifts it by one, so the walk passes through exactly 3 (the last
      # admissible value) instead of skipping from 5 to 2.
      rejected = revoke_intent(3, 999)
      start = fold_all(fresh, [record(rejected, "prepared"), rejected_record(rejected)])
      capacity = Core.capacity(start, paused: true)
      assert rem(capacity["remaining_soft_entries"] - capacity["reserved_entries"], 3) == 0

      outcome =
        Enum.reduce_while(1..40, start, fn n, acc ->
          ready? = Core.increase_headroom?(acc, paused: true)

          case Core.append(acc, record(intent(3, n), "prepared")) do
            {:ok, next} ->
              assert ready?, "headroom false but increase #{n} admitted"
              {:cont, next}

            {:error, :soft_capacity_exhausted} ->
              refute ready?, "headroom true but increase #{n} refused"
              {:halt, {:refused_at, n, acc}}
          end
        end)

      assert {:refused_at, n, refused} = outcome
      assert n > 1
      capacity = Core.capacity(refused, paused: true)
      assert capacity["remaining_soft_entries"] - capacity["reserved_entries"] == 0
    end

    test "increase_headroom? keeps room for a maximum-size record in the soft byte dimension" do
      {:ok, fresh} = Core.new()
      max_record = AuditJournal.limits().max_record_bytes
      soft_bytes = AuditJournal.limits().soft_byte_cap

      # Entries are plentiful; only the byte dimension is close to its cap.
      roomy = Map.put(fresh, "byte_count", soft_bytes - max_record)
      tight = Map.put(fresh, "byte_count", soft_bytes - max_record + 1)
      assert Core.increase_headroom?(roomy, paused: true)
      refute Core.increase_headroom?(tight, paused: true)

      # Conservative by design: a normal-size increase still fits.
      assert {:ok, _} = Core.append(tight, record(intent(3, 1), "prepared"))
    end

    test "increase_headroom? is false without retained headroom and for a malformed state" do
      state = restore_terminals(0, 3072)
      refute Core.increase_headroom?(state, paused: true)
      assert Core.capacity(state, paused: true)["remaining_increase_admissions"] == 0
      refute Core.increase_headroom?(nil)
      refute Core.increase_headroom?(%{"operations" => :bad})
    end
  end

  describe "producer" do
    test "CapabilityAuditCore emits v3 intents that a floor-3 journal admits" do
      cap_id = "cap_" <> String.duplicate("c", 32)

      data = %{
        "id" => cap_id,
        "principal_id" => "agent_producer",
        "resource_uri" => "arbor://fs/read/producer"
      }

      proposed = %Arbor.Contracts.Persistence.Record{id: "proposed", key: cap_id, data: data}
      after_entry = Arbor.Security.CapabilityAuditCore.replacement(proposed, :absent)

      assert {:ok, intent} =
               Arbor.Security.CapabilityAuditCore.intent(
                 :grant,
                 :absent,
                 after_entry,
                 data,
                 @time
               )

      assert intent["version"] == 3
      assert intent["kind"] == AuditJournal.intent_kind(3)

      {:ok, floor3} = Core.restore(restore_snapshot(%{}), [])
      assert Core.admission_floor(floor3) == 3
      assert {:ok, admitted} = Core.append(floor3, record(intent, "prepared"))
      assert Core.capacity(admitted)["retained_operation_count"] == 1

      # The v2 identity the pre-cutover producer derived for the same facts.
      v2_facts =
        intent
        |> Map.drop(["operation_id"])
        |> Map.merge(%{"version" => 2, "kind" => AuditJournal.intent_kind(2)})

      {:ok, v2} = AuditJournal.admit_intent(v2_facts)
      assert {:ok, v2["operation_id"]} == AuditJournal.legacy_alias_operation_id(intent)
      assert {:error, :retired_version} = Core.append(floor3, record(v2, "prepared"))
    end
  end

  # ---------------------------------------------------------------------------

  defp reservation(state) do
    capacity = Core.capacity(state)
    {capacity["reserved_entries"], capacity["reserved_bytes"]}
  end

  # The same projection over a state stripped of its maintained totals: the
  # core then derives the reservation from the operations themselves.
  defp derived_reservation(state), do: reservation(Map.drop(state, @reservation_keys))

  defp encodes_for_next_append(pending) do
    {:ok, fresh} = Core.new(:operational)

    state =
      fold_all(
        fresh,
        Enum.flat_map(1..pending, fn n ->
          grant = intent(3, n)
          [record(grant, "prepared"), record(grant, "effect_applied")]
        end)
      )

    next = record(intent(3, 10_000), "prepared")
    mfa = {AuditJournal, :canonical_record_bytes, 1}
    test_pid = self()

    pid =
      spawn(fn ->
        receive do
          :go -> send(test_pid, {:appended, self(), Core.append(state, next)})
        end
      end)

    :erlang.trace_pattern(mfa, true, [:global])
    :erlang.trace(pid, true, [:call, {:tracer, self()}])
    send(pid, :go)
    assert_receive {:appended, ^pid, {:ok, _}}, 30_000
    :erlang.trace_pattern(mfa, false, [:global])
    count_calls(pid, mfa, 0)
  end

  defp count_calls(pid, {m, f, a} = mfa, count) do
    receive do
      {:trace, ^pid, :call, {^m, ^f, args}} when length(args) == a ->
        count_calls(pid, mfa, count + 1)
    after
      100 -> count
    end
  end

  defp restore_snapshot(terminals) do
    %{
      "version" => 3,
      "kind" => AuditJournal.snapshot_kind(3),
      "source" => @source,
      "pending_manifest" => %{},
      "terminals" => terminals,
      "capacity_profile" => "operational",
      "retirement" => %{"retired_total" => 0, "ledger" => AuditJournal.ledger_genesis_binding()}
    }
  end

  defp restore_terminals(delivered, rejected) do
    terminals =
      Map.merge(delivered_terminals(delivered), rejected_terminals(rejected))

    {:ok, state} = Core.restore(restore_snapshot(terminals), [])
    state
  end

  defp restore_pending(intents, terminals) do
    records =
      intents
      |> Enum.map(&record(&1, "prepared"))
      |> Enum.sort_by(& &1["operation_id"])

    manifest =
      Map.new(records, fn record ->
        {:ok, bytes} = AuditJournal.canonical_record_bytes(record)
        {:ok, sha} = AuditJournal.record_fingerprint(bytes)
        {record["operation_id"], "prepared:" <> sha}
      end)

    snapshot = terminals |> restore_snapshot() |> Map.put("pending_manifest", manifest)
    {:ok, state} = Core.restore(snapshot, records)
    state
  end

  defp v2_snapshot(terminals) do
    %{
      "version" => 2,
      "kind" => AuditJournal.operational_snapshot_kind(),
      "source" => @source,
      "pending_manifest" => %{},
      "terminals" => terminals,
      "capacity_profile" => "operational"
    }
  end

  defp delivered_terminals(0), do: %{}

  defp delivered_terminals(count) do
    Map.new(1..count, fn n ->
      {sha({:d_op, n}),
       "delivered|authority_reduce|#{sha({:i, n})}|prepared:#{sha({:p, n})}|" <>
         "effect_applied:#{sha({:a, n})}|delivered:#{sha({:d, n})}"}
    end)
  end

  defp rejected_terminals(0), do: %{}

  defp rejected_terminals(count) do
    Map.new(1..count, fn n ->
      {sha({:r_op, n}),
       "effect_rejected|authority_increase|#{sha({:ri, n})}|prepared:#{sha({:rp, n})}|" <>
         "effect_rejected:#{sha({:rr, n})}"}
    end)
  end

  defp binding(frames, offset, len) do
    %{
      "frames" => frames,
      "tip_offset" => offset,
      "tip_len" => len,
      "tip_digest" => String.duplicate("9f", 32)
    }
  end

  defp sha(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  defp frame(record, predecessor) do
    {:ok, payload} = AuditJournal.canonical_record_bytes(record)
    {:ok, bytes, _digest} = FileCore.encode_frame(payload, predecessor)
    bytes
  end

  defp fold_all(state, records) do
    Enum.reduce(records, state, fn record, acc ->
      case Core.append(acc, record) do
        {:ok, next} -> next
        other -> flunk("append failed: #{inspect(other)} for #{inspect(record["record_type"])}")
      end
    end)
  end

  defp lifecycle(intent) do
    [record(intent, "prepared"), record(intent, "effect_applied"), record(intent, "delivered")]
  end

  defp intent(version, n) do
    {:ok, intent} = AuditJournal.admit_intent(facts(version, n))
    intent
  end

  defp revoke_intent(version, n) do
    grant = facts(version, n)

    {:ok, intent} =
      grant
      |> Map.put("operation", "capability_revoke")
      |> Map.put("effect_class", "authority_reduce")
      |> Map.put("before_fence", grant["after_fingerprint"])
      |> Map.put("after_fingerprint", %{"kind" => "tombstone", "generation" => 1})
      |> put_in(["audit", "event_type"], "capability_revoked")
      |> AuditJournal.admit_intent()

    intent
  end

  defp facts(version, n) do
    id = "cap_" <> String.pad_leading(String.downcase(Integer.to_string(n, 16)), 32, "0")

    %{
      "version" => version,
      "kind" => AuditJournal.intent_kind(version),
      "operation" => "capability_grant",
      "effect_class" => "authority_increase",
      "authority_namespace" => "capability",
      "authority_key" => id,
      "before_fence" => %{"kind" => "absent"},
      "after_fingerprint" => %{
        "kind" => "live",
        "record_id" => "record-#{n}",
        "generation" => 1,
        "revision" => 1,
        "capability_digest" => String.duplicate("ab", 32)
      },
      "audit" => %{
        "event_type" => "capability_granted",
        "data" => %{
          "capability_id" => id,
          "principal_id" => "agent_fixture",
          "resource_uri" => "arbor://memory/read"
        }
      },
      "prepared_at" => @time
    }
  end

  defp record(intent, type) do
    base = %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => type,
      "operation_id" => intent["operation_id"],
      "occurred_at" => @time
    }

    case type do
      "prepared" ->
        Map.merge(base, %{"intent" => intent, "occurred_at" => intent["prepared_at"]})

      "effect_applied" ->
        Map.put(base, "observation", %{
          "kind" => "applied",
          "after_fingerprint" => intent["after_fingerprint"]
        })

      "delivered" ->
        base
    end
  end

  defp rejected_record(intent) do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "effect_rejected",
      "operation_id" => intent["operation_id"],
      "occurred_at" => @time,
      "observation" => %{"kind" => "rejected", "reason" => "before_mismatch"}
    }
  end
end
