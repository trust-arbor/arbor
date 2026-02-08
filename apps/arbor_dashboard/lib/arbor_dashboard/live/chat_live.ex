defmodule Arbor.Dashboard.Live.ChatLive do
  @moduledoc """
  Agent chat interface.

  Interactive conversation with Arbor agents, displaying thinking blocks,
  recalled memories, signal emissions, and response streaming.
  """

  use Phoenix.LiveView

  import Arbor.Web.Components

  alias Arbor.Agent.Claude
  alias Arbor.Dashboard.ChatState
  alias Arbor.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    ChatState.init()

    subscription_ids =
      if connected?(socket) do
        safe_subscribe()
      end

    socket =
      socket
      |> assign(
        page_title: "Chat",
        agent: nil,
        agent_id: nil,
        session_id: nil,
        input: "",
        loading: false,
        error: nil,
        subscription_ids: subscription_ids,
        # Panel visibility toggles
        show_thinking: true,
        show_memories: true,
        show_actions: true,
        show_thoughts: true,
        show_goals: true,
        show_llm_panel: true,
        show_identity: true,
        show_cognitive: true,
        show_code: true,
        show_proposals: true,
        # Memory state
        memory_stats: nil,
        # Working memory thoughts
        working_thoughts: [],
        # Token tracking
        input_tokens: 0,
        output_tokens: 0,
        cached_tokens: 0,
        last_duration_ms: nil,
        total_tokens: 0,
        query_count: 0,
        # Goals
        agent_goals: [],
        # LLM heartbeat tracking
        llm_call_count: 0,
        last_llm_mode: nil,
        last_llm_thinking: nil,
        heartbeat_count: 0,
        memory_notes_total: 0,
        # Identity evolution
        self_insights: [],
        identity_changes: [],
        last_consolidation: nil,
        # Cognitive preferences
        cognitive_prefs: nil,
        cognitive_adjustments: [],
        pinned_count: 0,
        # Code modules
        code_modules: [],
        # Proposals
        proposals: []
      )
      |> stream(:messages, [])
      |> stream(:signals, [])
      |> stream(:thinking, [])
      |> stream(:memories, [])
      |> stream(:actions, [])
      |> stream(:llm_interactions, [])

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    # Stop the agent if running
    if agent = socket.assigns[:agent] do
      try do
        GenServer.stop(agent, :normal, 1000)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    # Unsubscribe from signals
    case socket.assigns[:subscription_ids] do
      {agent_sub, memory_sub} ->
        safe_unsubscribe(agent_sub)
        safe_unsubscribe(memory_sub)

      sub_id when is_binary(sub_id) ->
        safe_unsubscribe(sub_id)

      _ ->
        :ok
    end
  end

  @impl true
  def handle_event("start-agent", %{"model" => model}, socket) do
    model_atom = String.to_existing_atom(model)
    agent_id = "chat-#{System.unique_integer([:positive])}"

    case Claude.start_link(id: agent_id, model: model_atom, capture_thinking: true) do
      {:ok, agent} ->
        # Get initial memory stats
        memory_stats = get_memory_stats(agent)

        # Load persisted ETS state
        tokens = ChatState.get_tokens(agent_id)
        identity = ChatState.get_identity_state(agent_id)
        cognitive = ChatState.get_cognitive_state(agent_id)
        code = ChatState.get_code_modules(agent_id)
        proposals = unwrap_list(safe_call(fn -> Arbor.Memory.get_proposals(agent_id) end))
        ChatState.touch_agent(agent_id)

        socket =
          socket
          |> assign(agent: agent, agent_id: agent_id, error: nil, memory_stats: memory_stats)
          |> assign(
            query_count: 0,
            working_thoughts: [],
            agent_goals: fetch_goals(agent_id),
            llm_call_count: tokens.count,
            last_llm_mode: nil,
            last_llm_thinking: nil,
            heartbeat_count: 0,
            memory_notes_total: 0,
            input_tokens: tokens.input,
            output_tokens: tokens.output,
            cached_tokens: tokens.cached,
            last_duration_ms: tokens.last_duration,
            self_insights: identity.insights,
            identity_changes: identity.identity_changes,
            last_consolidation: identity.last_consolidation,
            cognitive_prefs: cognitive.current_prefs,
            cognitive_adjustments: cognitive.adjustments,
            pinned_count: cognitive.pinned_count,
            code_modules: code,
            proposals: proposals
          )
          |> stream(:messages, [], reset: true)
          |> stream(:signals, [], reset: true)
          |> stream(:thinking, [], reset: true)
          |> stream(:memories, [], reset: true)
          |> stream(:actions, [], reset: true)
          |> stream(:llm_interactions, [], reset: true)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to start agent: #{inspect(reason)}")}
    end
  rescue
    e ->
      {:noreply, assign(socket, error: "Error: #{Exception.message(e)}")}
  end

  def handle_event("stop-agent", _params, socket) do
    if agent = socket.assigns.agent do
      try do
        GenServer.stop(agent, :normal, 1000)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    {:noreply,
     assign(socket,
       agent: nil,
       agent_id: nil,
       session_id: nil,
       memory_stats: nil,
       agent_goals: [],
       llm_call_count: 0,
       heartbeat_count: 0
     )}
  end

  def handle_event("update-input", %{"message" => value}, socket) do
    {:noreply, assign(socket, input: value)}
  end

  def handle_event("update-input", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("send-message", _params, socket) do
    input = String.trim(socket.assigns.input)

    if input == "" or socket.assigns.agent == nil do
      {:noreply, socket}
    else
      # Add user message
      user_msg = %{
        id: "msg-#{System.unique_integer([:positive])}",
        role: :user,
        content: input,
        timestamp: DateTime.utc_now()
      }

      socket =
        socket
        |> stream_insert(:messages, user_msg)
        |> assign(input: "", loading: true, error: nil)

      # Send async query
      agent = socket.assigns.agent
      send(self(), {:query, agent, input})

      {:noreply, socket}
    end
  end

  def handle_event("toggle-thinking", _params, socket) do
    {:noreply, assign(socket, show_thinking: !socket.assigns.show_thinking)}
  end

  def handle_event("toggle-memories", _params, socket) do
    {:noreply, assign(socket, show_memories: !socket.assigns.show_memories)}
  end

  def handle_event("toggle-actions", _params, socket) do
    {:noreply, assign(socket, show_actions: !socket.assigns.show_actions)}
  end

  def handle_event("toggle-thoughts", _params, socket) do
    {:noreply, assign(socket, show_thoughts: !socket.assigns.show_thoughts)}
  end

  def handle_event("toggle-goals", _params, socket) do
    {:noreply, assign(socket, show_goals: !socket.assigns.show_goals)}
  end

  def handle_event("toggle-llm-panel", _params, socket) do
    {:noreply, assign(socket, show_llm_panel: !socket.assigns.show_llm_panel)}
  end

  def handle_event("toggle-identity", _params, socket) do
    {:noreply, assign(socket, show_identity: !socket.assigns.show_identity)}
  end

  def handle_event("toggle-cognitive", _params, socket) do
    {:noreply, assign(socket, show_cognitive: !socket.assigns.show_cognitive)}
  end

  def handle_event("toggle-code", _params, socket) do
    {:noreply, assign(socket, show_code: !socket.assigns.show_code)}
  end

  def handle_event("toggle-proposals", _params, socket) do
    {:noreply, assign(socket, show_proposals: !socket.assigns.show_proposals)}
  end

  def handle_event("accept-proposal", %{"id" => proposal_id}, socket) do
    agent_id = socket.assigns.agent_id
    safe_call(fn -> Arbor.Memory.accept_proposal(agent_id, proposal_id) end)
    proposals = unwrap_list(safe_call(fn -> Arbor.Memory.get_proposals(agent_id) end))
    {:noreply, assign(socket, proposals: proposals)}
  end

  def handle_event("reject-proposal", %{"id" => proposal_id}, socket) do
    agent_id = socket.assigns.agent_id
    safe_call(fn -> Arbor.Memory.reject_proposal(agent_id, proposal_id) end)
    proposals = unwrap_list(safe_call(fn -> Arbor.Memory.get_proposals(agent_id) end))
    {:noreply, assign(socket, proposals: proposals)}
  end

  def handle_event("defer-proposal", %{"id" => proposal_id}, socket) do
    agent_id = socket.assigns.agent_id
    safe_call(fn -> Arbor.Memory.defer_proposal(agent_id, proposal_id) end)
    proposals = unwrap_list(safe_call(fn -> Arbor.Memory.get_proposals(agent_id) end))
    {:noreply, assign(socket, proposals: proposals)}
  end

  @impl true
  def handle_info({:query, agent, prompt}, socket) do
    case Claude.query(agent, prompt,
           timeout: 60_000,
           max_turns: 1,
           permission_mode: :bypass
         ) do
      {:ok, response} ->
        socket = process_query_response(socket, agent, response)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, loading: false, error: "Query failed: #{inspect(reason)}")}
    end
  end

  def handle_info({:signal_received, signal}, socket) do
    # Only show signals related to our agent
    agent_id = socket.assigns.agent_id

    if agent_id && signal_matches_agent?(signal, agent_id) do
      signal_entry = %{
        id: "sig-#{System.unique_integer([:positive])}",
        category: signal.category,
        event: signal.type,
        timestamp: signal.timestamp,
        metadata: signal.metadata
      }

      socket = stream_insert(socket, :signals, signal_entry)

      # Process action signals
      socket = maybe_add_action(socket, signal)

      # Track heartbeat LLM data
      socket = maybe_track_heartbeat(socket, signal)

      # Track goal changes
      socket = maybe_refresh_goals(socket, signal)

      # Track memory note signals
      socket = maybe_track_memory_note(socket, signal)

      # Track identity, cognitive, code signals
      socket = maybe_track_identity(socket, signal)
      socket = maybe_track_cognitive(socket, signal)
      socket = maybe_track_code(socket, signal)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Query Response Helpers ────────────────────────────────────────────

  defp process_query_response(socket, agent, response) do
    assistant_msg = build_assistant_message(response)

    socket
    |> stream_insert(:messages, assistant_msg)
    |> assign(loading: false, session_id: response.session_id)
    |> add_thinking_blocks(response.thinking)
    |> add_recalled_memories(response.recalled_memories)
    |> extract_token_usage(response)
    |> update_agent_state(agent)
  end

  defp build_assistant_message(response) do
    %{
      id: "msg-#{System.unique_integer([:positive])}",
      role: :assistant,
      content: response.text,
      timestamp: DateTime.utc_now(),
      model: response.model,
      session_id: response.session_id,
      memory_count: length(response.recalled_memories || [])
    }
  end

  defp add_thinking_blocks(socket, nil), do: socket
  defp add_thinking_blocks(socket, []), do: socket

  defp add_thinking_blocks(socket, blocks) do
    Enum.reduce(blocks, socket, fn block, acc ->
      entry = %{
        id: "think-#{System.unique_integer([:positive])}",
        text: block.text || "",
        has_signature: block.signature != nil,
        timestamp: DateTime.utc_now()
      }

      stream_insert(acc, :thinking, entry)
    end)
  end

  defp add_recalled_memories(socket, nil), do: socket
  defp add_recalled_memories(socket, []), do: socket

  defp add_recalled_memories(socket, memories) do
    Enum.reduce(memories, socket, fn memory, acc ->
      entry = %{
        id: "mem-#{System.unique_integer([:positive])}",
        content: memory[:content] || memory["content"] || inspect(memory),
        score: memory[:score] || memory["score"],
        timestamp: DateTime.utc_now()
      }

      stream_insert(acc, :memories, entry)
    end)
  end

  defp update_agent_state(socket, agent) do
    socket
    |> assign(memory_stats: get_memory_stats(agent))
    |> assign(query_count: socket.assigns.query_count + 1)
    |> assign(working_thoughts: get_working_thoughts(agent))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="Agent Chat" subtitle="Interactive conversation with Claude + Memory" />

    <%!-- Stats bar --%>
    <div style="display: flex; gap: 0.5rem; flex-wrap: wrap; padding: 0.4rem 0.75rem; margin-top: 0.5rem; border: 1px solid var(--aw-border, #333); border-radius: 6px; font-size: 0.85em;">
      <.badge :if={@agent} label={"Agent: #{@agent_id}"} color={:green} />
      <.badge :if={!@agent} label="No Agent" color={:gray} />
      <.badge
        :if={@session_id}
        label={"Session: #{String.slice(@session_id || "", 0..7)}..."}
        color={:blue}
      />
      <.badge :if={@memory_stats && @memory_stats[:enabled]} label="Memory: ON" color={:purple} />
      <.badge :if={@memory_stats && !@memory_stats[:enabled]} label="Memory: OFF" color={:gray} />
      <.badge label={"Queries: #{@query_count}"} color={:blue} />
      <.badge
        :if={@memory_stats && @memory_stats[:enabled]}
        label={"Index: #{get_in(@memory_stats, [:index, :count]) || 0}"}
        color={:purple}
      />
      <.badge
        :if={@memory_stats && @memory_stats[:enabled]}
        label={"Knowledge: #{get_in(@memory_stats, [:knowledge, :node_count]) || 0}"}
        color={:green}
      />
      <.badge
        :if={@heartbeat_count > 0}
        label={"Heartbeats: #{@heartbeat_count}"}
        color={:yellow}
      />
      <.badge
        :if={@llm_call_count > 0}
        label={"LLM Calls: #{@llm_call_count}"}
        color={:blue}
      />
      <.badge
        :if={@memory_notes_total > 0}
        label={"Notes: #{@memory_notes_total}"}
        color={:purple}
      />
      <.badge
        :if={@last_llm_mode}
        label={"Mode: #{@last_llm_mode}"}
        color={:yellow}
      />
    </div>

    <%!-- Token counter bar --%>
    <div
      :if={@agent && @llm_call_count > 0}
      style="display: flex; gap: 0.75rem; flex-wrap: wrap; padding: 0.4rem 0.75rem; margin-top: 0.35rem; border: 1px solid rgba(74, 158, 255, 0.3); border-radius: 6px; font-size: 0.8em; background: rgba(74, 158, 255, 0.05);"
    >
      <span style="color: #4a9eff;">
        INPUT: <strong>{format_token_count(@input_tokens)}</strong>
      </span>
      <span style="color: #22c55e;">
        OUTPUT: <strong>{format_token_count(@output_tokens)}</strong>
      </span>
      <span :if={@cached_tokens > 0} style="color: #a855f7;">
        CACHED: <strong>{format_token_count(@cached_tokens)}</strong>
      </span>
      <span style="color: #e2e8f0;">
        TOTAL: <strong>{format_token_count(@input_tokens + @output_tokens)}</strong>
      </span>
      <span style="color: #4a9eff;">
        CALLS: <strong>{@llm_call_count}</strong>
      </span>
      <span :if={@last_duration_ms} style="color: #eab308;">
        LAST: <strong>{format_duration(@last_duration_ms)}</strong>
      </span>
    </div>

    <%!-- 3-column layout: 20% left | 50% center | 30% right --%>
    <div style="display: grid; grid-template-columns: 20% 1fr 30%; gap: 0.75rem; margin-top: 0.5rem; height: calc(100vh - 160px); min-height: 400px;">

      <%!-- LEFT PANEL: Signals + Actions --%>
      <div style="display: flex; flex-direction: column; gap: 0.5rem; overflow: hidden;">
        <%!-- Signal Stream — grows to fill --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; display: flex; flex-direction: column; flex: 1; min-height: 0;">
          <div style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); display: flex; justify-content: space-between; align-items: center; flex-shrink: 0;">
            <strong style="font-size: 0.85em;">📡 Signals</strong>
            <span style="color: #22c55e; font-size: 0.7em;">● LIVE</span>
          </div>
          <div
            id="signals-container"
            phx-update="stream"
            style="flex: 1; overflow-y: auto; padding: 0.4rem; min-height: 0;"
          >
            <div
              :for={{dom_id, sig} <- @streams.signals}
              id={dom_id}
              style="margin-bottom: 0.35rem; padding: 0.35rem; border-radius: 4px; background: rgba(74, 255, 158, 0.1); font-size: 0.8em;"
            >
              <div style="display: flex; align-items: center; gap: 0.25rem;">
                <span>{signal_icon(sig.category)}</span>
                <span style="font-weight: 500; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">{sig.event}</span>
                <span style="color: var(--aw-text-muted, #888); font-size: 0.75em; flex-shrink: 0;">
                  {format_time(sig.timestamp)}
                </span>
              </div>
            </div>
          </div>
          <div style="padding: 0.4rem; text-align: center; flex-shrink: 0;">
            <.empty_state
              :if={stream_empty?(@streams.signals)}
              icon="📡"
              title="Waiting for signals..."
              hint=""
            />
          </div>
        </div>

        <%!-- Recent Actions — collapsible --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
          <div
            phx-click="toggle-actions"
            style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
          >
            <strong style="font-size: 0.85em;">⚡ Actions</strong>
            <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
              {if @show_actions, do: "▼", else: "▶"}
            </span>
          </div>
          <div
            :if={@show_actions}
            id="actions-container"
            phx-update="stream"
            style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;"
          >
            <div
              :for={{dom_id, action} <- @streams.actions}
              id={dom_id}
              style={"margin-bottom: 0.35rem; padding: 0.35rem; border-radius: 4px; font-size: 0.8em; " <> action_style(action.outcome)}
            >
              <div style="display: flex; align-items: center; gap: 0.25rem;">
                <span>⚡</span>
                <span style="font-weight: 500; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">{action.name}</span>
                <.badge label={to_string(action.outcome)} color={outcome_color(action.outcome)} />
              </div>
            </div>
          </div>
          <div :if={@show_actions} style="padding: 0.4rem; text-align: center;">
            <.empty_state
              :if={stream_empty?(@streams.actions)}
              icon="⚡"
              title="No actions yet"
              hint=""
            />
          </div>
        </div>

        <%!-- LLM Heartbeat --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
          <div
            phx-click="toggle-llm-panel"
            style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
          >
            <strong style="font-size: 0.85em;">🔄 Heartbeat LLM</strong>
            <div style="display: flex; align-items: center; gap: 0.5rem;">
              <.badge :if={@llm_call_count > 0} label={"#{@llm_call_count}"} color={:blue} />
              <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
                {if @show_llm_panel, do: "▼", else: "▶"}
              </span>
            </div>
          </div>
          <div :if={@show_llm_panel} style="flex: 1; overflow-y: auto; min-height: 0;">
            <%!-- Last heartbeat thinking --%>
            <div :if={@last_llm_thinking} style="padding: 0.4rem; border-bottom: 1px solid var(--aw-border, #333);">
              <div style="font-size: 0.7em; color: var(--aw-text-muted, #888); margin-bottom: 0.2rem;">
                Last heartbeat ({@last_llm_mode || "unknown"} mode):
              </div>
              <p style="color: var(--aw-text, #ccc); font-size: 0.8em; white-space: pre-wrap; margin: 0;">
                {Helpers.truncate(@last_llm_thinking, 500)}
              </p>
            </div>
            <%!-- LLM interaction stream --%>
            <div
              id="llm-interactions-container"
              phx-update="stream"
              style="padding: 0.4rem;"
            >
              <div
                :for={{dom_id, interaction} <- @streams.llm_interactions}
                id={dom_id}
                style="margin-bottom: 0.35rem; padding: 0.35rem; border-radius: 4px; background: rgba(74, 158, 255, 0.05); font-size: 0.8em;"
              >
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.2rem;">
                  <.badge label={to_string(interaction.mode)} color={:yellow} />
                  <span style="font-size: 0.7em; color: var(--aw-text-muted, #888);">
                    {format_time(interaction.timestamp)}
                  </span>
                </div>
                <p style="color: var(--aw-text-muted, #888); white-space: pre-wrap; margin: 0;">
                  {Helpers.truncate(interaction.thinking, 250)}
                </p>
                <div :if={interaction.actions > 0 || interaction.notes > 0} style="margin-top: 0.2rem; display: flex; gap: 0.25rem;">
                  <.badge :if={interaction.actions > 0} label={"#{interaction.actions} actions"} color={:green} />
                  <.badge :if={interaction.notes > 0} label={"#{interaction.notes} notes"} color={:purple} />
                </div>
              </div>
            </div>
            <div style="padding: 0.4rem; text-align: center;">
              <.empty_state
                :if={stream_empty?(@streams.llm_interactions)}
                icon="🔄"
                title="No LLM heartbeats yet"
                hint="LLM calls happen during heartbeat cycles"
              />
            </div>
          </div>
        </div>

        <%!-- Code Modules Panel --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
          <div
            phx-click="toggle-code"
            style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
          >
            <strong style="font-size: 0.85em;">💻 Code</strong>
            <div style="display: flex; align-items: center; gap: 0.5rem;">
              <.badge :if={@code_modules != []} label={"#{length(@code_modules)}"} color={:green} />
              <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
                {if @show_code, do: "▼", else: "▶"}
              </span>
            </div>
          </div>
          <div :if={@show_code} style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;">
            <div
              :for={mod <- @code_modules}
              style="margin-bottom: 0.35rem; padding: 0.35rem; border-radius: 4px; background: rgba(34, 197, 94, 0.1); font-size: 0.8em;"
            >
              <div style="display: flex; align-items: center; gap: 0.25rem; margin-bottom: 0.15rem;">
                <span style="font-weight: 500;">{mod[:name] || "unnamed"}</span>
                <.badge :if={mod[:sandbox_level]} label={to_string(mod[:sandbox_level])} color={:yellow} />
              </div>
              <span :if={mod[:purpose]} style="color: var(--aw-text-muted, #888); font-size: 0.9em;">{Helpers.truncate(mod[:purpose], 100)}</span>
            </div>
            <.empty_state
              :if={@code_modules == []}
              icon="💻"
              title="No code modules"
              hint="Code appears when the agent creates modules"
            />
          </div>
        </div>

        <%!-- Proposals Panel --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
          <div
            phx-click="toggle-proposals"
            style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
          >
            <strong style="font-size: 0.85em;">📋 Proposals</strong>
            <div style="display: flex; align-items: center; gap: 0.5rem;">
              <.badge :if={@proposals != []} label={"#{length(@proposals)}"} color={:yellow} />
              <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
                {if @show_proposals, do: "▼", else: "▶"}
              </span>
            </div>
          </div>
          <div :if={@show_proposals} style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;">
            <div
              :for={proposal <- @proposals}
              style="margin-bottom: 0.4rem; padding: 0.4rem; border-radius: 4px; background: rgba(234, 179, 8, 0.1); font-size: 0.8em;"
            >
              <div style="display: flex; align-items: center; gap: 0.25rem; margin-bottom: 0.2rem;">
                <.badge :if={proposal[:type]} label={to_string(proposal[:type])} color={:yellow} />
                <.badge :if={proposal[:confidence]} label={"#{round(proposal[:confidence] * 100)}%"} color={:blue} />
              </div>
              <p style="color: var(--aw-text-muted, #888); margin: 0 0 0.3rem 0; white-space: pre-wrap;">{Helpers.truncate(proposal[:content] || proposal[:description] || "", 200)}</p>
              <div style="display: flex; gap: 0.3rem;">
                <button
                  phx-click="accept-proposal"
                  phx-value-id={proposal[:id]}
                  style="padding: 0.2rem 0.5rem; border: none; border-radius: 3px; background: #22c55e; color: white; cursor: pointer; font-size: 0.8em;"
                >
                  Accept
                </button>
                <button
                  phx-click="reject-proposal"
                  phx-value-id={proposal[:id]}
                  style="padding: 0.2rem 0.5rem; border: none; border-radius: 3px; background: #ff4a4a; color: white; cursor: pointer; font-size: 0.8em;"
                >
                  Reject
                </button>
                <button
                  phx-click="defer-proposal"
                  phx-value-id={proposal[:id]}
                  style="padding: 0.2rem 0.5rem; border: none; border-radius: 3px; background: #888; color: white; cursor: pointer; font-size: 0.8em;"
                >
                  Defer
                </button>
              </div>
            </div>
            <.empty_state
              :if={@proposals == []}
              icon="📋"
              title="No pending proposals"
              hint="Proposals appear from reflection & analysis"
            />
          </div>
        </div>
      </div>

      <%!-- CENTER: Chat Panel --%>
      <div style="display: flex; flex-direction: column; border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; min-height: 0;">
        <%!-- Agent controls --%>
        <div style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); display: flex; align-items: center; gap: 0.75rem; flex-shrink: 0;">
          <div :if={@agent == nil}>
            <form phx-submit="start-agent" style="display: flex; gap: 0.5rem;">
              <select
                name="model"
                style="padding: 0.4rem; border-radius: 4px; background: var(--aw-bg, #1a1a1a); border: 1px solid var(--aw-border, #333); color: inherit; font-size: 0.9em;"
              >
                <option value="haiku">Haiku (fast)</option>
                <option value="sonnet">Sonnet (balanced)</option>
                <option value="opus">Opus (powerful)</option>
              </select>
              <button
                type="submit"
                style="padding: 0.4rem 0.75rem; background: var(--aw-accent, #4a9eff); border: none; border-radius: 4px; color: white; cursor: pointer; font-size: 0.9em;"
              >
                Start Agent
              </button>
            </form>
          </div>
          <div
            :if={@agent != nil}
            style="display: flex; align-items: center; gap: 0.5rem; width: 100%;"
          >
            <span style="color: var(--aw-text-muted, #888); font-size: 0.9em;">Chat with Claude</span>
            <div style="flex: 1;"></div>
            <button
              phx-click="stop-agent"
              style="padding: 0.4rem 0.75rem; background: var(--aw-error, #ff4a4a); border: none; border-radius: 4px; color: white; cursor: pointer; font-size: 0.9em;"
            >
              Stop Agent
            </button>
          </div>
        </div>

        <%!-- Messages --%>
        <div
          id="messages-container"
          phx-update="stream"
          style="flex: 1; overflow-y: auto; padding: 0.75rem; min-height: 0;"
        >
          <div
            :for={{dom_id, msg} <- @streams.messages}
            id={dom_id}
            style={"margin-bottom: 0.75rem; padding: 0.6rem; border-radius: 6px; " <> message_style(msg.role)}
          >
            <div style="display: flex; justify-content: space-between; margin-bottom: 0.2rem;">
              <strong style="font-size: 0.9em;">{role_label(msg.role)}</strong>
              <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
                {format_time(msg.timestamp)}
              </span>
            </div>
            <div style="white-space: pre-wrap; font-size: 0.9em;">{msg.content}</div>
            <div
              :if={msg[:model] || msg[:memory_count]}
              style="margin-top: 0.4rem; display: flex; gap: 0.5rem;"
            >
              <.badge :if={msg[:model]} label={to_string(msg.model)} color={:gray} />
              <.badge
                :if={msg[:memory_count] && msg[:memory_count] > 0}
                label={"#{msg.memory_count} memories"}
                color={:purple}
              />
            </div>
          </div>
        </div>

        <%!-- Loading indicator --%>
        <div :if={@loading} style="padding: 0.75rem; border-top: 1px solid var(--aw-border, #333); flex-shrink: 0;">
          <span style="color: var(--aw-text-muted, #888);">🤔 Thinking...</span>
        </div>

        <%!-- Error display --%>
        <div
          :if={@error}
          style="padding: 0.5rem 0.75rem; background: rgba(255, 74, 74, 0.1); color: var(--aw-error, #ff4a4a); border-top: 1px solid var(--aw-error, #ff4a4a); flex-shrink: 0; font-size: 0.85em;"
        >
          {@error}
        </div>

        <%!-- Input area --%>
        <form
          phx-submit="send-message"
          phx-change="update-input"
          style="padding: 0.5rem 0.75rem; border-top: 1px solid var(--aw-border, #333); display: flex; gap: 0.5rem; flex-shrink: 0;"
        >
          <input
            type="text"
            name="message"
            value={@input}
            placeholder={if @agent, do: "Type a message...", else: "Start an agent first"}
            disabled={@agent == nil or @loading}
            style="flex: 1; padding: 0.4rem 0.6rem; border-radius: 4px; background: var(--aw-bg, #1a1a1a); border: 1px solid var(--aw-border, #333); color: inherit; font-size: 0.9em;"
            autocomplete="off"
          />
          <button
            type="submit"
            disabled={@agent == nil or @loading or @input == ""}
            style={"padding: 0.4rem 0.75rem; border: none; border-radius: 4px; color: white; font-size: 0.9em; cursor: " <> if(@agent && !@loading, do: "pointer", else: "not-allowed") <> "; background: " <> if(@agent && !@loading, do: "var(--aw-accent, #4a9eff)", else: "var(--aw-text-muted, #888)") <> ";"}
          >
            Send
          </button>
        </form>
      </div>

      <%!-- RIGHT PANEL: Goals + Thinking + Memory + LLM --%>
      <div style="display: flex; flex-direction: column; gap: 0.5rem; overflow: hidden; min-height: 0;">

        <%!-- Goals panel --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
          <div
            phx-click="toggle-goals"
            style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
          >
            <strong style="font-size: 0.85em;">🎯 Goals</strong>
            <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
              {if @show_goals, do: "▼", else: "▶"}
            </span>
          </div>
          <div :if={@show_goals} style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;">
            <div
              :for={goal <- @agent_goals}
              style="margin-bottom: 0.4rem; padding: 0.4rem; border-radius: 4px; background: rgba(74, 255, 158, 0.05); font-size: 0.8em;"
            >
              <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.2rem;">
                <span style="flex: 1;">{goal.description}</span>
                <.badge label={to_string(goal.status)} color={goal_status_color(goal.status)} />
              </div>
              <div style="background: rgba(128,128,128,0.2); height: 3px; border-radius: 2px; overflow: hidden;">
                <div style={"background: #{goal_progress_color(goal.progress)}; height: 100%; width: #{round(goal.progress * 100)}%; transition: width 0.3s ease;"}></div>
              </div>
              <div style="display: flex; justify-content: space-between; margin-top: 2px;">
                <span style="font-size: 0.7em; color: var(--aw-text-muted, #888);">
                  Priority: {goal.priority}
                </span>
                <span style="font-size: 0.7em; color: var(--aw-text-muted, #888);">
                  {round(goal.progress * 100)}%
                </span>
              </div>
            </div>
            <.empty_state
              :if={@agent_goals == []}
              icon="🎯"
              title="No active goals"
              hint="Goals appear as the agent works"
            />
          </div>
        </div>

        <%!-- Extended Thinking blocks — takes most space --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; display: flex; flex-direction: column; flex: 1; min-height: 0;">
          <div
            phx-click="toggle-thinking"
            style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center; flex-shrink: 0;"
          >
            <strong style="font-size: 0.85em;">🧠 Thinking</strong>
            <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
              {if @show_thinking, do: "▼", else: "▶"}
            </span>
          </div>
          <div
            :if={@show_thinking}
            id="thinking-container"
            phx-update="stream"
            style="flex: 1; overflow-y: auto; padding: 0.4rem; min-height: 0;"
          >
            <div
              :for={{dom_id, block} <- @streams.thinking}
              id={dom_id}
              style="margin-bottom: 0.4rem; padding: 0.4rem; border-radius: 4px; background: rgba(74, 158, 255, 0.1); font-size: 0.8em;"
            >
              <div style="display: flex; justify-content: space-between; margin-bottom: 0.2rem;">
                <.badge :if={block.has_signature} label="signed" color={:blue} />
                <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
                  {format_time(block.timestamp)}
                </span>
              </div>
              <p style="color: var(--aw-text-muted, #888); white-space: pre-wrap; margin: 0;">
                {Helpers.truncate(block.text, 300)}
              </p>
            </div>
          </div>
          <div :if={@show_thinking} style="padding: 0.4rem; text-align: center; flex-shrink: 0;">
            <.empty_state
              :if={stream_empty?(@streams.thinking)}
              icon="🧠"
              title="No thinking yet"
              hint="Thinking blocks appear after queries"
            />
          </div>
        </div>

        <%!-- Working Thoughts --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
          <div
            phx-click="toggle-thoughts"
            style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
          >
            <strong style="font-size: 0.85em;">💭 Working Thoughts</strong>
            <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
              {if @show_thoughts, do: "▼", else: "▶"}
            </span>
          </div>
          <div :if={@show_thoughts} style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;">
            <div
              :for={thought <- @working_thoughts}
              style="margin-bottom: 0.35rem; padding: 0.35rem; border-radius: 4px; background: rgba(255, 165, 0, 0.1); font-size: 0.8em;"
            >
              <span>💭</span>
              <span style="color: var(--aw-text-muted, #888); white-space: pre-wrap;">
                {Helpers.truncate(thought.content, 200)}
              </span>
            </div>
            <.empty_state
              :if={@working_thoughts == []}
              icon="💭"
              title="Waiting for activity..."
              hint=""
            />
          </div>
        </div>

        <%!-- Memory Notes --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
          <div
            phx-click="toggle-memories"
            style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
          >
            <strong style="font-size: 0.85em;">📝 Memory Notes</strong>
            <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
              {if @show_memories, do: "▼", else: "▶"}
            </span>
          </div>
          <div
            :if={@show_memories}
            id="memories-container"
            phx-update="stream"
            style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;"
          >
            <div
              :for={{dom_id, memory} <- @streams.memories}
              id={dom_id}
              style="margin-bottom: 0.35rem; padding: 0.35rem; border-radius: 4px; background: rgba(138, 43, 226, 0.1); font-size: 0.8em;"
            >
              <div style="display: flex; align-items: center; gap: 0.25rem; margin-bottom: 0.2rem;">
                <span>📝</span>
                <.badge
                  :if={memory.score}
                  label={"score: #{Float.round(memory.score, 2)}"}
                  color={:purple}
                />
              </div>
              <p style="color: var(--aw-text-muted, #888); white-space: pre-wrap; margin: 0;">
                {Helpers.truncate(memory.content, 200)}
              </p>
            </div>
          </div>
          <div :if={@show_memories} style="padding: 0.4rem; text-align: center; flex-shrink: 0;">
            <.empty_state
              :if={stream_empty?(@streams.memories)}
              icon="📝"
              title="No memories recalled"
              hint="Relevant memories appear here"
            />
          </div>
        </div>

        <%!-- Identity Evolution Panel --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
          <div
            phx-click="toggle-identity"
            style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
          >
            <strong style="font-size: 0.85em;">🪞 Identity</strong>
            <div style="display: flex; align-items: center; gap: 0.5rem;">
              <.badge :if={@self_insights != []} label={"#{length(@self_insights)}"} color={:purple} />
              <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
                {if @show_identity, do: "▼", else: "▶"}
              </span>
            </div>
          </div>
          <div :if={@show_identity} style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;">
            <div :if={@self_insights != []} style="margin-bottom: 0.5rem;">
              <div style="font-size: 0.7em; color: var(--aw-text-muted, #888); margin-bottom: 0.2rem; font-weight: 600;">Self Insights</div>
              <div
                :for={insight <- Enum.take(@self_insights, 5)}
                style="margin-bottom: 0.35rem; padding: 0.35rem; border-radius: 4px; background: rgba(168, 85, 247, 0.1); font-size: 0.8em;"
              >
                <div style="display: flex; align-items: center; gap: 0.25rem; margin-bottom: 0.15rem;">
                  <.badge :if={insight[:category]} label={to_string(insight[:category])} color={:purple} />
                  <.badge :if={insight[:confidence]} label={"#{round(insight[:confidence] * 100)}%"} color={:blue} />
                </div>
                <span style="color: var(--aw-text-muted, #888);">{Helpers.truncate(insight[:content] || "", 150)}</span>
              </div>
            </div>
            <div :if={@identity_changes != []} style="margin-bottom: 0.5rem;">
              <div style="font-size: 0.7em; color: var(--aw-text-muted, #888); margin-bottom: 0.2rem; font-weight: 600;">Identity Changes</div>
              <div
                :for={change <- Enum.take(@identity_changes, 5)}
                style="margin-bottom: 0.25rem; padding: 0.3rem; border-radius: 4px; background: rgba(234, 179, 8, 0.1); font-size: 0.8em;"
              >
                <.badge :if={change[:field]} label={to_string(change[:field])} color={:yellow} />
                <.badge :if={change[:change_type]} label={to_string(change[:change_type])} color={:gray} />
                <span :if={change[:reason]} style="color: var(--aw-text-muted, #888); font-size: 0.9em;"> {Helpers.truncate(change[:reason], 100)}</span>
              </div>
            </div>
            <div :if={@last_consolidation} style="font-size: 0.75em; color: var(--aw-text-muted, #888); padding: 0.3rem; background: rgba(128,128,128,0.1); border-radius: 4px;">
              Last consolidation: promoted {Map.get(@last_consolidation, :promoted, 0)}, deferred {Map.get(@last_consolidation, :deferred, 0)}
            </div>
            <.empty_state
              :if={@self_insights == [] && @identity_changes == [] && @last_consolidation == nil}
              icon="🪞"
              title="No identity data"
              hint="Identity changes appear as the agent evolves"
            />
          </div>
        </div>

        <%!-- Cognitive Preferences Panel --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 6px; overflow: hidden; flex: 1; min-height: 0; display: flex; flex-direction: column;">
          <div
            phx-click="toggle-cognitive"
            style="padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
          >
            <strong style="font-size: 0.85em;">🧠 Cognitive</strong>
            <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
              {if @show_cognitive, do: "▼", else: "▶"}
            </span>
          </div>
          <div :if={@show_cognitive} style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;">
            <div :if={@cognitive_prefs} style="margin-bottom: 0.4rem;">
              <div style="display: flex; gap: 0.5rem; flex-wrap: wrap; margin-bottom: 0.3rem;">
                <.badge label={"Decay: #{Map.get(@cognitive_prefs, :decay_rate, "—")}"} color={:blue} />
                <.badge label={"Threshold: #{Map.get(@cognitive_prefs, :retrieval_threshold, "—")}"} color={:green} />
                <.badge :if={@pinned_count > 0} label={"Pinned: #{@pinned_count}"} color={:purple} />
              </div>
            </div>
            <div :if={@cognitive_adjustments != []}>
              <div style="font-size: 0.7em; color: var(--aw-text-muted, #888); margin-bottom: 0.2rem; font-weight: 600;">Adjustments</div>
              <div
                :for={adj <- Enum.take(@cognitive_adjustments, 5)}
                style="margin-bottom: 0.25rem; padding: 0.3rem; border-radius: 4px; background: rgba(74, 158, 255, 0.05); font-size: 0.8em;"
              >
                <span style="color: var(--aw-text-muted, #888);">{inspect(adj)}</span>
              </div>
            </div>
            <.empty_state
              :if={@cognitive_prefs == nil && @cognitive_adjustments == []}
              icon="🧠"
              title="No cognitive data"
              hint="Preferences appear as the agent adapts"
            />
          </div>
        </div>

      </div>
    </div>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp message_style(:user), do: "background: rgba(74, 158, 255, 0.1); margin-left: 2rem;"
  defp message_style(:assistant), do: "background: rgba(74, 255, 158, 0.1); margin-right: 2rem;"
  defp message_style(_), do: ""

  defp role_label(:user), do: "You"
  defp role_label(:assistant), do: "Claude"
  defp role_label(_), do: "System"

  defp format_time(%DateTime{} = dt), do: Helpers.format_relative_time(dt)
  defp format_time(_), do: ""

  defp signal_matches_agent?(signal, agent_id) do
    matches_in?(signal.metadata, agent_id) or matches_in?(signal.data, agent_id)
  end

  defp matches_in?(%{agent_id: id}, agent_id) when id == agent_id, do: true
  defp matches_in?(%{"agent_id" => id}, agent_id) when id == agent_id, do: true
  defp matches_in?(%{id: id}, agent_id) when id == agent_id, do: true
  defp matches_in?(%{"id" => id}, agent_id) when id == agent_id, do: true
  defp matches_in?(_, _), do: false

  defp stream_empty?(%Phoenix.LiveView.LiveStream{inserts: []}), do: true
  defp stream_empty?(_), do: false

  defp action_style(:success), do: "background: rgba(74, 255, 158, 0.1);"
  defp action_style(:failure), do: "background: rgba(255, 74, 74, 0.1);"
  defp action_style(:blocked), do: "background: rgba(255, 165, 0, 0.1);"
  defp action_style(_), do: "background: rgba(128, 128, 128, 0.1);"

  defp outcome_color(:success), do: :green
  defp outcome_color(:failure), do: :red
  defp outcome_color(:blocked), do: :yellow
  defp outcome_color(_), do: :gray

  defp signal_icon(:agent), do: "🤖"
  defp signal_icon(:memory), do: "📝"
  defp signal_icon(:action), do: "⚡"
  defp signal_icon(:security), do: "🔒"
  defp signal_icon(:consensus), do: "🗳️"
  defp signal_icon(:monitor), do: "📊"
  defp signal_icon(_), do: "▶"

  defp get_memory_stats(agent) do
    case Claude.memory_stats(agent) do
      {:ok, stats} -> stats
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_subscribe do
    pid = self()
    handler = fn signal -> send(pid, {:signal_received, signal}); :ok end

    agent_sub =
      case Arbor.Signals.subscribe("agent.*", handler) do
        {:ok, id} -> id
        _ -> nil
      end

    memory_sub =
      case Arbor.Signals.subscribe("memory.*", handler) do
        {:ok, id} -> id
        _ -> nil
      end

    {agent_sub, memory_sub}
  rescue
    _ -> {nil, nil}
  catch
    :exit, _ -> {nil, nil}
  end

  defp safe_unsubscribe(nil), do: :ok

  defp safe_unsubscribe(sub_id) do
    Arbor.Signals.unsubscribe(sub_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_call(fun) do
    try do
      fun.()
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp unwrap_list(result) do
    case result do
      {:ok, list} when is_list(list) -> list
      list when is_list(list) -> list
      _ -> []
    end
  end

  # ── Token Tracking ─────────────────────────────────────────────────

  defp extract_token_usage(socket, response) do
    usage = Map.get(response, :usage) || %{}
    input = usage["input_tokens"] || usage[:input_tokens] || 0
    output = usage["output_tokens"] || usage[:output_tokens] || 0
    cached = usage["cache_read_input_tokens"] || usage[:cache_read_input_tokens] || 0
    agent_id = socket.assigns.agent_id

    if agent_id && (input > 0 || output > 0) do
      tokens = ChatState.add_tokens(agent_id, input, output, nil)
      if cached > 0, do: ChatState.add_cached_tokens(agent_id, cached)

      assign(socket,
        input_tokens: tokens.input,
        output_tokens: tokens.output,
        cached_tokens: if(cached > 0, do: tokens.cached + cached, else: tokens.cached),
        llm_call_count: tokens.count
      )
    else
      socket
    end
  end

  defp format_token_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_token_count(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp format_token_count(n), do: to_string(n)

  defp format_duration(ms) when is_number(ms) and ms >= 1000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms) when is_number(ms), do: "#{ms}ms"
  defp format_duration(_), do: ""

  # ── Signal Tracking: Identity, Cognitive, Code ─────────────────────

  defp maybe_track_identity(socket, signal) do
    event = to_string(signal.type)
    agent_id = socket.assigns.agent_id

    cond do
      event == "memory_self_insight_created" ->
        insight = %{
          content: get_in(signal.data, [:content]) || get_in(signal.metadata, [:content]) || "",
          category: get_in(signal.data, [:category]) || get_in(signal.metadata, [:category]),
          confidence: get_in(signal.data, [:confidence]) || get_in(signal.metadata, [:confidence]),
          timestamp: signal.timestamp
        }

        ChatState.add_insight(agent_id, insight)
        assign(socket, self_insights: ChatState.get_identity_state(agent_id).insights)

      event == "memory_identity_change" ->
        change = %{
          field: get_in(signal.data, [:field]) || get_in(signal.metadata, [:field]),
          change_type: get_in(signal.data, [:change_type]) || get_in(signal.metadata, [:change_type]),
          reason: get_in(signal.data, [:reason]) || get_in(signal.metadata, [:reason]),
          timestamp: signal.timestamp
        }

        ChatState.add_identity_change(agent_id, change)
        assign(socket, identity_changes: ChatState.get_identity_state(agent_id).identity_changes)

      event == "memory_consolidation_completed" ->
        data = signal.data || signal.metadata || %{}

        consolidation = %{
          promoted: data[:promoted] || data["promoted"] || 0,
          deferred: data[:deferred] || data["deferred"] || 0,
          timestamp: signal.timestamp
        }

        ChatState.set_consolidation(agent_id, consolidation)
        assign(socket, last_consolidation: consolidation)

      true ->
        socket
    end
  end

  defp maybe_track_cognitive(socket, signal) do
    event = to_string(signal.type)
    agent_id = socket.assigns.agent_id

    if event == "memory_cognitive_adjustment" do
      data = signal.data || signal.metadata || %{}

      adjustment = %{
        field: data[:field] || data["field"],
        old_value: data[:old_value] || data["old_value"],
        new_value: data[:new_value] || data["new_value"],
        timestamp: signal.timestamp
      }

      ChatState.add_cognitive_adjustment(agent_id, adjustment)
      assign(socket, cognitive_adjustments: ChatState.get_cognitive_state(agent_id).adjustments)
    else
      socket
    end
  end

  defp maybe_track_code(socket, signal) do
    event = to_string(signal.type)
    agent_id = socket.assigns.agent_id

    if event in ["code_created", "memory_code_loaded"] do
      data = signal.data || signal.metadata || %{}

      module_info = %{
        name: data[:name] || data["name"] || data[:module] || data["module"] || "unnamed",
        purpose: data[:purpose] || data["purpose"] || "",
        sandbox_level: data[:sandbox_level] || data["sandbox_level"],
        created_at: signal.timestamp
      }

      ChatState.add_code_module(agent_id, module_info)
      assign(socket, code_modules: ChatState.get_code_modules(agent_id))
    else
      socket
    end
  end

  defp get_working_thoughts(agent) do
    case Claude.get_working_memory(agent) do
      {:ok, nil} -> []
      {:ok, working_memory} -> extract_thoughts(working_memory)
      {:error, _} -> []
    end
  rescue
    _ -> []
  end

  defp extract_thoughts(working_memory) when is_map(working_memory) do
    thoughts = get_thoughts_list(working_memory)

    thoughts
    |> Enum.take(10)
    |> Enum.map(&format_thought/1)
  end

  defp extract_thoughts(_), do: []

  defp get_thoughts_list(wm) do
    cond do
      Map.has_key?(wm, :recent_thoughts) -> wm.recent_thoughts || []
      Map.has_key?(wm, :thoughts) -> wm.thoughts || []
      true -> []
    end
  end

  defp format_thought(t) when is_map(t) do
    %{
      content: t[:content] || Map.get(t, :content) || inspect(t),
      timestamp: t[:timestamp] || Map.get(t, :timestamp) || DateTime.utc_now()
    }
  end

  defp format_thought(t) do
    %{content: to_string(t), timestamp: DateTime.utc_now()}
  end

  defp maybe_add_action(socket, signal) do
    # Check if signal contains action data
    event = to_string(signal.type)

    if String.contains?(event, "action") or String.contains?(event, "tool") do
      action_entry = %{
        id: "act-#{System.unique_integer([:positive])}",
        name: get_action_name(signal),
        outcome: get_action_outcome(signal),
        timestamp: signal.timestamp,
        details: signal.metadata
      }

      stream_insert(socket, :actions, action_entry)
    else
      socket
    end
  end

  defp get_action_name(signal) do
    case signal.metadata do
      %{action: name} -> to_string(name)
      %{"action" => name} -> to_string(name)
      %{tool: name} -> to_string(name)
      %{"tool" => name} -> to_string(name)
      %{name: name} -> to_string(name)
      %{"name" => name} -> to_string(name)
      _ -> to_string(signal.type)
    end
  end

  defp get_action_outcome(signal) do
    extract_outcome(signal.metadata)
  end

  defp extract_outcome(meta) do
    get_explicit_outcome(meta) ||
      get_success_outcome(meta) ||
      get_error_outcome(meta) ||
      :unknown
  end

  defp get_explicit_outcome(meta) do
    meta[:outcome] || meta["outcome"] || meta[:status] || meta["status"]
  end

  defp get_success_outcome(meta) do
    case {meta[:success], meta["success"]} do
      {true, _} -> :success
      {_, true} -> :success
      {false, _} -> :failure
      {_, false} -> :failure
      _ -> nil
    end
  end

  defp get_error_outcome(meta) do
    if Map.has_key?(meta, :error) or Map.has_key?(meta, "error"), do: :failure
  end

  # ── Goals ──────────────────────────────────────────────────────────

  defp fetch_goals(agent_id) do
    if Code.ensure_loaded?(Arbor.Memory) and
         function_exported?(Arbor.Memory, :get_active_goals, 1) do
      Arbor.Memory.get_active_goals(agent_id)
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp goal_status_color(:active), do: :green
  defp goal_status_color(:achieved), do: :blue
  defp goal_status_color(:abandoned), do: :red
  defp goal_status_color(_), do: :gray

  defp goal_progress_color(p) when p >= 0.8, do: "#22c55e"
  defp goal_progress_color(p) when p >= 0.5, do: "#4a9eff"
  defp goal_progress_color(p) when p >= 0.2, do: "#eab308"
  defp goal_progress_color(_), do: "#888"

  # ── Heartbeat / LLM Tracking ───────────────────────────────────────

  defp maybe_track_heartbeat(socket, signal) do
    event = to_string(signal.type)

    if event == "heartbeat_complete" do
      data = signal.data || %{}

      mode = data[:cognitive_mode] || data["cognitive_mode"]
      thinking = data[:agent_thinking] || data["agent_thinking"]
      llm_actions = data[:llm_actions] || data["llm_actions"] || 0
      notes_count = data[:memory_notes_count] || data["memory_notes_count"] || 0

      # Count heartbeat and LLM calls
      heartbeat_count = socket.assigns.heartbeat_count + 1
      llm_call_count = if llm_actions > 0 or thinking, do: socket.assigns.llm_call_count + 1, else: socket.assigns.llm_call_count

      socket =
        assign(socket,
          heartbeat_count: heartbeat_count,
          llm_call_count: llm_call_count,
          last_llm_mode: mode,
          last_llm_thinking: thinking,
          memory_notes_total: socket.assigns.memory_notes_total + notes_count
        )

      # Add to LLM interactions stream if there was thinking
      if thinking && thinking != "" do
        interaction = %{
          id: "llm-#{System.unique_integer([:positive])}",
          mode: mode || :unknown,
          thinking: thinking,
          actions: llm_actions,
          notes: notes_count,
          timestamp: signal.timestamp
        }

        stream_insert(socket, :llm_interactions, interaction)
      else
        socket
      end
    else
      socket
    end
  end

  defp maybe_refresh_goals(socket, signal) do
    event = to_string(signal.type)

    if String.contains?(event, "goal") do
      agent_id = socket.assigns.agent_id
      assign(socket, agent_goals: fetch_goals(agent_id))
    else
      socket
    end
  end

  defp maybe_track_memory_note(socket, signal) do
    event = to_string(signal.type)

    if event == "agent_memory_note" do
      assign(socket, memory_notes_total: socket.assigns.memory_notes_total + 1)
    else
      socket
    end
  end
end
