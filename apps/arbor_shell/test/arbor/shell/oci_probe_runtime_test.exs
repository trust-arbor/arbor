defmodule Arbor.Shell.OciProbeRuntimeTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell.OciProbeRuntime, as: Runtime

  @moduletag :fast
  @moduletag :security_regression

  @digest "sha256:" <> String.duplicate("a", 64)

  test "security regression: OCI probe uses oci-probe launcher not generic exec" do
    source = File.read!(Path.expand("../../../lib/arbor/shell/oci_probe_runtime.ex", __DIR__))

    assert source =~ "Executor.run_oci_probe"
    refute source =~ "Executor.run_bound("
  end

  test "security regression: launcher C reviews sha256 hex inspect and skips no-fork for oci-probe" do
    source = File.read!(Path.expand("../../../c_src/arbor_shell_launcher.c", __DIR__))

    assert source =~ "EXECUTION_OCI_PROBE"
    assert source =~ "reviewed_oci_probe"
    assert source =~ "unreviewed OCI probe command"
    assert source =~ "oci-probe"
    assert source =~ "PR_SET_NO_NEW_PRIVS so rootless podman"
  end

  test "security regression: inspect of a non-digest reference is refused before execution" do
    assert {:error, :unreviewed_oci_probe_command} =
             Runtime.authorize_probe_args(["image", "inspect", "validation:latest"], %{
               image: @digest
             })

    assert {:error, :unreviewed_oci_probe_command} =
             Runtime.authorize_probe_args(["image", "inspect", "sha256:not-a-digest"], %{
               image: @digest
             })
  end
end
