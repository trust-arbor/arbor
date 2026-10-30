defmodule Arbor.Security.TestSupport.PlatformRuntimeHost do
  @moduledoc false

  @behaviour Arbor.Security.Contracts.RuntimeHost

  # Actual public snapshot captured after the legacy runtime's real boot handshake.
  # The adjacent provenance receipt records the source commit, source hashes and
  # successful private baseline compile/capture. Only this owned test fixture is read.
  @snapshot_path Path.expand("platform_runtime_boot_profile_snapshot.json", __DIR__)
  @external_resource @snapshot_path
  @snapshot @snapshot_path |> File.read!() |> Jason.decode!()

  @impl true
  def prepare_startup, do: :ok

  @impl true
  def start_profile, do: :full

  @impl true
  def boot_profile, do: {:ok, @snapshot}

  @impl true
  def provider_gate_child_spec(_name, _roots), do: {:error, :test_runtime_has_no_provider_gate}

  @impl true
  def start_provider_gate_supervisor(_children, _supervisor, _gate),
    do: {:error, :test_runtime_has_no_provider_gate}
end
