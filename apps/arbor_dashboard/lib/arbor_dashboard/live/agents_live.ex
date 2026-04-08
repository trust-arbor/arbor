defmodule Arbor.Dashboard.Live.AgentsLive do
  @moduledoc """
  Agent instances dashboard.

  Shows running agents, profiles, executor/reasoning status,
  and reasoning history.
  """

  use Phoenix.LiveView
  use Arbor.Dashboard.Live.SignalSubscription

  import Arbor.Web.Components

  alias Arbor.Agent.{Executor, Lifecycle, Manager, ReasoningLoop}
  alias Arbor.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    {running, profiles} = safe_load_agents()

    running_ids = safe_running_ids()

    socket =
      socket
      |> assign(
        page_title: "Agents",
        running_count: length(running),
        profile_count: length(profiles),
        running_ids: running_ids,
        selected_agent: nil,
        agent_detail: nil
      )
      |> stream_configure(:agents, dom_id: &"agent-#{&1.agent_id}")
      |> stream(:agents, profiles)

    socket = subscribe_signals(socket, "agent.*", &reload_agents/1)

    {:ok, socket}
  end

  defp reload_agents(socket) do
    {running, profiles} = safe_load_agents()

    socket
    |> assign(
      running_count: length(running),
      profile_count: length(profiles),
      running_ids: safe_running_ids()
    )
    |> stream(:agents, profiles, reset: true)
  end

  @impl true
  def handle_event("select-agent", %{"id" => agent_id}, socket) do
    detail = safe_load_detail(agent_id)
    {:noreply, assign(socket, selected_agent: agent_id, agent_detail: detail)}
  end

  def handle_event("close-detail", _params, socket) do
    {:noreply, assign(socket, selected_agent: nil, agent_detail: nil)}
  end

  def handle_event("chat-agent", %{"id" => agent_id}, socket) do
    {:noreply, push_navigate(socket, to: "/chat?agent_id=#{agent_id}")}
  end

  def handle_event("stop-agent", %{"id" => agent_id}, socket) do
    Manager.stop_agent(agent_id)
    {running, profiles} = safe_load_agents()

    socket =
      socket
      |> assign(
        running_count: length(running),
        profile_count: length(profiles),
        running_ids: safe_running_ids()
      )
      |> stream(:agents, profiles, reset: true)

    {:noreply, socket}
  end

  def handle_event("delete-agent", %{"id" => agent_id}, socket) do
    Lifecycle.destroy(agent_id)
    {running, profiles} = safe_load_agents()

    socket =
      socket
      |> assign(running_count: length(running), profile_count: length(profiles))
      |> stream(:agents, profiles, reset: true)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="Agents" subtitle="Running agent instances and profiles" />

    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; margin-top: 1rem;">
      <.stat_card value={@running_count} label="Running" color={:green} />
      <.stat_card value={@profile_count} label="Profiles" color={:blue} />
    </div>

    <div id="agents-stream" phx-update="stream" style="margin-top: 1rem;">
      <div
        :for={{dom_id, profile} <- @streams.agents}
        id={dom_id}
        style="
          border: 1px solid var(--aw-border, #333);
          border-radius: 6px;
          padding: 1rem;
          margin-bottom: 0.75rem;
          background: var(--aw-surface, #1a1a1a);
          transition: border-color 0.2s, box-shadow 0.2s;
        "
        onmouseover="this.style.borderColor='var(--aw-primary, #60a5fa)'; this.style.boxShadow='0 2px 8px rgba(96, 165, 250, 0.1)';"
        onmouseout="this.style.borderColor='var(--aw-border, #333)'; this.style.boxShadow='none';"
      >
        <div style="display: flex; justify-content: space-between; align-items: center;">
          <%!-- Left side: Agent info --%>
          <div style="flex: 1;">
            <div style="display: flex; align-items: center; gap: 0.75rem; margin-bottom: 0.5rem;">
              <h3 style="margin: 0; font-size: 1.1rem; color: var(--aw-text, #fff);">
                {agent_name(profile)}
              </h3>
              <.badge
                label={to_string(profile.trust_tier)}
                color={tier_color(profile.trust_tier)}
              />
              <span
                style={"width: 10px; height: 10px; border-radius: 50%; background: #{status_dot_color(@running_ids, profile.agent_id)};"}
                title={status_title(@running_ids, profile.agent_id)}
              >
              </span>
            </div>
            <div style="display: flex; gap: 1rem; font-size: 0.9rem; color: var(--aw-text-muted, #888);">
              <span :if={profile.template}>Template: {profile.template}</span>
              <span>Created: {format_created(profile.created_at)}</span>
            </div>
          </div>
          <%!-- Right side: Action buttons --%>
          <div style="display: flex; gap: 0.5rem; align-items: center;">
            <%= if MapSet.member?(@running_ids, profile.agent_id) do %>
              <%!-- Running agent actions --%>
              <button
                phx-click="chat-agent"
                phx-value-id={profile.agent_id}
                style="
                  padding: 0.5rem 1rem;
                  border: none;
                  border-radius: 4px;
                  background: var(--aw-success, #22c55e);
                  color: white;
                  font-weight: 500;
                  cursor: pointer;
                  transition: opacity 0.2s;
                "
                onmouseover="this.style.opacity='0.8';"
                onmouseout="this.style.opacity='1';"
              >
                💬 Chat
              </button>
              <a
                href={"/memory/#{profile.agent_id}"}
                style="
                  padding: 0.5rem 1rem;
                  border: 1px solid var(--aw-border, #333);
                  border-radius: 4px;
                  background: transparent;
                  color: var(--aw-text, #fff);
                  text-decoration: none;
                  cursor: pointer;
                  transition: border-color 0.2s;
                "
                onmouseover="this.style.borderColor='var(--aw-primary, #60a5fa)';"
                onmouseout="this.style.borderColor='var(--aw-border, #333)';"
              >
                🧠 Memory
              </a>
              <button
                phx-click="stop-agent"
                phx-value-id={profile.agent_id}
                style="
                  padding: 0.5rem 1rem;
                  border: none;
                  border-radius: 4px;
                  background: var(--aw-error, #ef4444);
                  color: white;
                  font-weight: 500;
                  cursor: pointer;
                  transition: opacity 0.2s;
                "
                onmouseover="this.style.opacity='0.8';"
                onmouseout="this.style.opacity='1';"
              >
                ⏹ Stop
              </button>
            <% else %>
              <%!-- Stopped agent actions --%>
              <button
                phx-click="chat-agent"
                phx-value-id={profile.agent_id}
                style="
                  padding: 0.5rem 1rem;
                  border: none;
                  border-radius: 4px;
                  background: var(--aw-primary, #60a5fa);
                  color: white;
                  font-weight: 500;
                  cursor: pointer;
                  transition: opacity 0.2s;
                "
                onmouseover="this.style.opacity='0.8';"
                onmouseout="this.style.opacity='1';"
              >
                ▶ Resume Chat
              </button>
              <a
                href={"/memory/#{profile.agent_id}"}
                style="
                  padding: 0.5rem 1rem;
                  border: 1px solid var(--aw-border, #333);
                  border-radius: 4px;
                  background: transparent;
                  color: var(--aw-text, #fff);
                  text-decoration: none;
                  cursor: pointer;
                  transition: border-color 0.2s;
                "
                onmouseover="this.style.borderColor='var(--aw-primary, #60a5fa)';"
                onmouseout="this.style.borderColor='var(--aw-border, #333)';"
              >
                🧠 Memory
              </a>
              <button
                phx-click="delete-agent"
                phx-value-id={profile.agent_id}
                data-confirm="Are you sure? This will permanently delete the agent profile."
                style="
                  padding: 0.5rem 1rem;
                  border: none;
                  border-radius: 4px;
                  background: var(--aw-error, #ef4444);
                  color: white;
                  font-weight: 500;
                  cursor: pointer;
                  transition: opacity 0.2s;
                "
                onmouseover="this.style.opacity='0.8';"
                onmouseout="this.style.opacity='1';"
              >
                🗑 Delete
              </button>
            <% end %>
            <button
              phx-click="select-agent"
              phx-value-id={profile.agent_id}
              style="
                padding: 0.5rem 0.75rem;
                border: 1px solid var(--aw-border, #333);
                border-radius: 4px;
                background: transparent;
                color: var(--aw-text-muted, #888);
                cursor: pointer;
                transition: border-color 0.2s;
              "
              onmouseover="this.style.borderColor='var(--aw-primary, #60a5fa)';"
              onmouseout="this.style.borderColor='var(--aw-border, #333)';"
              title="View details"
            >
              ℹ️
            </button>
          </div>
        </div>
      </div>
    </div>

    <div :if={@profile_count == 0} style="margin-top: 1rem;">
      <.empty_state
        icon="\u{1F916}"
        title="No agents yet"
        hint="Agent profiles will appear here when created."
      />
    </div>

    <.modal
      :if={@agent_detail}
      id="agent-detail"
      show={@agent_detail != nil}
      title={"Agent: #{@selected_agent}"}
      on_cancel={Phoenix.LiveView.JS.push("close-detail")}
    >
      <div class="aw-agent-detail">
        <div :if={detail = @agent_detail}>
          <%!-- Action buttons --%>
          <div style="display: flex; gap: 0.5rem; margin-bottom: 1.5rem; padding-bottom: 1rem; border-bottom: 1px solid var(--aw-border, #333);">
            <%= if detail.running do %>
              <button
                phx-click="chat-agent"
                phx-value-id={@selected_agent}
                style="
                  padding: 0.5rem 1rem;
                  border: none;
                  border-radius: 4px;
                  background: var(--aw-success, #22c55e);
                  color: white;
                  font-weight: 500;
                  cursor: pointer;
                "
              >
                💬 Chat
              </button>
              <button
                phx-click="stop-agent"
                phx-value-id={@selected_agent}
                style="
                  padding: 0.5rem 1rem;
                  border: none;
                  border-radius: 4px;
                  background: var(--aw-error, #ef4444);
                  color: white;
                  font-weight: 500;
                  cursor: pointer;
                "
              >
                ⏹ Stop
              </button>
            <% else %>
              <button
                phx-click="chat-agent"
                phx-value-id={@selected_agent}
                style="
                  padding: 0.5rem 1rem;
                  border: none;
                  border-radius: 4px;
                  background: var(--aw-primary, #60a5fa);
                  color: white;
                  font-weight: 500;
                  cursor: pointer;
                "
              >
                ▶ Resume Chat
              </button>
              <button
                phx-click="delete-agent"
                phx-value-id={@selected_agent}
                data-confirm="Are you sure? This will permanently delete the agent profile."
                style="
                  padding: 0.5rem 1rem;
                  border: none;
                  border-radius: 4px;
                  background: var(--aw-error, #ef4444);
                  color: white;
                  font-weight: 500;
                  cursor: pointer;
                "
              >
                🗑 Delete
              </button>
            <% end %>
          </div>

          <%!-- Summary card (Agent.summary/1 — the "2am rule") --%>
          <div
            :if={detail.summary}
            style="margin-bottom: 1.5rem; padding: 0.75rem; border: 1px solid var(--aw-border, #333); border-radius: 6px; background: rgba(96, 165, 250, 0.05);"
          >
            <h4 style="margin: 0 0 0.5rem 0; font-size: 0.9em; color: var(--aw-text-muted, #888); text-transform: uppercase; letter-spacing: 0.05em;">
              Summary
            </h4>
            <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 0.5rem; font-size: 0.9em;">
              <div>
                <strong>Name:</strong>
                <span>{detail.summary.display_name}</span>
              </div>
              <div>
                <strong>Status:</strong>
                <.badge
                  label={to_string(detail.summary.status)}
                  color={if detail.summary.status == :running, do: :green, else: :gray}
                />
              </div>
              <div :if={detail.summary.template}>
                <strong>Template:</strong>
                <span>{detail.summary.template}</span>
              </div>
              <div :if={detail.summary.model}>
                <strong>Model:</strong>
                <code style="font-size: 0.85em;">{detail.summary.model}</code>
              </div>
              <div>
                <strong>Tier:</strong>
                <.badge
                  label={to_string(detail.summary.trust_tier)}
                  color={tier_color(detail.summary.trust_tier)}
                />
              </div>
              <div :if={detail.summary.trust_score}>
                <strong>Score:</strong>
                <span>{detail.summary.trust_score}</span>
              </div>
              <div :if={detail.summary.turn_count}>
                <strong>Turns:</strong>
                <span>{detail.summary.turn_count}</span>
              </div>
              <div>
                <strong>Goals:</strong>
                <span>{detail.summary.active_goals_count}</span>
              </div>
              <div :if={detail.summary.session_cost}>
                <strong>Cost:</strong>
                <span>${:erlang.float_to_binary(detail.summary.session_cost, decimals: 4)}</span>
              </div>
              <div :if={detail.summary.avg_latency_ms}>
                <strong>p50 latency:</strong>
                <span>{detail.summary.avg_latency_ms}ms</span>
              </div>
            </div>
          </div>

          <%!-- Profile section --%>
          <div :if={detail.profile} style="margin-bottom: 1.5rem;">
            <h4 style="margin-bottom: 0.75rem;">Profile</h4>
            <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 0.75rem;">
              <div>
                <strong>Name:</strong>
                <span>{agent_name(detail.profile)}</span>
              </div>
              <div>
                <strong>Trust Tier:</strong>
                <.badge
                  label={to_string(detail.profile.trust_tier)}
                  color={tier_color(detail.profile.trust_tier)}
                />
              </div>
              <div :if={detail.profile.template}>
                <strong>Template:</strong>
                <span>{detail.profile.template}</span>
              </div>
              <div>
                <strong>Version:</strong>
                <span>{detail.profile.version}</span>
              </div>
            </div>
          </div>

          <%!-- Trust summary (from Authority.show_summary CRC convert) --%>
          <div :if={detail.trust_summary} style="margin-bottom: 1.5rem;">
            <h4 style="margin-bottom: 0.75rem;">Trust</h4>
            <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 0.75rem;">
              <div>
                <strong>Score:</strong>
                <span>{detail.trust_summary.trust_score}</span>
              </div>
              <div>
                <strong>Points:</strong>
                <span>{detail.trust_summary.trust_points}</span>
              </div>
              <div>
                <strong>Baseline:</strong>
                <span>{detail.trust_summary.baseline}</span>
              </div>
              <div>
                <strong>Rules:</strong>
                <span>{detail.trust_summary.rule_count}</span>
              </div>
              <div :if={detail.trust_summary.frozen}>
                <strong>Frozen:</strong>
                <.badge label="frozen" color={:red} />
              </div>
            </div>
            <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 0.5rem; margin-top: 0.5rem; font-size: 0.85em; color: var(--aw-text-muted, #888);">
              <div>Actions: {detail.trust_summary.stats.actions}</div>
              <div>Violations: {detail.trust_summary.stats.violations}</div>
              <div>Proposals: {detail.trust_summary.stats.proposals}</div>
              <div>Tests: {detail.trust_summary.stats.tests}</div>
            </div>
          </div>

          <%!-- Model config (from ConfigCore.show_config CRC convert) --%>
          <div :if={detail.model_summary} style="margin-bottom: 1.5rem;">
            <h4 style="margin-bottom: 0.75rem;">Model Configuration</h4>
            <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 0.75rem;">
              <div :if={detail.model_summary.provider}>
                <strong>Provider:</strong>
                <span>{detail.model_summary.provider}</span>
              </div>
              <div :if={detail.model_summary.model}>
                <strong>Model:</strong>
                <code style="font-size: 0.85em;">{detail.model_summary.model}</code>
              </div>
              <div :if={detail.model_summary.backend}>
                <strong>Backend:</strong>
                <.badge label={to_string(detail.model_summary.backend)} color={:blue} />
              </div>
              <div :if={detail.model_summary.temperature}>
                <strong>Temperature:</strong>
                <span>{detail.model_summary.temperature}</span>
              </div>
              <div :if={detail.model_summary.max_tokens}>
                <strong>Max tokens:</strong>
                <span>{detail.model_summary.max_tokens}</span>
              </div>
              <div>
                <strong>Context:</strong>
                <span>{format_token_count(detail.model_summary.context_window)}</span>
              </div>
              <div>
                <strong>Effective:</strong>
                <span>{format_token_count(detail.model_summary.effective_window)}</span>
              </div>
              <div>
                <strong>Max output:</strong>
                <span>{format_token_count(detail.model_summary.max_output)}</span>
              </div>
              <div>
                <strong>Tools:</strong>
                <span>{detail.model_summary.tool_count}</span>
              </div>
            </div>
          </div>

          <%!-- Running status --%>
          <div :if={detail.running} style="margin-bottom: 1.5rem;">
            <h4 style="margin-bottom: 0.75rem;">Running Instance</h4>
            <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 0.75rem;">
              <div>
                <strong>PID:</strong>
                <code style="font-size: 0.85em;">{inspect(detail.running.pid)}</code>
              </div>
              <div>
                <strong>Module:</strong>
                <code style="font-size: 0.85em;">{inspect(detail.running.module)}</code>
              </div>
            </div>
          </div>

          <%!-- Executor stats (from AgentDetailCore.show_executor) --%>
          <div :if={detail.drilldown.executor} style="margin-bottom: 1.5rem;">
            <h4 style="margin-bottom: 0.75rem;">Executor</h4>
            <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); gap: 0.5rem;">
              <.stat_card
                value={detail.drilldown.executor.status_label}
                label="Status"
                color={detail.drilldown.executor.status_color}
              />
              <.stat_card
                value={detail.drilldown.executor.intents_received}
                label="Received"
                color={:blue}
              />
              <.stat_card
                value={detail.drilldown.executor.intents_executed}
                label="Executed"
                color={:green}
              />
              <.stat_card
                value={detail.drilldown.executor.intents_blocked}
                label="Blocked"
                color={:error}
              />
            </div>
          </div>

          <%!-- Reasoning loop (from AgentDetailCore.show_reasoning) --%>
          <div :if={detail.drilldown.reasoning} style="margin-bottom: 1.5rem;">
            <h4 style="margin-bottom: 0.75rem;">Reasoning Loop</h4>
            <div style="display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 0.75rem;">
              <div>
                <strong>Mode:</strong>
                <.badge label={detail.drilldown.reasoning.mode_label} color={:purple} />
              </div>
              <div>
                <strong>Status:</strong>
                <.badge
                  label={detail.drilldown.reasoning.status_label}
                  color={detail.drilldown.reasoning.status_color}
                />
              </div>
              <div>
                <strong>Iteration:</strong>
                <span>{detail.drilldown.reasoning.iteration}</span>
              </div>
            </div>
          </div>

          <%!-- Goals (from AgentDetailCore.show_goals) --%>
          <div :if={detail.drilldown.goals != []} style="margin-bottom: 1.5rem;">
            <h4 style="margin-bottom: 0.75rem;">Active Goals</h4>
            <div
              :for={goal <- detail.drilldown.goals}
              style="border: 1px solid var(--aw-border, #333); border-radius: 4px; padding: 0.75rem; margin-bottom: 0.5rem;"
            >
              <div style="display: flex; align-items: center; gap: 0.5rem;">
                <span>{goal.icon}</span>
                <strong>{goal.label}</strong>
                <.badge :if={goal.priority} label={to_string(goal.priority)} color={:gray} />
              </div>
            </div>
          </div>

          <%!-- Recent thinking (from AgentDetailCore.show_thinking) --%>
          <div :if={detail.drilldown.thinking != []} style="margin-top: 1.5rem;">
            <h4 style="margin-bottom: 0.75rem;">Recent Thinking</h4>
            <div
              :for={block <- detail.drilldown.thinking}
              style="border: 1px solid var(--aw-border, #333); border-radius: 4px; padding: 0.75rem; margin-bottom: 0.5rem; font-size: 0.9em;"
            >
              <div style="display: flex; justify-content: space-between; margin-bottom: 0.25rem;">
                <.badge :if={block.significant} label="significant" color={:purple} />
                <span style="color: var(--aw-text-muted, #888); font-size: 0.85em;">
                  {block.time_relative}
                </span>
              </div>
              <p style="color: var(--aw-text-muted, #888); white-space: pre-wrap;">
                {block.text}
              </p>
            </div>
          </div>

          <%!-- Empty state when no detail available --%>
          <div :if={!detail.profile && !detail.running}>
            <.empty_state
              icon="\u{1F916}"
              title="Agent not found"
              hint="This agent may have been removed or is not yet created."
            />
          </div>
        </div>
      </div>
    </.modal>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  # Model config may have atom or string keys depending on source
  defp format_token_count("unknown"), do: "—"
  defp format_token_count(n) when is_integer(n) and n >= 1000, do: "#{div(n, 1000)}k"
  defp format_token_count(n), do: to_string(n)

  defp agent_name(profile) do
    case profile do
      %{display_name: name} when is_binary(name) and name != "" -> name
      %{character: %{name: name}} when is_binary(name) and name != "" -> name
      %{agent_id: id} -> id
      _ -> "Unknown"
    end
  end

  defp format_created(%DateTime{} = dt), do: Helpers.format_relative_time(dt)
  defp format_created(_), do: ""

  # Drill-down section formatters (executor_status_color, reasoning_status_color,
  # goal_icon, format_thinking_time) live in AgentDetailCore — see safe_load_detail
  # which pre-shapes the drill-down sections via show_drilldown/1.

  defp tier_color(:full_partner), do: :green
  defp tier_color(:trusted), do: :green
  defp tier_color(:established), do: :blue
  defp tier_color(:verified), do: :blue
  defp tier_color(:probationary), do: :purple
  defp tier_color(:untrusted), do: :gray
  defp tier_color(:restricted), do: :error
  defp tier_color(_), do: :gray

  defp status_dot_color(running_ids, agent_id) do
    if MapSet.member?(running_ids, agent_id) do
      "var(--aw-success, #22c55e)"
    else
      "var(--aw-muted, #666)"
    end
  end

  defp status_title(running_ids, agent_id) do
    if MapSet.member?(running_ids, agent_id), do: "Running", else: "Stopped"
  end

  # ── Safe API wrappers ───────────────────────────────────────────────

  defp safe_running_ids do
    case Arbor.Agent.Registry.list() do
      {:ok, agents} -> MapSet.new(agents, & &1.agent_id)
      _ -> MapSet.new()
    end
  rescue
    _ -> MapSet.new()
  catch
    :exit, _ -> MapSet.new()
  end

  defp safe_load_agents do
    running = safe_running()
    profiles = safe_profiles()
    {running, profiles}
  end

  defp safe_running do
    case Arbor.Agent.list() do
      {:ok, agents} -> agents
      _ -> []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_profiles do
    Arbor.Agent.list_agents()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_load_detail(agent_id) do
    summary = safe_summary(agent_id)
    profile = safe_find_profile(agent_id)
    running = safe_lookup(agent_id)
    executor = safe_executor_status(agent_id)
    reasoning = safe_reasoning_status(agent_id)
    goals = safe_goals(agent_id)
    thinking = safe_thinking(agent_id)
    model_config = safe_model_config(agent_id, profile, running)
    model_summary = safe_model_summary(model_config)
    trust_summary = safe_trust_summary(agent_id)

    detail = %{
      summary: summary,
      profile: profile,
      running: running,
      executor: executor,
      reasoning: reasoning,
      goals: goals,
      thinking: thinking,
      model_config: model_config,
      model_summary: model_summary,
      trust_summary: trust_summary
    }

    # Pre-shape drill-down sections via AgentDetailCore so the template
    # iterates over already-formatted maps instead of reaching into raw
    # executor/reasoning/goals/thinking structs inline.
    Map.put(detail, :drilldown, Arbor.Dashboard.Cores.AgentDetailCore.show_drilldown(detail))
  end

  defp safe_summary(agent_id) do
    case Arbor.Agent.summary(agent_id) do
      {:ok, summary} -> summary
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_model_summary(nil), do: nil

  defp safe_model_summary(model_config) do
    case Arbor.Agent.ConfigCore.from_metadata(model_config) do
      nil -> nil
      config -> Arbor.Agent.ConfigCore.show_config(config)
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_trust_summary(agent_id) do
    case Arbor.Trust.get_trust_profile(agent_id) do
      {:ok, profile} -> Arbor.Trust.Authority.show_summary(profile)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_model_config(agent_id, profile, running) do
    # Try multiple sources for model config:
    # 1. Profile metadata (persisted from AgentManager)
    # 2. Registry metadata (runtime, from AgentManager or Supervisor)
    # 3. DebugAgent state (for system agents)
    config =
      get_in(profile || %{}, [Access.key(:metadata, %{}), :last_model_config]) ||
        get_in(running || %{}, [Access.key(:metadata, %{}), :model_config]) ||
        safe_debug_agent_config(agent_id)

    config
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_debug_agent_config(agent_id) do
    # For DebugAgent, check the orchestrator session config
    case Lifecycle.get_host(agent_id) do
      {:ok, host_pid} ->
        state = :sys.get_state(host_pid)

        cond do
          is_map(state) and Map.has_key?(state, :model_config) ->
            state.model_config

          is_map(state) and Map.has_key?(state, :provider) ->
            %{provider: state.provider, model: state.model}

          true ->
            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_find_profile(agent_id) do
    case Arbor.Agent.load_profile(agent_id) do
      {:ok, profile} -> profile
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_lookup(agent_id) do
    case Arbor.Agent.lookup(agent_id) do
      {:ok, entry} -> entry
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_executor_status(agent_id) do
    case Executor.status(agent_id) do
      {:ok, status} -> status
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_reasoning_status(agent_id) do
    case ReasoningLoop.status(agent_id) do
      {:ok, status} -> status
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_goals(agent_id) do
    Arbor.Memory.get_active_goals(agent_id)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_thinking(agent_id) do
    Arbor.Memory.recent_thinking(agent_id, limit: 10)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
