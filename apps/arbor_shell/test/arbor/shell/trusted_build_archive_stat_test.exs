Code.require_file("trusted_build_test_helpers.exs", __DIR__)

defmodule Arbor.Shell.TrustedBuildArchiveStatTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell.TrustedBuildTestHelpers, as: Helpers

  test "launcher compiler tracks the archive stat header without compiling it" do
    units = Enum.map(Mix.Tasks.Compile.ArborShellLauncher.translation_units(), &Path.expand/1)
    headers = Enum.map(Mix.Tasks.Compile.ArborShellLauncher.header_dependencies(), &Path.expand/1)
    deps = Enum.map(Mix.Tasks.Compile.ArborShellLauncher.dependency_inputs(), &Path.expand/1)
    header = Path.expand("../../../c_src/arbor_shell_archive_stat.h", __DIR__)

    assert Enum.all?(units, &String.ends_with?(&1, ".c"))
    refute Enum.any?(units, &String.ends_with?(&1, ".h"))
    assert header in headers
    assert header in deps
    refute header in units

    {handle, root} = dest_container!()

    try do
      copied_units =
        Enum.map(units, fn unit ->
          dest = Path.join(root, Path.basename(unit))
          File.cp!(unit, dest)
          dest
        end)

      copied_header = Path.join(root, Path.basename(header))
      File.cp!(header, copied_header)
      target = Path.join(root, "dummy_target")
      File.write!(target, "old")

      now = System.os_time(:second)
      Enum.each(copied_units, &File.touch!(&1, now - 180))
      File.touch!(target, now - 60)
      File.touch!(copied_header, now)

      assert Mix.Utils.stale?(copied_units ++ [copied_header], [target])
      refute Mix.Utils.stale?(copied_units, [target])
    after
      assert :ok = Helpers.rm_fixture!(handle)
    end
  end

  test "synthetic archive stat predicate rejects uid, writable, symlink, and hardlink" do
    {handle, harness} = compile_harness!()

    try do
      assert {_, 1} = run_harness(harness, ["euid+1", "444", "reg", "1"])
      assert {_, 1} = run_harness(harness, ["euid", "666", "reg", "1"])
      assert {_, 1} = run_harness(harness, ["euid", "622", "reg", "1"])
      assert {_, 1} = run_harness(harness, ["euid", "444", "lnk", "1"])
      assert {_, 1} = run_harness(harness, ["euid", "444", "reg", "2"])
      assert {output, 0} = run_harness(harness, ["euid", "444", "reg", "1"])
      assert String.trim(output) == "allow"
      assert {_, 0} = run_harness(harness, ["euid", "555", "dir", "2"])
    after
      assert :ok = Helpers.rm_fixture!(handle)
    end
  end

  defp dest_container! do
    root = Path.join(System.tmp_dir!(), "arbor-tb-stale-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {Helpers.capture_handle!(root), root}
  end

  defp compile_harness! do
    root = Path.join(System.tmp_dir!(), "arbor-tb-harness-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    handle = Helpers.capture_handle!(root)
    out = Path.join(root, "archive_stat_harness")
    c_src = Path.expand("../../../c_src", __DIR__)
    harness = Path.expand("../native/archive_stat_harness.c", __DIR__)

    {output, status} =
      System.cmd(
        "cc",
        [
          "-std=c11",
          "-Wall",
          "-Wextra",
          "-Werror",
          "-I",
          c_src,
          Path.join(c_src, "arbor_shell_archive_stat.c"),
          harness,
          "-o",
          out
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    {handle, out}
  end

  defp run_harness(harness, args) do
    System.cmd(harness, args, stderr_to_stdout: true)
  end
end
