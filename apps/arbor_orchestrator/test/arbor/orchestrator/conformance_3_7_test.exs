defmodule Arbor.Orchestrator.Conformance37Test do
  use ExUnit.Case, async: true

  test "3.7 fail-edge condition wins over retry_target and fallback_retry_target" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      failing [simulate="fail", retry_target="retry_node", fallback_retry_target="fallback_node"]
      fail_edge [label="fail edge route"]
      retry_node [label="retry node"]
      fallback_node [label="fallback node"]
      exit [shape=Msquare]
      start -> failing
      failing -> fail_edge [condition="outcome=fail"]
      fail_edge -> exit
      retry_node -> exit
      fallback_node -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert "fail_edge" in result.completed_nodes
    refute "retry_node" in result.completed_nodes
    refute "fallback_node" in result.completed_nodes
  end

  test "3.7 retry_target then fallback_retry_target are used when no fail edge exists" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      failing [simulate="fail", retry_target="repair"]
      repair [label="repair"]
      exit [shape=Msquare]
      start -> failing
      repair -> exit
    }
    """

    assert {:ok, result} = Arbor.Orchestrator.run(dot)
    assert "repair" in result.completed_nodes
  end
end
