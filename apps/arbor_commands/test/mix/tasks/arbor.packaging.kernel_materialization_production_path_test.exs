defmodule Mix.Tasks.Arbor.Packaging.KernelMaterializationProductionPathTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.KernelMaterialization
  alias Arbor.Commands.KernelMaterialization.{Core, Encode}
  alias Arbor.Commands.SourceCoupling
  alias Mix.Tasks.Arbor.Packaging.KernelMaterialization, as: Task

  @moduletag :slow
  @moduletag timeout: 300_000

  test "production path projects the accepted inventory and planned check is stable" do
    root = umbrella_root()

    assert {:ok, report} =
             SourceCoupling.with_direct_runtime(fn ->
               KernelMaterialization.run(mode: "report", phase: "planned", root: root, json: true)
             end)

    assert report["schema"] == "arbor.packaging.kernel_materialization.report.v1"
    assert report["phase"] == "planned"

    counts = report["counts"]
    assert counts["source_entries"] == 640
    assert counts["exact_moves"] == 610
    assert counts["transform_inputs"] == 30
    assert counts["collision_destinations"] == 4

    assert {:ok, check} =
             SourceCoupling.with_direct_runtime(fn ->
               KernelMaterialization.run(mode: "check", phase: "planned", root: root, json: true)
             end)

    assert {:ok, check_again} =
             SourceCoupling.with_direct_runtime(fn ->
               KernelMaterialization.run(mode: "check", phase: "planned", root: root, json: true)
             end)

    assert check["status"] == "ok",
           "planned check failed: #{inspect(get_in(check, ["comparison", "failures"]))}"

    assert {:ok, bytes} = Encode.encode_report(check)
    assert {:ok, bytes_again} = Encode.encode_report(check_again)
    assert bytes == bytes_again

    plan_path =
      Path.join(root, "apps/arbor_commands/priv/packaging/kernel_materialization_plan.v1.json")

    assert File.regular?(plan_path)
    {:ok, raw} = File.read(plan_path)
    {:ok, plan} = Jason.decode(raw)
    assert {:ok, admitted} = Core.admit_plan(plan)
    assert :ok = Core.enforce_production_policy(admitted)
    assert admitted["counts"]["source_entries"] == 640
    assert admitted["entries_digest"] != String.duplicate("0", 64)
    assert byte_size(admitted["entries_digest"]) == 64

    retained = Map.new(admitted["retained_targets"], &{&1["path"], &1["disposition"]})
    assert retained["apps/arbor_kernel/mix.exs"] == "transform_input"
    assert retained["apps/arbor_kernel/test/test_helper.exs"] == "transform_input"
    assert retained["apps/arbor_kernel/lib/arbor/kernel.ex"] == "retain"

    assert {:ok, via_task} = Task.execute(["--check", "--phase", "planned", "--root", root])
    assert via_task["status"] == "ok"
    assert via_task["phase"] == "planned"
  end

  test "standalone Mix task uses direct runtime and does not start arbor_shell" do
    root = umbrella_root()
    build_path = Mix.Project.build_path() <> "-k4a-standalone-dev"

    {output, status} =
      System.cmd(
        Path.join(root, "bin/mix"),
        [
          "arbor.packaging.kernel_materialization",
          "--check",
          "--phase",
          "planned",
          "--root",
          root
        ],
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
    assert output =~ "kernel-materialization check phase=planned"
    assert output =~ "runtime=direct"
    refute output =~ "git_shell_unavailable"
    refute output =~ "journal"
    refute output =~ "container"
  end

  test "production-path root finder uses stable markers, not contracts" do
    assert {:ok, root} = KernelMaterialization.discover_root(__DIR__)
    assert File.regular?(Path.join(root, "mix.exs"))
    assert File.regular?(Path.join([root, "apps", "arbor_commands", "mix.exs"]))
    assert File.regular?(Path.join([root, "apps", "arbor_kernel", "mix.exs"]))
    refute Path.basename(root) == "arbor_contracts"
  end

  defp umbrella_root do
    find_root(__DIR__)
  end

  defp find_root(dir) do
    cond do
      File.regular?(Path.join(dir, "mix.exs")) and
        File.regular?(Path.join([dir, "apps", "arbor_commands", "mix.exs"])) and
          File.regular?(Path.join([dir, "apps", "arbor_kernel", "mix.exs"])) ->
        dir

      Path.dirname(dir) == dir ->
        raise "umbrella root not found"

      true ->
        find_root(Path.dirname(dir))
    end
  end
end
