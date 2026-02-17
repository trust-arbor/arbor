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

  ## Phase 4 Features

  - Pipeline stage animations (processing, complete, failed states)
  - Evaluator reasoning display with streaming votes
  - Proposal diff view with syntax highlighting
  - "System Thinking" status indicators
  - Enhanced activity feed with expandable entries
  - Timing display (per-stage and total elapsed)
  """

  use Phoenix.LiveView
  use Arbor.Dashboard.Live.SignalSubscription

  import Arbor.Web.Components
  import Arbor.Dashboard.Components.ProposalDiff
  import Arbor.Dashboard.Components.InvestigationPanel

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
  @timer_interval_ms 100

  # System thinking messages for each stage
  @thinking_messages %{
    "detect" => "Monitoring for anomalies...",
    "diagnose" => "Analyzing anomaly...",
    "diagnose_to_propose" => "Forming proposal...",
    "propose" => "Submitting proposal...",
    "review" => "Awaiting council...",
    "fix" => "Applying fix...",
    "verify" => "Verifying..."
  }

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Self-Healing Demo",
        pipeline_stages: build_pipeline(:idle),
        active_faults: safe_active_faults(),
        available_faults: safe_available_faults(),
        feed: [],
        monitor_status: safe_monitor_status(),
        # Consensus tracking
        current_proposal: nil,
        evaluations: [],
        decision: nil,
        # Investigation tracking
        current_anomaly: nil,
        current_investigation: nil,
        investigation_expanded: false,
        # Verification tracking
        verification_status: nil,
        # Phase 4: UI state
        system_thinking: nil,
        diff_expanded: false,
        expanded_evaluations: MapSet.new(),
        expanded_feed_entries: MapSet.new(),
        # Timing
        pipeline_start_time: nil,
        stage_start_times: %{},
        stage_elapsed: %{},
        total_elapsed: 0,
        timer_ref: nil
      )

    socket =
      if connected?(socket) do
        :timer.send_interval(@refresh_interval_ms, :refresh)

        socket
        |> Arbor.Web.SignalLive.subscribe_raw("demo.*")
        |> Arbor.Web.SignalLive.subscribe_raw("monitor.*")
        |> Arbor.Web.SignalLive.subscribe_raw("consensus.*")
        |> Arbor.Web.SignalLive.subscribe_raw("code.*")
        |> Arbor.Web.SignalLive.subscribe_raw("debug_agent.*")
      else
        socket
      end

    {:ok, socket}
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

  def handle_info(:tick_timer, socket) do
    now = System.monotonic_time(:millisecond)

    socket =
      if socket.assigns.pipeline_start_time do
        total = now - socket.assigns.pipeline_start_time

        # Update elapsed time for active stage
        stage_elapsed =
          update_stage_elapsed(
            socket.assigns.stage_start_times,
            socket.assigns.stage_elapsed,
            socket.assigns.pipeline_stages,
            now
          )

        assign(socket, total_elapsed: total, stage_elapsed: stage_elapsed)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:signal_received, signal}, socket) do
    entry = format_signal(signal)
    feed = Enum.take([entry | socket.assigns.feed], @max_feed_entries)

    pipeline = update_pipeline_from_signal(socket.assigns.pipeline_stages, signal)
    socket = update_consensus_state(socket, signal)
    socket = update_thinking_state(socket, signal)
    socket = update_timing_state(socket, signal, pipeline)

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
        now = System.monotonic_time(:millisecond)
        timer_ref = start_timer(socket.assigns.timer_ref)

        entry = %{
          id: System.unique_integer([:positive]),
          icon: "💥",
          message: "Fault injected: #{type}",
          time: format_time(System.system_time(:millisecond)),
          details: "Type: #{type}\nTriggered self-healing pipeline"
        }

        feed = Enum.take([entry | socket.assigns.feed], @max_feed_entries)

        {:noreply,
         assign(socket,
           active_faults: safe_active_faults(),
           available_faults: safe_available_faults(),
           feed: feed,
           pipeline_start_time: now,
           stage_start_times: %{"detect" => now},
           stage_elapsed: %{},
           total_elapsed: 0,
           timer_ref: timer_ref,
           system_thinking: @thinking_messages["detect"]
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to inject fault: #{inspect(reason)}")}
    end
  end

  def handle_event("clear_fault", %{"type" => type}, socket) do
    type_atom = String.to_existing_atom(type)

    case safe_clear_fault(type_atom) do
      :ok ->
        stop_timer(socket.assigns.timer_ref)

        entry = %{
          id: System.unique_integer([:positive]),
          icon: "🩹",
          message: "Fault cleared: #{type}",
          time: format_time(System.system_time(:millisecond)),
          details: nil
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
           decision: nil,
           system_thinking: nil,
           pipeline_start_time: nil,
           stage_start_times: %{},
           stage_elapsed: %{},
           total_elapsed: 0,
           timer_ref: nil
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to clear fault: #{inspect(reason)}")}
    end
  end

  def handle_event("clear_all", _params, socket) do
    safe_clear_all()
    stop_timer(socket.assigns.timer_ref)

    entry = %{
      id: System.unique_integer([:positive]),
      icon: "🧹",
      message: "All faults cleared",
      time: format_time(System.system_time(:millisecond)),
      details: nil
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
       decision: nil,
       system_thinking: nil,
       pipeline_start_time: nil,
       stage_start_times: %{},
       stage_elapsed: %{},
       total_elapsed: 0,
       timer_ref: nil
     )}
  end

  def handle_event("toggle_diff", _params, socket) do
    {:noreply, assign(socket, diff_expanded: !socket.assigns.diff_expanded)}
  end

  def handle_event("toggle_evaluation", %{"perspective" => perspective}, socket) do
    expanded = socket.assigns.expanded_evaluations

    expanded =
      if MapSet.member?(expanded, perspective) do
        MapSet.delete(expanded, perspective)
      else
        MapSet.put(expanded, perspective)
      end

    {:noreply, assign(socket, expanded_evaluations: expanded)}
  end

  def handle_event("toggle_feed_entry", %{"id" => id}, socket) do
    id = String.to_integer(id)
    expanded = socket.assigns.expanded_feed_entries

    expanded =
      if MapSet.member?(expanded, id) do
        MapSet.delete(expanded, id)
      else
        MapSet.put(expanded, id)
      end

    {:noreply, assign(socket, expanded_feed_entries: expanded)}
  end

  def handle_event("toggle_investigation", _params, socket) do
    {:noreply, assign(socket, investigation_expanded: !socket.assigns.investigation_expanded)}
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
          <.pipeline_stage_enhanced
            id={stage.id}
            label={stage.label}
            icon={stage.icon}
            status={stage.status}
            is_last={idx == length(@pipeline_stages) - 1}
            elapsed={Map.get(@stage_elapsed, stage.id)}
          />
        <% end %>
      </div>

      <%!-- Timing Bar --%>
      <%= if @pipeline_start_time do %>
        <.timing_bar
          total_elapsed={@total_elapsed}
          stage_elapsed={@stage_elapsed}
          pipeline_stages={@pipeline_stages}
        />
      <% end %>

      <%!-- System Thinking Indicator --%>
      <%= if @system_thinking do %>
        <div class="aw-system-thinking">
          <div class="aw-system-thinking-spinner"></div>
          <span class="aw-system-thinking-text">{@system_thinking}</span>
        </div>
      <% end %>
    </.card>

    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 400px), 1fr)); gap: 1rem; margin-top: 1rem;">
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

    <%!-- Investigation Panel (shows after diagnosis) --%>
    <%= if @current_investigation do %>
      <div style="margin-top: 1.5rem;">
        <.card title="Investigation">
          <.investigation_panel
            investigation={@current_investigation}
            expanded={@investigation_expanded}
            on_toggle="toggle_investigation"
          />
        </.card>
      </div>
    <% end %>

    <%!-- Proposal Diff (shows in Propose/Review stages) --%>
    <%= if @current_proposal do %>
      <div style="margin-top: 1.5rem;">
        <.card title="Proposed Change">
          <.proposal_diff
            proposal={@current_proposal}
            expanded={@diff_expanded}
            on_toggle="toggle_diff"
          />
        </.card>
      </div>
    <% end %>

    <%!-- Council Review Panel (shows during review stage) --%>
    <%= if @evaluations != [] || @decision do %>
      <div style="margin-top: 1.5rem;">
        <.card title="Council Review">
          <%!-- Vote Tally --%>
          <%= if @evaluations != [] do %>
            <.vote_tally evaluations={@evaluations} />
          <% end %>

          <%!-- Evaluator Cards --%>
          <%= if @evaluations != [] do %>
            <div class="aw-evaluator-grid">
              <%= for eval <- Enum.reverse(@evaluations) do %>
                <.evaluator_card
                  evaluation={eval}
                  expanded={MapSet.member?(@expanded_evaluations, to_string(eval.perspective))}
                />
              <% end %>
            </div>
          <% end %>

          <%!-- Decision --%>
          <%= if @decision do %>
            <div style={"margin-top: 1rem; padding: 0.75rem; border-radius: 6px; background: #{decision_bg(@decision)}; border: 1px solid #{decision_border(@decision)};"}>
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

          <%!-- Verification Status --%>
          <%= if @verification_status do %>
            <div
              class={"aw-verification-status #{verification_class(@verification_status)}"}
              style="margin-top: 1rem;"
            >
              <span>{verification_icon(@verification_status)}</span>
              <span>{verification_label(@verification_status)}</span>
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
              <div>
                <div
                  class={"aw-activity-entry #{if entry[:details], do: "aw-activity-entry-expandable", else: ""}"}
                  phx-click={if entry[:details], do: "toggle_feed_entry", else: nil}
                  phx-value-id={entry[:id]}
                >
                  <span class="aw-activity-time">{entry.time}</span>
                  <span class="aw-activity-icon">{entry.icon}</span>
                  <span class="aw-activity-message">{entry.message}</span>
                  <%= if entry[:details] do %>
                    <span style="color: var(--aw-text-secondary); font-size: 0.75rem; margin-left: auto;">
                      {if MapSet.member?(@expanded_feed_entries, entry[:id]), do: "▼", else: "▶"}
                    </span>
                  <% end %>
                </div>
                <%= if entry[:details] && MapSet.member?(@expanded_feed_entries, entry[:id]) do %>
                  <div class="aw-activity-details">
                    {entry.details}
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </.card>
    </div>
    """
  end

  # ── Function Components ────────────────────────────────────────────

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :status, :atom, default: :idle
  attr :is_last, :boolean, default: false
  attr :elapsed, :integer, default: nil

  defp pipeline_stage_enhanced(assigns) do
    ~H"""
    <div class={["aw-pipeline-stage", "aw-pipeline-#{@status}"]} id={"pipeline-#{@id}"}>
      <div class="aw-pipeline-icon">{@icon}</div>
      <div class="aw-pipeline-label">{@label}</div>
      <%= if @elapsed && @status in [:active, :processing] do %>
        <div style="font-size: 0.65rem; color: var(--aw-text-secondary); margin-top: 0.125rem;">
          {format_elapsed(@elapsed)}
        </div>
      <% end %>
    </div>
    <div
      :if={!@is_last}
      class={[
        "aw-pipeline-connector",
        if(@status in [:active, :processing], do: "aw-pipeline-connector-active", else: "")
      ]}
    >
      <span class="aw-pipeline-arrow">&rarr;</span>
    </div>
    """
  end

  attr :total_elapsed, :integer, required: true
  attr :stage_elapsed, :map, required: true
  attr :pipeline_stages, :list, required: true

  defp timing_bar(assigns) do
    ~H"""
    <div class="aw-timing-bar">
      <div class="aw-timing-stages">
        <%= for stage <- @pipeline_stages do %>
          <%= if Map.has_key?(@stage_elapsed, stage.id) || stage.status == :complete do %>
            <div class={"aw-timing-stage #{if stage.status == :complete, do: "aw-timing-stage-complete", else: "aw-timing-stage-active"}"}>
              <span>{stage.label}:</span>
              <span>{format_elapsed(Map.get(@stage_elapsed, stage.id, 0))}</span>
            </div>
          <% end %>
        <% end %>
      </div>
      <div class={"aw-timing-total #{timing_budget_class(@total_elapsed)}"}>
        <span class="aw-timing-total-label">Total:</span>
        <span>{format_elapsed(@total_elapsed)}</span>
      </div>
    </div>
    """
  end

  attr :evaluations, :list, required: true

  defp vote_tally(assigns) do
    approve_count = Enum.count(assigns.evaluations, &vote_is?(&1, :approve))
    reject_count = Enum.count(assigns.evaluations, &vote_is?(&1, :reject))
    abstain_count = Enum.count(assigns.evaluations, &vote_is?(&1, :abstain))

    assigns =
      assign(assigns,
        approve_count: approve_count,
        reject_count: reject_count,
        abstain_count: abstain_count
      )

    ~H"""
    <div class="aw-vote-tally">
      <div class="aw-vote-count aw-vote-approve">
        <span>✓</span>
        <span>{@approve_count}</span>
      </div>
      <div class="aw-vote-count aw-vote-reject">
        <span>✗</span>
        <span>{@reject_count}</span>
      </div>
      <div class="aw-vote-count aw-vote-abstain">
        <span>○</span>
        <span>{@abstain_count}</span>
      </div>
    </div>
    """
  end

  attr :evaluation, :map, required: true
  attr :expanded, :boolean, default: false

  defp evaluator_card(assigns) do
    ~H"""
    <div class={"aw-evaluator-card aw-evaluator-card-#{vote_class(@evaluation.vote)}"}>
      <div class="aw-evaluator-header">
        <div class="aw-evaluator-name">
          <span class="aw-evaluator-icon">{evaluator_icon(@evaluation.perspective)}</span>
          <span>{format_perspective(@evaluation.perspective)}</span>
        </div>
        <.badge label={format_vote(@evaluation.vote)} color={vote_badge_color(@evaluation.vote)} />
      </div>
      <div class={"aw-evaluator-reasoning #{if !@expanded, do: "aw-evaluator-reasoning-collapsed", else: ""}"}>
        {@evaluation.reasoning || "No reasoning provided"}
      </div>
      <%= if String.length(@evaluation.reasoning || "") > 100 do %>
        <button
          type="button"
          class="aw-evaluator-toggle"
          phx-click="toggle_evaluation"
          phx-value-perspective={@evaluation.perspective}
        >
          {if @expanded, do: "Show less", else: "Show more"}
        </button>
      <% end %>
      <%= if @evaluation.concerns != [] do %>
        <div class="aw-evaluator-concerns">
          ⚠️ {Enum.join(@evaluation.concerns, ", ")}
        </div>
      <% end %>
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
    category = signal_category(signal)
    type = signal_type(signal)
    key = {normalize_category(category), normalize_signal_type(type)}
    dispatch_pipeline_update(key, stages, signal)
  end

  # Helper to safely extract category from signal struct or map
  defp signal_category(%{category: cat}) when not is_nil(cat), do: cat
  defp signal_category(%{"category" => cat}) when not is_nil(cat), do: cat
  defp signal_category(_), do: nil

  # Helper to safely extract type from signal struct or map
  defp signal_type(%{type: t}) when not is_nil(t), do: t
  defp signal_type(%{"type" => t}) when not is_nil(t), do: t
  defp signal_type(_), do: nil

  defp dispatch_pipeline_update({:demo, :fault_injected}, stages, _signal),
    do: set_stage(stages, "detect", :active)

  defp dispatch_pipeline_update({:monitor, :anomaly_detected}, stages, _signal),
    do: stages |> set_stage("detect", :complete) |> set_stage("diagnose", :active)

  defp dispatch_pipeline_update({:demo, :pipeline_stage_changed}, stages, signal) do
    data = extract_signal_data(signal)
    stage_name = data[:stage] || data["stage"]
    update_pipeline_for_stage(stages, stage_name)
  end

  defp dispatch_pipeline_update({:consensus, :proposal_submitted}, stages, _signal),
    do: stages |> set_stage("diagnose", :complete) |> set_stage("propose", :active)

  defp dispatch_pipeline_update({:consensus, :evaluation_started}, stages, _signal),
    do: stages |> set_stage("propose", :complete) |> set_stage("review", :active)

  defp dispatch_pipeline_update({:consensus, :decision_made}, stages, signal) do
    data = extract_signal_data(signal)
    decision = data[:decision] || data["decision"]
    apply_decision_to_pipeline(stages, decision)
  end

  defp dispatch_pipeline_update({:code, :hot_loaded}, stages, _signal),
    do: stages |> set_stage("fix", :complete) |> set_stage("verify", :active)

  defp dispatch_pipeline_update({:demo, :fault_cleared}, stages, _signal),
    do: set_stage(stages, "verify", :complete)

  defp dispatch_pipeline_update(_, stages, _signal), do: stages

  defp apply_decision_to_pipeline(stages, decision) when decision in [:approved, "approved"],
    do: stages |> set_stage("review", :complete) |> set_stage("fix", :active)

  defp apply_decision_to_pipeline(stages, _decision),
    do: set_stage(stages, "review", :error)

  defp update_pipeline_for_stage(stages, stage_name) when is_atom(stage_name),
    do: update_pipeline_for_stage(stages, to_string(stage_name))

  defp update_pipeline_for_stage(stages, "detect"),
    do: set_stage(stages, "detect", :active)

  defp update_pipeline_for_stage(stages, "diagnose"),
    do: stages |> set_stage("detect", :complete) |> set_stage("diagnose", :active)

  defp update_pipeline_for_stage(stages, "propose"),
    do: stages |> set_stage("diagnose", :complete) |> set_stage("propose", :active)

  defp update_pipeline_for_stage(stages, "review"),
    do: stages |> set_stage("propose", :complete) |> set_stage("review", :active)

  defp update_pipeline_for_stage(stages, "fix"),
    do: stages |> set_stage("review", :complete) |> set_stage("fix", :active)

  defp update_pipeline_for_stage(stages, "verify"),
    do: stages |> set_stage("fix", :complete) |> set_stage("verify", :active)

  defp update_pipeline_for_stage(stages, "rejected"),
    do: set_stage(stages, "review", :error)

  defp update_pipeline_for_stage(_stages, "idle"),
    do: build_pipeline(:idle)

  defp update_pipeline_for_stage(stages, _), do: stages

  defp update_consensus_state(socket, signal) do
    category = signal_category(signal)
    type = signal_type(signal)
    key = {normalize_category(category), normalize_signal_type(type)}
    dispatch_consensus_update(key, socket, signal)
  end

  defp dispatch_consensus_update({:consensus, :proposal_submitted}, socket, signal) do
    data = extract_signal_data(signal)
    proposal = data[:proposal] || data["proposal"] || data
    assign(socket, current_proposal: proposal)
  end

  defp dispatch_consensus_update({:consensus, :evaluation_completed}, socket, signal) do
    data = extract_signal_data(signal)
    evaluation = data[:evaluation] || data["evaluation"] || data
    evaluations = [normalize_evaluation(evaluation) | socket.assigns.evaluations]
    assign(socket, evaluations: evaluations)
  end

  defp dispatch_consensus_update({:consensus, :decision_made}, socket, signal) do
    data = extract_signal_data(signal)

    decision = %{
      outcome: data[:decision] || data["decision"],
      reason: data[:reason] || data["reason"],
      decided_at: System.system_time(:millisecond)
    }

    assign(socket, decision: decision)
  end

  defp dispatch_consensus_update({:debug_agent, :investigation_complete}, socket, signal) do
    data = extract_signal_data(signal)

    investigation = %{
      id: data[:investigation_id] || data["investigation_id"] || "inv_unknown",
      anomaly: socket.assigns[:current_anomaly] || %{skill: :unknown},
      symptoms: [],
      hypotheses: [],
      selected_hypothesis: %{
        cause: data[:suggested_action] || :unknown,
        confidence: data[:confidence] || 0.0,
        suggested_action: data[:suggested_action] || :investigate,
        evidence_chain: []
      },
      confidence: data[:confidence] || 0.0,
      thinking_log: [
        "Investigation started",
        "Gathered #{data[:hypothesis_count] || 0} hypotheses"
      ]
    }

    assign(socket, current_investigation: investigation)
  end

  defp dispatch_consensus_update({:debug_agent, :fix_verified}, socket, _signal) do
    assign(socket, verification_status: :verified)
  end

  defp dispatch_consensus_update({:debug_agent, :fix_unverified}, socket, _signal) do
    assign(socket, verification_status: :unverified)
  end

  defp dispatch_consensus_update(_, socket, _signal), do: socket

  defp normalize_evaluation(eval) when is_map(eval) do
    %{
      perspective: get_field(eval, :perspective, :unknown),
      vote: get_field(eval, :vote, :abstain),
      reasoning: get_field(eval, :reasoning, ""),
      concerns: get_field(eval, :concerns, []),
      confidence: get_field(eval, :confidence, 0.0)
    }
  end

  defp normalize_evaluation(_),
    do: %{perspective: :unknown, vote: :abstain, reasoning: "", concerns: [], confidence: 0.0}

  defp get_field(map, key, default) do
    map[key] || map[to_string(key)] || default
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
    type = signal_type(signal) || :unknown
    category = signal_category(signal) || :unknown
    data = extract_signal_data(signal)
    {icon, message, details} = format_signal_content(normalize_type(type), data, category)

    %{
      id: System.unique_integer([:positive]),
      icon: icon,
      message: message,
      time: format_time(System.system_time(:millisecond)),
      details: details
    }
  end

  defp normalize_type(t) when t in [:fault_injected, "fault_injected"], do: :fault_injected
  defp normalize_type(t) when t in [:fault_cleared, "fault_cleared"], do: :fault_cleared
  defp normalize_type(t) when t in [:anomaly_detected, "anomaly_detected"], do: :anomaly_detected

  defp normalize_type(t) when t in [:proposal_submitted, "proposal_submitted"],
    do: :proposal_submitted

  defp normalize_type(t) when t in [:evaluation_started, "evaluation_started"],
    do: :evaluation_started

  defp normalize_type(t) when t in [:evaluation_completed, "evaluation_completed"],
    do: :evaluation_completed

  defp normalize_type(t) when t in [:decision_made, "decision_made"], do: :decision_made
  defp normalize_type(t) when t in [:hot_loaded, "hot_loaded"], do: :hot_loaded

  defp normalize_type(t) when t in [:pipeline_stage_changed, "pipeline_stage_changed"],
    do: :pipeline_stage_changed

  defp normalize_type(t), do: t

  defp format_signal_content(:fault_injected, data, _cat) do
    fault_type = data[:fault_type] || data["fault_type"] || "unknown"
    {"💥", "Fault injected: #{fault_type}", nil}
  end

  defp format_signal_content(:fault_cleared, data, _cat) do
    fault_type = data[:fault_type] || data["fault_type"] || "unknown"
    {"🩹", "Fault cleared: #{fault_type}", nil}
  end

  defp format_signal_content(:anomaly_detected, data, _cat) do
    anomaly_type = data[:type] || data["type"] || "unknown"
    severity = data[:severity] || data["severity"] || "medium"
    {"🚨", "Anomaly detected: #{anomaly_type}", "Severity: #{severity}"}
  end

  defp format_signal_content(:proposal_submitted, data, _cat) do
    proposal = data[:proposal] || data["proposal"] || %{}
    desc = proposal[:description] || proposal["description"] || "No description"
    target = get_in(proposal, [:context, :target_module]) || "N/A"
    {"📝", "Proposal submitted", "#{desc}\nTarget: #{inspect(target)}"}
  end

  defp format_signal_content(:evaluation_started, _data, _cat) do
    {"🗳", "Council evaluation started", nil}
  end

  defp format_signal_content(:evaluation_completed, data, _cat) do
    eval = data[:evaluation] || data["evaluation"] || %{}
    perspective = eval[:perspective] || eval["perspective"] || "unknown"
    vote = eval[:vote] || eval["vote"] || "abstain"
    reasoning = eval[:reasoning] || eval["reasoning"] || ""
    {"✓", "#{perspective}: #{vote}", truncate_string(reasoning, 150)}
  end

  defp format_signal_content(:decision_made, data, _cat) do
    decision = data[:decision] || data["decision"] || "unknown"
    reason = data[:reason] || data["reason"]
    {"⚖️", "Decision: #{decision}", reason}
  end

  defp format_signal_content(:hot_loaded, data, _cat) do
    module = data[:module] || data["module"] || "unknown"
    elapsed = data[:elapsed_ms] || data["elapsed_ms"]
    timing = if elapsed, do: " (#{elapsed}ms)", else: ""
    {"🔧", "Hot-loaded: #{inspect(module)}#{timing}", nil}
  end

  defp format_signal_content(:pipeline_stage_changed, data, _cat) do
    stage = data[:stage] || data["stage"] || "unknown"
    {"➡️", "Stage: #{stage}", nil}
  end

  defp format_signal_content(type, _data, category) do
    {"📡", "#{category}.#{type}", nil}
  end

  defp truncate_string(nil, _max), do: nil
  defp truncate_string("", _max), do: nil

  defp truncate_string(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "..."
    else
      str
    end
  end

  defp format_time(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp format_time(_), do: "--:--:--"

  # ── Vote styling helpers ────────────────────────────────────────────

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
    FaultInjector.stop_fault(type)
  rescue
    _ -> {:error, :rescue}
  catch
    :exit, reason -> {:error, reason}
  end

  defp safe_clear_all do
    FaultInjector.stop_all()
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

  # ── Phase 4: Thinking state updates ───────────────────────────────

  defp update_thinking_state(socket, signal) do
    category = signal_category(signal)
    type = signal_type(signal)
    key = {normalize_category(category), normalize_signal_type(type)}
    thinking = determine_thinking(key, signal, socket.assigns.system_thinking)
    assign(socket, system_thinking: thinking)
  end

  defp determine_thinking({:demo, :fault_injected}, _signal, _current),
    do: @thinking_messages["detect"]

  defp determine_thinking({:monitor, :anomaly_detected}, _signal, _current),
    do: @thinking_messages["diagnose"]

  defp determine_thinking({:consensus, :proposal_submitted}, _signal, _current),
    do: @thinking_messages["propose"]

  defp determine_thinking({:consensus, :evaluation_started}, _signal, _current),
    do: @thinking_messages["review"]

  defp determine_thinking({:consensus, :decision_made}, signal, _current) do
    data = extract_signal_data(signal)
    decision = data[:decision] || data["decision"]
    if decision in [:approved, "approved"], do: @thinking_messages["fix"], else: nil
  end

  defp determine_thinking({:code, :hot_loaded}, _signal, _current),
    do: @thinking_messages["verify"]

  defp determine_thinking({:demo, :fault_cleared}, _signal, _current), do: nil

  defp determine_thinking({:demo, :pipeline_stage_changed}, signal, _current) do
    data = extract_signal_data(signal)
    stage = data[:stage] || data["stage"]
    Map.get(@thinking_messages, to_string(stage))
  end

  defp determine_thinking(_, _, current), do: current

  defp normalize_category(cat) when cat in [:demo, "demo"], do: :demo
  defp normalize_category(cat) when cat in [:monitor, "monitor"], do: :monitor
  defp normalize_category(cat) when cat in [:consensus, "consensus"], do: :consensus
  defp normalize_category(cat) when cat in [:code, "code"], do: :code
  defp normalize_category(cat) when cat in [:debug_agent, "debug_agent"], do: :debug_agent
  defp normalize_category(_), do: :unknown

  defp normalize_signal_type(t) when t in [:fault_injected, "fault_injected"], do: :fault_injected

  defp normalize_signal_type(t) when t in [:anomaly_detected, "anomaly_detected"],
    do: :anomaly_detected

  defp normalize_signal_type(t) when t in [:proposal_submitted, "proposal_submitted"],
    do: :proposal_submitted

  defp normalize_signal_type(t) when t in [:evaluation_started, "evaluation_started"],
    do: :evaluation_started

  defp normalize_signal_type(t) when t in [:decision_made, "decision_made"], do: :decision_made
  defp normalize_signal_type(t) when t in [:hot_loaded, "hot_loaded"], do: :hot_loaded
  defp normalize_signal_type(t) when t in [:fault_cleared, "fault_cleared"], do: :fault_cleared

  defp normalize_signal_type(t) when t in [:pipeline_stage_changed, "pipeline_stage_changed"],
    do: :pipeline_stage_changed

  defp normalize_signal_type(t) when t in [:evaluation_completed, "evaluation_completed"],
    do: :evaluation_completed

  defp normalize_signal_type(t) when t in [:investigation_complete, "investigation_complete"],
    do: :investigation_complete

  defp normalize_signal_type(t) when t in [:fix_verified, "fix_verified"],
    do: :fix_verified

  defp normalize_signal_type(t) when t in [:fix_unverified, "fix_unverified"],
    do: :fix_unverified

  defp normalize_signal_type(t) when t in [:circuit_breaker_blocked, "circuit_breaker_blocked"],
    do: :circuit_breaker_blocked

  defp normalize_signal_type(_), do: :unknown

  # ── Phase 4: Timing state updates ─────────────────────────────────

  defp update_timing_state(socket, _signal, new_pipeline) do
    now = System.monotonic_time(:millisecond)

    # Find active stage
    active_stage = Enum.find(new_pipeline, &(&1.status in [:active, :processing]))

    socket =
      if active_stage do
        # Record start time for newly active stage if not already recorded
        stage_start_times =
          if Map.has_key?(socket.assigns.stage_start_times, active_stage.id) do
            socket.assigns.stage_start_times
          else
            Map.put(socket.assigns.stage_start_times, active_stage.id, now)
          end

        assign(socket, stage_start_times: stage_start_times)
      else
        socket
      end

    # Check if pipeline completed (verify stage is complete)
    verify_stage = Enum.find(new_pipeline, &(&1.id == "verify"))

    if verify_stage && verify_stage.status == :complete do
      stop_timer(socket.assigns.timer_ref)
      assign(socket, timer_ref: nil, system_thinking: nil)
    else
      socket
    end
  end

  # ── Phase 4: Timer helpers ────────────────────────────────────────

  defp start_timer(nil) do
    {:ok, ref} = :timer.send_interval(@timer_interval_ms, :tick_timer)
    ref
  end

  defp start_timer(existing_ref), do: existing_ref

  defp stop_timer(nil), do: :ok
  defp stop_timer(ref), do: :timer.cancel(ref)

  defp update_stage_elapsed(stage_start_times, stage_elapsed, pipeline_stages, now) do
    Enum.reduce(stage_start_times, stage_elapsed, fn {stage_id, start}, acc ->
      stage = Enum.find(pipeline_stages, &(&1.id == stage_id))

      if stage && stage.status in [:active, :processing] do
        Map.put(acc, stage_id, now - start)
      else
        acc
      end
    end)
  end

  # ── Phase 4: Formatting helpers ───────────────────────────────────

  defp format_elapsed(nil), do: "0.0s"

  defp format_elapsed(ms) when is_integer(ms) do
    seconds = ms / 1000
    "#{Float.round(seconds, 1)}s"
  end

  defp timing_budget_class(total_elapsed) when is_integer(total_elapsed) do
    seconds = total_elapsed / 1000

    cond do
      seconds < 20 -> "aw-timing-budget-green"
      seconds < 30 -> "aw-timing-budget-yellow"
      true -> "aw-timing-budget-red"
    end
  end

  defp timing_budget_class(_), do: "aw-timing-budget-green"

  # ── Phase 4: Vote helpers ─────────────────────────────────────────

  defp vote_is?(eval, expected_vote) do
    vote = eval.vote
    vote == expected_vote or vote == to_string(expected_vote)
  end

  defp vote_class(:approve), do: "approve"
  defp vote_class("approve"), do: "approve"
  defp vote_class(:reject), do: "reject"
  defp vote_class("reject"), do: "reject"
  defp vote_class(:abstain), do: "abstain"
  defp vote_class("abstain"), do: "abstain"
  defp vote_class(_), do: "pending"

  defp format_vote(:approve), do: "Approve"
  defp format_vote("approve"), do: "Approve"
  defp format_vote(:reject), do: "Reject"
  defp format_vote("reject"), do: "Reject"
  defp format_vote(:abstain), do: "Abstain"
  defp format_vote("abstain"), do: "Abstain"
  defp format_vote(v) when is_atom(v), do: v |> to_string() |> String.capitalize()
  defp format_vote(v) when is_binary(v), do: String.capitalize(v)
  defp format_vote(_), do: "Unknown"

  # ── Phase 4: Evaluator display helpers ────────────────────────────

  @evaluator_icons [
    {"security", "🔒"},
    {"performance", "⚡"},
    {"deterministic", "📋"},
    {"safety", "🛡️"},
    {"stability", "⚙️"},
    {"vision", "🔮"},
    {"design", "✏️"},
    {"risk", "⚠️"},
    {"feasibility", "🎯"},
    {"brainstorm", "💡"}
  ]

  defp evaluator_icon(perspective) do
    perspective_str = to_string(perspective)
    find_icon(perspective_str, @evaluator_icons)
  end

  defp find_icon(_str, []), do: "🧠"

  defp find_icon(str, [{key, icon} | rest]) do
    if String.contains?(str, key), do: icon, else: find_icon(str, rest)
  end

  defp format_perspective(perspective) when is_atom(perspective) do
    perspective
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_perspective(perspective) when is_binary(perspective) do
    perspective
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_perspective(_), do: "Unknown"

  # ── Phase 6: Verification helpers ────────────────────────────────

  defp verification_class(:verified), do: "aw-verification-verified"
  defp verification_class(:unverified), do: "aw-verification-unverified"
  defp verification_class(_), do: "aw-verification-pending"

  defp verification_icon(:verified), do: "✅"
  defp verification_icon(:unverified), do: "❌"
  defp verification_icon(_), do: "⏳"

  defp verification_label(:verified), do: "Fix verified successfully"
  defp verification_label(:unverified), do: "Fix verification failed"
  defp verification_label(_), do: "Verification pending"
end
