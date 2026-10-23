defmodule Arbor.Orchestrator.CodeReviewWithFixesFindingsGateSecurityRegressionTest do
  @moduledoc """
  arXiv 2610.29379 (Evron): review harnesses go quiet when a select/filter/merge
  step drops findings without telling anyone.

  `code_review_with_fixes.dot` used to route `check_findings` on the
  model-emitted `has_findings` flag. A review JSON with `has_findings: false`
  and a non-empty `findings` list took the clean / review-only branch, so the
  listed issues never entered the fix loop.

  The gate must be computed from `findings` list length, not the model flag.
  """

  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.Engine.{Context, Outcome, Router}
  alias Arbor.Orchestrator.Handlers.TransformHandler

  @pipeline Path.expand(
              "../../../../arbor_scheduler/priv/pipelines/code_review_with_fixes.dot",
              __DIR__
            )

  @mismatched_review %{
    "summary" => "model claimed the diff was clean",
    "has_findings" => false,
    "findings" => [
      %{
        "file" => "lib/secret.ex",
        "line" => 12,
        "issue" => "capability check skipped",
        "suggested_fix" => "authorize before write"
      }
    ]
  }

  test "security regression: has_findings false with a nonempty findings list takes the findings branch" do
    graph = load_graph()
    context = Context.new(%{"review_json" => Jason.encode!(@mismatched_review)})

    {_context, next_id} = walk_findings_gate(graph, context)

    assert next_id == "build_branch_name",
           "non-empty findings must take the fix branch even when the model sets has_findings:false; routed to #{inspect(next_id)}"
  end

  defp load_graph do
    assert {:ok, graph} = Orchestrator.parse(File.read!(@pipeline))
    graph
  end

  # Walk the real extract → check_findings path. Snapshot_review is the last
  # node before the verdict extract; its successor is the start of the gate.
  defp walk_findings_gate(graph, context) do
    start_id = unconditional_successor(graph, "snapshot_review")
    walk_until_routed(graph, start_id, context)
  end

  defp walk_until_routed(graph, "check_findings", context) do
    check = graph.nodes["check_findings"]
    routed = Router.select_next_step(check, %Outcome{status: :success}, context, graph)
    {context, routed_node_id(routed)}
  end

  defp walk_until_routed(graph, node_id, context) do
    node = Map.fetch!(graph.nodes, node_id)
    assert node.attrs["type"] == "transform"

    outcome = TransformHandler.execute(node, context, graph, [])

    assert outcome.status == :success,
           "extract node #{node_id} failed: #{inspect(outcome.failure_reason)}"

    context = Context.apply_updates(context, outcome.context_updates)
    next_id = routed_node_id(Router.select_next_step(node, outcome, context, graph))
    walk_until_routed(graph, next_id, context)
  end

  defp unconditional_successor(graph, node_id) do
    case Router.select_next_step(
           graph.nodes[node_id],
           %Outcome{status: :success},
           Context.new(%{}),
           graph
         ) do
      {:edge, edge} -> edge.to
      {:node_id, id} -> id
    end
  end

  defp routed_node_id({:edge, edge}), do: edge.to
  defp routed_node_id({:node_id, id}), do: id
  defp routed_node_id(other), do: flunk("unexpected routing: #{inspect(other)}")
end
