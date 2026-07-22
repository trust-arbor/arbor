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
end
