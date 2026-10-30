defmodule Arbor.Commands.SourceCoupling.OwnershipTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SourceCoupling.Ownership

  @moduletag :fast

  test "nondependency metadata cannot declare a published repository edge" do
    source = """
    defmodule Signals.MixProject do
      @labels [arbor_kernel: "Kernel"]
      @versions [arbor_kernel: "~> 2.0.0-dev"]
      @examples [{:arbor_kernel, "~> 2.0.0-dev", runtime: false}]

      def project, do: [deps: deps(), package: [arbor_kernel: "~> 2.0.0-dev"]]
      defp labels, do: [arbor_kernel: "~> 2.0.0-dev"]

      defp deps do
        _labels = [arbor_kernel: "~> 2.0.0-dev"]
        [{:external, "~> 1.0", metadata: [arbor_kernel: "~> 2.0.0-dev"]}]
      end
    end
    """

    assert {:ok, []} =
             Ownership.in_umbrella_deps(
               source,
               "packages/arbor_signals/mix.exs",
               MapSet.new(["arbor_kernel"])
             )
  end

  test "published declarations follow returned project lists and static helpers only" do
    source = """
    defmodule Signals.MixProject do
      def project, do: [deps: core_deps() ++ optional_deps()]
      defp core_deps, do: [{:arbor_kernel, "~> 2.0.0-dev"}] |> Enum.uniq()
      defp optional_deps, do: repeated_deps()
      defp repeated_deps, do: optional_deps()
      defp labels, do: [arbor_signals: "~> 0.2.0-dev"]
    end
    """

    assert {:ok, ["arbor_kernel"]} =
             Ownership.in_umbrella_deps(
               source,
               "packages/arbor_signals/mix.exs",
               MapSet.new(["arbor_kernel", "arbor_signals"])
             )
  end

  test "OIDC's conditional tuple helper declares its public OAuth dependency" do
    source = """
    defmodule Arbor.CapabilitiesOIDC.MixProject do
      def project, do: [app: :arbor_capabilities_oidc, deps: deps()]

      defp deps do
        [
          oauth_dependency(),
          {:jason, "~> 1.4"},
          {:joken, "~> 2.7", runtime: false},
          {:plug_crypto, "~> 2.0", runtime: false},
          {:boundary, "~> 0.10", runtime: false}
        ]
      end

      defp oauth_dependency do
        case System.get_env("ARBOR_OAUTH_PATH") do
          nil -> {:arbor_oauth, "~> 0.1.0-dev"}
          path -> {:arbor_oauth, "~> 0.1.0-dev", path: path, override: true}
        end
      end
    end
    """

    assert {:ok, ["arbor_oauth"]} =
             Ownership.in_umbrella_deps(
               source,
               "packages/arbor_capabilities_oidc/mix.exs",
               MapSet.new(["arbor_oauth", "arbor_capabilities_oidc"])
             )

    # A possible public default proves no local edge without an admitted owner.
    assert {:ok, []} =
             Ownership.in_umbrella_deps(source, "packages/arbor_capabilities_oidc/mix.exs")
  end

  test "conditional list helpers resolve only dependency-position returns" do
    source = """
    defmodule Signals.MixProject do
      def project, do: [deps: selected_deps()]
      defp selected_deps do
        case System.get_env("HIERARCHY_PACKAGE_LIST") do
          nil -> base_deps() ++ optional_deps()
          _configured -> []
        end
      end

      defp base_deps, do: [package_dependency()]
      defp package_dependency, do: {:arbor_kernel, "~> 2.0.0-dev"}
      defp optional_deps, do: repeated_deps()
      defp repeated_deps, do: optional_deps()
    end
    """

    assert {:ok, ["arbor_kernel"]} =
             Ownership.in_umbrella_deps(
               source,
               "packages/arbor_signals/mix.exs",
               MapSet.new(["arbor_kernel", "arbor_signals"])
             )
  end

  test "entry helpers do not promote metadata, nested lists, or unresolved sources" do
    source = """
    defmodule Signals.MixProject do
      @versions [{:arbor_kernel, "~> 2.0.0-dev"}]
      defp deps do
        [metadata_entry(), nested_list(), attribute_entry(), dynamic_entry(),
         foreign_entry(), dynamic_version(), returned_external(), cycle_a(),
         Foreign.package_dependency()]
      end

      defp metadata_entry, do: {:external, "~> 1.0", metadata: [arbor_kernel: "~> 2.0.0-dev"]}
      defp nested_list, do: [{:arbor_kernel, "~> 2.0.0-dev"}]
      defp attribute_entry, do: @versions
      defp unused_entry, do: {:arbor_kernel, "~> 2.0.0-dev"}
      defp foreign_entry, do: {:arbor_kernel, "~> 2.0.0-dev", git: "https://example.invalid/kernel.git"}
      defp dynamic_version, do: {:arbor_kernel, dependency_version()}
      defp cycle_a, do: cycle_b()
      defp cycle_b, do: cycle_a()

      defp dynamic_entry do
        case System.get_env("HIERARCHY_PACKAGE_PATH") do
          nil -> {:arbor_kernel, "~> 2.0.0-dev", path: dependency_path()}
          path -> {:arbor_kernel, "~> 2.0.0-dev", path: path}
        end
      end

      defp returned_external do
        _not_returned = {:arbor_kernel, "~> 2.0.0-dev"}
        case {:arbor_kernel, "~> 2.0.0-dev"} do
          {:arbor_kernel, "~> 2.0.0-dev"} -> {:external, "~> 1.0"}
        end
      end

      defmodule Foreign do
        def package_dependency, do: {:arbor_kernel, "~> 2.0.0-dev"}
      end
    end
    """

    assert {:ok, []} =
             Ownership.in_umbrella_deps(
               source,
               "packages/arbor_signals/mix.exs",
               MapSet.new(["arbor_kernel"])
             )
  end

  test "published version dependencies count only known repository owners" do
    known_apps = MapSet.new(["arbor_kernel", "arbor_signals"])

    for declaration <- [
          "{:arbor_kernel, \"~> 0.1.0-dev\"}",
          "{:arbor_kernel, \"~> 0.1.0-dev\", runtime: false}"
        ] do
      source = "defmodule Signals.MixProject do def deps, do: [#{declaration}] end"

      assert {:ok, ["arbor_kernel"]} =
               Ownership.in_umbrella_deps(source, "packages/arbor_signals/mix.exs", known_apps)
    end

    assert {:ok, []} =
             Ownership.in_umbrella_deps(
               ~s(def deps, do: [{:arbor_unknown, "~> 0.1.0"}, {:external, "~> 1.0"}]),
               "packages/arbor_signals/mix.exs",
               known_apps
             )

    # Without an owner inventory, a published package name proves no local edge.
    assert {:ok, []} =
             Ownership.in_umbrella_deps("def deps, do: [{:arbor_kernel, \"~> 0.1.0\"}]")
  end

  test "version requirements do not turn foreign or dynamic sources into local dependencies" do
    known_apps = MapSet.new(["arbor_kernel"])

    for declaration <- [
          "{:arbor_kernel, \"~> 0.1.0\", path: \"../../../arbor_kernel\"}",
          "{:arbor_kernel, \"~> 0.1.0\", path: dependency_path()}",
          "{:arbor_kernel, \"~> 0.1.0\", git: \"https://example.invalid/kernel.git\"}",
          "{:arbor_kernel, \"~> 0.1.0\", github: \"external/kernel\"}",
          "{:arbor_kernel, \"~> 0.1.0\", hex: :external_kernel}",
          "{:arbor_kernel, dependency_version()}"
        ] do
      source = "defmodule Signals.MixProject do def deps, do: [#{declaration}] end"

      assert {:ok, []} =
               Ownership.in_umbrella_deps(source, "packages/arbor_signals/mix.exs", known_apps)
    end
  end

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
