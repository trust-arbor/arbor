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

    test "remaining_increase_admissions counts retirable terminals unless paused" do
      state = restore_terminals(3000, 50)
      cap = Core.capacity(state)
      assert cap["retained_operation_count"] == 3050
      assert cap["remaining_retained_increase_operations"] == 22
      assert cap["retirable_operation_count"] == 3000
      assert cap["remaining_increase_admissions"] == 3072 - 50

      paused = Core.capacity(state, paused: true)
      assert paused["retirable_operation_count"] == 3000
      assert paused["remaining_increase_admissions"] == 22

      assert Core.capacity(state, effective_retirable: 10)["remaining_increase_admissions"] == 32

      assert Core.capacity(state, effective_retirable: 10_000)["remaining_increase_admissions"] ==
               3072 - 50

      assert Core.capacity(state, []) == Core.capacity(state)
    end

    test "after a retiring compaction the totals and headroom reflect the retirement" do
      state = restore_terminals(40, 2)
      {:ok, retired, _snapshot, []} = Core.compact(state, @source, retire: true)
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

      assert {:ok, bound, snapshot, []} =
               Core.compact(state, @source, retire: true, ledger: next)

      assert snapshot["retirement"] == %{"retired_total" => 3, "ledger" => next}
      assert {:ok, ^bound} = Core.restore(snapshot, [])

      # In-memory retirement keeps genesis.
      assert {:ok, _, genesis_snapshot, []} =
               Core.compact(state, @source, retire: true, ledger: genesis)

      assert genesis_snapshot["retirement"]["ledger"] == genesis

      # Non-retiring or nothing-to-retire compactions must carry the binding.
      assert {:error, :malformed} = Core.compact(state, @source, ledger: next)
      assert {:error, :malformed} = Core.compact(state, @source, retire: false, ledger: next)

      assert {:error, :malformed} =
               Core.compact(bound, @source, retire: true, ledger: binding(2, 772, 5))

      assert {:ok, _, carried, []} = Core.compact(bound, @source)
      assert carried["retirement"]["ledger"] == next

      # Skipping a frame or an inadmissible binding is refused.
      assert {:error, :malformed} =
               Core.compact(state, @source, retire: true, ledger: binding(2, 50, 5))

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

      {:ok, compacted, snapshot, pending_records} = Core.compact(state, @source, retire: true)
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
