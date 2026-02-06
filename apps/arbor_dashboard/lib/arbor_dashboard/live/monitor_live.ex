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

  import Arbor.Web.Components

  @refresh_interval 2_000
  @history_limit 20

  @impl true
  def mount(_params, _session, socket) do
    subscription_id =
      if connected?(socket) do
        :timer.send_interval(@refresh_interval, :refresh)
        subscribe_to_signals()
      else
        nil
      end

    socket =
      socket
      |> assign(:page_title, "Monitor")
      |> assign(:metrics, safe_fetch_metrics())
      |> assign(:anomalies, safe_fetch_anomalies())
      |> assign(:status, safe_fetch_status())
      |> assign(:selected_skill, nil)
      |> assign(:history, %{})
      |> assign(:subscription_id, subscription_id)

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if sub_id = socket.assigns[:subscription_id] do
      safe_unsubscribe(sub_id)
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    metrics = safe_fetch_metrics()

    socket =
      socket
      |> assign(:metrics, metrics)
      |> assign(:anomalies, safe_fetch_anomalies())
      |> assign(:status, safe_fetch_status())
      |> update_history(metrics)

    {:noreply, socket}
  end

  def handle_info({:signal_received, _signal}, socket) do
    # Refresh on any monitor signal
    {:noreply, assign(socket, anomalies: safe_fetch_anomalies())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_skill", %{"skill" => skill}, socket) do
    skill_atom = safe_to_existing_atom(skill)

    selected =
      if socket.assigns.selected_skill == skill_atom do
        nil
      else
        skill_atom
      end

    {:noreply, assign(socket, selected_skill: selected)}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, selected_skill: nil)}
  end

  def handle_event("refresh", _params, socket) do
    # Trigger a metrics collection
    safe_collect()

    socket =
      socket
      |> assign(:metrics, safe_fetch_metrics())
      |> assign(:anomalies, safe_fetch_anomalies())
      |> assign(:status, safe_fetch_status())

    {:noreply, socket}
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
      <div class={"aw-monitor-health-indicator aw-health-#{@status.status}"}>
        <span class="aw-health-dot"></span>
        <span class="aw-health-label">{format_status(@status.status)}</span>
      </div>
      <div class="aw-monitor-stats">
        <span class="aw-monitor-stat">
          <strong>{@status.anomaly_count}</strong> anomalies
        </span>
        <span class="aw-monitor-stat">
          <strong>{length(@status.skills)}</strong> skills active
        </span>
      </div>
    </div>

    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; margin-top: 1rem;">
      <%= for skill <- @status.skills do %>
        <.skill_card
          skill={skill}
          data={Map.get(@metrics, skill, %{})}
          selected={@selected_skill == skill}
        />
      <% end %>

      <%= if @status.skills == [] do %>
        <.empty_state
          icon="📊"
          title="No skills available"
          hint="Monitor skills will appear here when arbor_monitor is running."
        />
      <% end %>
    </div>

    <div class="aw-monitor-section" style="margin-top: 2rem;">
      <h2 style="font-size: 1.1rem; font-weight: 600; margin-bottom: 1rem;">Recent Anomalies</h2>
      <%= if @anomalies == [] do %>
        <.empty_state
          icon="✅"
          title="No anomalies detected"
          hint="The system is running smoothly."
        />
      <% else %>
        <div class="aw-anomaly-list">
          <%= for anomaly <- @anomalies do %>
            <.anomaly_card anomaly={anomaly} />
          <% end %>
        </div>
      <% end %>
    </div>

    <.modal
      :if={@selected_skill}
      id="skill-detail"
      show={@selected_skill != nil}
      title={format_skill_name(@selected_skill)}
      on_cancel={Phoenix.LiveView.JS.push("close_detail")}
    >
      <.skill_detail
        skill={@selected_skill}
        data={Map.get(@metrics, @selected_skill, %{})}
        history={Map.get(@history, @selected_skill, [])}
      />
    </.modal>
    """
  end

  # ============================================================================
  # Components
  # ============================================================================

  defp skill_card(assigns) do
    ~H"""
    <div
      class={"aw-skill-card #{if @selected, do: "aw-skill-card-selected"}"}
      phx-click="select_skill"
      phx-value-skill={@skill}
    >
      <div class="aw-skill-header">
        <span class="aw-skill-icon">{skill_icon(@skill)}</span>
        <span class="aw-skill-name">{format_skill_name(@skill)}</span>
      </div>
      <div class="aw-skill-summary">
        {skill_summary(@skill, @data)}
      </div>
    </div>
    """
  end

  defp anomaly_card(assigns) do
    severity = Map.get(assigns.anomaly, :severity, :info)
    assigns = assign(assigns, :severity, severity)

    ~H"""
    <div class={"aw-anomaly-card aw-severity-#{@severity}"}>
      <div class="aw-anomaly-header">
        <span class="aw-anomaly-severity">{severity_icon(@severity)}</span>
        <span class="aw-anomaly-metric">{@anomaly[:metric] || "unknown"}</span>
      </div>
      <div class="aw-anomaly-body">
        <div class="aw-anomaly-value">
          Current: <strong>{format_value(@anomaly[:value])}</strong>
        </div>
        <div class="aw-anomaly-baseline">
          Baseline: {format_value(@anomaly[:baseline])}
        </div>
        <%= if @anomaly[:deviation] do %>
          <div class="aw-anomaly-deviation">
            {Float.round(@anomaly[:deviation] * 1.0, 1)} stddev
          </div>
        <% end %>
      </div>
      <div class="aw-anomaly-time">
        {format_time(@anomaly[:detected_at] || @anomaly[:timestamp])}
      </div>
    </div>
    """
  end

  defp skill_detail(assigns) do
    ~H"""
    <div class="aw-skill-detail">
      <div class="aw-skill-metrics">
        <%= if @data == %{} do %>
          <p class="aw-text-gray">No metrics available</p>
        <% else %>
          <%= for {key, value} <- flatten_metrics(@data) do %>
            <div class="aw-metric-row">
              <span class="aw-metric-key">{key}</span>
              <span class="aw-metric-value">{format_value(value)}</span>
            </div>
          <% end %>
        <% end %>
      </div>

      <%= if @history != [] do %>
        <div class="aw-skill-history" style="margin-top: 1rem;">
          <h4 style="font-size: 0.875rem; color: var(--aw-text-secondary); margin-bottom: 0.5rem;">
            Recent Values
          </h4>
          <div class="aw-history-values">
            <%= for val <- Enum.take(@history, 10) do %>
              <span class="aw-history-value">{format_value(val)}</span>
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

  defp subscribe_to_signals do
    pid = self()

    case safe_subscribe("monitor.*", fn signal ->
           send(pid, {:signal_received, signal})
           :ok
         end) do
      {:ok, id} -> id
      _ -> nil
    end
  end

  defp safe_subscribe(pattern, callback) do
    Arbor.Signals.subscribe(pattern, callback)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp safe_unsubscribe(nil), do: :ok

  defp safe_unsubscribe(id) do
    Arbor.Signals.unsubscribe(id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

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

  defp update_history(socket, metrics) do
    history = socket.assigns.history

    new_history =
      Enum.reduce(metrics, history, fn {skill, data}, acc ->
        # Extract a representative value for history tracking
        value = extract_primary_value(skill, data)
        existing = Map.get(acc, skill, [])
        updated = [value | existing] |> Enum.take(@history_limit)
        Map.put(acc, skill, updated)
      end)

    assign(socket, history: new_history)
  end

  defp extract_primary_value(:memory, data), do: data[:total_mb]
  defp extract_primary_value(:processes, data), do: data[:count]
  defp extract_primary_value(:ets, data), do: data[:table_count]
  defp extract_primary_value(:scheduler, data), do: data[:total_utilization]
  defp extract_primary_value(:gc, data), do: data[:total_collections]
  defp extract_primary_value(_skill, data) when is_map(data), do: map_size(data)
  defp extract_primary_value(_skill, _data), do: nil

  defp format_status(:healthy), do: "Healthy"
  defp format_status(:warning), do: "Warning"
  defp format_status(:critical), do: "Critical"
  defp format_status(:emergency), do: "Emergency"
  defp format_status(_), do: "Unknown"

  defp skill_icon(:beam), do: "🔮"
  defp skill_icon(:memory), do: "💾"
  defp skill_icon(:ets), do: "📊"
  defp skill_icon(:processes), do: "⚙️"
  defp skill_icon(:supervisor), do: "👁️"
  defp skill_icon(:system), do: "🖥️"
  defp skill_icon(:gc), do: "🗑️"
  defp skill_icon(:allocator), do: "📦"
  defp skill_icon(:ports), do: "🔌"
  defp skill_icon(:scheduler), do: "📅"
  defp skill_icon(_), do: "📈"

  defp format_skill_name(skill) when is_atom(skill) do
    skill
    |> to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_skill_name(skill), do: to_string(skill)

  defp skill_summary(:memory, data), do: "#{data[:total_mb] || "?"}MB used"
  defp skill_summary(:processes, data), do: "#{data[:count] || "?"}procs"
  defp skill_summary(:ets, data), do: "#{data[:table_count] || "?"}tables"
  defp skill_summary(:scheduler, data), do: "#{data[:total_utilization] || "?"}%util"
  defp skill_summary(:gc, data), do: "#{data[:total_collections] || "?"}GCs"
  defp skill_summary(:ports, data), do: "#{data[:count] || "?"}ports"
  defp skill_summary(:system, data), do: "#{data[:otp_release] || "?"}"
  defp skill_summary(:beam, data), do: "v#{data[:version] || "?"}"
  defp skill_summary(_, data) when map_size(data) > 0, do: "#{map_size(data)} metrics"
  defp skill_summary(_, _), do: "-"

  defp severity_icon(:emergency), do: "🚨"
  defp severity_icon(:critical), do: "❌"
  defp severity_icon(:warning), do: "⚠️"
  defp severity_icon(:info), do: "ℹ️"
  defp severity_icon(_), do: "📋"

  defp flatten_metrics(data) when is_map(data) do
    Enum.flat_map(data, fn
      {k, v} when is_map(v) ->
        Enum.map(v, fn {k2, v2} -> {"#{k}.#{k2}", v2} end)

      {k, v} ->
        [{to_string(k), v}]
    end)
    |> Enum.sort_by(fn {k, _} -> k end)
  end

  defp flatten_metrics(_), do: []

  defp format_value(v) when is_float(v), do: Float.round(v, 2)
  defp format_value(v) when is_integer(v), do: v
  defp format_value(nil), do: "-"
  defp format_value(v), do: inspect(v)

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
