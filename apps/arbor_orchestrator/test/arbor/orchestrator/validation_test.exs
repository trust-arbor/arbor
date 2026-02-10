defmodule Arbor.Orchestrator.ValidationTest do
  use ExUnit.Case, async: true

  test "flags unreachable nodes" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      exit [shape=Msquare]
      orphan [label="never reached"]
      start -> exit
    }
    """

    diagnostics = Arbor.Orchestrator.validate(dot)
    assert Enum.any?(diagnostics, &(&1.rule == "reachability" and &1.node_id == "orphan"))
  end

  test "flags invalid condition syntax" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      mid [label="mid"]
      exit [shape=Msquare]
      start -> mid [condition="outcome>>success"]
      mid -> exit
    }
    """

    diagnostics = Arbor.Orchestrator.validate(dot)
    assert Enum.any?(diagnostics, &(&1.rule == "condition_syntax" and &1.severity == :error))
  end

  test "warns when goal gate is missing retry target" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      gate [goal_gate=true]
      exit [shape=Msquare]
      start -> gate -> exit
    }
    """

    diagnostics = Arbor.Orchestrator.validate(dot)
    assert Enum.any?(diagnostics, &(&1.rule == "goal_gate_has_retry" and &1.severity == :warning))
  end

  test "errors when multiple terminal nodes exist" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      exit_a [shape=Msquare]
      exit_b [shape=Msquare]
      start -> exit_a
    }
    """

    diagnostics = Arbor.Orchestrator.validate(dot)
    assert Enum.any?(diagnostics, &(&1.rule == "terminal_node" and &1.severity == :error))
  end

  test "warns when codergen node has missing prompt" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      task [shape=box]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """

    diagnostics = Arbor.Orchestrator.validate(dot)

    assert Enum.any?(
             diagnostics,
             &(&1.rule == "codergen_prompt" and &1.severity == :warning and &1.node_id == "task")
           )
  end
end
