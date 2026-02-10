defmodule Arbor.Orchestrator.Conformance.MatrixTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Conformance.Matrix

  test "contains all three spec groups" do
    summary = Matrix.summary()

    assert Map.has_key?(summary.by_spec, :attractor)
    assert Map.has_key?(summary.by_spec, :coding_agent_loop)
    assert Map.has_key?(summary.by_spec, :unified_llm)
  end

  test "tracks at least one implemented or partial attractor item" do
    rows = Matrix.items().attractor
    assert Enum.any?(rows, &(&1.status in [:implemented, :partial]))
  end

  test "attaches local spec doc and section metadata to rows" do
    row = Matrix.items().unified_llm |> hd()
    assert row.spec_doc == "specs/attractor/unified-llm-spec.md"
    assert is_binary(row.spec_section)
  end
end
