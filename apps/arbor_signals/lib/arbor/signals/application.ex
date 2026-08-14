defmodule Arbor.Signals.Application do
  @moduledoc false

  use Application

  alias Arbor.Signals.Config

  @impl true
  def start(_type, _args) do
    children =
      if Config.start_children?() do
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
    if Config.security_telemetry_bridge?() do
      Arbor.Signals.Telemetry.attach_security_bridge()
    end

    :ok
  end
end
