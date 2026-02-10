defmodule Arbor.Orchestrator.Conformance112Test do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Validation.Validator
  alias Arbor.Orchestrator.Validation.Validator.ValidationError

  test "11.2 validator reports linting diagnostics and blocks hard errors" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      exit [shape=Msquare]
      orphan [label="unreachable", retry_target="missing_node"]
      start -> exit [condition="outcome>>success"]
    }
    """

    diagnostics = Arbor.Orchestrator.validate(dot)

    assert Enum.any?(diagnostics, &(&1.rule == "condition_syntax" and &1.severity == :error))
    assert Enum.any?(diagnostics, &(&1.rule == "reachability" and &1.node_id == "orphan"))
    assert Enum.any?(diagnostics, &(&1.rule == "retry_target_exists" and &1.severity == :warning))
  end

  test "11.2 validate_or_raise raises ValidationError when any error diagnostics exist" do
    dot = """
    digraph Flow {
      only [label="missing start and terminal"]
    }
    """

    assert {:ok, graph} = Arbor.Orchestrator.parse(dot)

    assert_raise ValidationError, fn ->
      Validator.validate_or_raise(graph)
    end
  end
end
