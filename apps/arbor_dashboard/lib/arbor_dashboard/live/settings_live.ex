defmodule Arbor.Dashboard.Live.SettingsLive do
  @moduledoc """
  Settings page for the Arbor Dashboard.

  Currently houses one section: **External Agents** — register external tools
  (Claude Code, Codex, future agents) so they can authenticate to the Arbor
  cluster via per-request Ed25519 signatures (`Arbor.Gateway.SignedRequestAuth`).

  This is a thin LiveView that delegates all state management and rendering
  to `Arbor.Dashboard.Components.ExternalAgentsComponent` (socket-first
  delegate) and `Arbor.Dashboard.Cores.ExternalAgentsCore` (pure CRC).
  """

  use Phoenix.LiveView

  import Arbor.Web.Components

  alias Arbor.Dashboard.Components.ExternalAgentsComponent

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Settings")
      |> ExternalAgentsComponent.mount(nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("external_agents:" <> event, params, socket) do
    {:noreply, ExternalAgentsComponent.update_external_agents(socket, event, params)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header
      title="Settings"
      subtitle="Manage your Arbor account, integrations, and registered external agents"
    />

    <ExternalAgentsComponent.external_agents_section
      authenticated?={@authenticated?}
      external_agents_state={@external_agents_state}
      agent_types={@agent_types}
      show_register_form={@show_register_form}
      just_registered={@just_registered}
      external_agents_error={@external_agents_error}
      editing_agent_id={@editing_agent_id}
    />
    """
  end
end
