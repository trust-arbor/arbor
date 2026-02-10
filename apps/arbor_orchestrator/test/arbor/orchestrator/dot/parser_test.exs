defmodule Arbor.Orchestrator.Dot.ParserTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Dot.Parser

  test "parses graph, nodes, attrs, and chained edges" do
    dot = """
    digraph Flow {
      graph [goal="Build feature", default_max_retry=2]
      start [shape=Mdiamond]
      plan [label="Plan", prompt="Use $goal"]
      review [shape=diamond]
      exit [shape=Msquare]

      start -> plan -> review [label="next"]
      review -> exit [condition="outcome=success", weight=10]
    }
    """

    assert {:ok, graph} = Parser.parse(dot)
    assert graph.id == "Flow"
    assert graph.attrs["goal"] == "Build feature"
    assert map_size(graph.nodes) == 4
    assert length(graph.edges) == 3
  end

  test "applies node and edge defaults from default blocks" do
    dot = """
    digraph Flow {
      node [llm_provider="anthropic", max_retries=3]
      edge [fidelity="compact"]
      start [shape=Mdiamond]
      task [label="Task"]
      start -> task [condition="outcome=success"]
    }
    """

    assert {:ok, graph} = Parser.parse(dot)

    assert graph.nodes["start"].attrs["llm_provider"] == "anthropic"
    assert graph.nodes["start"].attrs["max_retries"] == 3
    assert graph.nodes["task"].attrs["llm_provider"] == "anthropic"

    [edge] = graph.edges
    assert edge.attrs["fidelity"] == "compact"
    assert edge.attrs["condition"] == "outcome=success"
  end

  test "flattens subgraph contents into parent graph" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]

      subgraph cluster_build {
        plan [label="Plan"]
        implement [label="Implement"]
        plan -> implement
      }

      implement -> exit
      exit [shape=Msquare]
    }
    """

    assert {:ok, graph} = Parser.parse(dot)
    assert Map.has_key?(graph.nodes, "plan")
    assert Map.has_key?(graph.nodes, "implement")
    assert Map.has_key?(graph.nodes, "exit")
    assert Enum.any?(graph.edges, &(&1.from == "plan" and &1.to == "implement"))
    assert Enum.any?(graph.edges, &(&1.from == "implement" and &1.to == "exit"))
  end

  test "parses multi-line node attribute blocks" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      task [
        label="Task node",
        prompt="Build $goal",
        max_retries=2
      ]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    assert {:ok, graph} = Parser.parse(dot)
    assert graph.nodes["task"].attrs["label"] == "Task node"
    assert graph.nodes["task"].attrs["prompt"] == "Build $goal"
    assert graph.nodes["task"].attrs["max_retries"] == 2
  end

  test "parses quoted attribute values containing commas" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      manager [manager.actions="observe,steer,wait", class="alpha,beta"]
      exit [shape=Msquare]
      start -> manager -> exit
    }
    """

    assert {:ok, graph} = Parser.parse(dot)
    assert graph.nodes["manager"].attrs["manager.actions"] == "observe,steer,wait"
    assert graph.nodes["manager"].attrs["class"] == "alpha,beta"
  end
end
