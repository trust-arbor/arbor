defmodule Arbor.Orchestrator.CodingPlan.ReadinessCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Orchestrator.CodingPlan.ReadinessCore

  @digest "sha256:" <> String.duplicate("a", 64)
  @observed_at "2026-07-22T12:00:00.000Z"
  @expires_at "2026-07-22T12:01:00.000Z"

  test "derives report status from diagnostics and retains bounded expiry" do
    passed = diagnostic("passed")
    unavailable = diagnostic("unavailable")
    blocked = diagnostic("blocked")

    assert {:ok, ready} = ReadinessCore.report(@digest, @observed_at, [passed])
    assert ready["status"] == "ready"
    refute Map.has_key?(ready, "expires_at")

    assert {:ok, degraded} =
             ReadinessCore.report(@digest, @observed_at, [passed, unavailable],
               expires_at: @expires_at
             )

    assert degraded["status"] == "degraded"
    assert degraded["expires_at"] == @expires_at

    assert {:ok, blocked_report} =
             ReadinessCore.report(@digest, @observed_at, [passed, unavailable, blocked])

    assert blocked_report["status"] == "blocked"
  end

  defp diagnostic(decision) do
    ReadinessCore.diagnostic(
      "gate_#{decision}",
      "preflight",
      decision,
      "code_#{decision}",
      @observed_at,
      "Diagnostic #{decision}.",
      nil
    )
  end

  test "only an all-passed diagnostic set reaches ready" do
    # Regression: the status fold used to end in `true -> "ready"`, so any
    # decision outside the known list fell through to ready — a gate failing
    # OPEN. Nothing may reach "ready" by default.
    for decision <- ["blocked", "degraded", "unavailable"] do
      assert {:ok, report} =
               ReadinessCore.report(@digest, @observed_at, [
                 diagnostic("passed"),
                 diagnostic(decision)
               ])

      refute report["status"] == "ready",
             "a #{decision} diagnostic must never yield a ready report"
    end

    assert {:ok, ready} = ReadinessCore.report(@digest, @observed_at, [diagnostic("passed")])
    assert ready["status"] == "ready"
  end

  test "security regression: empty diagnostics fail closed as degraded" do
    assert {:ok, report} = ReadinessCore.report(@digest, @observed_at, [])
    assert report["status"] == "degraded"
    refute report["status"] == "ready"
    assert report["diagnostics"] == []
  end
end
