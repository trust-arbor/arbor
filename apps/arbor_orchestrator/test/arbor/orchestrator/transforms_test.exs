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

  test "compile/2 preserves post-IR custom-transform boundary" do
    # Bare codergen aliases inject purpose="llm" before IR compilation.
    # Custom transforms run AFTER IR.Compiler and must not re-trigger static analysis.
    # A second IR.Compiler.compile/1 would re-inject alias defaults and recompute
    # capabilities/classification/taint/schema from the mutated attrs.
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      work [type="codergen", prompt="hello", simulate="true"]
      exit [shape=Msquare]
      start -> work -> exit
    }
    """

    assert {:ok, baseline} = Arbor.Orchestrator.compile(dot, cache: false)
    baseline_work = baseline.nodes["work"]

    # Capture compiler-produced IR before any custom mutation.
    pre_caps = baseline_work.capabilities_required
    pre_class = baseline_work.data_classification
    pre_schema_errors = baseline_work.schema_errors
    pre_taint = baseline_work.taint_profile
    pre_graph_caps = baseline.capabilities_required
    pre_graph_max_class = baseline.max_data_classification
    pre_handler_types = baseline.handler_types

    # Alias-injected purpose must be present on a normal compile.
    assert baseline_work.attrs["purpose"] == "llm"
    assert pre_schema_errors == []

    transform = fn %Graph{} = g ->
      work = g.nodes["work"]

      # Delete alias-injected purpose/simulate; add post-compile analysis attrs.
      mutated_attrs =
        work.attrs
        |> Map.drop(["purpose", "simulate"])
        |> Map.put("capabilities", "shell.execute,fs.write")
        |> Map.put("data_class", "secret")
        |> Map.put("sensitivity", "restricted")

      mutated_work = %{work | attrs: mutated_attrs}
      %{g | nodes: Map.put(g.nodes, "work", mutated_work)}
    end

    assert {:ok, transformed} =
             Arbor.Orchestrator.compile(dot, cache: false, transforms: [transform])

    work = transformed.nodes["work"]

    # Deleted alias defaults stay absent — no second compile re-injection.
    refute Map.has_key?(work.attrs, "purpose")
    refute Map.has_key?(work.attrs, "simulate")

    # Post-transform attrs are present on the node (mutation applied).
    assert work.attrs["capabilities"] == "shell.execute,fs.write"
    assert work.attrs["data_class"] == "secret"
    assert work.attrs["sensitivity"] == "restricted"

    # Compiler-produced IR fields stay at pre-transform compiled values.
    assert work.capabilities_required == pre_caps
    assert work.data_classification == pre_class
    assert work.schema_errors == pre_schema_errors
    assert work.taint_profile == pre_taint

    # Graph-level aggregates unchanged by post-IR custom transforms.
    assert transformed.capabilities_required == pre_graph_caps
    assert transformed.max_data_classification == pre_graph_max_class
    assert transformed.handler_types == pre_handler_types
  end
end
