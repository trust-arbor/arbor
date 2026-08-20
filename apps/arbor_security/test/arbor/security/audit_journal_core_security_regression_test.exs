defmodule Arbor.Security.AuditJournalCoreSecurityRegressionTest do
  @moduledoc """
  Exact-parent security regression for P1C-B1 audit-journal contract and reducer.

  Parent (modules absent) fails to load/call these APIs. Candidate must pass.
  """

  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag security: :regression

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
    assert {:error, :struct_not_allowed} = AuditJournal.admit_intent(%URI{})

    assert {:error, :forbidden_content} =
             AuditJournal.admit_intent(Map.put(grant_absent(), "capability", %{"id" => @cap_id}))

    assert {:error, :forbidden_content} =
             AuditJournal.admit_intent(Map.put(grant_absent(), "metadata", %{"note" => "x"}))

    assert {:error, :forbidden_content} =
             AuditJournal.admit_intent(Map.put(grant_absent(), "bearer", "secret-token"))
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
end
