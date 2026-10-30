defmodule Arbor.Security.AuditJournalCoreReliefCostTest do
  @moduledoc """
  The relief predicate's cost on the refusal path (Floor-and-Ledger v3,
  slice 4 fix).

  `AuditJournalOwner` asks `AuditJournalCore.publication_relieves?/3` inside
  its single-writer mailbox on every capacity refusal (durable and ephemeral
  T3). When the counts already rule relief out (nothing retirable, nothing a
  compaction would reclaim: a no-consumer backlog, the test default) it must
  decide from operation statuses alone. It used to decode every retained
  record twice: about 0.8 s per refusal under 1024 pending grants, enough for
  queued callers to pass the 5 s journal call timeout.

  A branch-internal regression pin: it fails on 57ec0939e (34 record
  admissions for an 8-operation backlog, 1602 for 400). The parent 52a2cc3fa
  has no `publication_relieves?/3`.

  `async: false`: the test sets a global call-trace pattern on
  `AuditJournal.admit_record/1`, which is VM-wide state. Run in the async
  phase (inside the async core test module), every one of three full
  arbor_security runs had two or three unrelated async OIDC loopback tests
  miss their 2 s accept timeout (`:econnrefused`); in the sync phase, or
  absent, none did.
  """
  use ExUnit.Case, async: false

  alias Arbor.Security.AuditJournalCore, as: Core
  alias Arbor.Security.Contracts.AuditJournal

  @moduletag :fast
  @time "2026-09-28T12:00:00Z"

  test "a relief the counts rule out decodes no retained record, whatever the backlog" do
    small = record_admissions_for_relief_check(8)
    large = record_admissions_for_relief_check(400)
    assert small == large
    assert small <= 2
  end

  # Record decodes (`AuditJournal.admit_record/1`) while the relief predicate
  # evaluates an increase against `pending` effect_applied grants with nothing
  # delivered.
  defp record_admissions_for_relief_check(pending) do
    {:ok, fresh} = Core.new(:operational)

    state =
      Enum.reduce(1..pending, fresh, fn n, acc ->
        grant = intent(n)
        {:ok, acc} = Core.append(acc, record(grant, "prepared"))
        {:ok, acc} = Core.append(acc, record(grant, "effect_applied"))
        acc
      end)

    raw = record(intent(10_000), "prepared")
    retirable = Core.retirable_count(state)
    assert retirable == 0
    mfa = {AuditJournal, :admit_record, 1}
    test_pid = self()

    pid =
      spawn(fn ->
        receive do
          :go ->
            send(test_pid, {:relief, self(), Core.publication_relieves?(state, raw, retirable)})
        end
      end)

    :erlang.trace_pattern(mfa, true, [:global])
    :erlang.trace(pid, true, [:call, {:tracer, self()}])

    try do
      send(pid, :go)
      assert_receive {:relief, ^pid, false}, 30_000
    after
      :erlang.trace_pattern(mfa, false, [:global])
    end

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

  defp intent(n) do
    id = "cap_" <> String.pad_leading(String.downcase(Integer.to_string(n, 16)), 32, "0")

    {:ok, intent} =
      AuditJournal.admit_intent(%{
        "version" => 3,
        "kind" => AuditJournal.intent_kind(3),
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
      })

    intent
  end

  defp record(intent, "prepared") do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "prepared",
      "operation_id" => intent["operation_id"],
      "occurred_at" => intent["prepared_at"],
      "intent" => intent
    }
  end

  defp record(intent, "effect_applied") do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "effect_applied",
      "operation_id" => intent["operation_id"],
      "occurred_at" => @time,
      "observation" => %{"kind" => "applied", "after_fingerprint" => intent["after_fingerprint"]}
    }
  end
end
