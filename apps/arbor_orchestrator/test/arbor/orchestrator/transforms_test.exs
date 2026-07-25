defmodule Arbor.Orchestrator.TransformsTest do
  use ExUnit.Case, async: true
  @moduletag :fast

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

  test "security regression: compile/2 rebuilds IR after a custom transform changes handler type" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      work [type="transform", transform="set", value="hello", output_key="message"]
      exit [shape=Msquare]
      start -> work -> exit
    }
    """

    assert {:ok, baseline} = Arbor.Orchestrator.compile(dot, cache: false)
    assert baseline.nodes["work"].handler_module == Arbor.Orchestrator.Handlers.TransformHandler
    assert baseline.nodes["work"].idempotency == :idempotent

    transform = fn %Graph{} = g ->
      work = g.nodes["work"]

      mutated_attrs =
        work.attrs
        |> Map.put("type", "exec")
        |> Map.put("target", "function")
        |> Map.put("data_class", "secret")

      mutated_work = %{work | attrs: mutated_attrs}
      %{g | nodes: Map.put(g.nodes, "work", mutated_work)}
    end

    assert {:ok, transformed} =
             Arbor.Orchestrator.compile(dot, cache: false, transforms: [transform])

    work = transformed.nodes["work"]
    assert work.attrs["type"] == "exec"
    assert work.attrs["target"] == "function"
    assert work.attrs["data_class"] == "secret"
    assert work.handler_module == Arbor.Orchestrator.Handlers.ExecHandler
    assert work.idempotency == :side_effecting
    assert work.data_classification == :secret
    assert transformed.handler_types["work"] == "exec"
    assert transformed.max_data_classification == :secret
  end
end
