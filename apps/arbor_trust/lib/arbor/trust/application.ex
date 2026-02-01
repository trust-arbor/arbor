defmodule Arbor.Trust.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Arbor.Trust.Supervisor, []}
    ]

    opts = [strategy: :one_for_one, name: Arbor.Trust.ApplicationSupervisor]
    Supervisor.start_link(children, opts)
  end
end
