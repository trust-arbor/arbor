defmodule Arbor.Orchestrator.Conformance114Test do
  use ExUnit.Case, async: true

  test "11.4 goal gate retries via retry_target until gate succeeds" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      gate [goal_gate=true, retry_target="repair", simulate="fail_once"]
      repair [label="Repair work"]
      exit [shape=Msquare]
      start -> gate
      gate -> exit [condition="outcome=success"]
      gate -> exit [condition="outcome=fail"]
      repair -> gate
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot, max_steps: 20)
    assert Enum.count(result.completed_nodes, &(&1 == "gate")) >= 2
    assert "repair" in result.completed_nodes
    assert List.last(result.completed_nodes) == "exit"
  end

  test "11.4 unsatisfied goal gate without retry target fails pipeline at terminal" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      gate [goal_gate=true, simulate="fail"]
      exit [shape=Msquare]
      start -> gate
      gate -> exit [condition="outcome=fail"]
    }
    """

    assert {:error, :goal_gate_unsatisfied_no_retry_target} = Arbor.Orchestrator.run(dot)
  end
end
