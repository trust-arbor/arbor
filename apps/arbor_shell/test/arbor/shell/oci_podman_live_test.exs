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
end
