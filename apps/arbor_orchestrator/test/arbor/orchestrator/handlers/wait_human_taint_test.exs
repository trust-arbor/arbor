defmodule Arbor.Orchestrator.Handlers.WaitHumanTaintTest do
  @moduledoc """
  Human-review taint reduction (taint-rebuild Phase 4): when an operator picks the
  declared approval choice at a human gate, the reviewed data is reduced via
  :human_review. Rejection / other choices do NOT reduce.
  """
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}
  alias Arbor.Orchestrator.Handlers.WaitHumanHandler
  alias Arbor.Orchestrator.Human.Answer

  @moduletag :fast

  # gate -> approve ("approve") / reject ("reject")
  defp gate_graph do
    %Graph{
      edges: [
        %Edge{from: "gate", to: "do_it", attrs: %{"label" => "approve"}},
        %Edge{from: "gate", to: "stop", attrs: %{"label" => "reject"}}
      ]
    }
  end

  defp run(answer, attrs) do
    node = %Node{id: "gate", attrs: attrs}
    # Explicit interviewer fn (a nil interviewer would hit the is_atom clause and
    # fall through to AutoApproveInterviewer, masking the choice).
    interviewer = fn _question, _opts -> %Answer{value: answer} end
    WaitHumanHandler.execute(node, %{}, gate_graph(), interviewer: interviewer)
  end

  test "the approval choice reduces the reviewed keys via :human_review" do
    outcome =
      run("approve", %{"reviews_keys" => "fetched,extracted", "review_on_choice" => "approve"})

    assert outcome.status == :success

    assert outcome.taint_reductions == [
             {"fetched", :trusted, :human_review},
             {"extracted", :trusted, :human_review}
           ]
  end

  test "review_target=derived produces a weaker vouch" do
    outcome =
      run("approve", %{
        "reviews_keys" => "x",
        "review_on_choice" => "approve",
        "review_target" => "derived"
      })

    assert outcome.taint_reductions == [{"x", :derived, :human_review}]
  end

  test "a non-approval choice (reject) does NOT reduce" do
    outcome =
      run("reject", %{"reviews_keys" => "fetched", "review_on_choice" => "approve"})

    assert outcome.status == :success
    assert outcome.taint_reductions == []
  end

  test "no reviews_keys / no review_on_choice => no reduction" do
    assert run("approve", %{}).taint_reductions == []
    assert run("approve", %{"reviews_keys" => "x"}).taint_reductions == []
    assert run("approve", %{"review_on_choice" => "approve"}).taint_reductions == []
  end
end
