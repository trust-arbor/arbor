Code.require_file("trusted_build_test_helpers.exs", __DIR__)

defmodule Arbor.Shell.TrustedBuildArchiveStatTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell.TrustedBuildTestHelpers, as: Helpers

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
