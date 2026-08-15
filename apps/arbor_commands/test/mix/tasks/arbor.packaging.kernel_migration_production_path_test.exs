defmodule Mix.Tasks.Arbor.Packaging.KernelMigrationProductionPathTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.KernelMigration
  alias Arbor.Commands.KernelMigration.Encode
  alias Arbor.Commands.SourceCoupling
  alias Mix.Tasks.Arbor.Packaging.KernelMigration, as: Task

  @moduletag :slow
  @moduletag timeout: 300_000

  test "production path derives current inventory and complete disposition coverage" do
    root = umbrella_root()

    report_path =
      Path.join(root, "apps/arbor_commands/priv/packaging/kernel_migration_report.v1.json")

    assert File.regular?(report_path),
           "checked-in kernel_migration_report.v1.json must exist at #{report_path}"

    assert {:ok, report} =
             KernelMigration.run(
               mode: "report",
               root: root,
               json: true
             )

    assert report["schema"] == "arbor.packaging.kernel_migration.report.v1"
    assert is_binary(report["identity"])
    assert byte_size(report["identity"]) == 64
    assert report["provenance"]["scan_manifest_digest"]
    refute Map.has_key?(report["provenance"], "tree_oid")

    runtime = report["counts"]["runtime"]
    mix_task = report["counts"]["mix_task"]
    total = report["counts"]["total"]

    assert is_integer(runtime) and runtime > 0
    assert is_integer(mix_task) and mix_task > 0
    assert total == runtime + mix_task

    committed_digest =
      report["provenance"]["scan_manifest_digest"]

    expected_scan =
      get_in(report, ["provenance", "scan_manifest_digest"])

    assert committed_digest == expected_scan

    if runtime == 22 and mix_task == 20 do
      assert total == 42
      assert report["counts"]["dispositions"] == 22
      assert report["counts"]["boundary"] == 22
      assert report["counts"]["formatter"] == 38

      disp_ids = MapSet.new(report["runtime"], & &1["finding_id"])
      reviewed = MapSet.new(report["dispositions"], & &1["finding_id"])
      assert disp_ids == reviewed

      refute Enum.any?(report["boundary"], &(&1["target"] == "Arbor.Agent.Character"))

      assert Enum.any?(report["boundary"], &(&1["target"] == "LLMDB"))
      assert Enum.any?(report["boundary"], &(&1["target"] == "Ecto.Adapters.Postgres"))

      assert Enum.all?(report["formatter"], fn row ->
               String.starts_with?(row["proof_destination"], "apps/arbor_kernel/")
             end)
    else
      flunk(
        "source_scan_drift: expected 22 runtime / 20 mix_task, got #{runtime}/#{mix_task} " <>
          "scan_manifest_digest=#{report["provenance"]["scan_manifest_digest"]}"
      )
    end

    assert {:ok, check} = KernelMigration.run(mode: "check", root: root, json: true)
    assert {:ok, check_again} = KernelMigration.run(mode: "check", root: root, json: true)
    assert {:ok, check_bytes} = Encode.encode_report(check)
    assert {:ok, check_again_bytes} = Encode.encode_report(check_again)
    assert check_bytes == check_again_bytes
    assert File.read!(report_path) == check_bytes

    if runtime == 22 and mix_task == 20 do
      assert check["status"] == "ok",
             "kernel-migration check failed: #{inspect(get_in(check, ["comparison", "failures"]))}"
    end
  end

  test "mix task execute wires report mode through direct runtime" do
    root = umbrella_root()
    assert {:ok, report} = Task.execute(["--root", root, "--json"])
    assert report["schema"] == "arbor.packaging.kernel_migration.report.v1"
  end

  test "standalone Mix task uses direct runtime and does not start arbor_shell" do
    root = umbrella_root()
    build_path = Mix.Project.build_path() <> "-km-standalone-dev"

    {output, status} =
      System.cmd(
        Path.join(root, "bin/mix"),
        ["arbor.packaging.kernel_migration", "--root", root],
        cd: root,
        env: [
          {"MIX_ENV", "dev"},
          {"ARBOR_DB", "sqlite"},
          {"MIX_DEPS_PATH", System.get_env("MIX_DEPS_PATH") || Path.join(root, "deps")},
          {"MIX_BUILD_PATH", build_path}
        ],
        stderr_to_stdout: true
      )

    assert status in [0, 1], output
    assert output =~ "kernel-migration report status="
    assert output =~ "runtime=direct"
    refute output =~ "git_shell_unavailable"
    refute output =~ "journal"
    refute output =~ "container"
  end

  test "census helper is production-safe" do
    root = umbrella_root()
    assert {:ok, census} = SourceCoupling.census(root: root)
    assert is_list(census["classified_edges"])
    assert census["classified_edges"] != []
  end

  defp umbrella_root do
    {:ok, root} = Arbor.Commands.PackagingRoot.discover(__DIR__)
    root
  end
end
