defmodule Arbor.Orchestrator.CodingPlan.TerminalReclassifyCoreTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.CodingPlan.TerminalReclassifyCore, as: Core

  @budget_reason "Action council_review_change context_keys invalid: timeout budget rejected action execution: :budget_exhausted"

  test "review_failed caused by a spent budget becomes review_unavailable" do
    assert {"review_unavailable", %{from: "review_failed", to: "review_unavailable", reason: r}} =
             Core.reclassify("review_failed", %{"review_change" => @budget_reason})

    assert r == @budget_reason
  end

  test "a council that ran and failed stays review_failed" do
    assert {"review_failed", nil} =
             Core.reclassify("review_failed", %{"review_change" => "council quorum not met"})
  end

  test "other nodes' budget failures do not touch the review status" do
    assert {"review_failed", nil} =
             Core.reclassify("review_failed", %{"validate" => @budget_reason})
  end

  test "non-review statuses and malformed reason maps pass through" do
    assert {"change_committed", nil} =
             Core.reclassify("change_committed", %{"review_change" => @budget_reason})

    assert {"review_failed", nil} = Core.reclassify("review_failed", nil)
    assert {"review_failed", nil} = Core.reclassify("review_failed", %{"review_change" => 42})
    assert {nil, nil} = Core.reclassify(nil, %{})
  end
end
