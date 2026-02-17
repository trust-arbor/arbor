defmodule Arbor.Dashboard.Live.SignalsLive do
  @moduledoc """
  Real-time signal stream dashboard.

  Displays published signals, subscription state, and bus health.
  Subscribes to the signal bus for live updates.
  """

  use Phoenix.LiveView
  use Arbor.Dashboard.Live.SignalSubscription

  import Arbor.Web.Components
  import Arbor.Web.Helpers

  alias Arbor.Signals.Config, as: SignalsConfig
  alias Arbor.Web.{Helpers, Icons, SignalLive}

  @stats_refresh_interval :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    {signals, stats} =
      if connected?(socket) do
        stats = safe_stats()
        Process.send_after(self(), :refresh_stats, @stats_refresh_interval)
        {safe_recent(limit: 50), stats}
      else
        {[], default_stats()}
      end

    # Subscribe to each non-restricted category individually.
    # "*" is rejected because it overlaps restricted topics (security, identity)
    # and the dashboard has no principal_id yet (needs auth first).
    restricted = SignalsConfig.restricted_topics()
    all_categories = Map.keys(Icons.category_icons())
    subscribed_categories = all_categories -- restricted

    socket =
      socket
      |> assign(
        page_title: "Signals",
        stats: stats,
        selected_signal: nil,
        active_categories: MapSet.new(subscribed_categories),
        paused: false,
        buffered_signals: [],
        subscribed_categories: subscribed_categories,
        filter_open: false
      )
      |> stream(:signals, signals)

    socket =
      if connected?(socket) do
        Enum.reduce(subscribed_categories, socket, fn cat, sock ->
          SignalLive.subscribe_raw(sock, "#{cat}.*")
        end)
      else
        socket
      end

    {:ok, socket}
  end

  # terminate/2 injected by SignalSubscription — calls unsubscribe automatically

  @impl true
  @max_buffer 1000

  def handle_info({:signal_received, signal}, socket) do
    if socket.assigns.paused do
      buffer = socket.assigns.buffered_signals

      if length(buffer) < @max_buffer do
        {:noreply, assign(socket, :buffered_signals, [signal | buffer])}
      else
        {:noreply, socket}
      end
    else
      if MapSet.member?(socket.assigns.active_categories, signal.category) do
        {:noreply, stream_insert(socket, :signals, signal, at: 0)}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_info(:refresh_stats, socket) do
    Process.send_after(self(), :refresh_stats, @stats_refresh_interval)
    {:noreply, assign(socket, :stats, safe_stats())}
  end

  @impl true
  def handle_event("toggle-pause", _params, socket) do
    socket =
      if socket.assigns.paused do
        # Unpausing — flush buffer into stream (oldest first so newest ends up on top)
        socket.assigns.buffered_signals
        |> Enum.filter(&MapSet.member?(socket.assigns.active_categories, &1.category))
        |> Enum.reduce(socket, fn signal, sock ->
          stream_insert(sock, :signals, signal, at: 0)
        end)
        |> assign(:buffered_signals, [])
      else
        socket
      end

    {:noreply, assign(socket, :paused, !socket.assigns.paused)}
  end

  def handle_event("toggle-filter-dropdown", _params, socket) do
    {:noreply, assign(socket, :filter_open, !socket.assigns.filter_open)}
  end

  def handle_event("toggle-category", %{"category" => category}, socket) do
    cat = String.to_existing_atom(category)
    active = socket.assigns.active_categories

    active =
      if MapSet.member?(active, cat),
        do: MapSet.delete(active, cat),
        else: MapSet.put(active, cat)

    signals = reload_signals(active)

    socket =
      socket
      |> assign(:active_categories, active)
      |> stream(:signals, signals, reset: true)

    {:noreply, socket}
  end

  def handle_event("filter-select-all", _params, socket) do
    active = MapSet.new(socket.assigns.subscribed_categories)
    signals = reload_signals(active)

    socket =
      socket
      |> assign(:active_categories, active)
      |> stream(:signals, signals, reset: true)

    {:noreply, socket}
  end

  def handle_event("filter-select-none", _params, socket) do
    socket =
      socket
      |> assign(:active_categories, MapSet.new())
      |> stream(:signals, [], reset: true)

    {:noreply, socket}
  end

  def handle_event("select-signal", %{"id" => signal_id}, socket) do
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

    {:noreply, assign(socket, :selected_signal, signal)}
  end

  def handle_event("close-detail", _params, socket) do
    {:noreply, assign(socket, :selected_signal, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="Signals" subtitle="Real-time signal stream">
      <:actions>
        <button
          phx-click="toggle-pause"
          class={"aw-btn #{if @paused, do: "aw-btn-success", else: "aw-btn-warning"}"}
        >
          <%= if @paused do %>
            Resume ({length(@buffered_signals)})
          <% else %>
            Pause
          <% end %>
        </button>
      </:actions>
    </.dashboard_header>

    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; margin-top: 1rem;">
      <.stat_card
        value={@stats.current_count}
        label="In Store"
        color={:blue}
      />
      <.stat_card
        value={@stats.active_subscriptions}
        label="Subscriptions"
        color={:purple}
      />
      <.stat_card
        value={if @stats.healthy, do: "Healthy", else: "Degraded"}
        label="System health"
        color={if @stats.healthy, do: :green, else: :error}
      />
    </div>

    <div style="position: relative; margin-top: 1rem;">
      <button
        phx-click="toggle-filter-dropdown"
        style="background: var(--aw-bg-secondary, #1e293b); border: 1px solid var(--aw-border, #334155); color: var(--aw-text, #e2e8f0); padding: 0.5rem 1rem; border-radius: 6px; cursor: pointer; display: flex; align-items: center; gap: 0.5rem; font-size: 0.9rem;"
      >
        <span>Categories ({MapSet.size(@active_categories)}/{length(@subscribed_categories)})</span>
        <span style={"transform: #{if @filter_open, do: "rotate(180deg)", else: "rotate(0)"}; transition: transform 0.2s;"}>
          &#9662;
        </span>
      </button>

      <div
        :if={@filter_open}
        style="position: absolute; top: 100%; left: 0; z-index: 50; margin-top: 0.25rem; background: var(--aw-bg-secondary, #1e293b); border: 1px solid var(--aw-border, #334155); border-radius: 6px; padding: 0.5rem; min-width: 220px; max-height: 400px; overflow-y: auto; box-shadow: 0 4px 12px rgba(0,0,0,0.4);"
      >
        <div style="display: flex; gap: 0.5rem; margin-bottom: 0.5rem; padding-bottom: 0.5rem; border-bottom: 1px solid var(--aw-border, #334155);">
          <button
            phx-click="filter-select-all"
            style="flex: 1; background: transparent; border: 1px solid var(--aw-border, #334155); color: var(--aw-text-muted, #94a3b8); padding: 0.25rem 0.5rem; border-radius: 4px; cursor: pointer; font-size: 0.8rem;"
          >
            All
          </button>
          <button
            phx-click="filter-select-none"
            style="flex: 1; background: transparent; border: 1px solid var(--aw-border, #334155); color: var(--aw-text-muted, #94a3b8); padding: 0.25rem 0.5rem; border-radius: 4px; cursor: pointer; font-size: 0.8rem;"
          >
            None
          </button>
        </div>

        <label
          :for={cat <- @subscribed_categories}
          phx-click="toggle-category"
          phx-value-category={cat}
          style="display: flex; align-items: center; gap: 0.5rem; padding: 0.35rem 0.5rem; border-radius: 4px; cursor: pointer; color: var(--aw-text, #e2e8f0); font-size: 0.85rem;"
        >
          <span style={"width: 16px; height: 16px; border: 1px solid var(--aw-border, #334155); border-radius: 3px; display: inline-flex; align-items: center; justify-content: center; background: #{if MapSet.member?(@active_categories, cat), do: "var(--aw-accent, #3b82f6)", else: "transparent"}; flex-shrink: 0;"}>
            <span
              :if={MapSet.member?(@active_categories, cat)}
              style="color: white; font-size: 0.7rem;"
            >
              &#10003;
            </span>
          </span>
          <span>{Icons.category_icon(cat)}</span>
          <span>{cat}</span>
        </label>
      </div>
    </div>

    <div id="signals-stream" phx-update="stream" style="margin-top: 1rem;">
      <div
        :for={{dom_id, signal} <- @streams.signals}
        id={dom_id}
        phx-click="select-signal"
        phx-value-id={signal.id}
        style="cursor: pointer;"
      >
        <.event_card
          icon={Icons.category_icon(signal.category)}
          title={"#{signal.category}.#{signal.type}"}
          subtitle={format_signal_data(signal.data)}
          timestamp={format_time(signal.timestamp)}
        />
      </div>
    </div>

    <div :if={@streams.signals |> stream_empty?()} style="margin-top: 1rem;">
      <.empty_state
        icon="📡"
        title="No signals yet"
        hint="Signals will appear here as they are emitted by the system."
      />
    </div>

    <.modal
      :if={@selected_signal}
      id="signal-detail"
      show={@selected_signal != nil}
      title={"#{@selected_signal.category}.#{@selected_signal.type}"}
      on_cancel={Phoenix.LiveView.JS.push("close-detail")}
    >
      <div class="aw-signal-detail">
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 0.75rem; margin-bottom: 1rem;">
          <div>
            <strong>ID:</strong>
            <code style="font-size: 0.85em; word-break: break-all;">{@selected_signal.id}</code>
          </div>
          <div>
            <strong>Timestamp:</strong>
            <span>{Helpers.format_timestamp(@selected_signal.timestamp)}</span>
          </div>
          <div :if={@selected_signal.source}>
            <strong>Source:</strong>
            <span>{@selected_signal.source}</span>
          </div>
          <div :if={@selected_signal.correlation_id}>
            <strong>Correlation:</strong>
            <code style="font-size: 0.85em;">{@selected_signal.correlation_id}</code>
          </div>
          <div :if={@selected_signal.cause_id}>
            <strong>Cause:</strong>
            <code style="font-size: 0.85em;">{@selected_signal.cause_id}</code>
          </div>
        </div>

        <div style="margin-top: 1rem;">
          <strong>Data:</strong>
          <pre style="background: var(--aw-bg-secondary, #1a1a1a); padding: 1rem; border-radius: 4px; overflow-x: auto; margin-top: 0.5rem; font-size: 0.85em;"><%= format_signal_json(@selected_signal.data) %></pre>
        </div>

        <div :if={@selected_signal.metadata != %{}} style="margin-top: 1rem;">
          <strong>Metadata:</strong>
          <pre style="background: var(--aw-bg-secondary, #1a1a1a); padding: 1rem; border-radius: 4px; overflow-x: auto; margin-top: 0.5rem; font-size: 0.85em;"><%= format_signal_json(@selected_signal.metadata) %></pre>
        </div>
      </div>
    </.modal>
    """
  end

  defp reload_signals(active_categories) do
    if MapSet.size(active_categories) == 0 do
      []
    else
      safe_recent(limit: 50)
      |> Enum.filter(fn s -> MapSet.member?(active_categories, s.category) end)
    end
  end

  defp format_signal_data(data) when data == %{}, do: "(empty)"

  defp format_signal_data(data) when is_map(data) do
    data
    |> Enum.take(3)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
    |> Helpers.truncate(80)
  end

  defp format_signal_json(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(data, pretty: true)
    end
  end

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(%NaiveDateTime{} = ndt), do: Calendar.strftime(ndt, "%H:%M:%S")

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

  defp safe_stats do
    stats = Arbor.Signals.stats()

    %{
      current_count: get_in(stats, [:store, :current_count]) || 0,
      active_subscriptions: get_in(stats, [:bus, :active_subscriptions]) || 0,
      healthy: stats[:healthy] || false
    }
  rescue
    _ -> default_stats()
  catch
    :exit, _ -> default_stats()
  end

  defp default_stats do
    %{current_count: 0, active_subscriptions: 0, healthy: false}
  end
end
