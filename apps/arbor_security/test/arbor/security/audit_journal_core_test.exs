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

    test "pending_summary empty is zero count and zero age" do
      assert {:ok, state} = Core.new()
      assert Core.pending_operations(state) == []

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
      assert Core.pending_operations(prepared_state) == summary["operations"]

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
      assert Core.pending_operations(delivered_state) == []

      {:ok, intent} = AuditJournal.admit_intent(revoke_facts(1))
      rejected = rejected_record(intent, @t1)
      assert {:ok, rejected_state} = Core.fold([prepared_record(intent), rejected])
      assert Core.pending_operations(rejected_state) == []
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
