defmodule Arbor.Commands.StartupFootprint.ProposedApplication do
  @moduledoc false

  use Application

  @supervisor Arbor.Commands.StartupFootprint.ProposedSupervisor

  @impl true
  def start(_type, [scenario]) when scenario in ["proposed_gated", "proposed_eager"] do
    children =
      case scenario do
        "proposed_gated" -> []
        "proposed_eager" -> eager_children()
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: @supervisor
    )
  end

  def start(_type, other), do: {:error, {:invalid_proposed_scenario, other}}

  defp eager_children do
    [
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
  end
end
