defmodule Arbor.Trust.Application do
  @moduledoc false

  use Application

  alias Arbor.Trust.ProviderGate

  @provider_gate Arbor.Trust.ProviderGate
  @supervisor Arbor.Trust.ApplicationSupervisor

  @impl true
  def start(_type, _args) do
    with {:ok, profile} <- closed_start_profile() do
      start_profile(profile, start_children())
    end
  end

  @doc false
  @spec closed_start_profile() :: {:ok, :full | :activation_only} | {:error, term()}
  def closed_start_profile do
    case Arbor.KernelRuntime.Config.start_profile() do
      :full -> {:ok, :full}
      :activation_only -> {:ok, :activation_only}
      other -> {:error, {:invalid_start_profile, other}}
    end
  rescue
    ArgumentError -> {:error, {:invalid_start_profile, :malformed_namespace}}
  end

  defp start_children do
    Application.get_env(:arbor_trust, :start_children, true)
  end

  # PolicyHost is mandatory reference-monitor infrastructure. start_children
  # may suppress Arbor.Trust.Supervisor (Store/Manager/etc.) but not the host.
  # The provider gate is omitted when those consumers are suppressed.
  defp start_profile(:activation_only, _start_children) do
    Supervisor.start_link([policy_host_child(:activation_only)],
      strategy: :rest_for_one,
      name: @supervisor
    )
  end

  defp start_profile(:full, true) do
    Arbor.KernelRuntime.start_provider_gate_supervisor(
      [
        policy_host_child(:full),
        ProviderGate.child_spec([]),
        {Arbor.Trust.Supervisor, []}
      ],
      @supervisor,
      @provider_gate
    )
  end

  defp start_profile(:full, _start_children) do
    Supervisor.start_link([policy_host_child(:full)],
      strategy: :rest_for_one,
      name: @supervisor
    )
  end

  defp policy_host_child(profile) do
    {Arbor.Trust.PolicyHost, [start_profile: profile]}
  end
end
