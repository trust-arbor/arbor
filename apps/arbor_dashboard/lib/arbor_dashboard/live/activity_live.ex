defmodule Arbor.Dashboard.Live.ActivityLive do
  @moduledoc """
  Unified activity feed dashboard.

  Shows all system activity with agent, category, and time filtering.
  Complements SignalsLive by focusing on the "what happened" view
  with agent attribution and time ranges.
  """

  use Phoenix.LiveView

  import Arbor.Web.Components

  alias Arbor.Web.{Helpers, Icons}

  @impl true
  def mount(_params, _session, socket) do
    {activity, subscription_id} =
      if connected?(socket) do
        {safe_recent(limit: 100), safe_subscribe()}
      else
        {[], nil}
      end

    stats = compute_stats(activity)

    socket =
      socket
      |> assign(
        page_title: "Activity",
        stats: stats,
        category_filter: :all,
        time_filter: :all,
        agent_filter: nil,
        paused: false,
        selected_event: nil,
        subscription_id: subscription_id,
        categories: Map.keys(Icons.category_icons())
      )
      |> stream(:activity, activity)

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if sub_id = socket.assigns[:subscription_id] do
      try do
        Arbor.Signals.unsubscribe(sub_id)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  @impl true
  def handle_info({:signal_received, signal}, socket) do
    if socket.assigns.paused do
      {:noreply, socket}
    else
      if matches_filters?(signal, socket.assigns) do
        {:noreply, stream_insert(socket, :activity, signal, at: 0)}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle-pause", _params, socket) do
    {:noreply, assign(socket, :paused, !socket.assigns.paused)}
  end

  def handle_event("filter-category", %{"category" => "all"}, socket) do
    activity = reload_with_filters(%{socket.assigns | category_filter: :all})

    socket =
      socket
      |> assign(:category_filter, :all)
      |> assign(:stats, compute_stats(activity))
      |> stream(:activity, activity, reset: true)

    {:noreply, socket}
  end

  def handle_event("filter-category", %{"category" => category}, socket) do
    cat = String.to_existing_atom(category)
    activity = reload_with_filters(%{socket.assigns | category_filter: cat})

    socket =
      socket
      |> assign(:category_filter, cat)
      |> assign(:stats, compute_stats(activity))
      |> stream(:activity, activity, reset: true)

    {:noreply, socket}
  end

  def handle_event("filter-time", %{"range" => "all"}, socket) do
    activity = reload_with_filters(%{socket.assigns | time_filter: :all})

    socket =
      socket
      |> assign(:time_filter, :all)
      |> assign(:stats, compute_stats(activity))
      |> stream(:activity, activity, reset: true)

    {:noreply, socket}
  end

  def handle_event("filter-time", %{"range" => range}, socket) do
    range_atom = String.to_existing_atom(range)
    activity = reload_with_filters(%{socket.assigns | time_filter: range_atom})

    socket =
      socket
      |> assign(:time_filter, range_atom)
      |> assign(:stats, compute_stats(activity))
      |> stream(:activity, activity, reset: true)

    {:noreply, socket}
  end

  def handle_event("filter-agent", %{"agent" => ""}, socket) do
    activity = reload_with_filters(%{socket.assigns | agent_filter: nil})

    socket =
      socket
      |> assign(:agent_filter, nil)
      |> assign(:stats, compute_stats(activity))
      |> stream(:activity, activity, reset: true)

    {:noreply, socket}
  end

  def handle_event("filter-agent", %{"agent" => agent_id}, socket) do
    activity = reload_with_filters(%{socket.assigns | agent_filter: agent_id})

    socket =
      socket
      |> assign(:agent_filter, agent_id)
      |> assign(:stats, compute_stats(activity))
      |> stream(:activity, activity, reset: true)

    {:noreply, socket}
  end

  def handle_event("clear-filters", _params, socket) do
    activity = safe_recent(limit: 100)

    socket =
      socket
      |> assign(:category_filter, :all)
      |> assign(:time_filter, :all)
      |> assign(:agent_filter, nil)
      |> assign(:stats, compute_stats(activity))
      |> stream(:activity, activity, reset: true)

    {:noreply, socket}
  end

  def handle_event("select-event", %{"id" => signal_id}, socket) do
    signal =
      try do
        case Arbor.Signals.get_signal(signal_id) do
          {:ok, s} -> s
          _ -> nil
        end
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end

    {:noreply, assign(socket, :selected_event, signal)}
  end

  def handle_event("close-detail", _params, socket) do
    {:noreply, assign(socket, :selected_event, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="Activity" subtitle="Unified activity feed">
      <:actions>
        <button
          phx-click="toggle-pause"
          class={"aw-btn #{if @paused, do: "aw-btn-success", else: "aw-btn-warning"}"}
        >
          {if @paused, do: "Resume", else: "Pause"}
        </button>
      </:actions>
    </.dashboard_header>

    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; margin-top: 1rem;">
      <.stat_card value={@stats.event_count} label="Events" color={:blue} />
      <.stat_card value={@stats.category_count} label="Categories" color={:purple} />
      <.stat_card value={@stats.agent_count} label="Agents" color={:green} />
    </div>

    <.filter_bar>
      <button
        phx-click="filter-category"
        phx-value-category="all"
        class={"aw-filter-btn #{if @category_filter == :all, do: "aw-filter-active"}"}
      >
        All
      </button>
      <button
        :for={cat <- @categories}
        phx-click="filter-category"
        phx-value-category={cat}
        class={"aw-filter-btn #{if @category_filter == cat, do: "aw-filter-active"}"}
      >
        {Icons.category_icon(cat)} {cat}
      </button>
    </.filter_bar>

    <div style="display: flex; gap: 0.5rem; margin-top: 0.5rem; align-items: center;">
      <button
        :for={range <- [:all, :hour, :today]}
        phx-click="filter-time"
        phx-value-range={range}
        class={"aw-filter-btn #{if @time_filter == range, do: "aw-filter-active"}"}
      >
        {time_label(range)}
      </button>

      <form phx-change="filter-agent" style="display: inline; margin-left: 0.5rem;">
        <input
          type="text"
          name="agent"
          value={@agent_filter || ""}
          placeholder="Filter by agent..."
          class="aw-input"
          style="width: 180px; padding: 0.25rem 0.5rem; font-size: 0.85em;"
          phx-debounce="300"
        />
      </form>

      <button phx-click="clear-filters" class="aw-btn aw-btn-default" style="margin-left: auto;">
        Clear filters
      </button>
    </div>

    <div id="activity-stream" phx-update="stream" style="margin-top: 1rem;">
      <div
        :for={{dom_id, signal} <- @streams.activity}
        id={dom_id}
        phx-click="select-event"
        phx-value-id={signal.id}
        style="cursor: pointer;"
      >
        <.event_card
          icon={Icons.category_icon(signal.category)}
          title={"#{signal.category}.#{signal.type}"}
          subtitle={format_activity_subtitle(signal)}
          timestamp={Helpers.format_relative_time(signal.timestamp)}
        />
      </div>
    </div>

    <div :if={@stats.event_count == 0} style="margin-top: 1rem;">
      <.empty_state
        icon="📊"
        title="No activity yet"
        hint="Activity will appear here as the system operates."
      />
    </div>

    <.modal
      :if={@selected_event}
      id="activity-detail"
      show={@selected_event != nil}
      title={"#{@selected_event.category}.#{@selected_event.type}"}
      on_cancel={Phoenix.LiveView.JS.push("close-detail")}
    >
      <div class="aw-activity-detail">
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 0.75rem; margin-bottom: 1rem;">
          <div>
            <strong>ID:</strong>
            <code style="font-size: 0.85em; word-break: break-all;">{@selected_event.id}</code>
          </div>
          <div>
            <strong>Timestamp:</strong>
            <span>{Helpers.format_timestamp(@selected_event.timestamp)}</span>
          </div>
          <div :if={@selected_event.source}>
            <strong>Source:</strong>
            <span>{@selected_event.source}</span>
          </div>
          <div :if={@selected_event.correlation_id}>
            <strong>Correlation:</strong>
            <code style="font-size: 0.85em;">{@selected_event.correlation_id}</code>
          </div>
        </div>

        <div style="margin-top: 1rem;">
          <strong>Data:</strong>
          <pre style="background: var(--aw-bg-secondary, #1a1a1a); padding: 1rem; border-radius: 4px; overflow-x: auto; margin-top: 0.5rem; font-size: 0.85em;"><%= format_json(@selected_event.data) %></pre>
        </div>

        <div :if={@selected_event.metadata != %{}} style="margin-top: 1rem;">
          <strong>Metadata:</strong>
          <pre style="background: var(--aw-bg-secondary, #1a1a1a); padding: 1rem; border-radius: 4px; overflow-x: auto; margin-top: 0.5rem; font-size: 0.85em;"><%= format_json(@selected_event.metadata) %></pre>
        </div>
      </div>
    </.modal>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp time_label(:all), do: "All time"
  defp time_label(:hour), do: "Last hour"
  defp time_label(:today), do: "Today"

  defp format_activity_subtitle(signal) do
    agent = get_in(signal.data, [:agent_id]) || get_in(signal.data, ["agent_id"])
    parts = []
    parts = if agent, do: ["agent: #{agent}" | parts], else: parts
    parts = [format_signal_data(signal.data) | parts]
    Enum.join(parts, " | ")
  end

  defp format_signal_data(data) when data == %{}, do: "(empty)"

  defp format_signal_data(data) when is_map(data) do
    data
    |> Enum.take(3)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
    |> Helpers.truncate(60)
  end

  defp format_json(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(data, pretty: true)
    end
  end

  defp compute_stats(activity) do
    categories = activity |> Enum.map(& &1.category) |> Enum.uniq()

    agents =
      activity
      |> Enum.map(fn s ->
        get_in(s.data, [:agent_id]) || get_in(s.data, ["agent_id"])
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{
      event_count: length(activity),
      category_count: length(categories),
      agent_count: length(agents)
    }
  end

  defp matches_filters?(signal, assigns) do
    matches_category?(signal, assigns.category_filter) &&
      matches_agent?(signal, assigns.agent_filter) &&
      matches_time?(signal, assigns.time_filter)
  end

  defp matches_category?(_signal, :all), do: true
  defp matches_category?(signal, cat), do: signal.category == cat

  defp matches_agent?(_signal, nil), do: true

  defp matches_agent?(signal, agent_id) do
    sig_agent =
      get_in(signal.data, [:agent_id]) || get_in(signal.data, ["agent_id"]) || ""

    String.contains?(to_string(sig_agent), agent_id)
  end

  defp matches_time?(_signal, :all), do: true

  defp matches_time?(signal, :hour) do
    DateTime.diff(DateTime.utc_now(), signal.timestamp, :second) < 3600
  end

  defp matches_time?(signal, :today) do
    DateTime.diff(DateTime.utc_now(), signal.timestamp, :second) < 86_400
  end

  defp reload_with_filters(assigns) do
    opts = [limit: 100]

    opts =
      case assigns.category_filter do
        :all -> opts
        cat -> Keyword.put(opts, :category, cat)
      end

    opts =
      case assigns.time_filter do
        :all -> opts
        :hour -> Keyword.put(opts, :since, DateTime.add(DateTime.utc_now(), -3600, :second))
        :today -> Keyword.put(opts, :since, DateTime.add(DateTime.utc_now(), -86_400, :second))
      end

    activity = safe_recent(opts)

    case assigns.agent_filter do
      nil -> activity
      agent_id -> Enum.filter(activity, &matches_agent?(&1, agent_id))
    end
  end

  # ── Safe API wrappers ───────────────────────────────────────────────

  defp safe_recent(opts) do
    case Arbor.Signals.recent(opts) do
      {:ok, signals} -> signals
      _ -> []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_subscribe do
    pid = self()

    case Arbor.Signals.subscribe("*", fn signal ->
           send(pid, {:signal_received, signal})
           :ok
         end) do
      {:ok, id} -> id
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
