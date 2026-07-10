defmodule Arbor.Orchestrator.EngineRouterConditionalRoutingRegressionTest do
  @moduledoc """
  Routing regression for conditional review routes.

  A route_review-style node with only conditioned edges must not select the
  lexical first edge when its review enum is unknown. It may continue only
  through an explicitly declared unconditional fallback.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.{Context, Outcome, Router}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}

  test "routing regression: unknown review enum selects no conditioned edge" do
    graph = review_graph([])
    route_review = Map.fetch!(graph.nodes, "route_review")
    context = Context.new(%{"review.tier_decision" => "unknown"})

    assert Router.select_next_step(route_review, %Outcome{status: :success}, context, graph) ==
             nil
  end

  test "uses an explicit unconditional fallback when no review condition matches" do
    graph = review_graph([%Edge{from: "route_review", to: "fallback", attrs: %{}}])
    route_review = Map.fetch!(graph.nodes, "route_review")
    context = Context.new(%{"review.tier_decision" => "unknown"})

    assert {:edge, %Edge{to: "fallback"}} =
             Router.select_next_step(route_review, %Outcome{status: :success}, context, graph)
  end

  defp review_graph(extra_edges) do
    %Graph{
      id: "review_routing",
      attrs: %{},
      nodes: %{
        "route_review" => %Node{id: "route_review", attrs: %{}},
        "approved" => %Node{id: "approved", attrs: %{}},
        "rework" => %Node{id: "rework", attrs: %{}},
        "fallback" => %Node{id: "fallback", attrs: %{}}
      },
      edges: [
        %Edge{
          from: "route_review",
          to: "approved",
          attrs: %{"condition" => "context.review.tier_decision=approved"}
        },
        %Edge{
          from: "route_review",
          to: "rework",
          attrs: %{"condition" => "context.review.tier_decision=rework"}
        }
        | extra_edges
      ]
    }
  end
end
