defmodule Arbor.Security.AuditJournalNoConsumerSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Security
  alias Arbor.Security.AuditJournalOwner

  @moduletag :integration

  test "security regression: an unacknowledged principal backlog cannot be retired by a test journal" do
    principal = "agent_" <> String.duplicate("d", 64)
    original = Process.whereis(AuditJournalOwner)
    assert is_pid(original)
    assert Process.unregister(AuditJournalOwner)

    {:ok, journal} =
      AuditJournalOwner.start_link(
        mode: :ephemeral,
        name: AuditJournalOwner,
        capacity_profile: :operational
      )

    Process.unlink(journal)
    :ok = AuditJournalOwner.install_test_fixture(journal)

    on_exit(fn ->
      {:ok, caps} = Security.list_capabilities(principal)
      Enum.each(caps, fn cap -> assert :ok = Security.revoke_fixture(cap.id) end)
      :ok = AuditJournalOwner.clear_test_fixture()
      if Process.alive?(journal), do: GenServer.stop(journal)
      assert Process.register(original, AuditJournalOwner)
    end)

    for n <- 1..128 do
      assert {:ok, _capability} =
               Security.grant_fixture(
                 principal: principal,
                 resource: "arbor://memory/read/no-consumer-regression/#{n}"
               )
    end

    assert {:error, :audit_unavailable} =
             Security.grant_fixture(
               principal: principal,
               resource: "arbor://memory/read/no-consumer-regression/129"
             )

    assert {:ok, status} = Security.audit_journal_status()
    assert status["last_refusal"] == "principal_capacity_exhausted"
    assert status["pending_count"] == 128
    assert status["capacity"]["retired_operation_total"] == 0
  end
end
