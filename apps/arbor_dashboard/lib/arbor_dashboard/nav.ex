defmodule Arbor.Dashboard.Nav do
  @moduledoc false
  @doc """
  LiveView on_mount hook that sets shared navigation assigns.

  Assigns `app_name`, `nav_items`, and `node_info` so the
  `Arbor.Web.Layouts` app template renders the header and nav bar.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Arbor.Dashboard.Live.{
    AgentsLive,
    ChannelsLive,
    ChatLive,
    ConsensusLive,
    EvalLive,
    EventsLive,
    LandingLive,
    MemoryLive,
    MonitorLive,
    RoadmapLive,
    SignalsLive
  }

  @nav_entries [
    %{href: "/", label: "Home", icon: "\u{1F3E0}", view: LandingLive},
    %{href: "/signals", label: "Signals", icon: "\u{1F4E1}", view: SignalsLive},
    %{href: "/eval", label: "Eval", icon: "\u{1F4CA}", view: EvalLive},
    %{href: "/consensus", label: "Consensus", icon: "\u{1F5F3}", view: ConsensusLive},
    %{href: "/events", label: "Events", icon: "\u{1F4DC}", view: EventsLive},
    %{href: "/agents", label: "Agents", icon: "\u{1F916}", view: AgentsLive},
    %{href: "/monitor", label: "Monitor", icon: "\u{1F4CA}", view: MonitorLive},
    %{href: "/roadmap", label: "Roadmap", icon: "\u{1F5FA}", view: RoadmapLive},
    %{href: "/channels", label: "Channels", icon: "\u{1F4E2}", view: ChannelsLive},
    %{href: "/chat", label: "Chat", icon: "\u{1F4AC}", view: ChatLive},
    %{href: "/memory", label: "Memory", icon: "\u{1F9E0}", view: MemoryLive}
  ]

  def on_mount(:default, _params, session, socket) do
    current_view = socket.view
    agent_id = session["agent_id"]
    display_name = session["user_display_name"]

    nav_items =
      Enum.map(@nav_entries, fn entry ->
        Map.put(entry, :active, entry.view == current_view)
      end)

    # Build TenantContext for multi-user support (nil when no OIDC session)
    tenant_context = build_tenant_context(agent_id, display_name)

    socket =
      socket
      |> assign(:app_name, "Arbor Dashboard")
      |> assign(:nav_items, nav_items)
      |> assign(:node_info, node() |> to_string())
      |> assign(:current_agent_id, agent_id)
      |> assign(:current_user_display_name, display_name)
      |> assign(:tenant_context, tenant_context)
      |> assign(:authenticated?, agent_id != nil)

    {:cont, socket}
  end

  defp build_tenant_context(nil, _display_name), do: nil

  defp build_tenant_context(agent_id, display_name) do
    if Code.ensure_loaded?(Arbor.Contracts.TenantContext) do
      workspace_root =
        apply(Arbor.Contracts.TenantContext, :default_workspace_root, [agent_id])

      opts =
        [workspace_root: workspace_root] ++
          if(display_name, do: [display_name: display_name], else: [])

      apply(Arbor.Contracts.TenantContext, :new, [agent_id, opts])
    end
  end
end
