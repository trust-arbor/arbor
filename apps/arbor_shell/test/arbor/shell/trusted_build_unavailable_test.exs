defmodule Arbor.Shell.TrustedBuildUnavailableTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell

  test "non-Darwin acquire does not execute the wrapper" do
    if match?({:unix, :darwin}, :os.type()) do
      assert function_exported?(Shell, :acquire_trusted_build_lease, 1)
    else
      request = %{
        "schema" => "arbor.shell.trusted_build.request.v1",
        "source" => %{
          "schema" => "arbor.shell.trusted_build.source.v1",
          "identity" => %{
            "path" => "/tmp/arbor-tb-missing",
            "type" => "directory",
            "device" => 1,
            "minor_device" => 0,
            "inode" => 1
          }
        }
      }

      assert {:error, :trusted_build_unavailable} = Shell.acquire_trusted_build_lease(request)
      refute launcher_running?()
    end
  end

  test "native trusted-build is unavailable off Apple" do
    unless match?({:unix, :darwin}, :os.type()) do
      launcher =
        :arbor_shell
        |> :code.priv_dir()
        |> List.to_string()
        |> Path.join("arbor_shell_launcher")

      port =
        Port.open({:spawn_executable, to_charlist(launcher)}, [
          :binary,
          :exit_status,
          :use_stdio,
          {:packet, 4},
          args: [~c"trusted-build", ~c"1000", ~c"1024"]
        ])

      assert_receive {^port, {:data, <<4, message::binary>>}}, 2_000
      assert message =~ "unavailable"
      Port.close(port)
    end
  end

  defp launcher_running? do
    Enum.any?(os_processes(), &String.contains?(&1.command, "arbor_shell_launcher trusted-build"))
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
end
