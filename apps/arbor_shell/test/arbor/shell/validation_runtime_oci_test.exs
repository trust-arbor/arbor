defmodule Arbor.Shell.ValidationRuntime.OciTest do
  use ExUnit.Case, async: false

  alias Arbor.Shell.ValidationRuntime.Authority
  alias Arbor.Shell.ValidationRuntime.Oci

  @moduletag :fast

  test "implements the ValidationRuntime behaviour" do
    Code.ensure_loaded!(Oci)
    assert function_exported?(Oci, :execute, 3)
    assert function_exported?(Oci, :probe, 0)
    assert function_exported?(Oci, :public_status, 0)

    status = Oci.public_status()
    assert status["driver"] == "podman"
    refute Map.has_key?(status, "path")
    refute Map.has_key?(status, "implementation")
    refute inspect(status) =~ "OciExecutor"
    refute inspect(status) =~ "/usr/bin/podman"
    refute inspect(status) =~ "sha256:"
  end

  test "public status never includes paths, digests, PIDs, or module names" do
    status = Oci.public_status()
    encoded = Jason.encode!(status)
    refute encoded =~ "podman unit"
    refute encoded =~ "Arbor.Shell"
    refute encoded =~ "#PID"
    refute encoded =~ "sha256:"
  end

  test "Authority injects Oci and execute goes there" do
    name = :"validation_runtime_oci_#{System.unique_integer([:positive])}"
    boot_epoch = make_ref()

    {:ok, pid} =
      Authority.start_link(name: name, boot_epoch: boot_epoch, implementation: Oci)

    Process.unlink(pid)

    on_exit(fn ->
      Authority.clear_boot_epoch(boot_epoch)
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    end)

    assert {:ok, Oci} = Authority.checkout_implementation(pid)
    status = Authority.public_status(pid)
    assert status["state"] == "pinned"
    assert status["driver"] == "podman"
    refute inspect(status) =~ "Oci"

    assert {:error, {:invalid_tool_name, :relative_path}} =
             Oci.execute("mix", ["compile"], [])
  end
end
