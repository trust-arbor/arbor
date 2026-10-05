defmodule Arbor.Orchestrator.Handlers.WaitHumanSourceSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  @dot """
  digraph SourceChoice {
    start [shape=Mdiamond]
    gate [shape=hexagon, label="Choose a destination", fan_out="false"]
    first [shape=box, simulate="true"]
    second [shape=box, simulate="true"]
    exit [shape=Msquare]
    start -> gate
    gate -> first [label="[A] Same label"]
    gate -> second [label="[A] Same label"]
    first -> exit
    second -> exit
  }
  """

  test "security regression: actual Engine missing or exceptional interviewer cannot approve first edge" do
    for opts <- [
          [],
          [interviewer: fn _ -> raise "interviewer unavailable" end],
          [interviewer: __MODULE__]
        ] do
      assert {:ok, result} = Arbor.Orchestrator.run(@dot, opts)
      assert result.final_outcome.status == :fail
      refute "first" in result.completed_nodes
      refute "second" in result.completed_nodes
    end
  end

  test "security regression: actual Engine rejects unknown, forged, and ambiguous selections" do
    for answer <- ["unknown", "A", %{value: "bad", selected_option: %{to: "missing"}}] do
      assert {:ok, result} = Arbor.Orchestrator.run(@dot, interviewer: fn _ -> answer end)
      assert result.final_outcome.status == :fail
      refute "first" in result.completed_nodes
    end
  end

  test "actual Engine selects unique immutable option identity despite duplicate labels" do
    assert {:ok, result} =
             Arbor.Orchestrator.run(@dot,
               interviewer: fn question ->
                 assert Enum.map(question.options, & &1.id) == ["choice_1", "choice_2"]
                 %{value: "choice_2", selected_option: Enum.at(question.options, 1)}
               end
             )

    assert result.final_outcome.status == :success
    assert "second" in result.completed_nodes
    refute "first" in result.completed_nodes
  end

  test "security regression: chat labels and callbacks cannot create protected review authority" do
    dot =
      String.replace(
        @dot,
        "label=\"Choose a destination\"",
        "label=\"Approve\", reviews_keys=\"secret\", review_on_choice=\"first\""
      )

    assert {:ok, result} = Arbor.Orchestrator.run(dot, interviewer: fn _ -> "first" end)
    assert result.final_outcome.status == :fail
    assert result.final_outcome.taint_reductions == []
    refute "first" in result.completed_nodes
  end

  test "security regression: source-bound conditional human choices fail closed" do
    dot =
      String.replace(
        @dot,
        "gate -> first [label=\"[A] Same label\"]",
        "gate -> first [label=\"[A] Same label\", condition=\"context.human.gate.selected=A\"]"
      )

    source = %{session_pid: self(), generation: make_ref(), handle: {self(), make_ref()}}

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot,
               conversation_source: source,
               interviewer: Arbor.Orchestrator.Human.AutoApproveInterviewer
             )

    assert result.final_outcome.status == :fail
    refute "first" in result.completed_nodes
  end

  test "explicit AutoApprove fixture works for ordinary single selection" do
    assert {:ok, result} =
             Arbor.Orchestrator.run(@dot,
               interviewer: Arbor.Orchestrator.Human.AutoApproveInterviewer
             )

    assert result.final_outcome.status == :success
    assert "first" in result.completed_nodes
  end
end
