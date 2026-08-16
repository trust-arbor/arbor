Code.require_file("trusted_build_test_helpers.exs", __DIR__)

defmodule Arbor.Shell.TrustedBuildUnavailableTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell
  alias Arbor.Shell.TrustedBuildTestHelpers, as: Helpers

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

      assert {:error, :owned_tree_not_registered} = Shell.acquire_trusted_build_lease(request)
      refute launcher_running?()

      parent = Helpers.unique_source_root()
      {:ok, identity} = Shell.create_private_owned_tree(parent)
      handle = Helpers.handle_for_owned!(identity)
      source = Path.join(parent, "source")

      _project =
        Helpers.plant_production_child_project!(
          source,
          """
          defmodule TrustedBuildFixture.MixProject do
            use Mix.Project
            def project, do: [app: :trusted_build_fixture, version: "0.1.0"]
            def application, do: []
          end
          """,
          "defmodule TrustedBuildFixture, do: def hello, do: :ok\n"
        )

      :ok = Helpers.plant_fixed_overlay!(identity.path)

      try do
        assert {:error, :trusted_build_unavailable} =
                 Shell.acquire_trusted_build_lease(request_for(identity))

        refute launcher_running?()
      after
        _ = Shell.remove_owned_tree(identity)
        assert :ok = Helpers.rm_fixture!(handle)
      end
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

  defp request_for(identity) do
    %{
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
