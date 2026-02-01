defmodule Arbor.Checkpoint.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_checkpoint, :start_children, true) do
        [{Arbor.Checkpoint.Store.ETS, []}]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Arbor.Checkpoint.Supervisor)
  end
end
