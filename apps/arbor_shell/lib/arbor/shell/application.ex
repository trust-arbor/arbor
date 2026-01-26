defmodule Arbor.Shell.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Arbor.Shell.ExecutionRegistry, []}
    ]

    opts = [strategy: :one_for_one, name: Arbor.Shell.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
