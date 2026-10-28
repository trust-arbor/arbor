defmodule Arbor.Commands.SourceCoupling.OwnershipTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SourceCoupling.Ownership

  @moduletag :fast

  test "versioned adapter path dependencies preserve declared Core ownership and levels" do
    source = """
    defmodule Arbor.Persistence.SQL.MixProject do
      def deps, do: [{:arbor_persistence, "~> 0.1.0-dev", path: "../arbor_persistence"}]
    end
    """

    assert {:ok, ["arbor_persistence"]} =
             Ownership.in_umbrella_deps(source, "packages/arbor_persistence_sql/mix.exs")

    assert {:ok, %{"arbor_persistence" => 0, "arbor_persistence_sql" => 1}} =
             Ownership.compute_levels(%{
               "arbor_persistence" => [],
               "arbor_persistence_sql" => ["arbor_persistence"]
             })
  end

  test "extracted packages retain application and source ownership" do
    assert {:ok, "arbor_signals"} =
             Ownership.app_of_path("packages/arbor_signals/lib/arbor/signals.ex")

    assert Ownership.mix_project_path?("packages/arbor_signals/mix.exs")
    assert Ownership.lib_source_path?("packages/arbor_signals/lib/arbor/signals.ex")
    refute Ownership.mix_project_path?("packages/arbor_signals/examples/standalone/mix.exs")
    refute Ownership.lib_source_path?("packages/arbor_signals/test/signals_test.exs")
  end

  test "repository-local path dependencies count alongside umbrella dependencies" do
    source = """
    defmodule Host.MixProject do
      def deps do
        [
          {:arbor_kernel, in_umbrella: true},
          {:arbor_signals, path: "../../packages/arbor_signals", runtime: false},
          {:arbor_external, path: "../../../arbor_external"},
          {:arbor_wrong_name, path: "../../packages/arbor_other"}
        ]
      end
    end
    """

    assert {:ok, ["arbor_kernel", "arbor_signals"]} =
             Ownership.in_umbrella_deps(source, "apps/arbor_kernel_runtime/mix.exs")
  end

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
