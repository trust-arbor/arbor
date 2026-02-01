defmodule Arbor.Checkpoint.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Arbor.Checkpoint.Store.ETS, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Arbor.Checkpoint.Supervisor)
  end
end
