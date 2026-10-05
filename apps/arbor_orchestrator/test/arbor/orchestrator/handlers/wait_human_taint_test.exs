defmodule Arbor.Orchestrator.Handlers.WaitHumanTaintTest do
  use ExUnit.Case, async: true
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}
  alias Arbor.Orchestrator.Handlers.WaitHumanHandler
  @moduletag :fast

  test "security regression: a plain callback cannot declassify reviewed data" do
    graph = %Graph{edges: [%Edge{from: "gate", to: "approved", attrs: %{"label" => "approve"}}]}

    for attrs <- [
          %{"reviews_keys" => "secret", "review_on_choice" => "approve"},
          %{"reviews_keys" => "secret"},
          %{"review_on_choice" => "approve"}
        ] do
      outcome =
        WaitHumanHandler.execute(%Node{id: "gate", attrs: attrs}, %{}, graph,
          interviewer: fn _ -> "approve" end
        )

      assert outcome.status == :fail
      assert outcome.taint_reductions == []
    end
  end
end
