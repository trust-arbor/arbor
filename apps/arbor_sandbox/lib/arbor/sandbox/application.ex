defmodule Arbor.Sandbox.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_sandbox, :start_children, true) do
        [Arbor.Sandbox.Registry]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Sandbox.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
