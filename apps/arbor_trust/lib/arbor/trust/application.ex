defmodule Arbor.Trust.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_trust, :start_children, true) do
        [{Arbor.Trust.Supervisor, []}]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Trust.ApplicationSupervisor]
    Supervisor.start_link(children, opts)
  end
end
