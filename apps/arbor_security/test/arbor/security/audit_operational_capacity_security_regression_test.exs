defmodule Arbor.Security.AuditOperationalCapacitySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  alias Arbor.Security.AuditJournalOwner

  test "security regression: operational profile survives cold replay and refuses a small-profile downgrade" do
    Process.flag(:trap_exit, true)
    root = Path.join(System.tmp_dir!(), "audit-profile-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    name = :audit_operational_capacity_test
    opts = [mode: :durable, root: root, name: name, capacity_profile: :operational]

    on_exit(fn ->
      if pid = Process.whereis(name), do: GenServer.stop(pid)
      File.rm_rf!(root)
    end)

    assert {:ok, first} = AuditJournalOwner.start_link(opts)
    Process.unlink(first)
    assert {:ok, status} = AuditJournalOwner.status(name)
    assert status["capacity"]["hard_entry_cap"] == 4096
    assert status["capacity"]["reserve_entries"] == 1024
    assert status["capacity"]["hard_byte_cap"] == 16 * 1024 * 1024
    assert status["capacity"]["retained_operation_cap"] == 4096
    assert status["capacity"]["retained_increase_operation_cap"] == 3072
    assert status["capacity"]["retained_operation_count"] == 0
    assert status["committed_frames"] == 1
    # Retirement (2026-09-28): promotion installs a v3 snapshot (floor 3) and
    # never touches the ledger; the whole increase budget is available.
    assert status["retirement"]["floor"] == 3
    assert status["retirement"]["ledger_state"] == "absent"
    assert status["retirement"]["ledger_frames"] == 0
    assert status["retirement"]["last_error"] == "none"
    assert status["last_refusal"] == "none"
    assert status["admission_open"] == true
    assert status["capacity"]["retired_operation_total"] == 0
    assert status["capacity"]["retire_batch"] == 512
    assert status["capacity"]["remaining_increase_admissions"] == 3072
    assert status["capacity"]["remaining_soft_entries"] == 3071
    GenServer.stop(first)
    assert {:ok, second} = AuditJournalOwner.start_link(opts)
    Process.unlink(second)
    assert {:ok, ^status} = AuditJournalOwner.status(name)
    GenServer.stop(second)

    assert {:error, {:journal_open_failed, :capacity_profile_mismatch}} =
             AuditJournalOwner.start_link(Keyword.put(opts, :capacity_profile, :small))
  end

  test "security regression: unrecognized caller-selected profile is refused" do
    assert {:error, :invalid_opts} =
             AuditJournalOwner.start_link(mode: :ephemeral, capacity_profile: :unbounded)
  end
end
