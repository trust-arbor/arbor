defmodule Arbor.Shell.OciUnitRuntimeTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.OciUnitRuntime

  @moduletag :fast
  @moduletag :security_regression

  test "security regression: unreviewed argv is refused before PortSession" do
    executable = podman_executable()

    assert {:error, :unreviewed_oci_unit_command} =
             OciUnitRuntime.start_command(
               executable,
               ["run", "--network", "bridge", "sha256:" <> String.duplicate("a", 64)],
               "podman unit",
               :standard,
               []
             )
  end

  test "security regression: non-podman executable is refused" do
    executable = %{podman_executable() | path: "/bin/sh"}

    assert {:error, :untrusted_path} =
             OciUnitRuntime.start_command(
               executable,
               ["ps", "-a", "--format", "json"],
               "podman unit",
               :standard,
               []
             )
  end

  test "security regression: caller cannot select a launcher mode through opts" do
    executable = podman_executable()

    assert {:error, :invalid_runtime_command} =
             OciUnitRuntime.start_command(
               executable,
               ["ps", "-a", "--format", "json"],
               "podman unit",
               :standard,
               launcher_command: "exec"
             )
  end

  defp podman_executable do
    %Executable{
      name: "podman",
      path: "/usr/bin/podman",
      device: 1,
      inode: 2,
      size: 100,
      mtime: 1,
      ctime: 1,
      mode: 0o100755,
      sha256: String.duplicate("a", 64)
    }
  end
end
