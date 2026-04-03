defmodule Arbor.Dashboard.Live.TelemetryLive do
  @moduledoc """
  Real-time agent telemetry dashboard.

  Displays per-agent token usage, cost breakdowns, tool success rates,
  latency percentiles, and routing statistics. Data refreshes every 5 seconds.

  This is a thin LiveView that delegates all state management and rendering
  to `TelemetryComponent` (socket-first delegate) and `TelemetryCore` (pure CRC).
  """

  use Phoenix.LiveView
  use Arbor.Dashboard.Live.SignalSubscription

  import Arbor.Web.Components

  alias Arbor.Dashboard.Components.TelemetryComponent

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Telemetry")
      |> TelemetryComponent.mount(nil)

    socket =
      if connected?(socket) do
        :timer.send_interval(@refresh_interval, :refresh)
        socket
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("telemetry:" <> event, params, socket) do
    {:noreply, TelemetryComponent.update_telemetry(socket, event, params)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, TelemetryComponent.update_telemetry(socket, "refresh")}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="Agent Telemetry" subtitle="Token usage, costs, latency, and tool metrics">
      <:actions>
        <button phx-click="telemetry:refresh" class="aw-btn">
          Refresh
        </button>
      </:actions>
    </.dashboard_header>

    <TelemetryComponent.overview_cards telemetry_overview={@telemetry_overview} />

    <TelemetryComponent.agent_table
      telemetry_agents={@telemetry_agents}
      sort_field={@sort_field}
    />

    <%= if @selected_agent_telemetry do %>
      <TelemetryComponent.agent_detail selected_agent_telemetry={@selected_agent_telemetry} />

      <%= if @history_loaded do %>
        <TelemetryComponent.cost_over_time history_cost_trend={@history_cost_trend} />
        <TelemetryComponent.event_timeline history_events={@history_events} />
        <TelemetryComponent.tool_failures history_tool_failures={@history_tool_failures} />
      <% end %>
    <% end %>
    """
  end
end
