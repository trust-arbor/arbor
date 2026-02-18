defmodule Arbor.Dashboard.Live.EventsLive do
  @moduledoc """
  Persisted events dashboard backed by Arbor.Historian.

  Shows durable history entries from the event log with category,
  time, and agent filtering. Unlike SignalsLive (real-time stream),
  this view shows persisted historical events with manual refresh.
  """

  use Phoenix.LiveView

  import Arbor.Web.Components


  alias Arbor.Web.{Helpers, Icons}

  @refresh_interval :timer.seconds(30)

  @impl true
  def mount(_params, _session, socket) do
    {events, stats, categories} =
      if connected?(socket) do
        events = safe_recent(limit: 100)
        stats = safe_stats()
        dist = safe_category_distribution()
        cats = dist |> Map.keys() |> Enum.sort()
        Process.send_after(self(), :auto_refresh, @refresh_interval)
        {events, stats, cats}
      else
        {[], default_stats(), []}
      end

    socket =
      socket
      |> assign(
        page_title: "Events",
        stats: stats,
        category_filter: :all,
        time_filter: :all,
        agent_filter: nil,
        selected_event: nil,
        categories: categories,
        event_count: length(events)
      )
      |> stream(:events, events)

    {:ok, socket}
  end

  @impl true
  def handle_info(:auto_refresh, socket) do
    Process.send_after(self(), :auto_refresh, @refresh_interval)
    {:noreply, reload_events(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, reload_events(socket)}
  end

  def handle_event("filter-category", %{"category" => "all"}, socket) do
    socket =
      socket
      |> assign(:category_filter, :all)
      |> reload_events()

    {:noreply, socket}
  end

  def handle_event("filter-category", %{"category" => category}, socket) do
    cat = String.to_existing_atom(category)

    socket =
      socket
      |> assign(:category_filter, cat)
      |> reload_events()

    {:noreply, socket}
  end

  def handle_event("filter-time", %{"range" => range}, socket) do
    range_atom =
      case range do
        "all" -> :all
        "hour" -> :hour
        "today" -> :today
        _ -> :all
      end

    socket =
      socket
      |> assign(:time_filter, range_atom)
      |> reload_events()

    {:noreply, socket}
  end

  def handle_event("filter-agent", %{"agent" => ""}, socket) do
    socket =
      socket
      |> assign(:agent_filter, nil)
      |> reload_events()

    {:noreply, socket}
  end

  def handle_event("filter-agent", %{"agent" => agent_id}, socket) do
    socket =
      socket
      |> assign(:agent_filter, agent_id)
      |> reload_events()

    {:noreply, socket}
  end

  def handle_event("clear-filters", _params, socket) do
    socket =
      socket
      |> assign(:category_filter, :all)
      |> assign(:time_filter, :all)
      |> assign(:agent_filter, nil)
      |> reload_events()

    {:noreply, socket}
  end

  def handle_event("select-event", %{"id" => event_id}, socket) do
    # Find event from the current stream by re-querying
    events = fetch_filtered_events(socket.assigns)
    event = Enum.find(events, fn e -> e.id == event_id end)

    {:noreply, assign(socket, :selected_event, event)}
  end

  def handle_event("close-detail", _params, socket) do
    {:noreply, assign(socket, :selected_event, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="Events" subtitle="Persisted event history">
      <:actions>
        <button phx-click="refresh" class="aw-btn aw-btn-default">
          Refresh
        </button>
      </:actions>
    </.dashboard_header>

    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; margin-top: 1rem;">
      <.stat_card value={@stats.total_events} label="Total Events" color={:blue} />
      <.stat_card value={@stats.stream_count} label="Streams" color={:purple} />
      <.stat_card value={length(@categories)} label="Categories" color={:green} />
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

      <button
        :if={@category_filter != :all or @time_filter != :all or @agent_filter != nil}
        phx-click="clear-filters"
        class="aw-btn aw-btn-default"
        style="margin-left: auto;"
      >
        Clear filters
      </button>
    </div>

    <div id="events-stream" phx-update="stream" style="margin-top: 1rem;">
      <div
        :for={{dom_id, event} <- @streams.events}
        id={dom_id}
        phx-click="select-event"
        phx-value-id={event.id}
        style="cursor: pointer;"
      >
        <.event_card
          icon={Icons.category_icon(event.category)}
          title={"#{event.category}.#{event.type}"}
          subtitle={format_event_subtitle(event)}
          timestamp={Helpers.format_relative_time(event.timestamp)}
        />
      </div>
    </div>

    <div :if={@event_count == 0} style="margin-top: 1rem;">
      <.empty_state
        icon="\u{1F4DC}"
        title="No events recorded"
        hint="Events will appear here as they are persisted by the historian."
      />
    </div>

    <.modal
      :if={@selected_event}
      id="event-detail"
      show={@selected_event != nil}
      title={"#{@selected_event.category}.#{@selected_event.type}"}
      on_cancel={Phoenix.LiveView.JS.push("close-detail")}
    >
      <div class="aw-event-detail">
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 0.75rem; margin-bottom: 1rem;">
          <div>
            <strong>ID:</strong>
            <code style="font-size: 0.85em; word-break: break-all;">{@selected_event.id}</code>
          </div>
          <div>
            <strong>Signal ID:</strong>
            <code style="font-size: 0.85em; word-break: break-all;">{@selected_event.signal_id}</code>
          </div>
          <div>
            <strong>Stream:</strong>
            <code style="font-size: 0.85em;">{@selected_event.stream_id}</code>
          </div>
          <div :if={@selected_event.event_number}>
            <strong>Event #:</strong>
            <span>{@selected_event.event_number}</span>
          </div>
          <div :if={@selected_event.global_position}>
            <strong>Global Position:</strong>
            <span>{@selected_event.global_position}</span>
          </div>
          <div>
            <strong>Category:</strong>
            <span>{Icons.category_icon(@selected_event.category)} {@selected_event.category}</span>
          </div>
          <div>
            <strong>Type:</strong>
            <span>{@selected_event.type}</span>
          </div>
          <div :if={@selected_event.source}>
            <strong>Source:</strong>
            <span>{@selected_event.source}</span>
          </div>
          <div :if={@selected_event.cause_id}>
            <strong>Cause ID:</strong>
            <code style="font-size: 0.85em;">{@selected_event.cause_id}</code>
          </div>
          <div :if={@selected_event.correlation_id}>
            <strong>Correlation ID:</strong>
            <code style="font-size: 0.85em;">{@selected_event.correlation_id}</code>
          </div>
          <div>
            <strong>Timestamp:</strong>
            <span>{Helpers.format_timestamp(@selected_event.timestamp)}</span>
          </div>
          <div :if={@selected_event.persisted_at}>
            <strong>Persisted At:</strong>
            <span>{Helpers.format_timestamp(@selected_event.persisted_at)}</span>
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

  defp format_event_subtitle(event) do
    parts = []

    agent =
      get_in(event.data, [:agent_id]) || get_in(event.data, ["agent_id"])

    parts = if agent, do: ["agent: #{agent}" | parts], else: parts

    stream_part =
      if event.stream_id && event.stream_id != "unknown",
        do: "stream: #{event.stream_id}",
        else: nil

    parts = if stream_part, do: [stream_part | parts], else: parts
    parts = [format_data_summary(event.data) | parts]
    Enum.join(parts, " | ")
  end

  defp format_data_summary(data) when data == %{}, do: "(empty)"

  defp format_data_summary(data) when is_map(data) do
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

  defp reload_events(socket) do
    events = fetch_filtered_events(socket.assigns)
    stats = safe_stats()
    dist = safe_category_distribution()
    cats = dist |> Map.keys() |> Enum.sort()

    socket
    |> assign(:stats, stats)
    |> assign(:categories, cats)
    |> assign(:event_count, length(events))
    |> stream(:events, events, reset: true)
  end

  defp fetch_filtered_events(assigns) do
    opts = [limit: 100]

    opts =
      case assigns.time_filter do
        :all -> opts
        :hour -> Keyword.put(opts, :from, DateTime.add(DateTime.utc_now(), -3600, :second))
        :today -> Keyword.put(opts, :from, DateTime.add(DateTime.utc_now(), -86_400, :second))
      end

    events =
      case assigns.category_filter do
        :all -> safe_query(opts)
        cat -> safe_for_category(cat, opts)
      end

    case assigns.agent_filter do
      nil -> events
      agent_id -> Enum.filter(events, &matches_agent?(&1, agent_id))
    end
  end

  defp matches_agent?(event, agent_id) do
    sig_agent =
      get_in(event.data, [:agent_id]) || get_in(event.data, ["agent_id"]) || ""

    String.contains?(to_string(sig_agent), agent_id)
  end

  # ── Safe API wrappers ───────────────────────────────────────────────

  defp safe_recent(opts) do
    case Arbor.Historian.recent(opts) do
      {:ok, entries} -> entries
      _ -> []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_query(opts) do
    case Arbor.Historian.query(opts) do
      {:ok, entries} -> entries
      _ -> []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_for_category(cat, opts) do
    case Arbor.Historian.for_category(cat, opts) do
      {:ok, entries} -> entries
      _ -> []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_stats do
    Arbor.Historian.stats()
  rescue
    _ -> default_stats()
  catch
    :exit, _ -> default_stats()
  end

  defp safe_category_distribution do
    Arbor.Historian.category_distribution()
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp default_stats do
    %{stream_count: 0, total_events: 0}
  end
end
