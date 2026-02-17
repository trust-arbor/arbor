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

          <%!-- Model config --%>
          <div :if={detail.model_config} style="margin-bottom: 1.5rem;">
            <h4 style="margin-bottom: 0.75rem;">Model Configuration</h4>
            <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 0.75rem;">
              <div :if={model_field(detail.model_config, :provider)}>
                <strong>Provider:</strong>
                <span>{model_field(detail.model_config, :provider)}</span>
              </div>
              <div :if={
                model_field(detail.model_config, :id) || model_field(detail.model_config, :model)
              }>
                <strong>Model:</strong>
                <code style="font-size: 0.85em;">
                  {model_field(detail.model_config, :id) || model_field(detail.model_config, :model)}
                </code>
              </div>
              <div :if={model_field(detail.model_config, :backend)}>
                <strong>Backend:</strong>
                <.badge label={to_string(model_field(detail.model_config, :backend))} color={:blue} />
              </div>
              <div :if={model_field(detail.model_config, :temperature)}>
                <strong>Temperature:</strong>
                <span>{model_field(detail.model_config, :temperature)}</span>
              </div>
              <div :if={model_field(detail.model_config, :max_tokens)}>
                <strong>Max tokens:</strong>
                <span>{model_field(detail.model_config, :max_tokens)}</span>
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

          <%!-- Executor stats --%>
          <div :if={detail.executor} style="margin-bottom: 1.5rem;">
            <h4 style="margin-bottom: 0.75rem;">Executor</h4>
            <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); gap: 0.5rem;">
              <.stat_card
                value={to_string(detail.executor.status)}
                label="Status"
                color={executor_status_color(detail.executor.status)}
              />
              <.stat_card
                value={get_in(detail.executor, [:stats, :intents_received]) || 0}
                label="Received"
                color={:blue}
              />
              <.stat_card
                value={get_in(detail.executor, [:stats, :intents_executed]) || 0}
                label="Executed"
                color={:green}
              />
              <.stat_card
                value={get_in(detail.executor, [:stats, :intents_blocked]) || 0}
                label="Blocked"
                color={:error}
              />
            </div>
          </div>

          <%!-- Reasoning loop --%>
          <div :if={detail.reasoning} style="margin-bottom: 1.5rem;">
            <h4 style="margin-bottom: 0.75rem;">Reasoning Loop</h4>
            <div style="display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 0.75rem;">
              <div>
                <strong>Mode:</strong>
                <.badge label={to_string(detail.reasoning.mode)} color={:purple} />
              </div>
              <div>
                <strong>Status:</strong>
                <.badge
                  label={to_string(detail.reasoning.status)}
                  color={reasoning_status_color(detail.reasoning.status)}
                />
              </div>
              <div>
                <strong>Iteration:</strong>
                <span>{detail.reasoning.iteration}</span>
              </div>
            </div>
          </div>

          <%!-- Goals --%>
          <div :if={detail.goals != []} style="margin-bottom: 1.5rem;">
            <h4 style="margin-bottom: 0.75rem;">Active Goals</h4>
            <div
              :for={goal <- detail.goals}
              style="border: 1px solid var(--aw-border, #333); border-radius: 4px; padding: 0.75rem; margin-bottom: 0.5rem;"
            >
              <div style="display: flex; align-items: center; gap: 0.5rem;">
                <span>{goal_icon(goal)}</span>
                <strong>{goal.description || goal.type}</strong>
                <.badge :if={goal.priority} label={to_string(goal.priority)} color={:gray} />
              </div>
            </div>
          </div>

          <%!-- Recent thinking --%>
          <div :if={detail.thinking != []} style="margin-top: 1.5rem;">
            <h4 style="margin-bottom: 0.75rem;">Recent Thinking</h4>
            <div
              :for={block <- Enum.take(detail.thinking, 5)}
              style="border: 1px solid var(--aw-border, #333); border-radius: 4px; padding: 0.75rem; margin-bottom: 0.5rem; font-size: 0.9em;"
            >
              <div style="display: flex; justify-content: space-between; margin-bottom: 0.25rem;">
                <.badge :if={block[:significant]} label="significant" color={:purple} />
                <span style="color: var(--aw-text-muted, #888); font-size: 0.85em;">
                  {format_thinking_time(block[:created_at])}
                </span>
              </div>
              <p style="color: var(--aw-text-muted, #888); white-space: pre-wrap;">
                {Helpers.truncate(block[:text] || "", 300)}
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
  defp model_field(nil, _key), do: nil

  defp model_field(config, key) when is_map(config) do
    Map.get(config, key) || Map.get(config, to_string(key))
  end

  defp agent_name(profile) do
    case profile do
      %{character: %{name: name}} when is_binary(name) and name != "" -> name
      %{agent_id: id} -> id
      _ -> "Unknown"
    end
  end

  defp format_created(%DateTime{} = dt), do: Helpers.format_relative_time(dt)
  defp format_created(_), do: ""

  defp format_thinking_time(%DateTime{} = dt), do: Helpers.format_relative_time(dt)
  defp format_thinking_time(_), do: ""

  defp tier_color(:full_partner), do: :green
  defp tier_color(:trusted), do: :green
  defp tier_color(:established), do: :blue
  defp tier_color(:verified), do: :blue
  defp tier_color(:probationary), do: :purple
  defp tier_color(:untrusted), do: :gray
  defp tier_color(:restricted), do: :error
  defp tier_color(_), do: :gray

  defp executor_status_color(:running), do: :green
  defp executor_status_color(:paused), do: :purple
  defp executor_status_color(:stopped), do: :gray
  defp executor_status_color(_), do: :gray

  defp reasoning_status_color(:thinking), do: :blue
  defp reasoning_status_color(:idle), do: :gray
  defp reasoning_status_color(:awaiting_percept), do: :purple
  defp reasoning_status_color(_), do: :gray

  defp goal_icon(%{type: :maintain}), do: "\u{1F504}"
  defp goal_icon(%{type: :achieve}), do: "\u{1F3AF}"
  defp goal_icon(_), do: "\u{2B50}"

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
    profile = safe_find_profile(agent_id)
    running = safe_lookup(agent_id)
    executor = safe_executor_status(agent_id)
    reasoning = safe_reasoning_status(agent_id)
    goals = safe_goals(agent_id)
    thinking = safe_thinking(agent_id)
    model_config = safe_model_config(agent_id, profile, running)

    %{
      profile: profile,
      running: running,
      executor: executor,
      reasoning: reasoning,
      goals: goals,
      thinking: thinking,
      model_config: model_config
    }
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
    Arbor.Agent.list_agents()
    |> Enum.find(&(&1.agent_id == agent_id))
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
