defmodule Arbor.Dashboard.Live.AgentsLive do
  @moduledoc """
  Agent instances dashboard.

  Shows running agents, profiles, executor/reasoning status,
  and reasoning history.
  """

  use Phoenix.LiveView

  import Arbor.Web.Components

  alias Arbor.Agent.{Executor, ReasoningLoop}
  alias Arbor.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    subscription_id =
      if connected?(socket) do
        safe_subscribe()
      end

    {running, profiles} = safe_load_agents()

    socket =
      socket
      |> assign(
        page_title: "Agents",
        running_count: length(running),
        profile_count: length(profiles),
        selected_agent: nil,
        agent_detail: nil,
        subscription_id: subscription_id
      )
      |> stream(:agents, profiles)

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
  def handle_info({:signal_received, _signal}, socket) do
    {running, profiles} = safe_load_agents()

    socket =
      socket
      |> assign(:running_count, length(running))
      |> assign(:profile_count, length(profiles))
      |> stream(:agents, profiles, reset: true)

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select-agent", %{"id" => agent_id}, socket) do
    detail = safe_load_detail(agent_id)
    {:noreply, assign(socket, selected_agent: agent_id, agent_detail: detail)}
  end

  def handle_event("close-detail", _params, socket) do
    {:noreply, assign(socket, selected_agent: nil, agent_detail: nil)}
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
        phx-click="select-agent"
        phx-value-id={profile.agent_id}
        style="cursor: pointer;"
      >
        <.event_card
          icon="\u{1F916}"
          title={agent_name(profile)}
          subtitle={agent_subtitle(profile)}
          timestamp={format_created(profile.created_at)}
        />
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
                <.badge :if={goal[:priority]} label={to_string(goal.priority)} color={:gray} />
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

  defp agent_name(profile) do
    case profile do
      %{character: %{name: name}} when is_binary(name) and name != "" -> name
      %{agent_id: id} -> id
      _ -> "Unknown"
    end
  end

  defp agent_subtitle(profile) do
    tier = to_string(profile.trust_tier)
    template = if profile.template, do: " | #{profile.template}", else: ""
    "#{tier}#{template}"
  end

  defp format_created(%DateTime{} = dt), do: Helpers.format_relative_time(dt)
  defp format_created(_), do: ""

  defp format_thinking_time(%DateTime{} = dt), do: Helpers.format_relative_time(dt)
  defp format_thinking_time(_), do: ""

  defp tier_color(:trusted), do: :green
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

  # ── Safe API wrappers ───────────────────────────────────────────────

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

    %{
      profile: profile,
      running: running,
      executor: executor,
      reasoning: reasoning,
      goals: goals,
      thinking: thinking
    }
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

  defp safe_subscribe do
    pid = self()

    case Arbor.Signals.subscribe("agent.*", fn signal ->
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
