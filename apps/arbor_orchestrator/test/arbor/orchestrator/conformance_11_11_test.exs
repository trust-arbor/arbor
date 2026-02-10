defmodule Arbor.Orchestrator.Conformance1111Test do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Graph

  defmodule SetTaskPromptTransform do
    alias Arbor.Orchestrator.Graph

    def transform(%Graph{} = graph) do
      node = graph.nodes["task"]
      updated = %{node | attrs: Map.put(node.attrs, "prompt", "from-transform")}
      %{graph | nodes: Map.put(graph.nodes, "task", updated)}
    end
  end

  defmodule SetGoalA do
    alias Arbor.Orchestrator.Graph
    def transform(%Graph{} = graph), do: %{graph | attrs: Map.put(graph.attrs, "goal", "A")}
  end

  defmodule SetGoalB do
    alias Arbor.Orchestrator.Graph
    def transform(%Graph{} = graph), do: %{graph | attrs: Map.put(graph.attrs, "goal", "B")}
  end

  test "11.11 built-in variable expansion replaces $goal in prompt before execution" do
    dot = """
    digraph Flow {
      goal="Ship feature"
      start [shape=Mdiamond]
      task [shape=box, prompt="Do $goal now"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert result.context["last_prompt"] == "Do Ship feature now"
  end

  test "11.11 transform interface transform(graph) -> graph is supported" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      task [shape=box]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot, transforms: [SetTaskPromptTransform])
    assert result.context["last_prompt"] == "from-transform"
  end

  test "11.11 custom transforms run after built-ins and preserve registration order" do
    dot = """
    digraph Flow {
      goal="orig"
      start [shape=Mdiamond]
      task [shape=box, prompt="Goal:$goal"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot, transforms: [SetGoalA, SetGoalB])
    # Built-in variable expansion runs before custom transforms; prompt uses original goal.
    assert result.context["last_prompt"] == "Goal:orig"
    # Custom transforms still run in order and last wins for graph attrs.
    assert result.context["graph.goal"] == "B"
  end

  test "11.11 function transforms are supported and invalid transforms are rejected" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      task [shape=box, prompt="Do $goal"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    transform = fn graph ->
      %{graph | attrs: Map.put(graph.attrs, "goal", "from-fn")}
    end

    assert {:ok, result} = Arbor.Orchestrator.run(dot, transforms: [transform])
    assert result.context["graph.goal"] == "from-fn"

    diagnostics = Arbor.Orchestrator.validate(dot, transforms: [:not_a_transform])
    assert Enum.any?(diagnostics, &(&1.rule == "parse_error"))
  end
end
