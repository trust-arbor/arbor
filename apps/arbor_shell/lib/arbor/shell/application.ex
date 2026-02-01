defmodule Arbor.Shell.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_shell, :start_children, true) do
        [{Arbor.Shell.ExecutionRegistry, []}]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Shell.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
