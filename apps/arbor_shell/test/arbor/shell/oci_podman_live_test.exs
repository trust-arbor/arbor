defmodule Arbor.Shell.OciPodmanLiveTest do
  @moduledoc """
  Optional live checks against a distro `/usr/bin/podman`.

  Skips visibly when the binary is absent. Never greens silently.
  """

  use ExUnit.Case, async: false

  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.OciProbeRuntime

  @moduletag :podman

  @podman_path "/usr/bin/podman"
  @podman_skip_reason "podman missing at #{@podman_path}"

  if not File.regular?(@podman_path) do
    @moduletag skip: @podman_skip_reason
    # ExUnit prints skip reasons only under --trace; emit so a plain run
    # cannot look silently green.
    IO.puts(:stderr, "[arbor_shell] skipping OciPodmanLiveTest: #{@podman_skip_reason}")
  end

  test "resolves the distro podman executable" do
    assert {:ok, %Executable{path: "/usr/bin/podman"}} =
             OciProbeRuntime.resolve_executable("/usr/bin/podman")
  end

  test "oci-probe inspect of a missing digest is a podman error, not clone EPERM" do
    assert {:ok, executable} = OciProbeRuntime.resolve_executable(@podman_path)

    {:ok, env} = Arbor.Shell.OciHostEnv.resolve()
    digest = "sha256:" <> String.duplicate("0", 64)

    result =
      Arbor.Shell.Executor.run_oci_probe(
        executable,
        ["image", "inspect", digest],
        cwd: "/",
        clear_env: true,
        env: env,
        timeout: 30_000,
        max_output_bytes: 8_192
      )

    case result do
      {:ok, run} ->
        refute run.stdout =~ "pthread_create"
        refute run.stdout =~ "Operation not permitted"
        refute run.killed
        refute Map.get(run, :cancelled) == true
        assert run.exit_code != 0

      {:error, reason} ->
        refute inspect(reason) =~ "pthread_create"
        flunk("oci-probe launcher failed before podman ran: #{inspect(reason)}")
    end
  end
end
