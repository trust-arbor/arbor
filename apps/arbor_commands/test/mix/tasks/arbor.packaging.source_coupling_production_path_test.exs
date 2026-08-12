defmodule Mix.Tasks.Arbor.Packaging.SourceCouplingProductionPathTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.SourceCoupling
  alias Mix.Tasks.Arbor.Packaging.SourceCoupling, as: Task

  @moduletag :slow
  @moduletag timeout: 300_000

  test "production report path returns census with provisional_delta series" do
    root = umbrella_root()

    # Prefer injected-free Git inventory against the real worktree.
    assert {:ok, report} =
             SourceCoupling.run(
               mode: "report",
               root: root,
               json: true
             )

    assert report["schema"] == "arbor.packaging.source_coupling.report.v1"
    assert is_map(report["provenance"])
    assert is_binary(report["provenance"]["scan_manifest_digest"])
    assert is_binary(report["provenance"]["tree_oid"])
    assert is_map(report["provisional_delta"]["undeclared"])
    assert is_map(report["provisional_delta"]["level_hierarchy"])
    assert is_map(report["provisional_delta"]["band_fate"])

    u = report["undeclared"]["occurrence_count"]
    pairs = report["undeclared"]["app_pair_count"]
    unresolved = report["unresolved"]["count"]
    # General all-occurrence census metrics (unchanged surface).
    all_level_up = report["summaries"]["hierarchy_direction"]["level_upward"]
    all_fate = report["summaries"]["fate"]
    # Provisional series must report the undeclared occurrence universe.
    prov_fate = report["provisional_delta"]["band_fate"]["actual"]
    prov_level_up = report["provisional_delta"]["level_hierarchy"]["actual"]["level_upward"]
    undeclared_fate = report["undeclared"]["fate"]

    # Exact counts for Arbor evidence log (values depend on tree).
    assert is_integer(u) and u >= 0
    assert is_integer(pairs) and pairs >= 0
    assert is_integer(unresolved) and unresolved >= 0
    assert is_integer(all_level_up) and all_level_up >= 0
    assert is_integer(all_fate["intra_band"])
    assert is_integer(all_fate["downward"])
    assert is_integer(all_fate["upward"])
    assert is_map(undeclared_fate)
    assert prov_fate["intra_band"] == undeclared_fate["intra_band"]
    assert prov_fate["downward"] == undeclared_fate["downward"]
    assert prov_fate["upward"] == undeclared_fate["upward"]
    assert prov_level_up == report["undeclared"]["upward_occurrence_count"]

    IO.puts("""
    source-coupling production report counts:
      undeclared_occurrences=#{u}
      app_pairs=#{pairs}
      unresolved=#{unresolved}
      all_occurrence level_upward=#{all_level_up}
      all_occurrence band_fate intra=#{all_fate["intra_band"]} downward=#{all_fate["downward"]} upward=#{all_fate["upward"]}
      provisional_undeclared band_fate intra=#{prov_fate["intra_band"]} downward=#{prov_fate["downward"]} upward=#{prov_fate["upward"]}
      provisional_undeclared level_upward=#{prov_level_up}
      scan_manifest_digest=#{report["provenance"]["scan_manifest_digest"]}
      tree_oid=#{report["provenance"]["tree_oid"]}
    """)
  end

  test "production check against committed baseline is clean (reviewed baseline gate)" do
    root = umbrella_root()

    baseline =
      Path.join(root, "apps/arbor_commands/priv/packaging/source_coupling_baseline.v1.json")

    assert File.regular?(baseline),
           "reviewed baseline must be committed at #{baseline} — regenerate via --write-baseline"

    assert {:ok, report} = SourceCoupling.run(mode: "check", root: root, baseline: baseline)

    failure_count = get_in(report, ["baseline", "failure_count"])

    assert report["mode"] == "check"

    assert report["status"] == "ok",
           "source-coupling drifted from the reviewed baseline: #{inspect(get_in(report, ["baseline", "failures"]))}"

    assert failure_count == 0

    IO.puts(
      "source-coupling production check status=#{report["status"]} failures=#{failure_count}"
    )
  end

  test "mix task execute wires report mode" do
    root = umbrella_root()
    assert {:ok, report} = Task.execute(["--root", root, "--json"])
    assert report["schema"] == "arbor.packaging.source_coupling.report.v1"
  end

  test "standalone Mix task starts its shell runtime dependency" do
    root = umbrella_root()

    # `MIX_ENV=test` is not usable here: config/test.exs sets
    # `config :arbor_shell, start_children: false` so ordinary test runs
    # don't spin up shell subsystem processes, which would make this
    # assertion (arbor_shell actually starting its runtime) vacuous. Keep
    # `dev`, matching real standalone/production task usage, but derive an
    # isolated build path from this test run's own build root (never the
    # worktree/canonical ambient `_build/dev`, which may carry stale state
    # compiled against a different DB adapter). Set `ARBOR_DB` explicitly so
    # the fresh build doesn't inherit a Postgres selection from the parent
    # shell and mismatch the SQLite topology this test run uses.
    build_path = Mix.Project.build_path() <> "-standalone-dev"

    {output, status} =
      System.cmd(
        Path.join(root, "bin/mix"),
        ["arbor.packaging.source_coupling", "--root", root],
        cd: root,
        env: [
          {"MIX_ENV", "dev"},
          {"ARBOR_DB", "sqlite"},
          {"MIX_DEPS_PATH", System.get_env("MIX_DEPS_PATH") || Path.join(root, "deps")},
          {"MIX_BUILD_PATH", build_path}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "source-coupling report status="
    refute output =~ "git_shell_unavailable"
  end

  test "production-path compatibility: private module references tracked Arbor module" do
    root = umbrella_root()

    # Use a stable tracked module that exists in the real umbrella.
    tracked_module = "Arbor.Contracts"

    private_files = [
      %{
        path: "apps/arbor_integrations/mix.exs",
        blob_oid: String.duplicate("1", 64),
        bytes: """
        defmodule Arbor.Integrations.MixProject do
          use Mix.Project
          def project do
            [app: :arbor_integrations, deps: [{:arbor_contracts, in_umbrella: true}]]
          end
        end
        """
      },
      %{
        path: "apps/arbor_integrations/lib/private_tracked_ref.ex",
        blob_oid: String.duplicate("2", 64),
        bytes: """
        defmodule Arbor.Integrations.PrivateTrackedRef do
          @moduledoc false
          def ping, do: #{tracked_module}.__info__(:module)
        end
        """
      }
    ]

    # Baseline: production Git census without compatibility.
    assert {:ok, baseline_report} =
             SourceCoupling.run(
               mode: "report",
               root: root,
               json: true
             )

    # Compatibility injection is test-only; production run rejects it.
    assert {:error, {:production_opts_forbid_synthetic, _}} =
             SourceCoupling.run(
               mode: "report",
               root: root,
               compatibility_integrations: true,
               compatibility_files: private_files
             )

    assert {:ok, report} =
             SourceCoupling.run_for_test(
               mode: "report",
               root: root,
               json: true,
               compatibility_integrations: true,
               compatibility_files: private_files
             )

    compat = report["compatibility"]
    assert is_map(compat)
    assert compat["gating"] == false
    assert compat["source"] == "private_opt_in"
    assert compat["file_count"] == 2

    occ =
      Enum.find(compat["occurrences"] || [], fn o ->
        o["target"] == tracked_module and o["from_app"] == "arbor_integrations"
      end)

    assert occ,
           "expected private→tracked occurrence for #{tracked_module}, got: #{inspect(compat["occurrences"])}"

    assert occ["to_app"] == "arbor_contracts"
    assert occ["from_band"] == "private"
    assert occ["fate"] == "private_to_tracked"

    # Real proof: canonical gating/baseline inputs identical with vs without compat.
    assert baseline_report["provenance"]["scan_manifest_digest"] ==
             report["provenance"]["scan_manifest_digest"]

    assert baseline_report["provenance"]["tree_oid"] == report["provenance"]["tree_oid"]

    assert baseline_report["undeclared"]["occurrence_count"] ==
             report["undeclared"]["occurrence_count"]

    assert baseline_report["undeclared"]["app_pair_count"] ==
             report["undeclared"]["app_pair_count"]

    assert baseline_report["summaries"]["hierarchy_direction"] ==
             report["summaries"]["hierarchy_direction"]

    assert baseline_report["summaries"]["fate"] == report["summaries"]["fate"]

    assert baseline_report["unresolved"]["count"] == report["unresolved"]["count"]

    undeclared_files =
      (report["undeclared"]["findings"] || [])
      |> Enum.map(& &1["file"])

    refute Enum.any?(undeclared_files, &String.contains?(&1, "arbor_integrations"))

    assert report["output"] == "json"
    assert report["write_plan"] == nil
  end

  defp umbrella_root do
    find_root(__DIR__)
  end

  defp find_root(dir) do
    cond do
      File.exists?(Path.join([dir, "apps", "arbor_contracts", "mix.exs"])) -> dir
      Path.dirname(dir) == dir -> raise "umbrella root not found"
      true -> find_root(Path.dirname(dir))
    end
  end
end
