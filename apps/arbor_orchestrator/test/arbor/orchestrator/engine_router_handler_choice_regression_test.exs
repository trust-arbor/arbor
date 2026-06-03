defmodule Arbor.Orchestrator.EngineRouterHandlerChoiceRegressionTest do
  @moduledoc """
  Regression test for the fan-out-vs-handler-choice bug.

  Before the fix in `Engine.Router.collect_fan_out_siblings/4`, a node
  with multiple unconditional outgoing edges would always fan out to
  ALL of them, even when the handler had explicitly chosen one via
  `outcome.preferred_label` or `outcome.suggested_next_ids`. The
  preferred branch ran first; the others got queued as pending and
  ran in sequence. So a "decision" gate that should produce one
  outcome produced three.

  Surfaced by `wait.human` (WaitHumanHandler returns
  `preferred_label: <selected.label>` + `suggested_next_ids: [<target>]`)
  — but the same shape applies to any handler that wants to pick one
  branch from N unconditional siblings.

  Fix: `collect_fan_out_siblings` now returns [] when the outcome
  carries a handler-chosen branch signal, in addition to the existing
  `fan_out=false` attr and `outcome.status == :fail` paths.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.{Outcome, Router}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}

  defp three_branch_graph do
    %Graph{
      id: "test",
      attrs: %{},
      nodes: %{
        "decision" => %Node{id: "decision", attrs: %{}},
        "a" => %Node{id: "a", attrs: %{}},
        "b" => %Node{id: "b", attrs: %{}},
        "c" => %Node{id: "c", attrs: %{}}
      },
      edges: [
        %Edge{from: "decision", to: "a", attrs: %{"label" => "Approve"}},
        %Edge{from: "decision", to: "b", attrs: %{"label" => "Modify"}},
        %Edge{from: "decision", to: "c", attrs: %{"label" => "Reject"}}
      ]
    }
  end

  defp decision_node(graph), do: Map.fetch!(graph.nodes, "decision")

  test "preferred_label suppresses fan-out siblings" do
    graph = three_branch_graph()
    outcome = %Outcome{status: :success, preferred_label: "Approve"}

    assert Router.collect_fan_out_siblings(decision_node(graph), outcome, %{}, graph) == []
  end

  test "suggested_next_ids suppresses fan-out siblings" do
    graph = three_branch_graph()
    outcome = %Outcome{status: :success, suggested_next_ids: ["a"]}

    assert Router.collect_fan_out_siblings(decision_node(graph), outcome, %{}, graph) == []
  end

  test "absent handler choice still fans out (true parallel case)" do
    # No preferred_label, no suggested_next_ids → ordinary fan-out node,
    # all three unconditional edges count as siblings.
    graph = three_branch_graph()
    outcome = %Outcome{status: :success}

    siblings = Router.collect_fan_out_siblings(decision_node(graph), outcome, %{}, graph)
    assert length(siblings) == 3
  end

  test "fan_out=\"false\" still suppresses siblings regardless of handler choice" do
    graph = three_branch_graph()
    decision = %{decision_node(graph) | attrs: %{"fan_out" => "false"}}
    graph = %{graph | nodes: Map.put(graph.nodes, "decision", decision)}
    outcome = %Outcome{status: :success}

    assert Router.collect_fan_out_siblings(decision, outcome, %{}, graph) == []
  end

  test "failure status still suppresses siblings (existing behavior preserved)" do
    graph = three_branch_graph()
    outcome = %Outcome{status: :fail}

    assert Router.collect_fan_out_siblings(decision_node(graph), outcome, %{}, graph) == []
  end
end
