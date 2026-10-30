defmodule Arbor.Security.TestAuditConsumerTest do
  @moduledoc """
  Regression (2026-10-07): test runs had a hidden audit-journal budget.

  Test runs do not start the Historian, so nothing acknowledged the Security
  audit journal's deliveries. Every grant and revoke stayed pending (two
  written entries plus one reserved), and the 3072-entry soft cap admitted only
  about 1023 of them per test run. After that, every grant failed with
  `{:error, :audit_unavailable}`. `Arbor.Security.TestBootstrap.start!/1` (called
  by this app's test_helper) now starts `Arbor.Security.TestAuditConsumer`, so
  operations are acknowledged and retire as in production.

  `async: false`: it spends a large share of the run's shared journal.
  """
  use ExUnit.Case, async: false

  alias Arbor.Security.TestAuditConsumer

  @moduletag :fast

  # More than the ~1023 operations a journal that is never acknowledged admits.
  @grants 1_100
  # Spread over principals: each may hold only 128 undelivered increases, a
  # separate limit a burst at one principal would hit between consumer polls.
  @principals 20

  test "TestBootstrap's consumer lets a run grant past the unacknowledged budget" do
    base = "agent_audit_budget_#{System.unique_integer([:positive])}"
    principals = for n <- 1..@principals, do: "#{base}_#{n}"
    on_exit(fn -> Enum.each(principals, &Arbor.Security.revoke_all_fixture/1) end)

    failures =
      1..@grants
      |> Enum.map(fn n ->
        Arbor.Security.grant_fixture(
          principal: Enum.at(principals, rem(n, @principals)),
          resource: "arbor://fs/read/audit-budget/#{n}"
        )
      end)
      |> Enum.reject(&match?({:ok, _capability}, &1))

    assert failures == [],
           "#{length(failures)} of #{@grants} grants were refused: " <>
             inspect(Enum.frequencies(failures))

    _ = TestAuditConsumer.drain()
    assert {:ok, status} = Arbor.Security.audit_journal_status()
    assert status["last_refusal"] == "none"
    assert status["capacity"]["retired_operation_total"] > 0
  end

  test "drain acknowledges what is deliverable now" do
    principal = "agent_audit_drain_#{System.unique_integer([:positive])}"
    on_exit(fn -> Arbor.Security.revoke_all_fixture(principal) end)

    assert {:ok, _capability} =
             Arbor.Security.grant_fixture(principal: principal, resource: "arbor://fs/read/drain")

    _ = TestAuditConsumer.drain()

    assert {:ok, pending} = Arbor.Security.audit_journal_pending_operations()
    refute Enum.any?(pending, &(&1["status"] == "effect_applied"))
  end
end
