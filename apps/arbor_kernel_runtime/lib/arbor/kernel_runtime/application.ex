defmodule Arbor.KernelRuntime.Application do
  @moduledoc false

  use Application

  alias Arbor.KernelRuntime.Config

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
    case children_for_profile(Config.start_profile()) do
      {:ok, children} ->
        Supervisor.start_link(children,
          strategy: :one_for_one,
          name: Arbor.KernelRuntime.Supervisor
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp children_for_profile(:full), do: {:ok, @full_children}
  defp children_for_profile(:activation_only), do: {:ok, []}
  defp children_for_profile(other), do: {:error, {:invalid_start_profile, other}}
end
