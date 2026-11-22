defmodule Arbor.Dashboard.Feature do
  @moduledoc """
  Passive description of the current Dashboard Application entrypoint.

  children/1 accepts exactly %{start_children: boolean()}. The boolean is the
  already resolved effective owner setting; this callback does not read or
  supply its runtime default. An empty list is valid only for the explicit
  disabled branch and does not mean that the application or its code is absent.

  No child-spec producer, endpoint, session helper or request is invoked.
  Malformed direct calls raise a fixed redacted ArgumentError. Inputs belong
  to trusted owner plumbing; a map shape does not authenticate its origin.

  Empty action/URI lists mean no additional DIRECT Application entrypoint
  global catalog/provider contribution, not global absence. Routes report
  explicit source declarations and delegated macro ownership, not every
  generated leaf URL. Health remains unobserved.
  """

  @behaviour Arbor.Contracts.Feature

  @invalid_snapshot "invalid feature snapshot"

  @impl true
  def id, do: :dashboard

  @impl true
  def requires, do: [:core]

  @impl true
  @spec children(map()) :: [Supervisor.child_spec()]
  def children(%{start_children: enabled} = snapshot) when is_boolean(enabled) do
    if map_size(snapshot) == 1 do
      if enabled do
        [
          %{
            id: Phoenix.PubSub.Supervisor,
            start: {Phoenix.PubSub.Supervisor, :start_link, [[name: Arbor.Dashboard.PubSub]]},
            type: :supervisor
          },
          %{
            id: Arbor.Dashboard.Endpoint,
            start: {Arbor.Dashboard.Endpoint, :start_link, [[]]},
            type: :supervisor
          }
        ]
      else
        []
      end
    else
      invalid_snapshot!()
    end
  end

  def children(_snapshot), do: invalid_snapshot!()

  @impl true
  def action_modules, do: []

  @impl true
  def uri_prefixes, do: []

  @impl true
  def routes do
    [
      %{kind: :live, path: "/", owner: Arbor.Dashboard.Live.ConversationLive},
      %{kind: :live, path: "/console", owner: Arbor.Dashboard.Live.LandingLive},
      %{kind: :live, path: "/signals", owner: Arbor.Dashboard.Live.SignalsLive},
      %{kind: :live, path: "/eval", owner: Arbor.Dashboard.Live.EvalLive},
      %{kind: :live, path: "/consensus", owner: Arbor.Dashboard.Live.ConsensusLive},
      %{kind: :live, path: "/events", owner: Arbor.Dashboard.Live.EventsLive},
      %{kind: :live, path: "/agents", owner: Arbor.Dashboard.Live.AgentsLive},
      %{kind: :live, path: "/monitor", owner: Arbor.Dashboard.Live.MonitorLive},
      %{kind: :live, path: "/roadmap", owner: Arbor.Dashboard.Live.RoadmapLive},
      %{kind: :live, path: "/home", owner: Arbor.Dashboard.Live.ConversationLive},
      %{kind: :live, path: "/c/:engagement_id", owner: Arbor.Dashboard.Live.ConversationLive},
      %{
        kind: :live,
        path: "/conversation/:agent_id",
        owner: Arbor.Dashboard.Live.ConversationLive
      },
      %{kind: :live, path: "/channels", owner: Arbor.Dashboard.Live.ChannelsLive},
      %{kind: :live, path: "/memory", owner: Arbor.Dashboard.Live.MemoryLive},
      %{kind: :live, path: "/memory/:agent_id", owner: Arbor.Dashboard.Live.MemoryLive},
      %{kind: :live, path: "/telemetry", owner: Arbor.Dashboard.Live.TelemetryLive},
      %{kind: :live, path: "/settings", owner: Arbor.Dashboard.Live.SettingsLive},
      %{
        kind: :route,
        method: "GET",
        path: "/chat",
        owner: Arbor.Dashboard.LegacyChatController,
        action: :index
      },
      %{
        kind: :delegated_router_macro,
        owner: Arbor.Web.Router,
        scope: "/",
        coverage: :delegated_unexpanded
      }
    ]
  end

  @impl true
  def health, do: %{status: :unobserved}

  defp invalid_snapshot!, do: raise(ArgumentError, @invalid_snapshot)
end
