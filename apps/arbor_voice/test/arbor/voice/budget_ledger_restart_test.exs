defmodule Arbor.Voice.BudgetLedgerRestartTest do
  @moduledoc """
  Restart-simulation proof for VOICE-24 (partial — Session does not yet close
  the backend or emit the notice/signal; see VP-04). A fresh ledger caller
  starts a new `Arbor.Voice.Test.BudgetLedgerFakeBackend` instance against
  the same file-persisted path, simulating a node restart: the durable data
  survives even though the in-memory Agent does not.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Voice.BudgetLedger
  alias Arbor.Voice.Config
  alias Arbor.Voice.Test.BudgetLedgerFakeBackend, as: Fake

  @tag spec: "VOICE-24"
  test "a fresh caller against the same durable fake observes prior consumed usage and active reservations" do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor-voice-budget-ledger-restart-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(path) end)

    name1 = :"budget_ledger_restart_a_#{System.unique_integer([:positive])}"
    {:ok, _pid1} = Fake.start_link(agent_name: name1, path: path)
    opts1 = [backend: Fake, backend_opts: [agent_name: name1]]
    daily_limit = 1000

    assert {:ok, r1} = BudgetLedger.reserve("user-1", "2026-08-02", 200, daily_limit, opts1)
    assert :ok = BudgetLedger.consume(r1, 150, opts1)
    assert {:ok, r2} = BudgetLedger.reserve("user-1", "2026-08-02", 300, daily_limit, opts1)

    :ok = Fake.stop(name1)

    name2 = :"budget_ledger_restart_b_#{System.unique_integer([:positive])}"
    {:ok, _pid2} = Fake.start_link(agent_name: name2, path: path)
    on_exit(fn -> Fake.stop(name2) end)
    opts2 = [backend: Fake, backend_opts: [agent_name: name2]]

    assert {:ok, remaining} = BudgetLedger.remaining("user-1", "2026-08-02", daily_limit, opts2)
    assert remaining == daily_limit - 150 - 300

    assert :ok = BudgetLedger.consume(r2, 300, opts2)

    assert {:ok, remaining_after} =
             BudgetLedger.remaining("user-1", "2026-08-02", daily_limit, opts2)

    assert remaining_after == daily_limit - 150 - 300
  end

  @tag spec: "VOICE-24"
  test "an abandoned reservation is eventually reclaimed across a simulated restart" do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor-voice-budget-ledger-restart-expiry-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(path) end)

    name1 = :"budget_ledger_restart_expiry_a_#{System.unique_integer([:positive])}"
    {:ok, _pid1} = Fake.start_link(agent_name: name1, path: path)
    opts1 = [backend: Fake, backend_opts: [agent_name: name1], now_unix_ms: 0]
    daily_limit = 1000

    assert {:ok, r1} = BudgetLedger.reserve("user-1", "2026-08-02", 1000, daily_limit, opts1)
    :ok = Fake.stop(name1)

    name2 = :"budget_ledger_restart_expiry_b_#{System.unique_integer([:positive])}"
    {:ok, _pid2} = Fake.start_link(agent_name: name2, path: path)
    on_exit(fn -> Fake.stop(name2) end)

    {:ok, _grace_ms} = Config.budget_reservation_grace_ms()
    expiry_ms = r1.expires_at_ms

    opts_before = [backend: Fake, backend_opts: [agent_name: name2], now_unix_ms: expiry_ms - 1]

    assert {:ok, remaining_before} =
             BudgetLedger.remaining("user-1", "2026-08-02", daily_limit, opts_before)

    assert remaining_before == daily_limit - 1000

    opts_after = [backend: Fake, backend_opts: [agent_name: name2], now_unix_ms: expiry_ms]

    assert {:ok, remaining_after} =
             BudgetLedger.remaining("user-1", "2026-08-02", daily_limit, opts_after)

    assert remaining_after == daily_limit
  end
end
