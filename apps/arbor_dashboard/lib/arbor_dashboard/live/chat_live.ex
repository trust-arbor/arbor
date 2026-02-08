defmodule Arbor.Dashboard.Live.ChatLive do
  @moduledoc """
  Agent chat interface.

  Interactive conversation with Arbor agents, displaying thinking blocks,
  recalled memories, signal emissions, and response streaming.
  """

  use Phoenix.LiveView

  import Arbor.Web.Components

  alias Arbor.Agent.{APIAgent, Claude}
  alias Arbor.Dashboard.{AgentManager, ChatState}
  alias Arbor.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    ChatState.init()

    {subscription_ids, existing_agent} =
      if connected?(socket) do
        AgentManager.subscribe()
        {safe_subscribe(), AgentManager.find_agent()}
      else
        {nil, :not_found}
      end

    available_models =
      Application.get_env(:arbor_dashboard, :chat_models, default_models())

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
        available_models: available_models,
        current_model: nil,
        chat_backend: nil,
        # Panel visibility toggles
        show_thinking: true,
        show_memories: true,
        show_actions: true,
        show_thoughts: true,
        show_goals: true,
        show_completed_goals: false,
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
        # Heartbeat token tracking (separate from chat tokens)
        hb_input_tokens: 0,
        hb_output_tokens: 0,
        hb_cached_tokens: 0,
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
        proposals: [],
        # Heartbeat model selection (API agents only)
        heartbeat_models: Application.get_env(:arbor_dashboard, :heartbeat_models, []),
        selected_heartbeat_model: nil
      )
      |> stream(:messages, [])
      |> stream(:signals, [])
      |> stream(:thinking, [])
      |> stream(:memories, [])
      |> stream(:actions, [])
      |> stream(:llm_interactions, [])

    # Reconnect to existing agent if one is running
    socket =
      case existing_agent do
        {:ok, pid, metadata} ->
          reconnect_to_agent(socket, AgentManager.default_agent_id(), pid, metadata)

        :not_found ->
          socket
      end

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    # Agent survives navigation — managed by Supervisor, not LiveView.
    # Only unsubscribe from signals.
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
  def handle_event("start-agent", %{"model" => model_id}, socket) do
    model_config = find_model_config(model_id, socket.assigns.available_models)

    case model_config do
      nil ->
        {:noreply, assign(socket, error: "Unknown model: #{model_id}")}

      config ->
        case AgentManager.start_agent(config) do
          {:ok, agent_id, pid} ->
            metadata = %{model_config: config, backend: config.backend}
            socket = reconnect_to_agent(socket, agent_id, pid, metadata)
            {:noreply, socket}

          {:error, :already_running} ->
            # Agent already exists — just reconnect
            case AgentManager.find_agent() do
              {:ok, pid, metadata} ->
                socket =
                  reconnect_to_agent(socket, AgentManager.default_agent_id(), pid, metadata)

                {:noreply, socket}

              :not_found ->
                {:noreply, assign(socket, error: "Agent reported running but not found")}
            end

          {:error, reason} ->
            {:noreply, assign(socket, error: "Failed to start agent: #{inspect(reason)}")}
        end
    end
  rescue
    e ->
      {:noreply, assign(socket, error: "Error: #{Exception.message(e)}")}
  end

  def handle_event("stop-agent", _params, socket) do
    if socket.assigns[:agent_id] do
      AgentManager.stop_agent(socket.assigns.agent_id)
    end

    {:noreply, clear_agent_assigns(socket)}
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

      # Spawn async query — keeps LiveView responsive during LLM calls
      lv = self()
      agent = socket.assigns.agent

      case socket.assigns.chat_backend do
        :cli ->
          Task.start(fn ->
            result =
              try do
                Claude.query(agent, input, timeout: 300_000, permission_mode: :bypass)
              catch
                :exit, reason -> {:error, {:agent_crashed, reason}}
              end

            send(lv, {:query_result, :cli, result})
          end)

        :api ->
          Task.start(fn ->
            result =
              try do
                APIAgent.query(agent, input)
              catch
                :exit, reason -> {:error, {:agent_crashed, reason}}
              end

            send(lv, {:query_result, :api, result})
          end)
      end

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

  def handle_event("toggle-completed-goals", _params, socket) do
    agent_id = socket.assigns.agent_id
    show_completed = !socket.assigns.show_completed_goals
    goals = if agent_id, do: fetch_goals(agent_id, show_completed), else: []

    {:noreply, assign(socket, show_completed_goals: show_completed, agent_goals: goals)}
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

  def handle_event("set-heartbeat-model", %{"heartbeat_model" => ""}, socket) do
    {:noreply, assign(socket, selected_heartbeat_model: nil)}
  end

  def handle_event("set-heartbeat-model", %{"heartbeat_model" => model_id}, socket) do
    hb_config =
      Enum.find(socket.assigns.heartbeat_models, &(&1[:id] == model_id))

    if hb_config && is_pid(socket.assigns[:agent]) do
      APIAgent.set_heartbeat_model(socket.assigns.agent, hb_config)
    end

    {:noreply, assign(socket, selected_heartbeat_model: hb_config)}
  end

  @impl true
  def handle_info({:query_result, :cli, {:ok, response}}, socket) do
    socket = process_query_response(socket, socket.assigns.agent, response)
    {:noreply, socket}
  end

  def handle_info({:query_result, :api, {:ok, response}}, socket) do
    model_config = socket.assigns.current_model || %{}

    assistant_msg = %{
      id: "msg-#{System.unique_integer([:positive])}",
      role: :assistant,
      content: response[:text] || response.text || "",
      tool_uses: response[:tool_calls] || [],
      timestamp: DateTime.utc_now(),
      model: "#{model_config[:provider]}:#{model_config[:id]}",
      session_id: nil,
      memory_count: length(response[:recalled_memories] || [])
    }

    socket =
      socket
      |> stream_insert(:messages, assistant_msg)
      |> assign(loading: false, query_count: socket.assigns.query_count + 1)
      |> maybe_extract_api_usage(response)
      |> maybe_add_recalled_memories_api(response)

    {:noreply, socket}
  end

  def handle_info({:query_result, _backend, {:error, reason}}, socket) do
    {:noreply, assign(socket, loading: false, error: "Query failed: #{inspect(reason)}")}
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

  # PubSub: another tab started an agent — reconnect if we have none
  def handle_info({:agent_started, agent_id, pid, model_config}, socket) do
    if socket.assigns[:agent] == nil do
      metadata = %{
        model_config: model_config,
        backend: model_config[:backend] || model_config.backend
      }

      {:noreply, reconnect_to_agent(socket, agent_id, pid, metadata)}
    else
      {:noreply, socket}
    end
  end

  # PubSub: agent was stopped (by another tab or programmatically)
  def handle_info({:agent_stopped, _agent_id}, socket) do
    {:noreply, clear_agent_assigns(socket)}
  end

  # Process monitor: agent crashed or was killed
  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    if pid == socket.assigns[:agent] do
      {:noreply, clear_agent_assigns(socket)}
    else
      {:noreply, socket}
    end
  end

  # PubSub: external chat message (e.g., from Claude Code via AgentManager.chat/3)
  def handle_info({:chat_message, %{role: role, content: content} = payload}, socket) do
    sender = Map.get(payload, :sender, "External")

    msg = %{
      id: "msg-#{System.unique_integer([:positive])}",
      role: role,
      content: content,
      timestamp: DateTime.utc_now(),
      model: if(role == :assistant, do: sender, else: nil),
      sender: sender,
      tool_uses: [],
      memory_count: 0,
      session_id: nil
    }

    socket =
      socket
      |> stream_insert(:messages, msg)
      |> then(fn s ->
        if role == :assistant do
          assign(s, loading: false, query_count: s.assigns.query_count + 1)
        else
          assign(s, loading: true)
        end
      end)

    {:noreply, socket}
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
    tool_uses = response[:tool_uses] || response.tool_uses || []

    %{
      id: "msg-#{System.unique_integer([:positive])}",
      role: :assistant,
      content: strip_tool_output(response.text, tool_uses),
      tool_uses: tool_uses,
      timestamp: DateTime.utc_now(),
      model: response.model,
      session_id: response.session_id,
      memory_count: length(response.recalled_memories || [])
    }
  end

  # Strip tool call artifacts from the response text since we render them separately
  defp strip_tool_output(text, []), do: text

  defp strip_tool_output(text, _tool_uses) do
    text
    |> String.replace(~r/\n?⏺ [^\n]*(?:\n  [^\n]*)*/m, "")
    |> String.trim()
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
      :if={@agent && (@llm_call_count > 0 or @heartbeat_count > 0)}
      style="display: flex; justify-content: space-between; padding: 0.4rem 0.75rem; margin-top: 0.35rem; border: 1px solid rgba(74, 158, 255, 0.3); border-radius: 6px; font-size: 0.8em; background: rgba(74, 158, 255, 0.05);"
    >
      <%!-- Chat tokens (left) --%>
      <div :if={@llm_call_count > 0} style="display: flex; gap: 0.75rem; flex-wrap: wrap;">
        <span style="color: #94a3b8; font-weight: 600;">CHAT</span>
        <span style="color: #4a9eff;">
          IN: <strong>{format_token_count(@input_tokens)}</strong>
        </span>
        <span style="color: #22c55e;">
          OUT: <strong>{format_token_count(@output_tokens)}</strong>
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
      <%!-- Heartbeat tokens (right) --%>
      <div :if={@heartbeat_count > 0} style="display: flex; gap: 0.75rem; flex-wrap: wrap;">
        <span style="color: #f97316; font-weight: 600;">HB</span>
        <span style="color: #4a9eff;">
          IN: <strong>{format_token_count(@hb_input_tokens)}</strong>
        </span>
        <span style="color: #22c55e;">
          OUT: <strong>{format_token_count(@hb_output_tokens)}</strong>
        </span>
        <span :if={@hb_cached_tokens > 0} style="color: #a855f7;">
          CACHED: <strong>{format_token_count(@hb_cached_tokens)}</strong>
        </span>
        <span style="color: #e2e8f0;">
          TOTAL: <strong>{format_token_count(@hb_input_tokens + @hb_output_tokens)}</strong>
        </span>
        <span style="color: #f97316;">
          BEATS: <strong>{@heartbeat_count}</strong>
        </span>
      </div>
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
                <span style="font-weight: 500; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                  {sig.event}
                </span>
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
                <span style="font-weight: 500; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                  {action.name}
                </span>
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
            <div
              :if={@last_llm_thinking}
              style="padding: 0.4rem; border-bottom: 1px solid var(--aw-border, #333);"
            >
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
                <div
                  :if={interaction.actions > 0 || interaction.notes > 0}
                  style="margin-top: 0.2rem; display: flex; gap: 0.25rem;"
                >
                  <.badge
                    :if={interaction.actions > 0}
                    label={"#{interaction.actions} actions"}
                    color={:green}
                  />
                  <.badge
                    :if={interaction.notes > 0}
                    label={"#{interaction.notes} notes"}
                    color={:purple}
                  />
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
                <.badge
                  :if={mod[:sandbox_level]}
                  label={to_string(mod[:sandbox_level])}
                  color={:yellow}
                />
              </div>
              <span :if={mod[:purpose]} style="color: var(--aw-text-muted, #888); font-size: 0.9em;">
                {Helpers.truncate(mod[:purpose], 100)}
              </span>
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
          <div
            :if={@show_proposals}
            style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;"
          >
            <div
              :for={proposal <- @proposals}
              style="margin-bottom: 0.4rem; padding: 0.4rem; border-radius: 4px; background: rgba(234, 179, 8, 0.1); font-size: 0.8em;"
            >
              <div style="display: flex; align-items: center; gap: 0.25rem; margin-bottom: 0.2rem;">
                <.badge :if={proposal[:type]} label={to_string(proposal[:type])} color={:yellow} />
                <.badge
                  :if={proposal[:confidence]}
                  label={"#{round(proposal[:confidence] * 100)}%"}
                  color={:blue}
                />
              </div>
              <p style="color: var(--aw-text-muted, #888); margin: 0 0 0.3rem 0; white-space: pre-wrap;">
                {Helpers.truncate(proposal[:content] || proposal[:description] || "", 200)}
              </p>
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
                <%= for model <- @available_models do %>
                  <option value={model.id}>{model.label}</option>
                <% end %>
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
            <span style="color: var(--aw-text-muted, #888); font-size: 0.9em;">
              <%= if @current_model do %>
                Chat with {@current_model.label} ({@current_model.provider})
              <% else %>
                Chat with Claude
              <% end %>
            </span>
            <div style="flex: 1;"></div>
            <form
              :if={@chat_backend == :api and @heartbeat_models != []}
              phx-change="set-heartbeat-model"
              style="display: flex; align-items: center; gap: 0.3rem;"
            >
              <label style="color: var(--aw-text-muted, #888); font-size: 0.8em;">HB:</label>
              <select
                name="heartbeat_model"
                style="padding: 0.2rem 0.4rem; border-radius: 4px; background: var(--aw-bg, #1a1a1a); border: 1px solid var(--aw-border, #333); color: inherit; font-size: 0.8em;"
              >
                <option value="">default</option>
                <%= for hb <- @heartbeat_models do %>
                  <option
                    value={hb.id}
                    selected={@selected_heartbeat_model && @selected_heartbeat_model[:id] == hb.id}
                  >
                    {hb.label}
                  </option>
                <% end %>
              </select>
            </form>
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
            <div :if={msg.content != ""} style="white-space: pre-wrap; font-size: 0.9em;">
              {msg.content}
            </div>
            <%!-- Tool uses (collapsible) --%>
            <div
              :if={msg[:tool_uses] && msg[:tool_uses] != []}
              style="margin-top: 0.3rem; display: flex; flex-direction: column; gap: 0.2rem;"
            >
              <details
                :for={tool <- msg.tool_uses}
                style="border: 1px solid var(--aw-border, #333); border-radius: 4px; background: rgba(0,0,0,0.2); font-size: 0.85em;"
              >
                <summary style="padding: 0.3rem 0.5rem; cursor: pointer; color: var(--aw-text-muted, #aaa); user-select: none; list-style: none; display: flex; align-items: center; gap: 0.4rem;">
                  <span style="color: #888; font-size: 0.9em;">&#9654;</span>
                  <span style={"padding: 0.1rem 0.4rem; border-radius: 3px; font-size: 0.85em; font-weight: 600; " <> tool_badge_style(tool[:name] || tool["name"] || "unknown")}>
                    {tool[:name] || tool["name"] || "unknown"}
                  </span>
                  <span style="color: var(--aw-text-muted, #888); font-size: 0.9em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                    {tool_summary(tool)}
                  </span>
                </summary>
                <div style="padding: 0.4rem 0.5rem; border-top: 1px solid var(--aw-border, #333);">
                  <div style="margin-bottom: 0.3rem;">
                    <strong style="color: var(--aw-text-muted, #888); font-size: 0.85em;">
                      Input:
                    </strong>
                    <pre style="margin: 0.2rem 0; padding: 0.3rem; background: rgba(0,0,0,0.3); border-radius: 3px; overflow-x: auto; white-space: pre-wrap; font-size: 0.85em; max-height: 20vh; overflow-y: auto;">{format_tool_input(tool[:input] || tool[:arguments] || tool["input"] || tool["arguments"] || %{})}</pre>
                  </div>
                  <div :if={tool[:result] || tool["result"]}>
                    <strong style="color: var(--aw-text-muted, #888); font-size: 0.85em;">
                      Result:
                    </strong>
                    <pre style="margin: 0.2rem 0; padding: 0.3rem; background: rgba(0,0,0,0.3); border-radius: 3px; overflow-x: auto; white-space: pre-wrap; font-size: 0.85em; max-height: 20vh; overflow-y: auto;">{format_tool_result(tool[:result] || tool["result"])}</pre>
                  </div>
                </div>
              </details>
            </div>
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
        <div
          :if={@loading}
          style="padding: 0.75rem; border-top: 1px solid var(--aw-border, #333); flex-shrink: 0;"
        >
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
            <%!-- Toggle for completed goals --%>
            <div
              :if={@agent != nil}
              style="margin-bottom: 0.4rem; padding: 0.3rem 0.4rem; border-radius: 4px; background: rgba(128,128,128,0.1); display: flex; justify-content: space-between; align-items: center; cursor: pointer;"
              phx-click="toggle-completed-goals"
            >
              <span style="font-size: 0.75em; color: var(--aw-text-muted, #888);">
                Show completed
              </span>
              <span style="font-size: 0.8em;">
                {if @show_completed_goals, do: "✓", else: "○"}
              </span>
            </div>
            <div
              :for={goal <- @agent_goals}
              style={"margin-bottom: 0.4rem; padding: 0.4rem; border-radius: 4px; font-size: 0.8em; " <> goal_background_style(goal.status)}
            >
              <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.2rem;">
                <span style={"flex: 1; " <> goal_text_style(goal.status)}>{goal.description}</span>
                <.badge label={to_string(goal.status)} color={goal_status_color(goal.status)} />
              </div>
              <div style="background: rgba(128,128,128,0.2); height: 3px; border-radius: 2px; overflow: hidden;">
                <div style={"background: #{goal_progress_color(goal.progress)}; height: 100%; width: #{round(goal.progress * 100)}%; transition: width 0.3s ease;"}>
                </div>
              </div>
              <div style="display: flex; justify-content: space-between; margin-top: 2px;">
                <span style="font-size: 0.7em; color: var(--aw-text-muted, #888);">
                  Priority: {goal.priority}
                </span>
                <span style="font-size: 0.7em; color: var(--aw-text-muted, #888);">
                  {round(goal.progress * 100)}%
                </span>
              </div>
              <div
                :if={goal.achieved_at && goal.status == :achieved}
                style="margin-top: 0.2rem; font-size: 0.7em; color: var(--aw-text-muted, #888);"
              >
                ✓ Achieved {format_time(goal.achieved_at)}
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
              <div style="font-size: 0.7em; color: var(--aw-text-muted, #888); margin-bottom: 0.2rem; font-weight: 600;">
                Self Insights
              </div>
              <div
                :for={insight <- Enum.take(@self_insights, 5)}
                style="margin-bottom: 0.35rem; padding: 0.35rem; border-radius: 4px; background: rgba(168, 85, 247, 0.1); font-size: 0.8em;"
              >
                <div style="display: flex; align-items: center; gap: 0.25rem; margin-bottom: 0.15rem;">
                  <.badge
                    :if={insight[:category]}
                    label={to_string(insight[:category])}
                    color={:purple}
                  />
                  <.badge
                    :if={insight[:confidence]}
                    label={"#{round(insight[:confidence] * 100)}%"}
                    color={:blue}
                  />
                </div>
                <span style="color: var(--aw-text-muted, #888);">
                  {Helpers.truncate(insight[:content] || "", 150)}
                </span>
              </div>
            </div>
            <div :if={@identity_changes != []} style="margin-bottom: 0.5rem;">
              <div style="font-size: 0.7em; color: var(--aw-text-muted, #888); margin-bottom: 0.2rem; font-weight: 600;">
                Identity Changes
              </div>
              <div
                :for={change <- Enum.take(@identity_changes, 5)}
                style="margin-bottom: 0.25rem; padding: 0.3rem; border-radius: 4px; background: rgba(234, 179, 8, 0.1); font-size: 0.8em;"
              >
                <.badge :if={change[:field]} label={to_string(change[:field])} color={:yellow} />
                <.badge
                  :if={change[:change_type]}
                  label={to_string(change[:change_type])}
                  color={:gray}
                />
                <span
                  :if={change[:reason]}
                  style="color: var(--aw-text-muted, #888); font-size: 0.9em;"
                >
                  {Helpers.truncate(change[:reason], 100)}
                </span>
              </div>
            </div>
            <div
              :if={@last_consolidation}
              style="font-size: 0.75em; color: var(--aw-text-muted, #888); padding: 0.3rem; background: rgba(128,128,128,0.1); border-radius: 4px;"
            >
              Last consolidation: promoted {Map.get(@last_consolidation, :promoted, 0)}, deferred {Map.get(
                @last_consolidation,
                :deferred,
                0
              )}
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
          <div
            :if={@show_cognitive}
            style="flex: 1; overflow-y: auto; min-height: 0; padding: 0.4rem;"
          >
            <div :if={@cognitive_prefs} style="margin-bottom: 0.4rem;">
              <div style="display: flex; gap: 0.5rem; flex-wrap: wrap; margin-bottom: 0.3rem;">
                <.badge label={"Decay: #{Map.get(@cognitive_prefs, :decay_rate, "—")}"} color={:blue} />
                <.badge
                  label={"Threshold: #{Map.get(@cognitive_prefs, :retrieval_threshold, "—")}"}
                  color={:green}
                />
                <.badge :if={@pinned_count > 0} label={"Pinned: #{@pinned_count}"} color={:purple} />
              </div>
            </div>
            <div :if={@cognitive_adjustments != []}>
              <div style="font-size: 0.7em; color: var(--aw-text-muted, #888); margin-bottom: 0.2rem; font-weight: 600;">
                Adjustments
              </div>
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

  # ── Agent Lifecycle Helpers ──────────────────────────────────────────

  defp reconnect_to_agent(socket, agent_id, pid, metadata) do
    Process.monitor(pid)

    model_config = metadata[:model_config] || %{}
    backend = metadata[:backend] || model_config[:backend]

    memory_stats = get_memory_stats(pid)
    tokens = ChatState.get_tokens(agent_id)
    identity = ChatState.get_identity_state(agent_id)
    cognitive = ChatState.get_cognitive_state(agent_id)
    code = ChatState.get_code_modules(agent_id)
    proposals = unwrap_list(safe_call(fn -> Arbor.Memory.get_proposals(agent_id) end))
    ChatState.touch_agent(agent_id)

    socket
    |> assign(
      agent: pid,
      agent_id: agent_id,
      error: nil,
      memory_stats: memory_stats,
      current_model: model_config,
      chat_backend: backend
    )
    |> assign(
      query_count: 0,
      working_thoughts: [],
      agent_goals: fetch_goals(agent_id, socket.assigns[:show_completed_goals] || false),
      llm_call_count: tokens.count,
      last_llm_mode: nil,
      last_llm_thinking: nil,
      heartbeat_count: 0,
      memory_notes_total: 0,
      input_tokens: tokens.input,
      output_tokens: tokens.output,
      cached_tokens: tokens.cached,
      last_duration_ms: tokens.last_duration,
      hb_input_tokens: 0,
      hb_output_tokens: 0,
      hb_cached_tokens: 0,
      self_insights: identity.insights,
      identity_changes: identity.identity_changes,
      last_consolidation: identity.last_consolidation,
      cognitive_prefs: cognitive.current_prefs,
      cognitive_adjustments: cognitive.adjustments,
      pinned_count: cognitive.pinned_count,
      code_modules: code,
      proposals: proposals,
      selected_heartbeat_model: nil
    )
    |> stream(:messages, [], reset: true)
    |> stream(:signals, [], reset: true)
    |> stream(:thinking, [], reset: true)
    |> stream(:memories, [], reset: true)
    |> stream(:actions, [], reset: true)
    |> stream(:llm_interactions, [], reset: true)
  end

  defp clear_agent_assigns(socket) do
    assign(socket,
      agent: nil,
      agent_id: nil,
      session_id: nil,
      memory_stats: nil,
      agent_goals: [],
      llm_call_count: 0,
      heartbeat_count: 0,
      chat_backend: nil,
      current_model: nil
    )
  end

  # ── Model Config Helpers ─────────────────────────────────────────────

  defp find_model_config(model_id, models) do
    Enum.find(models, fn m -> m.id == model_id end)
  end

  defp default_models do
    [
      %{id: "haiku", label: "Haiku (fast)", provider: :anthropic, backend: :cli},
      %{id: "sonnet", label: "Sonnet (balanced)", provider: :anthropic, backend: :cli},
      %{id: "opus", label: "Opus (powerful)", provider: :anthropic, backend: :cli}
    ]
  end

  defp maybe_extract_api_usage(socket, response) do
    usage = response[:usage] || %{}
    input = usage[:input_tokens] || usage["input_tokens"] || 0
    output = usage[:output_tokens] || usage["output_tokens"] || 0

    if input > 0 or output > 0 do
      agent_id = socket.assigns.agent_id
      tokens = ChatState.add_tokens(agent_id, input, output, nil)

      assign(socket,
        input_tokens: tokens.input,
        output_tokens: tokens.output,
        total_tokens: tokens.input + tokens.output,
        llm_call_count: tokens.count
      )
    else
      assign(socket, llm_call_count: socket.assigns.llm_call_count + 1)
    end
  end

  defp maybe_add_recalled_memories_api(socket, response) do
    memories = response[:recalled_memories] || []

    if memories != [] do
      Enum.reduce(memories, socket, fn memory, sock ->
        entry = %{
          id: "mem-#{System.unique_integer([:positive])}",
          content: memory[:content] || memory[:text] || inspect(memory),
          score: memory[:score] || memory[:similarity],
          timestamp: DateTime.utc_now()
        }

        stream_insert(sock, :memories, entry)
      end)
    else
      socket
    end
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
    case GenServer.call(agent, :memory_stats) do
      {:ok, stats} -> stats
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # Max messages we allow in the LiveView mailbox before dropping signals.
  # Prevents signal storms from making the UI unresponsive.
  @max_signal_queue 500

  defp safe_subscribe do
    pid = self()

    handler = fn signal ->
      # Check queue pressure before sending — drop signals when overwhelmed
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, len} when len < @max_signal_queue ->
          send(pid, {:signal_received, signal})

        _ ->
          :ok
      end

      :ok
    end

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

  # ── Tool Display Helpers ────────────────────────────────────────────

  defp tool_badge_style(name) do
    cond do
      name in ~w(Read Glob Grep) ->
        "background: rgba(74, 158, 255, 0.2); color: #4a9eff;"

      name in ~w(Edit Write NotebookEdit) ->
        "background: rgba(255, 167, 38, 0.2); color: #ffa726;"

      name in ~w(Bash) ->
        "background: rgba(255, 74, 74, 0.2); color: #ff4a4a;"

      name in ~w(Task WebFetch WebSearch) ->
        "background: rgba(171, 71, 188, 0.2); color: #ab47bc;"

      true ->
        "background: rgba(255, 255, 255, 0.1); color: #aaa;"
    end
  end

  defp tool_summary(tool) when is_map(tool) do
    name = tool[:name] || tool["name"] || ""
    input = tool[:input] || tool[:arguments] || tool["input"] || tool["arguments"] || %{}

    case name do
      "Read" ->
        Map.get(input, "file_path", "") |> Path.basename()

      "Glob" ->
        Map.get(input, "pattern", "")

      "Grep" ->
        Map.get(input, "pattern", "")

      "Edit" ->
        Map.get(input, "file_path", "") |> Path.basename()

      "Write" ->
        Map.get(input, "file_path", "") |> Path.basename()

      "Bash" ->
        Map.get(input, "command", "") |> String.slice(0, 60)

      "Task" ->
        Map.get(input, "description", "")

      "WebFetch" ->
        Map.get(input, "url", "") |> String.slice(0, 60)

      "WebSearch" ->
        Map.get(input, "query", "")

      n when is_binary(n) ->
        # Handle API tool names like "memory_remember", "memory_recall"
        summarize_api_tool(n, input)

      _ ->
        ""
    end
  end

  defp tool_summary(_), do: ""

  defp summarize_api_tool(name, input) when is_map(input) do
    cond do
      Map.has_key?(input, "content") -> String.slice(to_string(input["content"]), 0, 50)
      Map.has_key?(input, :content) -> String.slice(to_string(input[:content]), 0, 50)
      Map.has_key?(input, "query") -> String.slice(to_string(input["query"]), 0, 50)
      Map.has_key?(input, :query) -> String.slice(to_string(input[:query]), 0, 50)
      true -> name
    end
  end

  defp summarize_api_tool(name, _), do: name

  defp format_tool_input(input) when is_map(input) do
    Jason.encode!(input, pretty: true)
  rescue
    _ -> inspect(input, pretty: true, limit: 500)
  end

  defp format_tool_input(input), do: inspect(input, pretty: true, limit: 500)

  defp format_tool_result({:ok, result}), do: format_tool_result(result)
  defp format_tool_result({:error, reason}), do: "Error: #{inspect(reason)}"
  defp format_tool_result(nil), do: "(handled by CLI)"

  defp format_tool_result(result) when is_binary(result) do
    if String.length(result) > 2000 do
      String.slice(result, 0, 2000) <> "\n... (truncated)"
    else
      result
    end
  end

  defp format_tool_result(result), do: inspect(result, pretty: true, limit: 500)

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
          confidence:
            get_in(signal.data, [:confidence]) || get_in(signal.metadata, [:confidence]),
          timestamp: signal.timestamp
        }

        ChatState.add_insight(agent_id, insight)
        assign(socket, self_insights: ChatState.get_identity_state(agent_id).insights)

      event == "memory_identity_change" ->
        change = %{
          field: get_in(signal.data, [:field]) || get_in(signal.metadata, [:field]),
          change_type:
            get_in(signal.data, [:change_type]) || get_in(signal.metadata, [:change_type]),
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

  defp fetch_goals(agent_id, show_completed \\ false) do
    if Code.ensure_loaded?(Arbor.Memory) do
      if show_completed do
        cond do
          function_exported?(Arbor.Memory, :get_all_goals, 1) ->
            Arbor.Memory.get_all_goals(agent_id)
            |> Enum.sort_by(fn goal ->
              # Sort: active goals by priority (desc), completed by achieved_at (desc)
              case goal.status do
                :active -> {0, -goal.priority}
                _ -> {1, goal.achieved_at || goal.created_at}
              end
            end)

          function_exported?(Arbor.Memory, :get_active_goals, 1) ->
            Arbor.Memory.get_active_goals(agent_id)

          true ->
            []
        end
      else
        if function_exported?(Arbor.Memory, :get_active_goals, 1) do
          Arbor.Memory.get_active_goals(agent_id)
        else
          []
        end
      end
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

  defp goal_background_style(:active), do: "background: rgba(74, 255, 158, 0.05);"
  defp goal_background_style(:achieved), do: "background: rgba(74, 158, 255, 0.05); opacity: 0.7;"
  defp goal_background_style(:abandoned), do: "background: rgba(255, 74, 74, 0.05); opacity: 0.7;"
  defp goal_background_style(:failed), do: "background: rgba(255, 74, 74, 0.05); opacity: 0.7;"
  defp goal_background_style(_), do: "background: rgba(128, 128, 128, 0.05); opacity: 0.7;"

  defp goal_text_style(:active), do: ""
  defp goal_text_style(_), do: "opacity: 0.8;"

  # ── Heartbeat / LLM Tracking ───────────────────────────────────────

  defp maybe_track_heartbeat(socket, signal) do
    event = to_string(signal.type)

    if event == "heartbeat_complete" do
      data = signal.data || %{}

      mode = data[:cognitive_mode] || data["cognitive_mode"]
      thinking = data[:agent_thinking] || data["agent_thinking"]
      llm_actions = data[:llm_actions] || data["llm_actions"] || 0
      notes_count = data[:memory_notes_count] || data["memory_notes_count"] || 0
      usage = data[:usage] || data["usage"] || %{}

      # Extract heartbeat LLM token usage
      hb_in = usage[:input_tokens] || usage["input_tokens"] || 0
      hb_out = usage[:output_tokens] || usage["output_tokens"] || 0
      hb_cached = usage[:cache_read_input_tokens] || usage["cache_read_input_tokens"] || 0

      # Count heartbeat (LLM call count tracked separately for chat only)
      heartbeat_count = socket.assigns.heartbeat_count + 1

      socket =
        assign(socket,
          heartbeat_count: heartbeat_count,
          last_llm_mode: mode,
          last_llm_thinking: thinking,
          memory_notes_total: socket.assigns.memory_notes_total + notes_count,
          hb_input_tokens: socket.assigns.hb_input_tokens + hb_in,
          hb_output_tokens: socket.assigns.hb_output_tokens + hb_out,
          hb_cached_tokens: socket.assigns.hb_cached_tokens + hb_cached
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
      show_completed = socket.assigns.show_completed_goals
      assign(socket, agent_goals: fetch_goals(agent_id, show_completed))
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
