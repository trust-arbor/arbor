defmodule Arbor.Dashboard.Live.SignalsLive do
  @moduledoc """
  Real-time signal stream dashboard.

  Displays published signals, subscription state, and bus health.
  Subscribes to the signal bus for live updates.
  """

  use Phoenix.LiveView

  import Arbor.Web.Components

  alias Arbor.Web.{Helpers, Icons}

  @stats_refresh_interval :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    {signals, stats, subscription_id} =
      if connected?(socket) do
        {sub_id, recent} = safe_subscribe_and_load()
        stats = safe_stats()
        Process.send_after(self(), :refresh_stats, @stats_refresh_interval)
        {recent, stats, sub_id}
      else
        {[], default_stats(), nil}
      end

    socket =
      socket
      |> assign(
        page_title: "Signals",
        stats: stats,
        selected_signal: nil,
        category_filter: :all,
        paused: false,
        subscription_id: subscription_id,
        categories: Map.keys(Icons.category_icons())
      )
      |> stream(:signals, signals)

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
      if matches_filter?(signal, socket.assigns.category_filter) do
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
    {:noreply, assign(socket, :paused, !socket.assigns.paused)}
  end

  def handle_event("filter-category", %{"category" => "all"}, socket) do
    signals = safe_recent(limit: 50)

    socket =
      socket
      |> assign(:category_filter, :all)
      |> stream(:signals, signals, reset: true)

    {:noreply, socket}
  end

  def handle_event("filter-category", %{"category" => category}, socket) do
    cat = String.to_existing_atom(category)
    signals = safe_recent(limit: 50, category: cat)

    socket =
      socket
      |> assign(:category_filter, cat)
      |> stream(:signals, signals, reset: true)

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
          {if @paused, do: "Resume", else: "Pause"}
        </button>
      </:actions>
    </.dashboard_header>

    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; margin-top: 1rem;">
      <.stat_card
        value={@stats.total_stored}
        label="Signals stored"
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
          timestamp={Helpers.format_relative_time(signal.timestamp)}
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

  # Check if a stream is empty by peeking at its items
  # LiveView streams don't have a built-in empty? check, so we track with CSS
  defp stream_empty?(_stream), do: false

  defp matches_filter?(_signal, :all), do: true
  defp matches_filter?(signal, category), do: signal.category == category

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

  defp safe_subscribe_and_load do
    pid = self()

    sub_id =
      try do
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

    recent =
      try do
        case Arbor.Signals.recent(limit: 50) do
          {:ok, signals} -> signals
          _ -> []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    {sub_id, recent}
  end

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
      total_stored: get_in(stats, [:store, :total_stored]) || 0,
      active_subscriptions: get_in(stats, [:bus, :active_subscriptions]) || 0,
      healthy: stats[:healthy] || false
    }
  rescue
    _ -> default_stats()
  catch
    :exit, _ -> default_stats()
  end

  defp default_stats do
    %{total_stored: 0, active_subscriptions: 0, healthy: false}
  end
end
