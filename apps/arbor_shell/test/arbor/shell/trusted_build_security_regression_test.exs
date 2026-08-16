Code.require_file("trusted_build_test_helpers.exs", __DIR__)

defmodule Arbor.Shell.TrustedBuildSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Shell
  alias Arbor.Shell.TrustedBuildTestHelpers, as: Helpers

  test "security regression: the test-only lease facade is not exposed on Arbor.Shell" do
    refute function_exported?(Shell, :acquire_trusted_build_lease_for_test, 2)
  end

  test "security regression: only the trusted-build facade may fork Mix; generic exec stays childless" do
    assert function_exported?(Shell, :acquire_trusted_build_lease, 1)
    assert function_exported?(Shell, :execute_trusted_build, 2)

    marker = Path.join(System.tmp_dir!(), "arbor-tb-fork-#{System.unique_integer([:positive])}")
    File.rm(marker)

    assert {:ok, result} =
             Shell.execute_direct(
               "python3",
               ["-c", "import os; os.fork(); open(#{inspect(marker)}, 'w').close()"],
               sandbox: :none,
               timeout: 5_000,
               launcher_command: "trusted-build",
               allow_fork: true
             )

    assert result.exit_code != 0
    refute File.exists?(marker)

    refute Enum.any?(
             os_processes(),
             &String.contains?(&1.command, "arbor_shell_launcher trusted-build")
           )

    if match?({:unix, :darwin}, :os.type()) do
      {lease, source_identity, handle} = start_fixture_lease!()

      try do
        watcher =
          Task.async(fn ->
            eventually?(fn ->
              Enum.any?(os_processes(), fn process ->
                String.contains?(process.command, "arbor_shell_launcher trusted-build")
              end)
            end)
          end)

        assert {:ok, deps} = Shell.execute_trusted_build(lease, "deps_get")
        assert deps.exit_code == 0
        :ok = Helpers.after_deps_get!(lease)
        assert {:ok, compile} = Shell.execute_trusted_build(lease, "compile")
        assert compile.exit_code == 0
        assert Task.await(watcher, 15_000) == true

        refute Enum.any?(
                 os_processes(),
                 &String.contains?(&1.command, "arbor_shell_launcher trusted-build")
               )
      after
        _ = Shell.release_trusted_build_lease(lease)
        _ = Shell.remove_owned_tree(source_identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  test "security regression: trusted-build environ snprintf is fail-closed on truncation" do
    if match?({:unix, :darwin}, :os.type()) do
      {handle, harness} = compile_replace_environ_harness!()

      try do
        {output, status} = System.cmd(harness, [], stderr_to_stdout: true)
        assert output == ""
        assert status == 126
      after
        assert :ok = Helpers.rm_fixture!(handle)
      end
    end
  end

  defp start_fixture_lease! do
    parent = Helpers.unique_source_root()
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    source = Path.join(parent, "source")

    _project =
      Helpers.plant_production_child_project!(
        source,
        mix_project(),
        """
        defmodule TrustedBuildFixture do
          def hello, do: :ok
        end
        """
      )

    :ok = Helpers.plant_fixed_overlay!(identity.path)

    request = %{
      "schema" => "arbor.shell.trusted_build.request.v1",
      "source" => %{
        "schema" => "arbor.shell.trusted_build.source.v1",
        "identity" => %{
          "path" => identity.path,
          "type" => "directory",
          "device" => identity.device,
          "minor_device" => identity.minor_device,
          "inode" => identity.inode
        }
      }
    }

    handle = Helpers.handle_for_owned!(identity)
    {:ok, lease, _view} = Shell.acquire_trusted_build_lease(request)
    {lease, identity, handle}
  end

  defp mix_project do
    """
    defmodule TrustedBuildFixture.MixProject do
      use Mix.Project

      def project do
        [app: :trusted_build_fixture, version: "0.1.0", elixir: "~> 1.17"]
      end

      def application do
        []
      end
    end
    """
  end

  defp os_processes do
    {output, 0} = System.cmd("ps", ["-axww", "-o", "pid=,command="])

    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(String.trim(line), " ", parts: 2) do
        [pid, command] -> %{pid: pid, command: command}
        _other -> %{pid: "", command: line}
      end
    end)
  end

  defp compile_replace_environ_harness! do
    root = Path.join(System.tmp_dir!(), "arbor-tb-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    handle = Helpers.capture_handle!(root)
    out = Path.join(root, "replace_environ_harness")
    c_src = Path.expand("../../../c_src", __DIR__)
    harness = Path.join(root, "replace_environ_harness.c")
    File.write!(harness, replace_environ_harness_source())
    archive = Path.join(c_src, "arbor_shell_archive_stat.c")

    {output, status} =
      System.cmd(
        "cc",
        [
          "-std=c11",
          "-O2",
          "-Wall",
          "-Wextra",
          "-Werror",
          "-D_POSIX_C_SOURCE=200809L",
          "-I",
          c_src,
          harness,
          archive,
          "-o",
          out
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    {handle, out}
  end

  defp replace_environ_harness_source do
    """
    #define main arbor_shell_launcher_original_main
    #include "arbor_shell_launcher.c"
    #undef main

    int main(void) {
      char erlang_root[5000];
      trusted_build_paths paths;

      memset(erlang_root, 'a', 4999U);
      erlang_root[0] = '/';
      erlang_root[4999] = '\\0';

      memset(&paths, 0, sizeof(paths));
      paths.home = "/h";
      paths.tmp = "/t";
      paths.build = "/b";
      paths.deps = "/d";
      paths.hex = "/x";
      paths.mix = "/m";
      paths.cache = "/c";
      paths.release = "/r";
      paths.source = "/s";
      paths.erlang_root = erlang_root;
      paths.elixir_root = "/e";
      paths.archives = "/a";
      trusted_build_replace_environ(&paths);
      return 0;
    }
    """
  end

  defp eventually?(fun, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        do_eventually(fun, deadline)
      else
        false
      end
    end
  end
end
