defmodule Arbor.Dashboard.Live.MonitorLive do
  @moduledoc """
  Real-time BEAM monitoring dashboard.

  Displays runtime metrics collected by Arbor.Monitor skills with real-time
  anomaly detection and visualization. Shows overall system health status,
  per-skill metrics cards, and a list of recent anomalies.

  ## Signal Integration

  Subscribes to `monitor.*` signals for real-time updates when anomalies
  are detected or escalations occur.
  """

  use Phoenix.LiveView
  use Arbor.Dashboard.Live.SignalSubscription

  import Arbor.Web.Components

  alias Arbor.Dashboard.Cores.MonitorCore

  @refresh_interval 2_000

  @impl true
  def mount(_params, _session, socket) do
    state = MonitorCore.new(safe_fetch_metrics(), safe_fetch_anomalies(), safe_fetch_status())

    socket =
      socket
      |> assign(:page_title, "Monitor")
      |> assign(:monitor_state, state)
      |> assign(:dashboard, MonitorCore.show_dashboard(state))

    socket =
      if connected?(socket) do
        :timer.send_interval(@refresh_interval, :refresh)

        subscribe_signals(socket, "monitor.*", fn s ->
          new_state =
            MonitorCore.update_data(
              s.assigns.monitor_state,
              s.assigns.monitor_state.metrics,
              safe_fetch_anomalies(),
              s.assigns.monitor_state.status
            )

          s
          |> assign(:monitor_state, new_state)
          |> assign(:dashboard, MonitorCore.show_dashboard(new_state))
        end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    new_state =
      MonitorCore.update_data(
        socket.assigns.monitor_state,
        safe_fetch_metrics(),
        safe_fetch_anomalies(),
        safe_fetch_status()
      )

    {:noreply,
     socket
     |> assign(:monitor_state, new_state)
     |> assign(:dashboard, MonitorCore.show_dashboard(new_state))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_skill", %{"skill" => skill}, socket) do
    skill_atom = safe_to_existing_atom(skill)
    new_state = MonitorCore.select_skill(socket.assigns.monitor_state, skill_atom)

    {:noreply,
     socket
     |> assign(:monitor_state, new_state)
     |> assign(:dashboard, MonitorCore.show_dashboard(new_state))}
  end

  def handle_event("close_detail", _params, socket) do
    new_state = MonitorCore.select_skill(socket.assigns.monitor_state, nil)

    {:noreply,
     socket
     |> assign(:monitor_state, new_state)
     |> assign(:dashboard, MonitorCore.show_dashboard(new_state))}
  end

  def handle_event("refresh", _params, socket) do
    # Trigger a metrics collection
    safe_collect()

    new_state =
      MonitorCore.update_data(
        socket.assigns.monitor_state,
        safe_fetch_metrics(),
        safe_fetch_anomalies(),
        safe_fetch_status()
      )

    {:noreply,
     socket
     |> assign(:monitor_state, new_state)
     |> assign(:dashboard, MonitorCore.show_dashboard(new_state))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="BEAM Runtime Monitor" subtitle="System health and anomaly detection">
      <:actions>
        <button phx-click="refresh" class="aw-btn">
          Refresh
        </button>
      </:actions>
    </.dashboard_header>

    <div class="aw-monitor-status-bar">
      <div class={"aw-monitor-health-indicator aw-health-#{@dashboard.status_card.status_code}"}>
        <span class="aw-health-dot"></span>
        <span class="aw-health-label">{@dashboard.status_card.status_label}</span>
      </div>
      <div class="aw-monitor-stats">
        <span class="aw-monitor-stat">
          <strong>{@dashboard.status_card.anomaly_count}</strong> anomalies
        </span>
        <span class="aw-monitor-stat">
          <strong>{@dashboard.status_card.skill_count}</strong> skills active
        </span>
      </div>
    </div>

    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; margin-top: 1rem;">
      <%= for card <- @dashboard.skill_cards do %>
        <.skill_card card={card} />
      <% end %>

      <%= if @dashboard.skill_cards == [] do %>
        <.empty_state
          icon="📊"
          title="No skills available"
          hint="Monitor skills will appear here when arbor_monitor is running."
        />
      <% end %>
    </div>

    <div class="aw-monitor-section" style="margin-top: 2rem;">
      <h2 style="font-size: 1.1rem; font-weight: 600; margin-bottom: 1rem;">Recent Anomalies</h2>
      <%= if @dashboard.anomaly_cards == [] do %>
        <.empty_state
          icon="✅"
          title="No anomalies detected"
          hint="The system is running smoothly."
        />
      <% else %>
        <div class="aw-anomaly-list">
          <%= for anomaly <- @dashboard.anomaly_cards do %>
            <.anomaly_card anomaly={anomaly} />
          <% end %>
        </div>
      <% end %>
    </div>

    <.modal
      :if={@dashboard.selected_skill_detail}
      id="skill-detail"
      show={@dashboard.selected_skill_detail != nil}
      title={@dashboard.selected_skill_detail.name}
      on_cancel={Phoenix.LiveView.JS.push("close_detail")}
    >
      <.skill_detail detail={@dashboard.selected_skill_detail} />
    </.modal>
    """
  end

  # ============================================================================
  # Components
  # ============================================================================

  defp skill_card(assigns) do
    ~H"""
    <div
      class={"aw-skill-card #{if @card.selected, do: "aw-skill-card-selected"}"}
      phx-click="select_skill"
      phx-value-skill={@card.key}
    >
      <div class="aw-skill-header">
        <span class="aw-skill-icon">{@card.icon}</span>
        <span class="aw-skill-name">{@card.name}</span>
      </div>
      <div class="aw-skill-summary">
        {@card.summary}
      </div>
    </div>
    """
  end

  defp anomaly_card(assigns) do
    ~H"""
    <div class={"aw-anomaly-card aw-severity-#{@anomaly.severity}"}>
      <div class="aw-anomaly-header">
        <span class="aw-anomaly-severity">{@anomaly.severity_icon}</span>
        <span class="aw-anomaly-metric">{@anomaly.metric}</span>
      </div>
      <div class="aw-anomaly-body">
        <div class="aw-anomaly-value">
          Current: <strong>{@anomaly.value}</strong>
        </div>
        <div class="aw-anomaly-baseline">
          Baseline: {@anomaly.baseline}
        </div>
        <%= if @anomaly.deviation do %>
          <div class="aw-anomaly-deviation">{@anomaly.deviation}</div>
        <% end %>
      </div>
      <div class="aw-anomaly-time">
        {format_time(@anomaly.detected_at)}
      </div>
    </div>
    """
  end

  defp skill_detail(assigns) do
    ~H"""
    <div class="aw-skill-detail">
      <div class="aw-skill-metrics">
        <%= if @detail.flat_metrics == [] do %>
          <p class="aw-text-gray">No metrics available</p>
        <% else %>
          <%= for {key, value} <- @detail.flat_metrics do %>
            <div class="aw-metric-row">
              <span class="aw-metric-key">{key}</span>
              <span class="aw-metric-value">{MonitorCore.format_value(value)}</span>
            </div>
          <% end %>
        <% end %>
      </div>

      <%= if @detail.history != [] do %>
        <div class="aw-skill-history" style="margin-top: 1rem;">
          <h4 style="font-size: 0.875rem; color: var(--aw-text-secondary); margin-bottom: 0.5rem;">
            Recent Values
          </h4>
          <div class="aw-history-values">
            <%= for val <- @detail.history do %>
              <span class="aw-history-value">{val}</span>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp safe_fetch_metrics do
    Arbor.Monitor.metrics()
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp safe_fetch_anomalies do
    Arbor.Monitor.anomalies()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_fetch_status do
    Arbor.Monitor.status()
  rescue
    _ -> %{status: :unknown, anomaly_count: 0, skills: [], metrics_available: []}
  catch
    :exit, _ -> %{status: :unknown, anomaly_count: 0, skills: [], metrics_available: []}
  end

  defp safe_collect do
    Arbor.Monitor.collect()
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  # Display formatting (icons, labels, primary values, summaries) lives in
  # MonitorCore. The LiveView only handles signal subscription, GenServer
  # fetches, and rendering pre-shaped data.

  defp format_time(nil), do: "-"

  defp format_time(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> "-"
    end
  end

  defp format_time(_), do: "-"

  defp safe_to_existing_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end

  defp safe_to_existing_atom(_), do: nil
end
