defmodule Arbor.Security.AuditJournalNoConsumerSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Security
  alias Arbor.Security.AuditJournalOwner

  @moduletag :integration

  test "security regression: an unacknowledged principal backlog cannot be retired by a test journal" do
    principal = "agent_" <> String.duplicate("d", 64)
    # TestBootstrap starts TestAuditConsumer for the whole suite. Its 100ms poll
    # acknowledges deliveries on whichever journal currently owns the name, so a
    # mid-loop ack frees principal quota and the 129th grant succeeds. Point the
    # consumer name at a process nobody registers — same isolation as
    # AuditRetirementEphemeralTest.no_consumer!/0.
    no_consumer!()
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

  defp no_consumer! do
    previous = Application.fetch_env(:arbor_security, :authority_audit_consumer_name)

    Application.put_env(
      :arbor_security,
      :authority_audit_consumer_name,
      :audit_no_consumer_regression_none
    )

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:arbor_security, :authority_audit_consumer_name, value)

        :error ->
          Application.delete_env(:arbor_security, :authority_audit_consumer_name)
      end
    end)
  end
end
