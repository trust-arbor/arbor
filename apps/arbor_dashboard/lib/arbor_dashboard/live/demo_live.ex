defmodule Arbor.Dashboard.Live.DemoLive do
  @moduledoc """
  Self-healing demo dashboard.

  Visualizes the self-healing pipeline: Detect -> Diagnose -> Propose -> Review -> Fix -> Verify.
  Provides controls for injecting and clearing faults, and shows a real-time activity feed.

  ## Signal Integration

  Subscribes to multiple signal categories:
  - `demo.*` — Fault injection events
  - `monitor.*` — Anomaly detection
  - `consensus.*` — Proposal submission, evaluation, and decisions
  - `code.*` — Hot-load events
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
    subscription_ids =
      if connected?(socket) do
        :timer.send_interval(@refresh_interval_ms, :refresh)
        subscribe_to_signals()
      else
        []
      end

    socket =
      assign(socket,
        page_title: "Self-Healing Demo",
        pipeline_stages: build_pipeline(:idle),
        active_faults: safe_active_faults(),
        available_faults: safe_available_faults(),
        feed: [],
        subscription_ids: subscription_ids,
        monitor_status: safe_monitor_status(),
        # Consensus tracking
        current_proposal: nil,
        evaluations: [],
        decision: nil
      )

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    for sub_id <- socket.assigns[:subscription_ids] || [] do
      safe_unsubscribe(sub_id)
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
    socket = update_consensus_state(socket, signal)

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
           pipeline_stages: build_pipeline(:idle),
           current_proposal: nil,
           evaluations: [],
           decision: nil
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
       pipeline_stages: build_pipeline(:idle),
       current_proposal: nil,
       evaluations: [],
       decision: nil
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

    <%!-- Council Review Panel (shows during review stage) --%>
    <%= if @current_proposal || @evaluations != [] || @decision do %>
      <div style="margin-top: 1.5rem;">
        <.card title="Council Review">
          <%!-- Current Proposal --%>
          <%= if @current_proposal do %>
            <div style="margin-bottom: 1rem; padding: 0.75rem; background: var(--aw-surface-secondary); border-radius: 6px;">
              <div style="font-weight: 600; margin-bottom: 0.5rem;">Proposal</div>
              <div style="font-size: 0.85rem; color: var(--aw-text-secondary);">
                {Map.get(@current_proposal, :description, "No description")}
              </div>
              <%= if Map.get(@current_proposal, :context) do %>
                <div style="font-size: 0.8rem; color: var(--aw-text-secondary); margin-top: 0.5rem;">
                  Target: {inspect(get_in(@current_proposal, [:context, :target_module]) || "N/A")}
                </div>
              <% end %>
            </div>
          <% end %>

          <%!-- Evaluations --%>
          <%= if @evaluations != [] do %>
            <div style="margin-bottom: 1rem;">
              <div style="font-weight: 600; margin-bottom: 0.5rem;">Evaluator Votes</div>
              <div style="display: flex; flex-direction: column; gap: 0.5rem;">
                <%= for eval <- @evaluations do %>
                  <div style={"padding: 0.5rem; border-radius: 4px; border-left: 3px solid #{vote_color(eval.vote)}; background: var(--aw-surface-secondary);"}>
                    <div style="display: flex; justify-content: space-between; align-items: center;">
                      <span style="font-weight: 500;">{eval.perspective}</span>
                      <.badge label={to_string(eval.vote)} color={vote_badge_color(eval.vote)} />
                    </div>
                    <div style="font-size: 0.8rem; color: var(--aw-text-secondary); margin-top: 0.25rem;">
                      {String.slice(eval.reasoning || "", 0, 100)}{if String.length(
                                                                        eval.reasoning || ""
                                                                      ) > 100, do: "...", else: ""}
                    </div>
                    <%= if eval.concerns != [] do %>
                      <div style="font-size: 0.75rem; color: var(--aw-accent-yellow); margin-top: 0.25rem;">
                        Concerns: {Enum.join(eval.concerns, ", ")}
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Decision --%>
          <%= if @decision do %>
            <div style={"padding: 0.75rem; border-radius: 6px; background: #{decision_bg(@decision)}; border: 1px solid #{decision_border(@decision)};"}>
              <div style="display: flex; justify-content: space-between; align-items: center;">
                <span style="font-weight: 600;">
                  {decision_icon(@decision)} Decision: {String.capitalize(
                    to_string(@decision.outcome)
                  )}
                </span>
                <span style="font-size: 0.8rem; color: var(--aw-text-secondary);">
                  {format_time(Map.get(@decision, :decided_at) || System.system_time(:millisecond))}
                </span>
              </div>
              <%= if Map.get(@decision, :reason) do %>
                <div style="font-size: 0.85rem; color: var(--aw-text-secondary); margin-top: 0.5rem;">
                  {Map.get(@decision, :reason)}
                </div>
              <% end %>
            </div>
          <% end %>
        </.card>
      </div>
    <% end %>

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

      match_signal?(category, type, :demo, :pipeline_stage_changed) ->
        data = extract_signal_data(signal)
        stage_name = data[:stage] || data["stage"]
        update_pipeline_for_stage(stages, stage_name)

      match_signal?(category, type, :consensus, :proposal_submitted) ->
        stages
        |> set_stage("diagnose", :complete)
        |> set_stage("propose", :active)

      match_signal?(category, type, :consensus, :evaluation_started) ->
        stages
        |> set_stage("propose", :complete)
        |> set_stage("review", :active)

      match_signal?(category, type, :consensus, :decision_made) ->
        data = extract_signal_data(signal)
        decision = data[:decision] || data["decision"]

        if decision == :approved or decision == "approved" do
          stages
          |> set_stage("review", :complete)
          |> set_stage("fix", :active)
        else
          set_stage(stages, "review", :error)
        end

      match_signal?(category, type, :code, :hot_loaded) ->
        stages
        |> set_stage("fix", :complete)
        |> set_stage("verify", :active)

      match_signal?(category, type, :demo, :fault_cleared) ->
        set_stage(stages, "verify", :complete)

      true ->
        stages
    end
  end

  defp update_pipeline_for_stage(stages, stage_name) when is_atom(stage_name) do
    update_pipeline_for_stage(stages, to_string(stage_name))
  end

  defp update_pipeline_for_stage(stages, stage_name) when is_binary(stage_name) do
    case stage_name do
      "detect" -> set_stage(stages, "detect", :active)
      "diagnose" -> stages |> set_stage("detect", :complete) |> set_stage("diagnose", :active)
      "propose" -> stages |> set_stage("diagnose", :complete) |> set_stage("propose", :active)
      "review" -> stages |> set_stage("propose", :complete) |> set_stage("review", :active)
      "fix" -> stages |> set_stage("review", :complete) |> set_stage("fix", :active)
      "verify" -> stages |> set_stage("fix", :complete) |> set_stage("verify", :active)
      "rejected" -> set_stage(stages, "review", :error)
      "idle" -> build_pipeline(:idle)
      _ -> stages
    end
  end

  defp update_pipeline_for_stage(stages, _), do: stages

  defp update_consensus_state(socket, signal) do
    category = get_in(signal, [:data, :category]) || signal[:category]
    type = get_in(signal, [:data, :type]) || signal[:type]
    data = extract_signal_data(signal)

    cond do
      match_signal?(category, type, :consensus, :proposal_submitted) ->
        proposal = data[:proposal] || data["proposal"] || data
        assign(socket, current_proposal: proposal)

      match_signal?(category, type, :consensus, :evaluation_completed) ->
        evaluation = data[:evaluation] || data["evaluation"] || data
        evaluations = [normalize_evaluation(evaluation) | socket.assigns.evaluations]
        assign(socket, evaluations: evaluations)

      match_signal?(category, type, :consensus, :decision_made) ->
        decision = %{
          outcome: data[:decision] || data["decision"],
          reason: data[:reason] || data["reason"],
          decided_at: System.system_time(:millisecond)
        }

        assign(socket, decision: decision)

      true ->
        socket
    end
  end

  defp normalize_evaluation(eval) when is_map(eval) do
    %{
      perspective: eval[:perspective] || eval["perspective"] || :unknown,
      vote: eval[:vote] || eval["vote"] || :abstain,
      reasoning: eval[:reasoning] || eval["reasoning"] || "",
      concerns: eval[:concerns] || eval["concerns"] || [],
      confidence: eval[:confidence] || eval["confidence"] || 0.0
    }
  end

  defp normalize_evaluation(_),
    do: %{perspective: :unknown, vote: :abstain, reasoning: "", concerns: [], confidence: 0.0}

  defp match_signal?(cat, type, expected_cat, expected_type) do
    (cat == expected_cat or cat == to_string(expected_cat)) and
      (type == expected_type or type == to_string(expected_type))
  end

  defp set_stage(stages, target_id, status) do
    Enum.map(stages, fn stage ->
      if stage.id == target_id, do: %{stage | status: status}, else: stage
    end)
  end

  defp extract_signal_data(signal) do
    case signal do
      %{data: data} when is_map(data) -> data
      data when is_map(data) -> data
      _ -> %{}
    end
  end

  defp format_signal(signal) do
    type = get_in(signal, [:data, :type]) || signal[:type] || :unknown
    category = get_in(signal, [:data, :category]) || signal[:category] || :unknown

    icon =
      case type do
        t when t in [:fault_injected, "fault_injected"] -> "💥"
        t when t in [:fault_cleared, "fault_cleared"] -> "🩹"
        t when t in [:anomaly_detected, "anomaly_detected"] -> "🚨"
        t when t in [:proposal_submitted, "proposal_submitted"] -> "📝"
        t when t in [:evaluation_started, "evaluation_started"] -> "🗳"
        t when t in [:evaluation_completed, "evaluation_completed"] -> "✓"
        t when t in [:decision_made, "decision_made"] -> "⚖️"
        t when t in [:hot_loaded, "hot_loaded"] -> "🔧"
        t when t in [:pipeline_stage_changed, "pipeline_stage_changed"] -> "➡️"
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

  # ── Vote styling helpers ────────────────────────────────────────────

  defp vote_color(:approve), do: "var(--aw-accent-green)"
  defp vote_color("approve"), do: "var(--aw-accent-green)"
  defp vote_color(:reject), do: "var(--aw-accent-red)"
  defp vote_color("reject"), do: "var(--aw-accent-red)"
  defp vote_color(_), do: "var(--aw-accent-yellow)"

  defp vote_badge_color(:approve), do: :success
  defp vote_badge_color("approve"), do: :success
  defp vote_badge_color(:reject), do: :error
  defp vote_badge_color("reject"), do: :error
  defp vote_badge_color(_), do: :warning

  defp decision_icon(%{outcome: :approved}), do: "✅"
  defp decision_icon(%{outcome: "approved"}), do: "✅"
  defp decision_icon(%{outcome: :rejected}), do: "❌"
  defp decision_icon(%{outcome: "rejected"}), do: "❌"
  defp decision_icon(_), do: "❓"

  defp decision_bg(%{outcome: outcome}) when outcome in [:approved, "approved"] do
    "rgba(63, 185, 80, 0.1)"
  end

  defp decision_bg(%{outcome: outcome}) when outcome in [:rejected, "rejected"] do
    "rgba(248, 81, 73, 0.1)"
  end

  defp decision_bg(_), do: "var(--aw-surface-secondary)"

  defp decision_border(%{outcome: outcome}) when outcome in [:approved, "approved"] do
    "var(--aw-accent-green)"
  end

  defp decision_border(%{outcome: outcome}) when outcome in [:rejected, "rejected"] do
    "var(--aw-accent-red)"
  end

  defp decision_border(_), do: "var(--aw-border)"

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

  defp subscribe_to_signals do
    pid = self()

    patterns = ["demo.*", "monitor.*", "consensus.*", "code.*"]

    Enum.map(patterns, fn pattern ->
      case Arbor.Signals.subscribe(pattern, fn signal ->
             send(pid, {:signal_received, signal})
             :ok
           end) do
        {:ok, id} -> id
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_unsubscribe(nil), do: :ok

  defp safe_unsubscribe(sub_id) do
    Arbor.Signals.unsubscribe(sub_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
