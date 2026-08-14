# Probe-only fixture; not a production application.
defmodule ArborKernelStartupFootprintProbe.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      case scenario() do
        "proposed_gated" ->
          []

        "proposed_eager" ->
          eager_children()

        other ->
          raise "refusing to start proposed application for #{inspect(other)}"
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: ArborKernelStartupFootprintProbe.Supervisor
    )
  end

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

  defp scenario do
    System.get_env("ARBOR_STARTUP_FOOTPRINT_SCENARIO") || "proposed_gated"
  end
end
