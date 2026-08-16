defmodule Arbor.Shell.TrustedBuildSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Shell
  alias Arbor.Shell.TrustedBuild

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
      {lease, source_identity} = start_fixture_lease!()

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
      end
    end
  end

  defp start_fixture_lease! do
    tmp = System.tmp_dir!()
    parent = Path.join(tmp, "arbor-tb-src-#{System.unique_integer([:positive])}")
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    source = Path.join(parent, "source")
    File.mkdir_p!(Path.join(source, "lib"))
    File.mkdir_p!(Path.join(source, "bin"))
    File.write!(Path.join(source, "mix.exs"), mix_project())

    File.write!(Path.join(source, "lib/trusted_build_fixture.ex"), """
    defmodule TrustedBuildFixture do
      def hello, do: :ok
    end
    """)

    File.cp!(Path.expand("../../../../../bin/mix", __DIR__), Path.join(source, "bin/mix"))
    File.chmod!(Path.join(source, "bin/mix"), 0o755)

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

    {:ok, lease, _view} = TrustedBuild.acquire(request, :omit_hex_seed)
    {lease, identity}
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
    {output, 0} = System.cmd("ps", ["-ax", "-o", "pid=,command="])

    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(String.trim(line), " ", parts: 2) do
        [pid, command] -> %{pid: pid, command: command}
        _other -> %{pid: "", command: line}
      end
    end)
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
