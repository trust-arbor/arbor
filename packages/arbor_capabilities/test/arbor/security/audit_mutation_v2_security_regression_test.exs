defmodule Arbor.Security.AuditMutationV2SecurityRegressionTest do
  use ExUnit.Case, async: true

  alias Arbor.Security.AuditJournalCore, as: Core
  alias Arbor.Security.Contracts.AuditJournal

  @moduletag :fast
  @time "2026-09-24T12:00:00Z"

  test "security regression: v2 operation identity survives observation-time changes" do
    assert {:ok, first} = AuditJournal.admit_intent(facts(1))

    assert {:ok, retry} =
             AuditJournal.admit_intent(Map.put(facts(1), "prepared_at", "2026-09-24T13:00:00Z"))

    assert first["operation_id"] == retry["operation_id"]
    assert {:ok, before} = Core.fold([record(first, "prepared")])
    assert {:error, :operation_conflict} = Core.append(before, record(retry, "prepared"))

    assert {:ok, other} =
             AuditJournal.admit_intent(
               put_in(
                 facts(1),
                 ["after_fingerprint", "capability_digest"],
                 String.duplicate("cd", 32)
               )
             )

    refute other["operation_id"] == first["operation_id"]
  end

  test "security regression: admitted grant lifecycles cannot consume the reduction reserve" do
    {:ok, empty} = Core.new()

    {state, admitted} =
      Enum.reduce_while(1..48, {empty, []}, fn n, {state, admitted} ->
        {:ok, intent} = AuditJournal.admit_intent(facts(n))

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
    {:ok, reduction} = AuditJournal.admit_intent(revoke_facts(99))
    assert {:ok, _} = Core.append(done, record(reduction, "prepared"))
  end

  test "operational profile retains more than the small-profile limit through compact and cold replay" do
    {:ok, empty} = Core.new(:operational)

    intents =
      Enum.map(1..60, fn n ->
        {:ok, intent} = AuditJournal.admit_intent(facts(n))
        intent
      end)

    state =
      Enum.reduce(intents, empty, fn intent, acc ->
        {:ok, next} = Core.append(acc, record(intent, "prepared"))
        next
      end)

    source = %{
      "committed_digest" => String.duplicate("ab", 32),
      "committed_frames" => 61,
      "committed_offset" => 100_000
    }

    assert {:ok, compacted, snapshot, pending} = Core.compact(state, source)
    assert snapshot["capacity_profile"] == "operational"
    assert {:ok, ^compacted} = Core.restore(snapshot, pending)
    assert length(pending) == 60

    done =
      Enum.reduce(intents, compacted, fn intent, acc ->
        {:ok, applied} = Core.append(acc, record(intent, "effect_applied"))
        {:ok, delivered} = Core.append(applied, record(intent, "delivered"))
        delivered
      end)

    assert Core.capacity(done)["remaining_hard_entries"] >= 1024
    assert {:error, _} = Core.restore(Map.put(snapshot, "capacity_profile", "unbounded"), pending)
  end

  defp facts(n) do
    id = "cap_" <> String.pad_leading(String.downcase(Integer.to_string(n, 16)), 32, "0")

    %{
      "version" => 2,
      "kind" => "arbor.security.authority_mutation_intent.v2",
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

  defp revoke_facts(n) do
    grant = facts(n)

    grant
    |> Map.put("operation", "capability_revoke")
    |> Map.put("effect_class", "authority_reduce")
    |> Map.put("before_fence", grant["after_fingerprint"])
    |> Map.put("after_fingerprint", %{"kind" => "tombstone", "generation" => 1})
    |> put_in(["audit", "event_type"], "capability_revoked")
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
end
