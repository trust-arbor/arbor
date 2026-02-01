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
          {Arbor.Signals.Bus, []}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Signals.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
