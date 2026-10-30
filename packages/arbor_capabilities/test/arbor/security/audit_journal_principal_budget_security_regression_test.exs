defmodule Arbor.Security.AuditJournalPrincipalBudgetSecurityRegressionTest do
  use ExUnit.Case, async: true
  @moduletag spec: "SSEC-011"

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security.AuditJournalOwner
  alias Arbor.Security.CapabilityAuditCore

  @principal "agent_" <> String.duplicate("a", 64)
  @other_principal "agent_" <> String.duplicate("b", 64)
  @prepared_at "2026-10-06T12:00:00Z"

  @tag spec: "SSEC-011"
  test "security regression: one principal cannot exhaust the shared grant journal" do
    name = :"audit_principal_budget_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      AuditJournalOwner.start_link(mode: :ephemeral, name: name, capacity_profile: :operational)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    for n <- 1..128 do
      assert {:ok, _intent, "prepared"} =
               AuditJournalOwner.prepare(pid, grant_intent(@principal, n))
    end

    assert {:error, :principal_capacity_exhausted} =
             AuditJournalOwner.prepare(pid, grant_intent(@principal, 129))

    assert {:ok, _intent, "prepared"} =
             AuditJournalOwner.prepare(pid, grant_intent(@other_principal, 130))

    assert {:ok, status} = AuditJournalOwner.status(pid)
    assert status["last_refusal"] == "principal_capacity_exhausted"
    assert status["entry_count"] == 129
  end

  defp grant_intent(principal_id, n) do
    capability_id = "cap_" <> String.pad_leading(Integer.to_string(n), 32, "0")

    data = %{
      "id" => capability_id,
      "principal_id" => principal_id,
      "resource_uri" => "arbor://memory/read/principal-budget"
    }

    replacement = CapabilityAuditCore.replacement(Record.new(capability_id, data), :absent)
    {:ok, intent} = CapabilityAuditCore.intent(:grant, :absent, replacement, data, @prepared_at)
    intent
  end
end
