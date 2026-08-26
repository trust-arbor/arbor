defmodule Arbor.Shell.OciPodmanLiveTest do
  @moduledoc """
  Optional live checks against a distro `/usr/bin/podman`.

  Skips visibly when the binary is absent. Never greens silently.
  """

  use ExUnit.Case, async: false

  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.OciProbeRuntime

  @moduletag :podman

  if not File.regular?("/usr/bin/podman") do
    @moduletag skip: "podman missing at /usr/bin/podman"
  end

  test "resolves the distro podman executable" do
    assert {:ok, %Executable{path: "/usr/bin/podman"}} =
             OciProbeRuntime.resolve_executable("/usr/bin/podman")
  end
end
