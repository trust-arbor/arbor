defmodule Arbor.Signals.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Arbor.Signals.Store, []},
      {Arbor.Signals.TopicKeys, []},
      {Arbor.Signals.Channels, []},
      {Arbor.Signals.Bus, []}
    ]

    opts = [strategy: :one_for_one, name: Arbor.Signals.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
