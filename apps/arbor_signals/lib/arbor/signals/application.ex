defmodule Arbor.Signals.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_signals, :start_children, true) do
        [
          {Arbor.Signals.Store, []},
          {Arbor.Signals.TopicKeys, []},
          {Arbor.Signals.Channels, []},
          {Arbor.Signals.Bus, []},
          {Arbor.Signals.Relay, []}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Signals.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _pid} = ok ->
        attach_telemetry_bridges()
        ok

      other ->
        other
    end
  end

  defp attach_telemetry_bridges do
    if Application.get_env(:arbor_signals, :security_telemetry_bridge, true) do
      Arbor.Signals.Telemetry.attach_security_bridge()
    end

    :ok
  end
end
