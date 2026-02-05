defmodule Arbor.Dashboard.Live.DemoLive do
  @moduledoc """
  Self-healing demo dashboard.

  Visualizes the self-healing pipeline: Detect -> Diagnose -> Propose -> Review -> Fix -> Verify.
  Provides controls for injecting and clearing faults, and shows a real-time activity feed.
  """

  use Phoenix.LiveView

  import Arbor.Web.Components

  alias Arbor.Demo.FaultInjector

  @pipeline_stages [
    %{id: "detect", label: "Detect", icon: "🔍"},
    %{id: "diagnose", label: "Diagnose", icon: "🔬"},
    %{id: "propose", label: "Propose", icon: "📝"},
    %{id: "review", label: "Review", icon: "🗳"},
    %{id: "fix", label: "Fix", icon: "🔧"},
    %{id: "verify", label: "Verify", icon: "✅"}
  ]

  @refresh_interval_ms 2_000
  @max_feed_entries 100

  @impl true
  def mount(_params, _session, socket) do
    sub_id =
      if connected?(socket) do
        :timer.send_interval(@refresh_interval_ms, :refresh)
        safe_subscribe()
      end

    socket =
      assign(socket,
        page_title: "Self-Healing Demo",
        pipeline_stages: build_pipeline(:idle),
        active_faults: safe_active_faults(),
        available_faults: safe_available_faults(),
        feed: [],
        sub_id: sub_id,
        monitor_status: safe_monitor_status()
      )

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if sub_id = socket.assigns[:sub_id] do
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
  def handle_info(:refresh, socket) do
    socket =
      assign(socket,
        active_faults: safe_active_faults(),
        monitor_status: safe_monitor_status()
      )

    {:noreply, socket}
  end

  def handle_info({:signal_received, signal}, socket) do
    entry = format_signal(signal)
    feed = Enum.take([entry | socket.assigns.feed], @max_feed_entries)

    pipeline = update_pipeline_from_signal(socket.assigns.pipeline_stages, signal)

    socket =
      assign(socket,
        feed: feed,
        pipeline_stages: pipeline,
        active_faults: safe_active_faults()
      )

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("inject_fault", %{"type" => type}, socket) do
    type_atom = String.to_existing_atom(type)

    case safe_inject_fault(type_atom) do
      {:ok, _} ->
        entry = %{
          icon: "💥",
          message: "Fault injected: #{type}",
          time: format_time(System.system_time(:millisecond))
        }

        feed = Enum.take([entry | socket.assigns.feed], @max_feed_entries)

        {:noreply,
         assign(socket,
           active_faults: safe_active_faults(),
           available_faults: safe_available_faults(),
           feed: feed
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to inject fault: #{inspect(reason)}")}
    end
  end

  def handle_event("clear_fault", %{"type" => type}, socket) do
    type_atom = String.to_existing_atom(type)

    case safe_clear_fault(type_atom) do
      :ok ->
        entry = %{
          icon: "🩹",
          message: "Fault cleared: #{type}",
          time: format_time(System.system_time(:millisecond))
        }

        feed = Enum.take([entry | socket.assigns.feed], @max_feed_entries)

        {:noreply,
         assign(socket,
           active_faults: safe_active_faults(),
           available_faults: safe_available_faults(),
           feed: feed,
           pipeline_stages: build_pipeline(:idle)
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to clear fault: #{inspect(reason)}")}
    end
  end

  def handle_event("clear_all", _params, socket) do
    safe_clear_all()

    entry = %{
      icon: "🧹",
      message: "All faults cleared",
      time: format_time(System.system_time(:millisecond))
    }

    feed = Enum.take([entry | socket.assigns.feed], @max_feed_entries)

    {:noreply,
     assign(socket,
       active_faults: %{},
       available_faults: safe_available_faults(),
       feed: feed,
       pipeline_stages: build_pipeline(:idle)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header
      title="Self-Healing Demo"
      subtitle="BEAM fault injection and autonomous recovery"
    >
      <:actions>
        <button class="aw-demo-btn aw-demo-btn-clear" phx-click="clear_all">
          🧹 Clear All
        </button>
      </:actions>
    </.dashboard_header>

    <%!-- Pipeline Visualization --%>
    <.card title="Pipeline">
      <div class="aw-pipeline">
        <%= for {stage, idx} <- Enum.with_index(@pipeline_stages) do %>
          <.pipeline_stage
            id={stage.id}
            label={stage.label}
            icon={stage.icon}
            status={stage.status}
            is_last={idx == length(@pipeline_stages) - 1}
          />
        <% end %>
      </div>
    </.card>

    <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 1.5rem; margin-top: 1.5rem;">
      <%!-- Fault Controls --%>
      <.card title="Fault Injection">
        <div class="aw-demo-controls" style="flex-direction: column;">
          <%= for fault <- @available_faults do %>
            <div style="display: flex; align-items: center; justify-content: space-between; padding: 0.5rem 0; border-bottom: 1px solid var(--aw-border);">
              <div>
                <span style="font-weight: 600; color: var(--aw-text-primary);">{fault.type}</span>
                <br />
                <span style="font-size: 0.8rem; color: var(--aw-text-secondary);">
                  {fault.description}
                </span>
                <br />
                <span style="font-size: 0.75rem; color: var(--aw-text-secondary);">
                  Detected by: {Enum.join(fault.detectable_by |> Enum.map(&to_string/1), ", ")}
                </span>
              </div>
              <div>
                <%= if fault.active do %>
                  <button
                    class="aw-demo-btn aw-demo-btn-danger"
                    phx-click="clear_fault"
                    phx-value-type={fault.type}
                  >
                    Clear
                  </button>
                <% else %>
                  <button class="aw-demo-btn" phx-click="inject_fault" phx-value-type={fault.type}>
                    Inject
                  </button>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </.card>

      <%!-- Active Faults --%>
      <.card title="Active Faults">
        <%= if map_size(@active_faults) == 0 do %>
          <.empty_state title="No active faults" icon="✨" hint="Inject a fault to start the demo." />
        <% else %>
          <div style="display: flex; flex-direction: column; gap: 0.5rem;">
            <%= for {type, info} <- @active_faults do %>
              <div style="padding: 0.75rem; border: 1px solid var(--aw-accent-red); border-radius: 6px; background: rgba(248, 81, 73, 0.05);">
                <div style="display: flex; justify-content: space-between; align-items: center;">
                  <span style="font-weight: 600; color: var(--aw-accent-red);">
                    💥 {type}
                  </span>
                  <.badge label="Active" color={:error} />
                </div>
                <div style="font-size: 0.8rem; color: var(--aw-text-secondary); margin-top: 0.25rem;">
                  {info.description}
                </div>
                <div style="font-size: 0.75rem; color: var(--aw-text-secondary); margin-top: 0.25rem;">
                  Since: {format_time(info.injected_at)}
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </.card>
    </div>

    <%!-- Monitor Status --%>
    <div style="margin-top: 1.5rem;">
      <.card title="Monitor Status">
        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 1rem;">
          <.stat_card
            value={@monitor_status.process_count}
            label="Processes"
            color={if @monitor_status.process_count > 500, do: :yellow, else: :green}
          />
          <.stat_card
            value={"#{@monitor_status.memory_mb} MB"}
            label="Memory"
            color={:blue}
          />
          <.stat_card
            value={@monitor_status.anomaly_count}
            label="Anomalies"
            color={if @monitor_status.anomaly_count > 0, do: :error, else: :green}
          />
        </div>
      </.card>
    </div>

    <%!-- Activity Feed --%>
    <div style="margin-top: 1.5rem;">
      <.card title="Activity Feed">
        <%= if @feed == [] do %>
          <.empty_state
            title="No activity yet"
            icon="📭"
            hint="Inject a fault to see events appear here."
          />
        <% else %>
          <div class="aw-activity-feed">
            <%= for entry <- @feed do %>
              <div class="aw-activity-entry">
                <span class="aw-activity-time">{entry.time}</span>
                <span class="aw-activity-icon">{entry.icon}</span>
                <span class="aw-activity-message">{entry.message}</span>
              </div>
            <% end %>
          </div>
        <% end %>
      </.card>
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp build_pipeline(status) do
    Enum.map(@pipeline_stages, fn stage ->
      Map.put(stage, :status, status)
    end)
  end

  defp update_pipeline_from_signal(stages, signal) do
    category = get_in(signal, [:data, :category]) || signal[:category]
    type = get_in(signal, [:data, :type]) || signal[:type]

    cond do
      match_signal?(category, type, :demo, :fault_injected) ->
        set_stage(stages, "detect", :active)

      match_signal?(category, type, :monitor, :anomaly_detected) ->
        stages
        |> set_stage("detect", :complete)
        |> set_stage("diagnose", :active)

      match_signal?(category, type, :demo, :fault_cleared) ->
        stages
        |> set_stage("fix", :complete)
        |> set_stage("verify", :active)

      true ->
        stages
    end
  end

  defp match_signal?(cat, type, expected_cat, expected_type) do
    (cat == expected_cat or cat == to_string(expected_cat)) and
      (type == expected_type or type == to_string(expected_type))
  end

  defp set_stage(stages, target_id, status) do
    Enum.map(stages, fn stage ->
      if stage.id == target_id, do: %{stage | status: status}, else: stage
    end)
  end

  defp format_signal(signal) do
    type = get_in(signal, [:data, :type]) || signal[:type] || :unknown
    category = get_in(signal, [:data, :category]) || signal[:category] || :unknown

    icon =
      case type do
        t when t in [:fault_injected, "fault_injected"] -> "💥"
        t when t in [:fault_cleared, "fault_cleared"] -> "🩹"
        t when t in [:anomaly_detected, "anomaly_detected"] -> "🚨"
        _ -> "📡"
      end

    %{
      icon: icon,
      message: "#{category}.#{type}",
      time: format_time(System.system_time(:millisecond))
    }
  end

  defp format_time(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp format_time(_), do: "--:--:--"

  # ── Safe external calls ────────────────────────────────────────────

  defp safe_active_faults do
    FaultInjector.active_faults()
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp safe_available_faults do
    FaultInjector.available_faults()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_inject_fault(type) do
    FaultInjector.inject_fault(type)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp safe_clear_fault(type) do
    FaultInjector.clear_fault(type)
  rescue
    _ -> {:error, :rescue}
  catch
    :exit, reason -> {:error, reason}
  end

  defp safe_clear_all do
    FaultInjector.clear_all()
  rescue
    _ -> {:ok, 0}
  catch
    :exit, _ -> {:ok, 0}
  end

  defp safe_monitor_status do
    metrics = Arbor.Monitor.metrics()
    beam = metrics[:beam] || %{}
    memory = metrics[:memory] || %{}

    %{
      process_count: beam[:process_count] || length(Process.list()),
      memory_mb: div(memory[:total_bytes] || :erlang.memory(:total), 1_048_576),
      anomaly_count: length(Arbor.Monitor.anomalies())
    }
  rescue
    _ -> %{process_count: 0, memory_mb: 0, anomaly_count: 0}
  catch
    :exit, _ -> %{process_count: 0, memory_mb: 0, anomaly_count: 0}
  end

  defp safe_subscribe do
    pid = self()

    case Arbor.Signals.subscribe("demo.*", fn signal ->
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
