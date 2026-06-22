defmodule Arbor.Comms.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Arbor.Comms.PubSub is the canonical bus for HITL InteractionRouter
    # traffic (presence, dashboard adapter broadcasts, per-agent response
    # topic). Owning it here — at the lowest library that needs it — means
    # the router infrastructure is reachable regardless of whether higher
    # libraries (dashboard, gateway) are present in the umbrella. Without
    # this, Comms.Supervisor.maybe_add_interaction_router ran before any
    # other PubSub existed and skipped starting the router pieces silently.
    children = [
      {Phoenix.PubSub, name: Arbor.Comms.PubSub},
      # Owns the Engagement ETS tables for the app's lifetime (see
      # Arbor.Comms.EngagementStore — direct ETS API, GenServer is just the
      # long-lived table owner). Started before the Supervisor so engagements
      # resolve stably from boot.
      Arbor.Comms.EngagementStore,
      Arbor.Comms.Supervisor
    ]

    opts = [strategy: :one_for_one, name: Arbor.Comms.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
