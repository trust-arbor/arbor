defmodule Arbor.Trust.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    with {:ok, profile} <- closed_start_profile(),
         {:ok, children} <- children_for(profile, start_children()) do
      Supervisor.start_link(children,
        strategy: :rest_for_one,
        name: Arbor.Trust.ApplicationSupervisor
      )
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

  defp children_for(_profile, start_children) when start_children in [false, nil] do
    {:ok, []}
  end

  defp children_for(:activation_only, _start_children) do
    {:ok, [policy_host_child(:activation_only)]}
  end

  defp children_for(:full, _start_children) do
    {:ok, [policy_host_child(:full), {Arbor.Trust.Supervisor, []}]}
  end

  defp policy_host_child(profile) do
    {Arbor.Trust.PolicyHost, [start_profile: profile]}
  end
end
