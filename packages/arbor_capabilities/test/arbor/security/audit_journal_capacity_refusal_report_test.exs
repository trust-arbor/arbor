defmodule Arbor.Security.AuditJournalCapacityRefusalReportTest do
  @moduledoc """
  A capacity refusal used to be silent: the owner only recorded `last_refusal`,
  and callers saw `{:error, :audit_unavailable}`. In test runs, where nothing
  acknowledged deliveries, that turned journal exhaustion into unexplained
  failures in whatever modules ran last (2026-10-07). The first refusal of an
  episode is now logged and telemetered once.

  `async: false`: the log capture and the telemetry handler are global.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security.AuditJournalOwner, as: Owner
  alias Arbor.Security.CapabilityAuditCore

  @moduletag :fast

  @event [:arbor, :security, :audit_journal, :capacity_refused]
  @time "2026-10-07T12:00:00Z"
  @principal "agent_capacity_refusal_report"
  @owner_name :audit_capacity_refusal_report_owner

  setup do
    # The default :small profile refuses an increase after about ten.
    owner = start_supervised!({Owner, mode: :ephemeral, name: @owner_name})

    handler = "audit-refusal-report-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        @event,
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:capacity_refused, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{owner: owner}
  end

  test "the first capacity refusal of an episode is logged and telemetered once", %{
    owner: owner
  } do
    log =
      capture_log(fn ->
        first_refused = fill_until_refused(owner)
        assert {:error, :soft_capacity_exhausted} = Owner.prepare(owner, grant(first_refused + 1))
        assert {:error, :soft_capacity_exhausted} = Owner.prepare(owner, grant(first_refused + 2))
      end)

    assert [_one] = Regex.scan(~r/refused an authority increase/, log)

    assert log =~
             "Security audit journal (ephemeral) refused an authority increase: soft_capacity_exhausted"

    assert log =~ "check that the authority audit consumer is keeping up"

    assert_received {:capacity_refused, %{count: 1, retained_operations: retained},
                     %{reason: :soft_capacity_exhausted, mode: :ephemeral}}

    assert retained > 0
    refute_received {:capacity_refused, _measurements, _metadata}

    assert {:ok, %{"last_refusal" => "soft_capacity_exhausted"}} = Owner.status(owner)
  end

  test "a refusal that is not about capacity is not reported", %{owner: owner} do
    intent = grant(1)
    assert {:ok, _intent, "prepared"} = Owner.prepare(owner, intent)

    assert {:ok, :committed} =
             Owner.observe(owner, intent["operation_id"], {:rejected, "cas_conflict"})

    log =
      capture_log(fn ->
        assert {:error, :operation_terminal} = Owner.prepare(owner, intent)
      end)

    refute log =~ "refused an authority increase"
    refute_received {:capacity_refused, _measurements, _metadata}
  end

  # Prepares grants until the journal refuses one; returns its number.
  defp fill_until_refused(owner, n \\ 1) do
    case Owner.prepare(owner, grant(n)) do
      {:ok, _intent, "prepared"} when n < 100 -> fill_until_refused(owner, n + 1)
      {:error, :soft_capacity_exhausted} -> n
    end
  end

  defp grant(n) do
    capability_id = "cap_" <> String.pad_leading(Integer.to_string(n), 32, "0")

    data = %{
      "id" => capability_id,
      "principal_id" => "#{@principal}_#{n}",
      "resource_uri" => "arbor://memory/read/refusal-report"
    }

    after_entry = CapabilityAuditCore.replacement(Record.new(capability_id, data), :absent)
    {:ok, intent} = CapabilityAuditCore.intent(:grant, :absent, after_entry, data, @time)
    intent
  end
end
