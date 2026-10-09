defmodule Arbor.Security.AuditJournalEphemeralTestReliefTest do
  @moduledoc """
  Ordinary test beams run an ephemeral operational journal and do not start
  the Historian consumer. Observed grants stay `effect_applied` until the
  soft entry cap. The test-only relief delivers that backlog in memory and
  retries the refused increase. An observed principal backlog is delivered
  the same way. Unobserved prepares still refuse at the principal cap.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security.AuditJournalOwner
  alias Arbor.Security.CapabilityAuditCore

  @prepared_at "2026-10-08T12:00:00Z"
  @per_principal 128
  @principals 8

  test "ephemeral test journal admits another increase after the unacked soft-entry backlog" do
    name = :"audit_ephemeral_relief_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      AuditJournalOwner.start_link(mode: :ephemeral, name: name, capacity_profile: :operational)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    for principal <- 1..@principals, n <- 1..@per_principal do
      observe_grant!(pid, principal, n)
    end

    assert {:ok, intent, "prepared"} =
             AuditJournalOwner.prepare(pid, grant_intent(@principals + 1, 1))

    assert is_binary(intent["operation_id"])
    {:ok, status} = AuditJournalOwner.status(pid)
    assert status["last_refusal"] == "none"
    assert status["capacity"]["retired_operation_total"] >= 512
    assert status["entry_count"] < 2_000
  end

  test "observed grants for one principal do not stick at the principal cap" do
    name = :"audit_ephemeral_principal_relief_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      AuditJournalOwner.start_link(mode: :ephemeral, name: name, capacity_profile: :operational)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    for n <- 1..@per_principal do
      observe_grant!(pid, 1, n)
    end

    assert {:ok, intent, "prepared"} =
             AuditJournalOwner.prepare(pid, grant_intent(1, @per_principal + 1))

    assert is_binary(intent["operation_id"])
    {:ok, status} = AuditJournalOwner.status(pid)
    assert status["last_refusal"] == "none"
    assert status["capacity"]["retired_operation_total"] >= @per_principal
  end

  test "the shared test journal grants the same principal past the unacked cap" do
    principal = "agent_" <> String.duplicate("c", 64)

    for n <- 1..(@per_principal + 1) do
      assert {:ok, _capability} =
               Arbor.Security.grant_fixture(
                 principal: principal,
                 resource: "arbor://memory/read/shared-principal-relief/#{n}"
               )
    end
  end

  defp observe_grant!(pid, principal, n) do
    assert {:ok, intent, "prepared"} =
             AuditJournalOwner.prepare(pid, grant_intent(principal, n))

    assert {:ok, :committed} =
             AuditJournalOwner.observe(pid, intent["operation_id"], :applied)
  end

  defp grant_intent(principal, n) do
    principal_id = "agent_" <> String.pad_leading(Integer.to_string(principal), 64, "0")

    capability_id =
      "cap_" <> String.pad_leading(Integer.to_string(principal * 1_000 + n), 32, "0")

    data = %{
      "id" => capability_id,
      "principal_id" => principal_id,
      "resource_uri" => "arbor://memory/read/ephemeral-relief"
    }

    replacement = CapabilityAuditCore.replacement(Record.new(capability_id, data), :absent)
    {:ok, intent} = CapabilityAuditCore.intent(:grant, :absent, replacement, data, @prepared_at)
    intent
  end
end
