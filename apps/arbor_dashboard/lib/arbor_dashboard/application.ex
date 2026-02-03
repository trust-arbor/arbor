defmodule Arbor.Dashboard.Application do
  @moduledoc false

  use Application

  alias Arbor.Dashboard.Endpoint

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_dashboard, :start_children, true) do
        [
          {Phoenix.PubSub, name: Arbor.Dashboard.PubSub},
          Endpoint
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Dashboard.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Endpoint.config_change(changed, removed)
    :ok
  end
end
