defmodule Arbor.Shell.TrustedBuildProcessGroupTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell
  alias Arbor.Shell.ExecutablePolicy
  alias Arbor.Shell.Executor
  alias Arbor.Shell.ProcessGroup

  test "generic run_bound cannot select trusted-build through options" do
    {:ok, executable} = ExecutablePolicy.resolve("python3")

    {:ok, result} =
      Executor.run_bound(
        executable,
        ["-c", "import os; os.fork(); print('unexpected-fork')"],
        allow_fork: true,
        fork_mode: :allow,
        execution_mode: :trusted_build,
        launcher_command: "trusted-build",
        timeout: 5_000
      )

    assert result.exit_code != 0
    refute result.stdout =~ "unexpected-fork"
    refute result.timed_out
    refute result.killed
  end

  test "native trusted-build rejects malformed argv without launching mix" do
    launcher = launcher_path()

    {port, ref} =
      open_launcher([
        "trusted-build",
        "1000",
        "1024",
        "--",
        "/bin/echo",
        "hello"
      ])

    assert_receive {^port, {:data, <<4, message::binary>>}}, 2_000
    assert message =~ "invalid trusted-build"
    Port.close(port)
    Process.demonitor(ref, [:flush])
  end

  test "run_trusted_build_executable is the only ProcessGroup entry that names trusted-build" do
    assert function_exported?(ProcessGroup, :run_trusted_build_executable, 6)
    refute function_exported?(ProcessGroup, :run_executable_with_launcher, 7)

    {:ok, result} =
      Shell.execute_direct("python3", ["-c", "import os; os.fork(); print('forked')"],
        sandbox: :none,
        timeout: 5_000,
        launcher_command: "trusted-build"
      )

    assert result.exit_code != 0
    refute result.stdout =~ "forked"
  end

  defp launcher_path do
    :arbor_shell
    |> :code.priv_dir()
    |> List.to_string()
    |> Path.join("arbor_shell_launcher")
  end

  defp open_launcher(args) do
    port =
      Port.open({:spawn_executable, to_charlist(launcher_path())}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:packet, 4},
        args: Enum.map(args, &to_charlist/1)
      ])

    {port, Port.monitor(port)}
  end
end
