defmodule Arbor.KernelRuntime.Application do
  @moduledoc false

  use Application

  alias Arbor.KernelRuntime.Config

  @owner_child %{
    id: Arbor.KernelRuntime.BootProfileBinding,
    start: {Arbor.KernelRuntime.BootProfileBinding, :start_link, [[]]},
    type: :worker,
    restart: :permanent
  }

  @full_children [
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
    case children_for_profile_safe() do
      {:ok, children} ->
        Supervisor.start_link(children,
          strategy: :rest_for_one,
          name: Arbor.KernelRuntime.Supervisor
        )

      {:error, _reason} = error ->
        error
    end
  end

  # Config.start_profile/0 raises ArgumentError on a malformed
  # :kernel_runtime namespace. Remap to a binding failure so
  # Application.start fails closed, later rest_for_one children
  # never start, and the VM-lifetime freeze is not replaced.
  defp children_for_profile_safe do
    children_for_profile(Config.start_profile())
  rescue
    ArgumentError -> {:error, {:boot_profile_binding_failed, :malformed_stage_zero}}
  end

  defp children_for_profile(:full), do: {:ok, [@owner_child | @full_children]}
  defp children_for_profile(:activation_only), do: {:ok, [@owner_child]}
  defp children_for_profile(other), do: {:error, {:invalid_start_profile, other}}
end
