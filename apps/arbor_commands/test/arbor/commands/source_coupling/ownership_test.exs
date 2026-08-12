defmodule Arbor.Commands.SourceCoupling.OwnershipTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SourceCoupling.Ownership

  @moduletag :fast

  test "compute_levels fails closed on missing dependency targets (no silent level-0)" do
    # common declares arbor_contracts, but contracts has no graph node.
    graph = %{
      "arbor_common" => ["arbor_contracts"]
    }

    assert {:error, {:missing_dependency_target, "arbor_common", "arbor_contracts"}} =
             Ownership.compute_levels(graph)

    # Must not invent the missing target as a level-0 leaf that would affect hierarchy.
    refute match?({:ok, %{"arbor_contracts" => 0}}, Ownership.compute_levels(graph))
    refute match?({:ok, %{"arbor_common" => _}}, Ownership.compute_levels(graph))
  end

  test "compute_levels does not fabricate missing transitive targets as level-0" do
    graph = %{
      "arbor_agent" => ["arbor_orchestrator"],
      "arbor_orchestrator" => ["arbor_actions"],
      "arbor_actions" => ["arbor_missing_lib"]
    }

    assert {:error, {:missing_dependency_target, "arbor_actions", "arbor_missing_lib"}} =
             Ownership.compute_levels(graph)
  end

  test "compute_levels succeeds when all declared deps are present" do
    graph = %{
      "arbor_contracts" => [],
      "arbor_common" => ["arbor_contracts"]
    }

    assert {:ok, levels} = Ownership.compute_levels(graph)
    assert levels["arbor_contracts"] == 0
    assert levels["arbor_common"] == 1
    # Only declared graph keys appear — no fabricated apps.
    assert Map.keys(levels) |> Enum.sort() == ["arbor_common", "arbor_contracts"]
  end

  test "compute_levels detects cycles" do
    graph = %{
      "arbor_a" => ["arbor_b"],
      "arbor_b" => ["arbor_a"]
    }

    assert {:error, {:cycle, _, _}} = Ownership.compute_levels(graph)
  end
end
