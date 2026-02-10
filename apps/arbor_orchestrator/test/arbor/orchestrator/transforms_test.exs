defmodule Arbor.Orchestrator.TransformsTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node

  defmodule AddGoalTransform do
    alias Arbor.Orchestrator.Graph

    def transform(%Graph{} = graph) do
      {:ok, %{graph | attrs: Map.put(graph.attrs, "goal", "from-transform")}}
    end
  end

  test "runs custom transform modules before validation/engine" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      exit [shape=Msquare]
      start -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot, transforms: [AddGoalTransform])
    assert "exit" in result.completed_nodes
    assert result.context["graph.goal"] == "from-transform"
  end

  test "supports function transforms" do
    graph = %Graph{
      id: "Flow",
      nodes: %{
        "start" => %Node{id: "start", attrs: %{"shape" => "Mdiamond"}},
        "exit" => %Node{id: "exit", attrs: %{"shape" => "Msquare"}}
      },
      edges: [%Arbor.Orchestrator.Graph.Edge{from: "start", to: "exit", attrs: %{}}]
    }

    transform = fn g ->
      %{g | attrs: Map.put(g.attrs, "goal", "function-transform")}
    end

    diagnostics = Arbor.Orchestrator.validate(graph, transforms: [transform])
    assert Enum.empty?(Enum.filter(diagnostics, &(&1.severity == :error)))
  end

  test "returns parse_error diagnostic when transform is invalid" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      exit [shape=Msquare]
      start -> exit
    }
    """

    diagnostics = Arbor.Orchestrator.validate(dot, transforms: [:not_a_transform])
    assert Enum.any?(diagnostics, &(&1.rule == "parse_error"))
  end
end
