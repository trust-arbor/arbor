defmodule Arbor.Dashboard.Live.MemoryLive do
  @moduledoc """
  Memory Viewer — tabbed inspection of agent memory state.

  Provides 8 tabs: Overview, Identity, Goals, Knowledge Graph,
  Working Memory, Preferences, Proposals, and Code.
  """

  use Phoenix.LiveView
  use Arbor.Dashboard.Live.SignalSubscription

  import Arbor.Web.Components
  import Arbor.Web.Helpers

  alias Arbor.Dashboard.ChatState
  alias Arbor.Web.Helpers

  @refresh_interval 10_000
  @tabs ~w(overview identity goals knowledge working_memory preferences proposals code)
  @expandable_sections ~w(thoughts concerns curiosity goals proposals kg)a

  @impl true
  def mount(%{"agent_id" => agent_id}, _session, socket) do
    ChatState.init()

    socket =
      socket
      |> assign(
        page_title: "Memory — #{agent_id}",
        agent_id: agent_id,
        active_tab: "overview",
        expanded_section: nil,
        tab_data: %{},
        error: nil
      )
      |> load_tab_data("overview", agent_id)

    socket =
      if connected?(socket) do
        Process.send_after(self(), :refresh, @refresh_interval)

        subscribe_signals(socket, "memory.*", fn s ->
          if aid = s.assigns.agent_id do
            load_tab_data(s, s.assigns.active_tab, aid)
          else
            s
          end
        end)
      else
        socket
      end

    {:ok, socket}
  end

  def mount(_params, _session, socket) do
    ChatState.init()

    socket =
      assign(socket,
        page_title: "Memory Viewer",
        agent_id: nil,
        active_tab: nil,
        expanded_section: nil,
        tab_data: %{},
        error: nil,
        available_agents: discover_agents()
      )

    {:ok, socket}
  end

  # terminate/2 injected by SignalSubscription — calls unsubscribe automatically

  # ── Events ────────────────────────────────────────────────────────

  @impl true
  def handle_event("change-tab", %{"tab" => tab}, socket) when tab in @tabs do
    agent_id = socket.assigns.agent_id

    socket =
      socket
      |> assign(active_tab: tab, expanded_section: nil)
      |> load_tab_data(tab, agent_id)

    {:noreply, socket}
  end

  def handle_event("toggle-section", %{"section" => section}, socket) do
    section_atom = String.to_existing_atom(section)

    if section_atom in @expandable_sections do
      current = socket.assigns.expanded_section
      new_section = if current == section_atom, do: nil, else: section_atom

      socket =
        socket
        |> assign(expanded_section: new_section)
        |> maybe_load_section_data(new_section, socket.assigns.agent_id)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select-agent", %{"agent_id" => agent_id}, socket) do
    {:noreply, push_navigate(socket, to: "/memory/#{agent_id}")}
  end

  def handle_event("refresh", _params, socket) do
    if agent_id = socket.assigns.agent_id do
      {:noreply, load_tab_data(socket, socket.assigns.active_tab, agent_id)}
    else
      {:noreply, assign(socket, available_agents: discover_agents())}
    end
  end

  def handle_event("accept-proposal", %{"id" => proposal_id}, socket) do
    agent_id = socket.assigns.agent_id
    safe_call(fn -> Arbor.Memory.accept_proposal(agent_id, proposal_id) end)
    {:noreply, load_tab_data(socket, "proposals", agent_id)}
  end

  def handle_event("reject-proposal", %{"id" => proposal_id}, socket) do
    agent_id = socket.assigns.agent_id
    safe_call(fn -> Arbor.Memory.reject_proposal(agent_id, proposal_id) end)
    {:noreply, load_tab_data(socket, "proposals", agent_id)}
  end

  def handle_event("defer-proposal", %{"id" => proposal_id}, socket) do
    agent_id = socket.assigns.agent_id
    safe_call(fn -> Arbor.Memory.defer_proposal(agent_id, proposal_id) end)
    {:noreply, load_tab_data(socket, "proposals", agent_id)}
  end

  # ── Info Handlers ─────────────────────────────────────────────────

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)

    if agent_id = socket.assigns.agent_id do
      {:noreply, load_tab_data(socket, socket.assigns.active_tab, agent_id)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Render ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header
      title="Memory Viewer"
      subtitle={if @agent_id, do: "Agent: #{@agent_id}", else: "Select an agent to inspect"}
    />

    <%= if @agent_id do %>
      <%!-- Tab bar --%>
      <div style="display: flex; gap: 0.25rem; padding: 0.5rem 0.75rem; margin-top: 0.5rem; border: 1px solid var(--aw-border, #333); border-radius: 6px; flex-wrap: wrap;">
        <button
          :for={tab <- tabs()}
          phx-click="change-tab"
          phx-value-tab={tab}
          style={"padding: 0.35rem 0.75rem; border: 1px solid #{if @active_tab == tab, do: "var(--aw-accent, #4a9eff)", else: "var(--aw-border, #333)"}; border-radius: 4px; cursor: pointer; font-size: 0.85em; color: #{if @active_tab == tab, do: "white", else: "var(--aw-text-muted, #888)"}; background: #{if @active_tab == tab, do: "var(--aw-accent, #4a9eff)", else: "transparent"};"}
        >
          {tab_label(tab)}
        </button>
        <div style="flex: 1;"></div>
        <button
          phx-click="refresh"
          style="padding: 0.35rem 0.75rem; border: 1px solid var(--aw-border, #333); border-radius: 4px; cursor: pointer; font-size: 0.85em; color: var(--aw-text-muted, #888); background: transparent;"
        >
          🔄 Refresh
        </button>
      </div>

      <%!-- Tab content --%>
      <div style="margin-top: 0.5rem; border: 1px solid var(--aw-border, #333); border-radius: 6px; padding: 0.75rem; min-height: 60vh; overflow-y: auto;">
        {render_tab(assigns)}
      </div>
    <% else %>
      <%!-- Agent selector --%>
      <div style="margin-top: 1rem; max-width: 600px;">
        <.card title="Select Agent">
          <div :if={@available_agents == []} style="padding: 1rem;">
            <.empty_state
              icon="🧠"
              title="No agents with memory data"
              hint="Start an agent with memory enabled in the Chat page"
            />
          </div>
          <div
            :for={agent <- @available_agents}
            style="padding: 0.5rem; border-bottom: 1px solid var(--aw-border, #333);"
          >
            <button
              phx-click="select-agent"
              phx-value-agent_id={agent.agent_id}
              style="display: flex; align-items: center; gap: 0.75rem; width: 100%; padding: 0.5rem; border: none; background: transparent; color: inherit; cursor: pointer; border-radius: 4px; text-align: left;"
            >
              <span style="font-size: 1.2em;">🤖</span>
              <div>
                <div style="font-weight: 500;">{agent.agent_id}</div>
                <div
                  :if={agent[:last_seen]}
                  style="font-size: 0.8em; color: var(--aw-text-muted, #888);"
                >
                  Last seen: {Helpers.format_relative_time(agent.last_seen)}
                  {if agent[:message_count], do: " · #{agent.message_count} messages", else: ""}
                </div>
              </div>
            </button>
          </div>
        </.card>
      </div>
    <% end %>
    """
  end

  # ── Tab Renderers ─────────────────────────────────────────────────

  defp render_tab(%{active_tab: "overview"} = assigns) do
    ~H"""
    <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 0.75rem;">
      <.clickable_stat_card
        label="Engagement"
        value={format_pct(@tab_data[:engagement])}
        section={nil}
        expanded={nil}
      />
      <.clickable_stat_card
        label="Thoughts"
        value={@tab_data[:thought_count] || get_in(@tab_data, [:wm_stats, :thought_count]) || 0}
        section="thoughts"
        expanded={@expanded_section}
      />
      <.clickable_stat_card
        label="Concerns"
        value={@tab_data[:concerns_count] || 0}
        section="concerns"
        expanded={@expanded_section}
      />
      <.clickable_stat_card
        label="Curiosity"
        value={@tab_data[:curiosity_count] || 0}
        section="curiosity"
        expanded={@expanded_section}
      />
      <.clickable_stat_card
        label="Active Goals"
        value={@tab_data[:goal_count] || 0}
        section="goals"
        expanded={@expanded_section}
      />
      <.clickable_stat_card
        label="Proposals Pending"
        value={get_in(@tab_data, [:proposal_stats, :pending]) || 0}
        section="proposals"
        expanded={@expanded_section}
      />
      <.clickable_stat_card
        label="KG Nodes"
        value={get_in(@tab_data, [:kg_stats, :node_count]) || 0}
        section="kg"
        expanded={@expanded_section}
      />
      <.clickable_stat_card
        label="KG Edges"
        value={get_in(@tab_data, [:kg_stats, :edge_count]) || 0}
        section="kg"
        expanded={@expanded_section}
      />
    </div>

    <%!-- Expanded detail panel --%>
    <div
      :if={@expanded_section}
      style="margin-top: 0.75rem; border: 1px solid var(--aw-border, #333); border-radius: 6px; padding: 0.75rem; background: rgba(0,0,0,0.15);"
    >
      {render_expanded_section(assigns)}
    </div>
    """
  end

  defp render_tab(%{active_tab: "identity"} = assigns) do
    ~H"""
    <div>
      <div :if={@tab_data[:self_knowledge]} style="margin-bottom: 1rem;">
        <h3 style="font-size: 0.95em; margin-bottom: 0.5rem;">Personality Traits</h3>
        <div :if={traits(@tab_data[:self_knowledge]) == []} style="padding: 0.5rem;">
          <.empty_state icon="🪞" title="No traits yet" hint="" />
        </div>
        <div
          :for={trait <- traits(@tab_data[:self_knowledge])}
          style="display: flex; align-items: center; gap: 0.5rem; padding: 0.3rem; margin-bottom: 0.25rem; border-radius: 4px; background: rgba(168, 85, 247, 0.05); font-size: 0.85em;"
        >
          <span style="font-weight: 500; min-width: 120px;">{elem(trait, 0)}</span>
          <div style="flex: 1; background: rgba(128,128,128,0.2); height: 4px; border-radius: 2px; overflow: hidden;">
            <div style={"background: #a855f7; height: 100%; width: #{round(elem(trait, 1) * 100)}%;"}>
            </div>
          </div>
          <span style="font-size: 0.8em; color: var(--aw-text-muted, #888);">
            {round(elem(trait, 1) * 100)}%
          </span>
        </div>

        <h3 style="font-size: 0.95em; margin-top: 1rem; margin-bottom: 0.5rem;">Values</h3>
        <div
          :for={value <- values(@tab_data[:self_knowledge])}
          style="display: inline-block; margin: 0.15rem; padding: 0.25rem 0.5rem; border-radius: 4px; background: rgba(34, 197, 94, 0.1); font-size: 0.8em;"
        >
          {elem(value, 0)}
          <span style="color: var(--aw-text-muted, #888); font-size: 0.85em;">
            ({round(elem(value, 1) * 100)}%)
          </span>
        </div>

        <h3 style="font-size: 0.95em; margin-top: 1rem; margin-bottom: 0.5rem;">Capabilities</h3>
        <div :if={caps(@tab_data[:self_knowledge]) == []} style="padding: 0.5rem;">
          <.empty_state icon="⚡" title="No capabilities" hint="" />
        </div>
        <div
          :for={cap <- caps(@tab_data[:self_knowledge])}
          style="display: flex; align-items: center; gap: 0.5rem; padding: 0.3rem; margin-bottom: 0.2rem; font-size: 0.85em;"
        >
          <span>⚡</span>
          <span style="font-weight: 500;">{elem(cap, 0)}</span>
          <.badge label={"#{round(elem(cap, 1) * 100)}%"} color={:blue} />
        </div>
      </div>
      <.empty_state
        :if={@tab_data[:self_knowledge] == nil}
        icon="🪞"
        title="No self-knowledge data"
        hint="Agent needs to be initialized with memory"
      />
    </div>
    """
  end

  defp render_tab(%{active_tab: "goals"} = assigns) do
    ~H"""
    <div>
      <div
        :for={goal <- @tab_data[:goals] || []}
        style="margin-bottom: 0.5rem; padding: 0.5rem; border-radius: 6px; background: rgba(74, 255, 158, 0.05); border: 1px solid var(--aw-border, #333);"
      >
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.3rem;">
          <span style="font-weight: 500; font-size: 0.9em;">{goal.description}</span>
          <div style="display: flex; gap: 0.25rem;">
            <.badge label={to_string(goal.status)} color={goal_color(goal.status)} />
            <.badge :if={goal[:type]} label={to_string(goal.type)} color={:gray} />
            <.badge label={"P#{goal.priority}"} color={:blue} />
          </div>
        </div>
        <div style="background: rgba(128,128,128,0.2); height: 4px; border-radius: 2px; overflow: hidden; margin-bottom: 0.2rem;">
          <div style={"background: #22c55e; height: 100%; width: #{round(goal.progress * 100)}%;"}>
          </div>
        </div>
        <div style="display: flex; justify-content: space-between; font-size: 0.75em; color: var(--aw-text-muted, #888);">
          <span>{round(goal.progress * 100)}% complete</span>
          <span :if={goal[:deadline]}>Deadline: {format_deadline(goal.deadline)}</span>
        </div>
      </div>
      <.empty_state
        :if={(@tab_data[:goals] || []) == []}
        icon="🎯"
        title="No goals"
        hint="Goals appear as the agent works"
      />
    </div>
    """
  end

  defp render_tab(%{active_tab: "knowledge"} = assigns) do
    ~H"""
    <div>
      <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 0.5rem; margin-bottom: 1rem;">
        <.stat_card label="Nodes" value={get_in(@tab_data, [:stats, :node_count]) || 0} />
        <.stat_card label="Edges" value={get_in(@tab_data, [:stats, :edge_count]) || 0} />
        <.stat_card label="Active Set" value={get_in(@tab_data, [:stats, :active_set_size]) || 0} />
        <.stat_card label="Pending" value={get_in(@tab_data, [:stats, :pending_count]) || 0} />
      </div>

      <h3 style="font-size: 0.95em; margin-bottom: 0.5rem;">
        Near-Threshold Nodes (decay candidates)
      </h3>
      <div
        :for={node <- @tab_data[:near_threshold] || []}
        style="display: flex; align-items: center; gap: 0.5rem; padding: 0.35rem; margin-bottom: 0.25rem; border-radius: 4px; background: rgba(234, 179, 8, 0.1); font-size: 0.85em;"
      >
        <.badge label={to_string(node[:type] || "unknown")} color={:yellow} />
        <span style="flex: 1;">{node[:content] || node[:name] || "—"}</span>
        <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
          relevance: {Float.round((node[:relevance] || 0) * 1.0, 3)}
        </span>
      </div>
      <.empty_state
        :if={(@tab_data[:near_threshold] || []) == []}
        icon="🕸️"
        title="No near-threshold nodes"
        hint=""
      />
    </div>
    """
  end

  defp render_tab(%{active_tab: "working_memory"} = assigns) do
    ~H"""
    <div>
      <div :if={@tab_data[:working_memory]}>
        <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 0.5rem; margin-bottom: 1rem;">
          <.stat_card
            label="Engagement"
            value={format_pct(Map.get(@tab_data[:working_memory], :engagement_level, 0.5))}
          />
          <.stat_card
            label="Thoughts"
            value={length(Map.get(@tab_data[:working_memory], :recent_thoughts, []))}
          />
          <.stat_card
            label="Concerns"
            value={length(Map.get(@tab_data[:working_memory], :concerns, []))}
          />
          <.stat_card
            label="Curiosity"
            value={length(Map.get(@tab_data[:working_memory], :curiosity, []))}
          />
        </div>

        <h3 style="font-size: 0.95em; margin-bottom: 0.5rem;">Recent Thoughts</h3>
        <div
          :for={thought <- Enum.take(Map.get(@tab_data[:working_memory], :recent_thoughts, []), 10)}
          style="margin-bottom: 0.35rem; padding: 0.35rem; border-radius: 4px; background: rgba(255, 165, 0, 0.1); font-size: 0.85em;"
        >
          <span>💭</span>
          <span style="color: var(--aw-text-muted, #888);">
            {Helpers.truncate(thought[:content] || to_string(thought), 200)}
          </span>
        </div>

        <h3
          :if={Map.get(@tab_data[:working_memory], :concerns, []) != []}
          style="font-size: 0.95em; margin-top: 0.75rem; margin-bottom: 0.5rem;"
        >
          Concerns
        </h3>
        <div
          :for={concern <- Map.get(@tab_data[:working_memory], :concerns, [])}
          style="margin-bottom: 0.25rem; padding: 0.3rem; border-radius: 4px; background: rgba(255, 74, 74, 0.1); font-size: 0.85em;"
        >
          <span>⚠️</span>
          <span style="color: var(--aw-text-muted, #888);">
            {Helpers.truncate(concern[:content] || to_string(concern), 150)}
          </span>
        </div>

        <h3
          :if={Map.get(@tab_data[:working_memory], :curiosity, []) != []}
          style="font-size: 0.95em; margin-top: 0.75rem; margin-bottom: 0.5rem;"
        >
          Curiosity
        </h3>
        <div
          :for={item <- Map.get(@tab_data[:working_memory], :curiosity, [])}
          style="margin-bottom: 0.25rem; padding: 0.3rem; border-radius: 4px; background: rgba(74, 158, 255, 0.1); font-size: 0.85em;"
        >
          <span>🔍</span>
          <span style="color: var(--aw-text-muted, #888);">
            {Helpers.truncate(item[:content] || to_string(item), 150)}
          </span>
        </div>

        <h3
          :if={Map.get(@tab_data[:working_memory], :conversation_context, nil)}
          style="font-size: 0.95em; margin-top: 0.75rem; margin-bottom: 0.5rem;"
        >
          Conversation Context
        </h3>
        <div
          :if={ctx = Map.get(@tab_data[:working_memory], :conversation_context, nil)}
          style="padding: 0.4rem; border-radius: 4px; background: rgba(128,128,128,0.1); font-size: 0.85em;"
        >
          <span style="color: var(--aw-text-muted, #888);">
            {Helpers.truncate(inspect(ctx), 300)}
          </span>
        </div>
      </div>
      <.empty_state
        :if={@tab_data[:working_memory] == nil}
        icon="💭"
        title="No working memory"
        hint="Agent needs to be active"
      />
    </div>
    """
  end

  defp render_tab(%{active_tab: "preferences"} = assigns) do
    ~H"""
    <div>
      <div :if={@tab_data[:prefs]}>
        <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 0.5rem; margin-bottom: 1rem;">
          <.stat_card label="Decay Rate" value={Map.get(@tab_data[:prefs], :decay_rate, "—")} />
          <.stat_card
            label="Retrieval Threshold"
            value={Map.get(@tab_data[:prefs], :retrieval_threshold, "—")}
          />
          <.stat_card label="Pinned Memories" value={Map.get(@tab_data[:prefs], :pinned_count, 0)} />
          <.stat_card label="Adjustments" value={Map.get(@tab_data[:prefs], :adjustment_count, 0)} />
        </div>

        <h3
          :if={Map.get(@tab_data[:prefs], :type_quotas)}
          style="font-size: 0.95em; margin-bottom: 0.5rem;"
        >
          Type Quotas
        </h3>
        <div
          :for={{type, quota} <- Map.get(@tab_data[:prefs], :type_quotas, %{}) |> Enum.to_list()}
          style="display: flex; align-items: center; gap: 0.5rem; padding: 0.3rem; margin-bottom: 0.2rem; font-size: 0.85em;"
        >
          <span style="min-width: 100px; font-weight: 500;">{type}</span>
          <div style="flex: 1; background: rgba(128,128,128,0.2); height: 4px; border-radius: 2px; overflow: hidden;">
            <div style={"background: #4a9eff; height: 100%; width: #{quota}%;"}></div>
          </div>
          <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">{quota}%</span>
        </div>

        <h3
          :if={Map.get(@tab_data[:prefs], :context_preferences)}
          style="font-size: 0.95em; margin-top: 0.75rem; margin-bottom: 0.5rem;"
        >
          Context Preferences
        </h3>
        <div
          :for={
            {key, value} <- Map.get(@tab_data[:prefs], :context_preferences, %{}) |> Enum.to_list()
          }
          style="display: flex; gap: 0.5rem; padding: 0.25rem; font-size: 0.85em;"
        >
          <span style="font-weight: 500; min-width: 150px;">{key}</span>
          <span style="color: var(--aw-text-muted, #888);">{inspect(value)}</span>
        </div>
      </div>
      <.empty_state
        :if={@tab_data[:prefs] == nil}
        icon="⚙️"
        title="No preferences data"
        hint="Preferences appear after initialization"
      />
    </div>
    """
  end

  defp render_tab(%{active_tab: "proposals"} = assigns) do
    ~H"""
    <div>
      <div
        :if={@tab_data[:stats]}
        style="display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 0.5rem; margin-bottom: 1rem;"
      >
        <.stat_card label="Pending" value={Map.get(@tab_data[:stats], :pending, 0)} />
        <.stat_card label="Accepted" value={Map.get(@tab_data[:stats], :accepted, 0)} />
        <.stat_card label="Rejected" value={Map.get(@tab_data[:stats], :rejected, 0)} />
        <.stat_card label="Deferred" value={Map.get(@tab_data[:stats], :deferred, 0)} />
      </div>

      <div
        :for={proposal <- @tab_data[:proposals] || []}
        style="margin-bottom: 0.5rem; padding: 0.5rem; border-radius: 6px; background: rgba(234, 179, 8, 0.05); border: 1px solid var(--aw-border, #333);"
      >
        <div style="display: flex; align-items: center; gap: 0.25rem; margin-bottom: 0.3rem;">
          <.badge :if={proposal[:type]} label={to_string(proposal[:type])} color={:yellow} />
          <.badge
            :if={proposal[:confidence]}
            label={"#{round(proposal[:confidence] * 100)}%"}
            color={:blue}
          />
          <.badge
            :if={proposal[:status]}
            label={to_string(proposal[:status])}
            color={proposal_status_color(proposal[:status])}
          />
        </div>
        <p style="color: var(--aw-text, #ccc); margin: 0 0 0.3rem 0; font-size: 0.9em; white-space: pre-wrap;">
          {Helpers.truncate(proposal[:content] || proposal[:description] || "", 300)}
        </p>
        <div
          :if={proposal[:status] == :pending || proposal[:status] == "pending"}
          style="display: flex; gap: 0.3rem;"
        >
          <button
            phx-click="accept-proposal"
            phx-value-id={proposal[:id]}
            style="padding: 0.25rem 0.6rem; border: none; border-radius: 4px; background: #22c55e; color: white; cursor: pointer; font-size: 0.8em;"
          >
            Accept
          </button>
          <button
            phx-click="reject-proposal"
            phx-value-id={proposal[:id]}
            style="padding: 0.25rem 0.6rem; border: none; border-radius: 4px; background: #ff4a4a; color: white; cursor: pointer; font-size: 0.8em;"
          >
            Reject
          </button>
          <button
            phx-click="defer-proposal"
            phx-value-id={proposal[:id]}
            style="padding: 0.25rem 0.6rem; border: none; border-radius: 4px; background: #888; color: white; cursor: pointer; font-size: 0.8em;"
          >
            Defer
          </button>
        </div>
      </div>
      <.empty_state
        :if={(@tab_data[:proposals] || []) == []}
        icon="📋"
        title="No proposals"
        hint="Proposals appear from reflection & analysis"
      />
    </div>
    """
  end

  defp render_tab(%{active_tab: "code"} = assigns) do
    ~H"""
    <div>
      <div
        :for={entry <- @tab_data[:code_entries] || []}
        style="margin-bottom: 0.5rem; padding: 0.5rem; border-radius: 6px; border: 1px solid var(--aw-border, #333);"
      >
        <div style="display: flex; align-items: center; gap: 0.25rem; margin-bottom: 0.3rem;">
          <span style="font-weight: 500; font-size: 0.9em;">{entry[:purpose] || "untitled"}</span>
          <.badge :if={entry[:language]} label={to_string(entry[:language])} color={:blue} />
        </div>
        <pre style="background: rgba(0,0,0,0.3); padding: 0.5rem; border-radius: 4px; font-size: 0.8em; overflow-x: auto; white-space: pre-wrap; color: var(--aw-text-muted, #888); margin: 0;">{Helpers.truncate(entry[:code] || "", 500)}</pre>
      </div>
      <.empty_state
        :if={(@tab_data[:code_entries] || []) == []}
        icon="💻"
        title="No code entries"
        hint="Code appears when the agent creates patterns"
      />
    </div>
    """
  end

  defp render_tab(assigns) do
    ~H"""
    <.empty_state icon="❓" title="Unknown tab" hint="" />
    """
  end

  # ── Clickable Stat Card ───────────────────────────────────────────

  defp clickable_stat_card(assigns) do
    is_clickable = assigns.section != nil
    is_active = is_clickable && to_string(assigns.expanded) == assigns.section

    assigns =
      assigns
      |> assign(:is_clickable, is_clickable)
      |> assign(:is_active, is_active)

    ~H"""
    <div
      phx-click={if @is_clickable, do: "toggle-section"}
      phx-value-section={@section}
      style={"padding: 0.75rem; border-radius: 6px; border: 1px solid #{if @is_active, do: "var(--aw-accent, #4a9eff)", else: "var(--aw-border, #333)"}; background: #{if @is_active, do: "rgba(74, 158, 255, 0.08)", else: "rgba(255,255,255,0.03)"}; #{if @is_clickable, do: "cursor: pointer;", else: ""}"}
    >
      <div style="font-size: 0.75em; color: var(--aw-text-muted, #888); margin-bottom: 0.25rem; display: flex; justify-content: space-between; align-items: center;">
        <span>{@label}</span>
        <span :if={@is_clickable} style="font-size: 0.9em;">{if @is_active, do: "▼", else: "▶"}</span>
      </div>
      <div style="font-size: 1.5em; font-weight: 600;">{@value}</div>
    </div>
    """
  end

  # ── Expanded Section Renderers ───────────────────────────────────

  defp render_expanded_section(%{expanded_section: :thoughts} = assigns) do
    thoughts = wm_field(assigns.tab_data, :recent_thoughts) || []
    assigns = assign(assigns, :thoughts, thoughts)

    ~H"""
    <h3 style="font-size: 0.95em; margin-bottom: 0.5rem;">Recent Thoughts</h3>
    <div
      :for={thought <- Enum.take(@thoughts, 15)}
      style="margin-bottom: 0.35rem; padding: 0.4rem 0.5rem; border-radius: 4px; background: rgba(255, 165, 0, 0.1); font-size: 0.85em;"
    >
      <span style="margin-right: 0.3rem;">💭</span>
      <span style="color: var(--aw-text, #ccc);">
        {thought[:content] || to_string(thought)}
      </span>
      <div
        :if={thought[:timestamp]}
        style="font-size: 0.75em; color: var(--aw-text-muted, #888); margin-top: 0.15rem;"
      >
        {Helpers.format_relative_time(thought[:timestamp])}
      </div>
    </div>
    <.empty_state
      :if={@thoughts == []}
      icon="💭"
      title="No thoughts yet"
      hint="Thoughts appear as the agent processes information"
    />
    """
  end

  defp render_expanded_section(%{expanded_section: :concerns} = assigns) do
    concerns = wm_field(assigns.tab_data, :concerns) || []
    assigns = assign(assigns, :concerns, concerns)

    ~H"""
    <h3 style="font-size: 0.95em; margin-bottom: 0.5rem;">Concerns</h3>
    <div
      :for={concern <- @concerns}
      style="margin-bottom: 0.35rem; padding: 0.4rem 0.5rem; border-radius: 4px; background: rgba(255, 74, 74, 0.1); font-size: 0.85em;"
    >
      <span style="margin-right: 0.3rem;">⚠️</span>
      <span style="color: var(--aw-text, #ccc);">
        {concern[:content] || to_string(concern)}
      </span>
    </div>
    <.empty_state
      :if={@concerns == []}
      icon="⚠️"
      title="No concerns"
      hint="Concerns appear when the agent detects potential issues"
    />
    """
  end

  defp render_expanded_section(%{expanded_section: :curiosity} = assigns) do
    curiosity = wm_field(assigns.tab_data, :curiosity) || []
    assigns = assign(assigns, :curiosity_items, curiosity)

    ~H"""
    <h3 style="font-size: 0.95em; margin-bottom: 0.5rem;">Curiosity</h3>
    <div
      :for={item <- @curiosity_items}
      style="margin-bottom: 0.35rem; padding: 0.4rem 0.5rem; border-radius: 4px; background: rgba(74, 158, 255, 0.1); font-size: 0.85em;"
    >
      <span style="margin-right: 0.3rem;">🔍</span>
      <span style="color: var(--aw-text, #ccc);">
        {item[:content] || to_string(item)}
      </span>
    </div>
    <.empty_state
      :if={@curiosity_items == []}
      icon="🔍"
      title="No curiosity items"
      hint="Curiosity items appear during idle reflection"
    />
    """
  end

  defp render_expanded_section(%{expanded_section: :goals} = assigns) do
    goals = assigns.tab_data[:goals] || []
    assigns = assign(assigns, :goals, goals)

    ~H"""
    <h3 style="font-size: 0.95em; margin-bottom: 0.5rem;">Active Goals</h3>
    <div
      :for={goal <- @goals}
      style="margin-bottom: 0.5rem; padding: 0.5rem; border-radius: 6px; background: rgba(74, 255, 158, 0.05); border: 1px solid var(--aw-border, #333);"
    >
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.3rem;">
        <span style="font-weight: 500; font-size: 0.9em;">{goal.description}</span>
        <div style="display: flex; gap: 0.25rem;">
          <.badge label={to_string(goal.status)} color={goal_color(goal.status)} />
          <.badge :if={goal[:type]} label={to_string(goal.type)} color={:gray} />
          <.badge label={"P#{goal.priority}"} color={:blue} />
        </div>
      </div>
      <div style="background: rgba(128,128,128,0.2); height: 4px; border-radius: 2px; overflow: hidden; margin-bottom: 0.2rem;">
        <div style={"background: #22c55e; height: 100%; width: #{round(goal.progress * 100)}%;"}>
        </div>
      </div>
      <div style="display: flex; justify-content: space-between; font-size: 0.75em; color: var(--aw-text-muted, #888);">
        <span>{round(goal.progress * 100)}% complete</span>
        <span :if={goal[:deadline]}>Deadline: {format_deadline(goal.deadline)}</span>
      </div>
    </div>
    <.empty_state
      :if={@goals == []}
      icon="🎯"
      title="No active goals"
      hint="Goals appear as the agent works"
    />
    """
  end

  defp render_expanded_section(%{expanded_section: :proposals} = assigns) do
    proposals = assigns.tab_data[:proposals] || []
    stats = assigns.tab_data[:proposal_stats] || %{}
    assigns = assign(assigns, proposals: proposals, proposal_stats_detail: stats)

    ~H"""
    <div style="display: flex; gap: 0.5rem; margin-bottom: 0.75rem;">
      <.badge label={"Pending: #{Map.get(@proposal_stats_detail, :pending, 0)}"} color={:yellow} />
      <.badge label={"Accepted: #{Map.get(@proposal_stats_detail, :accepted, 0)}"} color={:green} />
      <.badge label={"Rejected: #{Map.get(@proposal_stats_detail, :rejected, 0)}"} color={:red} />
      <.badge label={"Deferred: #{Map.get(@proposal_stats_detail, :deferred, 0)}"} color={:gray} />
    </div>
    <div
      :for={proposal <- Enum.take(@proposals, 10)}
      style="margin-bottom: 0.5rem; padding: 0.5rem; border-radius: 6px; background: rgba(234, 179, 8, 0.05); border: 1px solid var(--aw-border, #333);"
    >
      <div style="display: flex; align-items: center; gap: 0.25rem; margin-bottom: 0.3rem;">
        <.badge :if={proposal[:type]} label={to_string(proposal[:type])} color={:yellow} />
        <.badge
          :if={proposal[:confidence]}
          label={"#{round(proposal[:confidence] * 100)}%"}
          color={:blue}
        />
        <.badge
          :if={proposal[:status]}
          label={to_string(proposal[:status])}
          color={proposal_status_color(proposal[:status])}
        />
      </div>
      <p style="color: var(--aw-text, #ccc); margin: 0 0 0.3rem 0; font-size: 0.9em; white-space: pre-wrap;">
        {Helpers.truncate(proposal[:content] || proposal[:description] || "", 300)}
      </p>
      <div
        :if={proposal[:status] == :pending || proposal[:status] == "pending"}
        style="display: flex; gap: 0.3rem;"
      >
        <button
          phx-click="accept-proposal"
          phx-value-id={proposal[:id]}
          style="padding: 0.25rem 0.6rem; border: none; border-radius: 4px; background: #22c55e; color: white; cursor: pointer; font-size: 0.8em;"
        >
          Accept
        </button>
        <button
          phx-click="reject-proposal"
          phx-value-id={proposal[:id]}
          style="padding: 0.25rem 0.6rem; border: none; border-radius: 4px; background: #ff4a4a; color: white; cursor: pointer; font-size: 0.8em;"
        >
          Reject
        </button>
        <button
          phx-click="defer-proposal"
          phx-value-id={proposal[:id]}
          style="padding: 0.25rem 0.6rem; border: none; border-radius: 4px; background: #888; color: white; cursor: pointer; font-size: 0.8em;"
        >
          Defer
        </button>
      </div>
    </div>
    <.empty_state
      :if={@proposals == []}
      icon="📋"
      title="No proposals"
      hint="Proposals appear from reflection & analysis"
    />
    """
  end

  defp render_expanded_section(%{expanded_section: :kg} = assigns) do
    kg_stats = assigns.tab_data[:kg_stats] || %{}
    near_threshold = assigns.tab_data[:near_threshold] || []
    assigns = assign(assigns, kg_detail: kg_stats, near_threshold: near_threshold)

    ~H"""
    <h3 style="font-size: 0.95em; margin-bottom: 0.5rem;">Knowledge Graph</h3>
    <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 0.5rem; margin-bottom: 0.75rem;">
      <.stat_card label="Nodes" value={Map.get(@kg_detail, :node_count, 0)} />
      <.stat_card label="Edges" value={Map.get(@kg_detail, :edge_count, 0)} />
      <.stat_card label="Active Set" value={Map.get(@kg_detail, :active_set_size, 0)} />
      <.stat_card label="Pending" value={Map.get(@kg_detail, :pending_count, 0)} />
    </div>

    <h4 :if={@near_threshold != []} style="font-size: 0.9em; margin-bottom: 0.4rem;">
      Near-Threshold Nodes (decay candidates)
    </h4>
    <div
      :for={node <- @near_threshold}
      style="display: flex; align-items: center; gap: 0.5rem; padding: 0.35rem; margin-bottom: 0.25rem; border-radius: 4px; background: rgba(234, 179, 8, 0.1); font-size: 0.85em;"
    >
      <.badge label={to_string(node[:type] || "unknown")} color={:yellow} />
      <span style="flex: 1;">{node[:content] || node[:name] || "—"}</span>
      <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
        relevance: {Float.round((node[:relevance] || 0) * 1.0, 3)}
      </span>
    </div>
    <.empty_state :if={@near_threshold == []} icon="🕸️" title="No near-threshold nodes" hint="" />
    """
  end

  defp render_expanded_section(assigns) do
    ~H"""
    """
  end

  # ── Data Loading ──────────────────────────────────────────────────

  defp load_tab_data(socket, "overview", agent_id) do
    data =
      case safe_call(fn -> Arbor.Memory.read_self(agent_id, :all) end) do
        {:ok, result} when is_map(result) ->
          build_overview_data(result, agent_id)

        _ ->
          %{}
      end

    assign(socket, tab_data: data)
  end

  defp load_tab_data(socket, "identity", agent_id) do
    sk = safe_call(fn -> Arbor.Memory.get_self_knowledge(agent_id) end)
    assign(socket, tab_data: %{self_knowledge: sk})
  end

  defp load_tab_data(socket, "goals", agent_id) do
    goals =
      case safe_call(fn -> Arbor.Memory.get_active_goals(agent_id) end) do
        result when is_list(result) -> result
        _ -> []
      end

    assign(socket, tab_data: %{goals: goals})
  end

  defp load_tab_data(socket, "knowledge", agent_id) do
    stats = unwrap_map(safe_call(fn -> Arbor.Memory.knowledge_stats(agent_id) end)) || %{}
    near = unwrap_list(safe_call(fn -> Arbor.Memory.near_threshold_nodes(agent_id, 10) end))
    assign(socket, tab_data: %{stats: stats, near_threshold: near})
  end

  defp load_tab_data(socket, "working_memory", agent_id) do
    wm = unwrap_map(safe_call(fn -> Arbor.Memory.load_working_memory(agent_id) end))
    assign(socket, tab_data: %{working_memory: wm})
  end

  defp load_tab_data(socket, "preferences", agent_id) do
    prefs = unwrap_map(safe_call(fn -> Arbor.Memory.inspect_preferences(agent_id) end))
    assign(socket, tab_data: %{prefs: prefs})
  end

  defp load_tab_data(socket, "proposals", agent_id) do
    proposals = unwrap_list(safe_call(fn -> Arbor.Memory.get_proposals(agent_id) end))
    stats = unwrap_map(safe_call(fn -> Arbor.Memory.proposal_stats(agent_id) end)) || %{}
    assign(socket, tab_data: %{proposals: proposals, stats: stats})
  end

  defp load_tab_data(socket, "code", agent_id) do
    entries = unwrap_list(safe_call(fn -> Arbor.Memory.list_code(agent_id) end))
    assign(socket, tab_data: %{code_entries: entries})
  end

  defp load_tab_data(socket, _tab, _agent_id) do
    assign(socket, tab_data: %{})
  end

  defp build_overview_data(result, agent_id) do
    kg = get_in(result, [:memory_system, :knowledge_graph]) || %{}
    wm = get_in(result, [:memory_system, :working_memory]) || %{}
    proposals_summary = get_in(result, [:memory_system, :proposals]) || %{}
    goals = unwrap_list(safe_call(fn -> Arbor.Memory.get_active_goals(agent_id) end))
    engagement = get_in(result, [:cognition, :working_memory, :engagement]) || 0.5

    direct_wm = unwrap_map(safe_call(fn -> Arbor.Memory.load_working_memory(agent_id) end))
    proposals_list = unwrap_list(safe_call(fn -> Arbor.Memory.get_proposals(agent_id) end))

    near_threshold =
      unwrap_list(safe_call(fn -> Arbor.Memory.near_threshold_nodes(agent_id, 10) end))

    %{
      kg_stats: kg,
      wm_stats: wm,
      proposal_stats: proposals_summary,
      goal_count: length(goals),
      goals: goals,
      proposals: proposals_list,
      near_threshold: near_threshold,
      working_memory: direct_wm,
      engagement: wm_field(direct_wm, :engagement_level, engagement),
      thought_count: wm_list_count(direct_wm, :recent_thoughts),
      concerns_count: wm_list_count(direct_wm, :concerns),
      curiosity_count: wm_list_count(direct_wm, :curiosity)
    }
  end

  defp wm_field(nil, _key, default), do: default
  defp wm_field(wm, key, default), do: Map.get(wm, key, default)

  defp wm_list_count(nil, _key), do: 0
  defp wm_list_count(wm, key), do: length(Map.get(wm, key, []))

  # Refresh section-specific data when expanding from Overview
  defp maybe_load_section_data(socket, nil, _agent_id), do: socket

  defp maybe_load_section_data(socket, section, agent_id)
       when section in [:thoughts, :concerns, :curiosity] do
    direct_wm = unwrap_map(safe_call(fn -> Arbor.Memory.load_working_memory(agent_id) end))
    update(socket, :tab_data, &Map.put(&1, :working_memory, direct_wm))
  end

  defp maybe_load_section_data(socket, :goals, agent_id) do
    goals = unwrap_list(safe_call(fn -> Arbor.Memory.get_active_goals(agent_id) end))
    update(socket, :tab_data, &Map.put(&1, :goals, goals))
  end

  defp maybe_load_section_data(socket, :proposals, agent_id) do
    proposals = unwrap_list(safe_call(fn -> Arbor.Memory.get_proposals(agent_id) end))
    stats = unwrap_map(safe_call(fn -> Arbor.Memory.proposal_stats(agent_id) end)) || %{}

    socket
    |> update(:tab_data, &Map.merge(&1, %{proposals: proposals, proposal_stats: stats}))
  end

  defp maybe_load_section_data(socket, :kg, agent_id) do
    near = unwrap_list(safe_call(fn -> Arbor.Memory.near_threshold_nodes(agent_id, 10) end))
    update(socket, :tab_data, &Map.put(&1, :near_threshold, near))
  end

  defp maybe_load_section_data(socket, _section, _agent_id), do: socket

  # ── Helpers ───────────────────────────────────────────────────────

  defp tabs, do: @tabs

  defp tab_label("overview"), do: "📊 Overview"
  defp tab_label("identity"), do: "🪞 Identity"
  defp tab_label("goals"), do: "🎯 Goals"
  defp tab_label("knowledge"), do: "🕸️ Knowledge"
  defp tab_label("working_memory"), do: "💭 Working Memory"
  defp tab_label("preferences"), do: "⚙️ Preferences"
  defp tab_label("proposals"), do: "📋 Proposals"
  defp tab_label("code"), do: "💻 Code"
  defp tab_label(other), do: other

  defp goal_color(:active), do: :green
  defp goal_color(:achieved), do: :blue
  defp goal_color(:abandoned), do: :red
  defp goal_color(:failed), do: :red
  defp goal_color(_), do: :gray

  defp proposal_status_color(:pending), do: :yellow
  defp proposal_status_color("pending"), do: :yellow
  defp proposal_status_color(:accepted), do: :green
  defp proposal_status_color("accepted"), do: :green
  defp proposal_status_color(:rejected), do: :red
  defp proposal_status_color("rejected"), do: :red
  defp proposal_status_color(:deferred), do: :gray
  defp proposal_status_color("deferred"), do: :gray
  defp proposal_status_color(_), do: :gray

  defp format_pct(nil), do: "—"
  defp format_pct(n) when is_number(n), do: "#{round(n * 100)}%"
  defp format_pct(other), do: to_string(other)

  defp format_deadline(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
  defp format_deadline(other), do: to_string(other)

  defp traits(nil), do: []
  defp traits(sk), do: Map.get(sk, :personality_traits, [])

  defp values(nil), do: []
  defp values(sk), do: Map.get(sk, :values, [])

  defp caps(nil), do: []
  defp caps(sk), do: Map.get(sk, :capabilities, [])

  defp discover_agents do
    # Combine agents from ETS tables and ChatState recent list
    recent = ChatState.get_recent_agents()

    ets_agents =
      for table <- [:arbor_memory_graphs, :arbor_working_memory],
          :ets.whereis(table) != :undefined,
          {agent_id, _} <-
            (try do
               :ets.tab2list(table)
             rescue
               _ -> []
             end),
          is_binary(agent_id),
          reduce: MapSet.new() do
        acc -> MapSet.put(acc, agent_id)
      end

    # Merge: recent agents first, then ETS-only agents
    recent_ids = MapSet.new(Enum.map(recent, & &1.agent_id))

    ets_only =
      ets_agents
      |> MapSet.difference(recent_ids)
      |> Enum.map(fn id -> %{agent_id: id, last_seen: nil, message_count: nil} end)

    recent ++ ets_only
  end

  # Safely access a field on the working_memory struct in tab_data.
  # WorkingMemory is a struct that doesn't implement Access,
  # so get_in/2 with atom keys fails. Use Map.get/2 instead.
  defp wm_field(tab_data, field) when is_atom(field) do
    case tab_data[:working_memory] do
      %{} = wm -> Map.get(wm, field)
      _ -> nil
    end
  end
end
