defmodule Arbor.Security.AuditRetirementSecurityRegressionTest do
  @moduledoc """
  Security regressions for audit-journal terminal-identity retirement
  (Floor-and-Ledger v3, slice 1: contracts, reducer and producer).

  A retired identity must never be re-admitted as new (R5/R11): once an
  operational journal installs a v3 snapshot its admission floor is 3, and any
  unknown v1/v2 `prepared` is refused `:retired_version` before capacity is
  consulted, with nothing written.
  """
  use ExUnit.Case, async: false

  alias Arbor.Common.SafePath
  alias Arbor.Security.AuditJournalCore, as: Core
  alias Arbor.Security.AuditJournalOwner, as: Owner
  alias Arbor.Security.Contracts.AuditJournal

  @moduletag :fast
  @time "2026-09-28T12:00:00Z"
  @source %{
    "committed_digest" => String.duplicate("ab", 32),
    "committed_frames" => 40,
    "committed_offset" => 100_000
  }

  test "security regression: an operational core restored from its own compaction refuses unknown v1/v2 prepared records with :retired_version" do
    {:ok, empty} = Core.new(:operational)
    delivered = for n <- 1..5, do: intent(2, n)
    [pending] = [intent(2, 6)]

    state =
      empty
      |> fold_all(Enum.flat_map(delivered, &lifecycle/1))
      |> fold_all([record(pending, "prepared")])

    assert {:ok, compacted, snapshot, pending_records} = Core.compact(state, @source)
    assert {:ok, ^compacted} = Core.restore(snapshot, pending_records)

    # Parent 52a2cc3fa: the snapshot is v2, no floor exists, and this unknown v2
    # identity is admitted as a brand-new operation.
    assert {:error, :retired_version} = Core.append(compacted, record(intent(2, 7), "prepared"))
    assert {:error, :retired_version} = Core.append(compacted, record(intent(1, 8), "prepared"))
    assert Core.admission_floor(compacted) == 3

    # Continuations of known operations are never floored: the v2 op pending
    # across the cutover completes by id, and hot terminals keep exact
    # duplicate/conflict semantics.
    {:ok, applied} = Core.append(compacted, record(pending, "effect_applied"))
    {:ok, done} = Core.append(applied, record(pending, "delivered"))
    assert {:ok, ^done, :idempotent} = Core.append(done, record(hd(delivered), "prepared"))

    assert {:error, :operation_conflict} =
             Core.append(
               done,
               record(hd(delivered), "prepared")
               |> put_in(["intent", "prepared_at"], later())
               |> Map.put("occurred_at", later())
             )

    # New mutations use v3 and are admitted.
    assert {:ok, admitted} = Core.append(done, record(intent(3, 9), "prepared"))
    assert Core.show(admitted)["entry_count"] == Core.show(done)["entry_count"] + 1
  end

  test "security regression: the admission floor is evaluated before capacity so a retired-version identity is never a capacity refusal" do
    # The live exhausted shape: one v2 operational snapshot holding 4096
    # delivered terminals and nothing pending (admissible on the parent too).
    {:ok, restored} = Core.restore(v2_snapshot(delivered_terminals(4096)), [])
    assert Core.capacity(restored)["retained_operation_count"] == 4096

    assert {:ok, compacted, snapshot, []} = Core.compact(restored, @source)
    assert {:ok, ^compacted} = Core.restore(snapshot, [])
    capacity = Core.capacity(compacted)

    # Parent 52a2cc3fa: {:error, :capacity_exhausted} (v2 snapshot, no floor).
    assert {:error, :retired_version} =
             Core.append(compacted, record(revoke_intent(2, 1), "prepared"))

    assert snapshot["version"] == 3
    assert {:error, :retired_version} = Core.append(compacted, record(intent(2, 2), "prepared"))
    assert Core.capacity(compacted) == capacity

    # Admissible versions still meet the unchanged capacity clauses.
    assert {:error, :capacity_exhausted} =
             Core.append(compacted, record(revoke_intent(3, 1), "prepared"))

    assert {:error, :capacity_exhausted} =
             Core.append(compacted, record(intent(3, 2), "prepared"))
  end

  test "security regression: operational compaction with retire: true retires delivered terminals and keeps rejected and pending" do
    {:ok, empty} = Core.new(:operational)
    delivered = for n <- 1..4, do: intent(2, n)
    rejected = revoke_intent(2, 5)
    pending_prepared = intent(2, 6)
    pending_applied = intent(2, 7)

    state =
      empty
      |> fold_all(Enum.flat_map(delivered, &lifecycle/1))
      |> fold_all([record(rejected, "prepared"), rejected_record(rejected)])
      |> fold_all([record(pending_prepared, "prepared")])
      |> fold_all([
        record(pending_applied, "prepared"),
        record(pending_applied, "effect_applied")
      ])

    # Non-retiring (default) compaction keeps every terminal hot and emits the
    # v3 snapshot with zero retired. Parent 52a2cc3fa: kind v2, no retirement.
    assert {:ok, kept, kept_snapshot, _} = Core.compact(state, @source)
    assert kept_snapshot["kind"] == "arbor.security.audit_journal_snapshot.v3"
    assert kept_snapshot["retirement"]["retired_total"] == 0
    assert map_size(kept_snapshot["terminals"]) == 5
    assert map_size(kept["operations"]) == 7
    assert {:ok, ^kept, ^kept_snapshot, _} = Core.compact(state, @source, retire: false)

    assert {:ok, retired, snapshot, pending} = Core.compact(state, @source, retire: true)
    assert snapshot["kind"] == "arbor.security.audit_journal_snapshot.v3"
    assert snapshot["retirement"]["retired_total"] == 4
    assert snapshot["retirement"]["ledger"] == AuditJournal.ledger_genesis_binding()
    assert Map.keys(snapshot["terminals"]) == [rejected["operation_id"]]
    assert map_size(snapshot["pending_manifest"]) == 2
    assert map_size(retired["operations"]) == 3
    assert Core.capacity(retired)["retained_operation_count"] == 3
    assert Core.capacity(retired)["retired_operation_total"] == 4
    assert {:ok, ^retired} = Core.restore(snapshot, pending)

    for intent <- delivered do
      id = intent["operation_id"]
      refute Map.has_key?(retired["operations"], id)
      # A retired identity is refused, never admitted as new.
      assert {:error, :retired_version} = Core.append(retired, record(intent, "prepared"))
      assert {:error, :out_of_order} = Core.append(retired, record(intent, "effect_applied"))
      assert {:error, :out_of_order} = Core.append(retired, record(intent, "delivered"))
      refute Core.acknowledgement_matches?(retired, id, digest(intent))
    end

    # Rejected terminals stay hot with exact duplicate semantics.
    assert {:ok, ^retired, :idempotent} = Core.append(retired, record(rejected, "prepared"))

    # Pending operations continue by id across the retirement.
    {:ok, next} = Core.append(retired, record(pending_prepared, "effect_applied"))
    {:ok, next} = Core.append(next, record(pending_prepared, "delivered"))
    {:ok, next} = Core.append(next, record(pending_applied, "delivered"))
    assert Core.retirable_count(next) == 2

    # A later non-retiring compaction carries the total forward; a later
    # retiring one accumulates it.
    assert {:ok, carried, carried_snapshot, _} = Core.compact(next, @source)
    assert carried_snapshot["retirement"]["retired_total"] == 4
    assert map_size(carried_snapshot["terminals"]) == 3
    assert Core.retirable_count(carried) == 2

    assert {:ok, again, again_snapshot, []} = Core.compact(carried, @source, retire: true)
    assert again_snapshot["retirement"]["retired_total"] == 6
    assert Map.keys(again["operations"]) == [rejected["operation_id"]]
    assert {:ok, ^again} = Core.restore(again_snapshot, [])
  end

  test "security regression: v3 identity survives observation-time changes and differs from the v2 identity of identical facts" do
    assert {:ok, first} = AuditJournal.admit_intent(facts(3, 1))

    assert {:ok, retry} =
             AuditJournal.admit_intent(Map.put(facts(3, 1), "prepared_at", later()))

    assert first["operation_id"] == retry["operation_id"]
    assert {:ok, v2} = AuditJournal.admit_intent(facts(2, 1))
    refute first["operation_id"] == v2["operation_id"]
    assert {:ok, v2_id} = AuditJournal.legacy_alias_operation_id(first)
    assert v2_id == v2["operation_id"]

    assert {:ok, before} = Core.fold([record(first, "prepared")])

    assert {:error, :operation_conflict} =
             Core.append(before, record(retry, "prepared"))

    assert {:ok, other} =
             AuditJournal.admit_intent(
               put_in(
                 facts(3, 1),
                 ["after_fingerprint", "capability_digest"],
                 String.duplicate("cd", 32)
               )
             )

    refute other["operation_id"] == first["operation_id"]
  end

  test "security regression: admitted v3 grant lifecycles cannot consume the reduction reserve" do
    {:ok, empty} = Core.new()

    {state, admitted} =
      Enum.reduce_while(1..48, {empty, []}, fn n, {state, admitted} ->
        {:ok, intent} = AuditJournal.admit_intent(facts(3, n))

        case Core.append(state, record(intent, "prepared")) do
          {:ok, next} -> {:cont, {next, [intent | admitted]}}
          {:error, :soft_capacity_exhausted} -> {:halt, {state, admitted}}
        end
      end)

    assert admitted != []
    assert length(admitted) <= div(AuditJournal.limits().soft_entry_cap, 3)

    done =
      Enum.reduce(admitted, state, fn intent, state ->
        {:ok, state} = Core.append(state, record(intent, "effect_applied"))
        {:ok, state} = Core.append(state, record(intent, "delivered"))
        state
      end)

    assert Core.capacity(done)["remaining_hard_entries"] >= AuditJournal.limits().reserve_entries
    reduction = revoke_intent(3, 99)
    assert {:ok, _} = Core.append(done, record(reduction, "prepared"))
  end

  describe "durable operational owner" do
    setup do
      name = :"audit_retirement_owner_#{System.unique_integer([:positive])}"
      root = unique_root()

      on_exit(fn ->
        if pid = Process.whereis(name), do: GenServer.stop(pid)
      end)

      %{name: name, root: root}
    end

    test "security regression: a durable operational journal refuses an unknown v2 prepared with :retired_version and writes no frame",
         %{name: name, root: root} do
      Process.flag(:trap_exit, true)
      opts = [mode: :durable, root: root, name: name, capacity_profile: :operational]
      assert {:ok, pid} = Owner.start_link(opts)
      Process.unlink(pid)
      assert {:ok, before} = Owner.status(name)
      log = Path.join(root, "audit_journal.v1.log")
      size = File.stat!(log).size

      # Parent 52a2cc3fa: {:ok, :committed} — the operational snapshot is v2 and
      # an unknown v2 identity is admitted as new.
      assert {:error, :retired_version} = Owner.append(name, record(intent(2, 1), "prepared"))
      assert {:error, :retired_version} = Owner.append(name, record(intent(1, 2), "prepared"))
      assert {:ok, ^before} = Owner.status(name)
      assert File.stat!(log).size == size

      # The v3 producer shape is admitted.
      v3 = intent(3, 3)
      assert {:ok, :committed} = Owner.append(name, record(v3, "prepared"))
      assert {:ok, after_v3} = Owner.status(name)
      assert after_v3["committed_frames"] == before["committed_frames"] + 1
      assert after_v3["capacity"]["retained_operation_count"] == 1

      # The floor survives a cold restart (it is derived from the durable v3
      # snapshot, not from process state).
      GenServer.stop(pid)
      assert {:ok, again} = Owner.start_link(opts)
      Process.unlink(again)
      assert {:error, :retired_version} = Owner.append(name, record(intent(2, 4), "prepared"))
      assert {:ok, :idempotent} = Owner.append(name, record(v3, "prepared"))
      GenServer.stop(again)
    end
  end

  # ---------------------------------------------------------------------------

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
      # Literal wire kinds so this file runs unchanged against the parent commit.
      "kind" => "arbor.security.authority_mutation_intent.v#{version}",
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

  defp later, do: "2026-09-28T13:00:00Z"

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

  defp digest(intent) do
    {:ok, bytes} = AuditJournal.canonical_intent_bytes(intent)
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
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

  defp delivered_terminals(count) do
    Map.new(1..count, fn n ->
      {sha({:op, n}),
       "delivered|authority_reduce|#{sha({:i, n})}|prepared:#{sha({:p, n})}|" <>
         "effect_applied:#{sha({:a, n})}|delivered:#{sha({:d, n})}"}
    end)
  end

  defp sha(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  defp unique_root do
    base = System.tmp_dir!()

    dir =
      Path.join(
        base,
        "audit-retire-#{System.pid()}-#{System.unique_integer([:positive])}-" <>
          Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      )

    File.mkdir_p!(dir)
    {:ok, root} = SafePath.resolve_real(dir)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
