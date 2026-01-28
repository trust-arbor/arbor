defmodule Arbor.Persistence.Ecto.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # EventStore is started conditionally based on config
      # Users add it to their supervision tree with:
      #   {Arbor.Persistence.Ecto.EventStore, []}
    ]

    opts = [strategy: :one_for_one, name: Arbor.Persistence.Ecto.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
