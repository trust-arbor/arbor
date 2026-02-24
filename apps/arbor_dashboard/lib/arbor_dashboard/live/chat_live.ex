defmodule Arbor.Dashboard.Live.ChatLive do
  @moduledoc """
  Agent chat interface.

  Interactive conversation with Arbor agents, displaying thinking blocks,
  recalled memories, signal emissions, and response streaming.
  """

  use Phoenix.LiveView
  use Arbor.Dashboard.Live.SignalSubscription

  require Logger

  import Arbor.Web.Components
  import Arbor.Web.Helpers
  import Arbor.Dashboard.Live.ChatLive.Components

  alias Arbor.Agent.{APIAgent, Claude, Lifecycle, Manager}
  alias Arbor.Dashboard.ChatState
  alias Arbor.Dashboard.Live.ChatLive.{GroupChat, SignalTracker}
  alias Arbor.Dashboard.Live.ChatLive.Helpers, as: ChatHelpers
  alias Arbor.Web.SignalLive

  @chat_page_size 50

  @impl true
  def mount(_params, _session, socket) do
    ChatState.init()

    {existing_agent, socket} =
      if connected?(socket) do
        {Manager.find_first_agent(), socket}
      else
        {:not_found, socket}
      end

    available_models =
      Application.get_env(:arbor_dashboard, :chat_models, default_models())

    socket =
      socket
      |> assign(
        page_title: "Chat",
        agent: nil,
        agent_id: nil,
        display_name: nil,
        session_id: nil,
        input: "",
        loading: false,
        error: nil,
        available_models: available_models,
        current_model: nil,
        chat_backend: nil,
        # Panel visibility toggles — only key panels expanded by default
        # to avoid cramming 6+ panels into tiny vertical slivers
        show_thinking: true,
        show_memories: false,
        show_actions: true,
        show_thoughts: true,
        show_goals: true,
        show_completed_goals: false,
        show_llm_panel: false,
        show_identity: false,
        show_cognitive: false,
        show_code: false,
        show_proposals: false,
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
        last_memory_notes: [],
        last_concerns: [],
        last_curiosity: [],
        last_identity_insights: [],
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
        selected_heartbeat_model: nil,
        # Chat history pagination
        chat_history_cursor: nil,
        chat_has_more: false
      )
      |> assign(GroupChat.init_assigns())
      |> stream(:messages, [])
      |> stream(:signals, [])
      |> stream(:thinking, [])
      |> stream(:memories, [])
      |> stream(:actions, [])
      |> stream(:llm_interactions, [])

    # Subscribe to signals with backpressure (raw mode — we use individual signals)
    socket =
      if connected?(socket) do
        socket
        |> SignalLive.subscribe_raw("agent.*")
        |> SignalLive.subscribe_raw("memory.*")
      else
        socket
      end

    # Reconnect to existing agent if one is running
    socket =
      case existing_agent do
        {:ok, agent_id, pid, metadata} ->
          reconnect_to_agent(socket, agent_id, pid, metadata)

        :not_found ->
          socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"agent_id" => agent_id}, _uri, socket) do
    # Skip if we're already connected to this agent
    if socket.assigns.agent == agent_id do
      {:noreply, socket}
    else
      {:noreply, connect_or_resume_agent(socket, agent_id)}
    end
  rescue
    e ->
      {:noreply, assign(socket, error: "Error: #{Exception.message(e)}")}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    # Agent survives navigation — managed by Supervisor, not LiveView.
    # Only unsubscribe from signals.
    SignalLive.unsubscribe(socket)
  end

  @impl true
  def handle_event("start-agent", %{"model" => model_id}, socket) do
    model_config = find_model_config(model_id, socket.assigns.available_models)

    case model_config do
      nil ->
        {:noreply, assign(socket, error: "Unknown model: #{model_id}")}

      config ->
        case Manager.start_agent(config) do
          {:ok, agent_id, pid} ->
            metadata = %{model_config: config, backend: config.backend}
            socket = reconnect_to_agent(socket, agent_id, pid, metadata)
            {:noreply, socket}

          {:error, :already_running} ->
            {:noreply, reconnect_existing_agent(socket)}

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
      Manager.stop_agent(socket.assigns.agent_id)
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

    cond do
      input == "" ->
        {:noreply, socket}

      # Group chat mode
      socket.assigns.group_mode and socket.assigns.group_pid ->
        # Add user message to display
        user_msg = %{
          id: "msg-#{System.unique_integer([:positive])}",
          role: :user,
          content: input,
          sender_name: "User",
          sender_type: :human,
          timestamp: DateTime.utc_now()
        }

        socket =
          socket
          |> stream_insert(:messages, user_msg)
          |> assign(input: "", error: nil)

        # Persist to chat history
        try do
          if socket.assigns.group_id do
            Arbor.Memory.append_chat_message(socket.assigns.group_id, user_msg)
          end
        rescue
          _ -> :ok
        end

        # Send to group (triggers agent responses)
        Manager.group_send(
          socket.assigns.group_pid,
          "human_primary",
          "User",
          :human,
          input
        )

        {:noreply, socket}

      # Single-agent mode (existing flow)
      socket.assigns.agent != nil ->
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

        # Persist to chat history (agent_id is the string ID, not the PID)
        try do
          if socket.assigns.agent_id do
            Arbor.Memory.append_chat_message(socket.assigns.agent_id, user_msg)
          end
        rescue
          _ -> :ok
        end

        # Spawn async query — keeps LiveView responsive during LLM calls
        dispatch_query(socket.assigns.chat_backend, socket.assigns.agent, input)

        {:noreply, socket}

      # No agent or group
      true ->
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
    goals = if agent_id, do: SignalTracker.fetch_goals(agent_id, show_completed), else: []

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

  def handle_event("load-more-messages", _params, socket) do
    agent_id = socket.assigns.agent_id
    cursor = socket.assigns[:chat_history_cursor]

    if agent_id && cursor do
      try do
        older =
          Arbor.Memory.load_recent_chat_history(agent_id,
            limit: @chat_page_size,
            before: cursor
          )

        older_with_ids =
          Enum.map(older, fn msg ->
            Map.put_new(msg, :id, "hist-#{System.unique_integer([:positive])}")
          end)

        new_cursor =
          case older_with_ids do
            [first | _] -> first[:id]
            [] -> cursor
          end

        socket =
          older_with_ids
          |> Enum.reduce(socket, fn msg, acc ->
            stream_insert(acc, :messages, msg, at: 0)
          end)
          |> assign(
            chat_history_cursor: new_cursor,
            chat_has_more: older_with_ids != []
          )

        {:noreply, push_event(socket, "messages-loaded", %{count: length(older_with_ids)})}
      rescue
        _ ->
          {:noreply, push_event(socket, "messages-loaded", %{count: 0})}
      end
    else
      {:noreply, push_event(socket, "messages-loaded", %{count: 0})}
    end
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
    # Heartbeat model is now managed by the DOT Session — this UI event
    # only updates the local assign for display purposes.
    hb_config =
      Enum.find(socket.assigns.heartbeat_models, &(&1[:id] == model_id))

    {:noreply, assign(socket, selected_heartbeat_model: hb_config)}
  end

  def handle_event("show-group-modal" = e, p, s), do: GroupChat.handle_event(e, p, s)
  def handle_event("show-join-groups" = e, p, s), do: GroupChat.handle_event(e, p, s)

  def handle_event("join-group" = e, p, s) do
    {:noreply, socket} = GroupChat.handle_event(e, p, s)
    {:noreply, maybe_connect_group_agent(socket)}
  end

  def handle_event("toggle-group-agent" = e, p, s), do: GroupChat.handle_event(e, p, s)
  def handle_event("update-group-name" = e, p, s), do: GroupChat.handle_event(e, p, s)

  def handle_event("confirm-create-group" = e, p, s) do
    {:noreply, socket} = GroupChat.handle_event(e, p, s)
    {:noreply, maybe_connect_group_agent(socket)}
  end

  def handle_event("cancel-group-modal" = e, p, s), do: GroupChat.handle_event(e, p, s)
  def handle_event("leave-group" = e, p, s), do: GroupChat.handle_event(e, p, s)

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:query_result, :cli, {:ok, response}}, socket) do
    thinking = response.thinking

    thinking_label =
      case thinking do
        nil -> "nil"
        [] -> "[]"
        blocks when is_list(blocks) -> "#{length(blocks)} blocks"
        other -> inspect(other)
      end

    Logger.debug(
      "[ChatLive] CLI response — thinking: #{thinking_label}, text_len: #{String.length(response.text || "")}"
    )

    socket = process_query_response(socket, socket.assigns.agent, response)
    {:noreply, socket}
  end

  def handle_info({:query_result, :api, {:ok, response}}, socket) do
    model_config = socket.assigns.current_model || %{}

    # Session path uses tool_history, legacy uses tool_calls
    tool_uses = response[:tool_history] || response[:tool_calls] || []

    assistant_msg = %{
      id: "msg-#{System.unique_integer([:positive])}",
      role: :assistant,
      content: response[:text] || response.text || "",
      tool_uses: tool_uses,
      timestamp: DateTime.utc_now(),
      model: "#{model_config[:provider]}:#{model_config[:id]}",
      session_id: nil,
      memory_count: length(response[:recalled_memories] || [])
    }

    # Persist to chat history
    try do
      agent_id = socket.assigns[:agent_id]

      if agent_id do
        Arbor.Memory.append_chat_message(agent_id, assistant_msg)
      end
    rescue
      _ -> :ok
    end

    socket =
      socket
      |> stream_insert(:messages, assistant_msg)
      |> assign(loading: false, query_count: socket.assigns.query_count + 1)
      |> add_tool_use_actions(tool_uses)
      |> maybe_extract_api_usage(response)
      |> maybe_add_recalled_memories_api(response)

    {:noreply, socket}
  end

  def handle_info({:query_result, _backend, {:error, reason}}, socket) do
    error_msg = ChatHelpers.format_query_error(reason)
    {:noreply, assign(socket, loading: false, error: error_msg)}
  end

  def handle_info({:group_message, _} = msg, socket), do: GroupChat.handle_info(msg, socket)

  def handle_info({:group_participant_joined, _} = msg, socket),
    do: GroupChat.handle_info(msg, socket)

  def handle_info({:group_participant_left, _} = msg, socket),
    do: GroupChat.handle_info(msg, socket)

  # Signal: agent lifecycle events (started, stopped, chat_message)
  def handle_info({:signal_received, %{category: :agent, type: type} = signal}, socket)
      when type in [:started, :stopped, :chat_message] do
    handle_agent_signal(signal, socket)
  end

  # Signal: all other signals (agent activity, heartbeat, etc.)
  def handle_info({:signal_received, signal}, socket) do
    agent_id = socket.assigns.agent_id

    if agent_id && signal_matches_agent?(signal, agent_id) do
      signal_entry = %{
        id: "sig-#{System.unique_integer([:positive])}",
        category: signal.category,
        event: signal.type,
        timestamp: signal.timestamp,
        metadata: signal.metadata
      }

      socket =
        socket
        |> stream_insert(:signals, signal_entry)
        |> SignalTracker.process_signal(signal)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Process monitor: agent crashed or was killed
  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    if pid == socket.assigns[:agent] do
      {:noreply, clear_agent_assigns(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Agent Lifecycle Signal Handlers ────────────────────────────────────

  # Another tab started an agent — reconnect if we have none
  defp handle_agent_signal(%{type: :started} = signal, socket) do
    if socket.assigns[:agent] == nil do
      %{agent_id: agent_id, model_config: model_config} = signal.data
      pid = Map.get(signal.data, :pid)

      metadata = %{
        model_config: model_config,
        backend: model_config[:backend] || Map.get(model_config, :backend)
      }

      if pid && Process.alive?(pid) do
        {:noreply, reconnect_to_agent(socket, agent_id, pid, metadata)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # Agent was stopped (by another tab or programmatically)
  defp handle_agent_signal(%{type: :stopped}, socket) do
    {:noreply, clear_agent_assigns(socket)}
  end

  # External chat message (e.g., from Claude Code via Manager.chat/3)
  defp handle_agent_signal(%{type: :chat_message} = signal, socket) do
    %{role: role, content: content} = signal.data
    sender = Map.get(signal.data, :sender, "External")

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

  # Unknown agent signal — ignore
  defp handle_agent_signal(_signal, socket), do: {:noreply, socket}

  # ── Query Response Helpers ────────────────────────────────────────────

  defp process_query_response(socket, agent, response) do
    assistant_msg = build_assistant_message(response)

    # Persist to chat history (use agent_id string, not the PID)
    try do
      agent_id = socket.assigns[:agent_id]

      if agent_id do
        Arbor.Memory.append_chat_message(agent_id, assistant_msg)
      end
    rescue
      _ -> :ok
    end

    socket
    |> stream_insert(:messages, assistant_msg)
    |> assign(loading: false, session_id: response.session_id)
    |> add_thinking_blocks(response.thinking)
    |> add_recalled_memories(response.recalled_memories)
    |> add_tool_use_actions(assistant_msg.tool_uses)
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

  defp add_tool_use_actions(socket, nil), do: socket
  defp add_tool_use_actions(socket, []), do: socket

  defp add_tool_use_actions(socket, tool_uses) do
    Enum.reduce(tool_uses, socket, fn tool, acc ->
      name = tool[:name] || tool["name"] || "unknown"

      action_entry = %{
        id: "act-#{System.unique_integer([:positive])}",
        name: name,
        outcome: tool_use_outcome(tool),
        timestamp: DateTime.utc_now(),
        input:
          tool[:input] || tool[:arguments] || tool[:args] ||
            tool["input"] || tool["arguments"] || tool["args"] || %{},
        result: tool[:result] || tool["result"]
      }

      stream_insert(acc, :actions, action_entry)
    end)
  end

  defp tool_use_outcome(tool) do
    cond do
      tool[:error] || tool["error"] -> :error
      tool[:result] != nil || tool["result"] != nil -> :success
      true -> :success
    end
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

    <.stats_bar {assigns} />
    <.token_bar {assigns} />

    <%!-- 3-column layout: 20% left | 50% center | 30% right --%>
    <div style="display: grid; grid-template-columns: 20% 1fr 30%; gap: 0.75rem; margin-top: 0.5rem; height: calc(100vh - 160px); min-height: 400px;">
      <%!-- LEFT PANEL: Signals + Actions + Heartbeat + Code + Proposals --%>
      <div style="display: flex; flex-direction: column; gap: 0.5rem; overflow: hidden;">
        <.signals_panel {assigns} />
        <.actions_panel {assigns} />
        <.heartbeat_panel {assigns} />
        <.code_panel {assigns} />
        <.proposals_panel {assigns} />
      </div>

      <%!-- CENTER: Chat Panel --%>
      <.chat_panel {assigns} />

      <%!-- RIGHT PANEL: Goals + Thinking + Thoughts + Memory + Identity + Cognitive --%>
      <div style="display: flex; flex-direction: column; gap: 0.5rem; overflow: hidden; min-height: 0;">
        <.goals_panel {assigns} />
        <.thinking_panel {assigns} />
        <.thoughts_panel {assigns} />
        <.memories_panel {assigns} />
        <.identity_panel {assigns} />
        <.cognitive_panel {assigns} />
      </div>
    </div>

    <.group_modal {assigns} />
    """
  end

  # ── Agent Lifecycle Helpers ──────────────────────────────────────────

  defp dispatch_query(backend, agent, input) do
    lv = self()

    Task.start(fn ->
      {tag, result} = run_query(backend, agent, input)
      send(lv, {:query_result, tag, result})
    end)
  end

  defp run_query(:cli, agent, input) do
    result =
      try do
        Claude.query(agent, input, timeout: :infinity, permission_mode: :bypass)
      catch
        :exit, reason -> {:error, {:agent_crashed, reason}}
      end

    {:cli, result}
  end

  defp run_query(:api, agent, input) do
    result =
      try do
        APIAgent.query(agent, input)
      catch
        :exit, reason -> {:error, {:agent_crashed, reason}}
      end

    {:api, result}
  end

  # Agent already exists — just reconnect to the running instance
  defp reconnect_existing_agent(socket) do
    case Manager.find_first_agent() do
      {:ok, agent_id, pid, metadata} ->
        reconnect_to_agent(socket, agent_id, pid, metadata)

      :not_found ->
        assign(socket, error: "Agent reported running but not found")
    end
  end

  # When joining/creating a group, connect to the first agent participant
  # so side panels (heartbeat, thoughts, memories, goals) show agent data.
  defp maybe_connect_group_agent(socket) do
    if socket.assigns.group_mode do
      agent_participant =
        Enum.find(socket.assigns.group_participants, fn p -> p.type == :agent end)

      case agent_participant do
        nil ->
          socket

        %{id: agent_id} ->
          connect_to_host_or_recover(socket, agent_id, agent_participant[:name])
      end
    else
      socket
    end
  end

  defp get_agent_metadata(agent_id) do
    case Arbor.Agent.Registry.lookup(agent_id) do
      {:ok, entry} -> entry.metadata || %{}
      _ -> %{}
    end
  end

  # Auto-recover a crashed host by calling Lifecycle.start (idempotent).
  # Extracts model/provider from Registry metadata so the host restarts
  # with the same configuration it was originally created with.
  defp recover_host(agent_id) do
    metadata = get_agent_metadata(agent_id)
    model_config = metadata[:model_config] || %{}

    recovery_opts = [
      model: model_config[:id] || model_config["id"],
      provider: model_config[:provider] || model_config["provider"]
    ]

    case Lifecycle.start(agent_id, recovery_opts) do
      {:ok, _executor_pid} ->
        case Lifecycle.get_host(agent_id) do
          {:ok, host_pid} -> {:ok, host_pid, metadata}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Connect to a running agent, or resume a stopped one, handling host recovery.
  defp connect_or_resume_agent(socket, agent_id) do
    case Arbor.Agent.running?(agent_id) do
      true -> get_host_or_recover(socket, agent_id)
      false -> resume_stopped_agent(socket, agent_id)
    end
  end

  defp get_host_or_recover(socket, agent_id) do
    case Lifecycle.get_host(agent_id) do
      {:ok, pid} ->
        metadata = get_agent_metadata(agent_id)
        reconnect_to_agent(socket, agent_id, pid, metadata)

      _ ->
        case recover_host(agent_id) do
          {:ok, pid, metadata} ->
            reconnect_to_agent(socket, agent_id, pid, metadata)

          {:error, reason} ->
            assign(socket, error: "Failed to recover agent host: #{inspect(reason)}")
        end
    end
  end

  defp resume_stopped_agent(socket, agent_id) do
    case Manager.resume_agent(agent_id) do
      {:ok, ^agent_id, pid} ->
        metadata = get_agent_metadata(agent_id)
        reconnect_to_agent(socket, agent_id, pid, metadata)

      {:error, reason} ->
        assign(socket, error: "Failed to resume agent: #{inspect(reason)}")
    end
  end

  # Connect to host or fall back to metadata-only assignment for group agents.
  defp connect_to_host_or_recover(socket, agent_id, fallback_name) do
    case Lifecycle.get_host(agent_id) do
      {:ok, pid} ->
        metadata = get_agent_metadata(agent_id)
        reconnect_to_agent(socket, agent_id, pid, metadata)

      _ ->
        case recover_host(agent_id) do
          {:ok, pid, metadata} -> reconnect_to_agent(socket, agent_id, pid, metadata)
          {:error, _reason} -> assign(socket, agent_id: agent_id, display_name: fallback_name)
        end
    end
  end

  defp reconnect_to_agent(socket, agent_id, pid, metadata) do
    Process.monitor(pid)

    model_config = metadata[:model_config] || %{}
    backend = metadata[:backend] || model_config[:backend]
    display_name = metadata[:display_name]

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
      display_name: display_name,
      error: nil,
      memory_stats: memory_stats,
      current_model: model_config,
      chat_backend: backend
    )
    |> assign(
      query_count: 0,
      working_thoughts: [],
      agent_goals:
        SignalTracker.fetch_goals(agent_id, socket.assigns[:show_completed_goals] || false),
      llm_call_count: tokens.count,
      last_llm_mode: nil,
      last_llm_thinking: nil,
      last_memory_notes: [],
      last_concerns: [],
      last_curiosity: [],
      last_identity_insights: [],
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
    |> then(fn socket ->
      # Load recent chat history with pagination
      try do
        history = Arbor.Memory.load_recent_chat_history(agent_id, limit: @chat_page_size)
        total = Arbor.Memory.chat_history_count(agent_id)

        # Ensure each message has an :id field for streaming
        history_with_ids =
          Enum.map(history, fn msg ->
            Map.put_new(msg, :id, "hist-#{System.unique_integer([:positive])}")
          end)

        oldest_id =
          case history_with_ids do
            [first | _] -> first[:id]
            [] -> nil
          end

        socket
        |> assign(
          chat_history_cursor: oldest_id,
          chat_has_more: total > length(history_with_ids)
        )
        |> stream(:messages, history_with_ids, reset: true)
      rescue
        _ ->
          # Fallback to empty if history unavailable
          socket
          |> assign(chat_history_cursor: nil, chat_has_more: false)
          |> stream(:messages, [], reset: true)
      end
    end)
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
      display_name: nil,
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

  # ── Memory Stats ────────────────────────────────────────────────────

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

  # ── Token Tracking ─────────────────────────────────────────────────

  defp extract_token_usage(socket, response) do
    usage = Map.get(response, :usage) || %{}
    {input, output, cached} = parse_token_counts(usage)
    agent_id = socket.assigns.agent_id

    if agent_id && (input > 0 || output > 0) do
      apply_token_usage(socket, agent_id, input, output, cached)
    else
      socket
    end
  end

  defp parse_token_counts(usage) do
    input = usage["input_tokens"] || usage[:input_tokens] || 0
    output = usage["output_tokens"] || usage[:output_tokens] || 0
    cached = usage["cache_read_input_tokens"] || usage[:cache_read_input_tokens] || 0
    {input, output, cached}
  end

  defp apply_token_usage(socket, agent_id, input, output, cached) do
    tokens = ChatState.add_tokens(agent_id, input, output, nil)
    if cached > 0, do: ChatState.add_cached_tokens(agent_id, cached)

    assign(socket,
      input_tokens: tokens.input,
      output_tokens: tokens.output,
      cached_tokens: if(cached > 0, do: tokens.cached + cached, else: tokens.cached),
      llm_call_count: tokens.count
    )
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
end
