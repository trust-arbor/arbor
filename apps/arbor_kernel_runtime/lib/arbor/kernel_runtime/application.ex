defmodule Arbor.KernelRuntime.Application do
  @moduledoc false

  use Application

  alias Arbor.KernelRuntime.Config
  alias Arbor.KernelRuntime.ProviderGate

  @provider_gate Arbor.KernelRuntime.ProviderGate
  @supervisor Arbor.KernelRuntime.Supervisor

  @owner_child %{
    id: Arbor.KernelRuntime.BootProfileBinding,
    start: {Arbor.KernelRuntime.BootProfileBinding, :start_link, [[]]},
    type: :worker,
    restart: :permanent
  }

  @full_dependents [
    %{
      id: Arbor.Common.Application,
      start: {Arbor.Common.Application, :start, [:normal, []]},
      type: :supervisor
    },
    %{
      id: Arbor.Signals.Application,
      start: {Arbor.Signals.Application, :start, [:normal, []]},
      type: :supervisor
    },
    %{
      id: Arbor.Monitor.Application,
      start: {Arbor.Monitor.Application, :start, [:normal, []]},
      type: :supervisor
    }
  ]

  @impl true
  def start(_type, _args) do
    case admit_profile() do
      {:ok, :activation_only} ->
        Supervisor.start_link([@owner_child], strategy: :rest_for_one, name: @supervisor)

      {:ok, :full} ->
        start_full()

      {:error, _reason} = error ->
        error
    end
  end

  # Config.start_profile/0 raises ArgumentError on a malformed
  # :kernel_runtime namespace. Remap to a binding failure so
  # Application.start fails closed, later rest_for_one children
  # never start, and the VM-lifetime freeze is not replaced.
  defp admit_profile do
    case Config.start_profile() do
      :full -> {:ok, :full}
      :activation_only -> {:ok, :activation_only}
      other -> {:error, {:invalid_start_profile, other}}
    end
  rescue
    ArgumentError -> {:error, {:boot_profile_binding_failed, :malformed_stage_zero}}
  end

  defp start_full do
    Arbor.KernelRuntime.start_provider_gate_supervisor(
      [@owner_child, ProviderGate.child_spec([])] ++ @full_dependents,
      @supervisor,
      @provider_gate
    )
  end
end
