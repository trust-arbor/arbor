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
  alias Arbor.Contracts.Pipeline.Response, as: PipelineResponse
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
        {find_agent_for_session(socket), socket}
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
        action_count: 0,
        show_goals: true,
        show_completed_goals: false,
        show_llm_panel: false,
        show_approvals: true,
        # Memory state
        memory_stats: nil,
        # Token tracking
        input_tokens: 0,
        output_tokens: 0,
        cached_tokens: 0,
        last_duration_ms: nil,
        total_tokens: 0,
        total_cost: 0.0,
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
        hb_total_cost: 0.0,
        # Heartbeat model selection (API agents only)
        heartbeat_models: Application.get_env(:arbor_dashboard, :heartbeat_models, []),
        selected_heartbeat_model: nil,
        # Streaming text (real-time LLM output)
        streaming_text: "",
        # Chat history pagination
        chat_history_cursor: nil,
        chat_has_more: false,
        signal_count: 0,
        thinking_count: 0,
        memories_count: 0,
        llm_interactions_count: 0,
        approvals_count: 0
      )
      |> assign(GroupChat.init_assigns())
      |> stream(:messages, [])
      |> stream(:signals, [])
      |> stream(:thinking, [])
      |> stream(:memories, [])
      |> stream(:actions, [])
      |> stream(:llm_interactions, [])
      |> stream(:approvals, [])

    # Subscribe to signals with backpressure (raw mode — we use individual signals)
    socket =
      if connected?(socket) do
        # Pass principal_id + session_token for restricted topic subscriptions
        principal_id = socket.assigns[:current_agent_id]
        session_token = socket.assigns[:session_token]

        security_opts =
          if principal_id do
            opts = [principal_id: principal_id]
            if session_token, do: Keyword.put(opts, :session_token, session_token), else: opts
          else
            []
          end

        socket
        |> SignalLive.subscribe_raw("agent.*")
        |> SignalLive.subscribe_raw("memory.*")
        |> SignalLive.subscribe_raw("security.authorization_pending", security_opts)
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

    # Periodic approvals re-sync — defense in depth against signal drops at
    # the SignalLive bridge under backpressure. Every 5s, re-fetch pending
    # approvals from Consensus and reset the stream so dropped approvals can't
    # leave the user with no way to see/approve a pending tool call.
    if connected?(socket) do
      :timer.send_interval(5_000, :refresh_approvals)
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
        # Pass tenant_context so agent gets associated with the creating user
        start_opts =
          case Map.get(socket.assigns, :tenant_context) do
            nil -> []
            ctx -> [tenant_context: ctx]
          end

        case Manager.start_agent(config, start_opts) do
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
      socket.assigns.group_mode and socket.assigns.group_id ->
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

        # Persist to session store
        try do
          if socket.assigns.group_id do
            persist_group_message(socket.assigns.group_id, user_msg)
          end
        rescue
          _ -> :ok
        end

        # Send to channel (triggers agent responses)
        Manager.channel_send(
          socket.assigns.group_id,
          "human_primary",
          "User",
          :human,
          input
        )

        {:noreply, socket}

      # Single-agent mode (existing flow)
      socket.assigns.agent != nil ->
        # Guard: don't send a second message while a query is in flight.
        # Without this, the Session returns {:error, :turn_in_progress}
        # and the APIAgent falls back to direct query (potentially with stale context).
        if socket.assigns.loading do
          Logger.debug("[ChatLive] Ignoring send-message — query already in flight")
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
            |> assign(input: "", loading: true, error: nil, streaming_text: "")

          # Spawn async query — keeps LiveView responsive during LLM calls
          # Command routing happens centrally in Manager.chat/Session.send_message
          dispatch_query(socket.assigns.chat_backend, socket.assigns.agent, input)

          {:noreply, socket}
        end

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

  def handle_event("toggle-approvals", _params, socket) do
    {:noreply, assign(socket, show_approvals: !socket.assigns.show_approvals)}
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

  def handle_event("load-more-messages", _params, socket) do
    agent_id = socket.assigns.agent_id
    cursor = socket.assigns[:chat_history_cursor]

    if agent_id && cursor do
      try do
        sess_id = "agent-session-#{agent_id}"

        older =
          load_session_history(sess_id,
            limit: @chat_page_size,
            before_timestamp: cursor
          )

        older_with_ids =
          Enum.map(older, fn msg ->
            Map.put_new(msg, :id, "hist-#{System.unique_integer([:positive])}")
          end)

        new_cursor =
          case older_with_ids do
            [first | _] -> first[:timestamp]
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

  def handle_event("approve-tool", %{"id" => proposal_id}, socket) do
    actor_id = socket.assigns[:current_agent_id] || "system"

    case safe_consensus_approve(proposal_id, actor_id) do
      :ok ->
        {:noreply, stream_delete_by_dom_id(socket, :approvals, "approvals-#{proposal_id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Approve failed: #{inspect(reason)}")}
    end
  end

  def handle_event(
        "always-allow-tool",
        %{"id" => proposal_id, "agent" => agent_id, "resource" => resource},
        socket
      ) do
    actor_id = socket.assigns[:current_agent_id] || "system"

    case safe_consensus_approve(proposal_id, actor_id) do
      :ok ->
        # Update trust profile to auto-allow
        store = Arbor.Trust.Store

        if Code.ensure_loaded?(store) and function_exported?(store, :always_allow, 2) do
          apply(store, :always_allow, [agent_id, resource])
        end

        {:noreply, stream_delete_by_dom_id(socket, :approvals, "approvals-#{proposal_id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Always allow failed: #{inspect(reason)}")}
    end
  end

  def handle_event("deny-tool", %{"id" => proposal_id}, socket) do
    actor_id = socket.assigns[:current_agent_id] || "system"

    case safe_consensus_reject(proposal_id, actor_id) do
      :ok ->
        {:noreply, stream_delete_by_dom_id(socket, :approvals, "approvals-#{proposal_id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Deny failed: #{inspect(reason)}")}
    end
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

    socket =
      socket
      |> assign(streaming_text: "")
      |> process_query_response(socket.assigns.agent, response)

    {:noreply, socket}
  end

  def handle_info({:query_result, :api, {:ok, response}}, socket) do
    model_config = socket.assigns.current_model || %{}

    normalized = PipelineResponse.normalize(response)
    text = normalized.content

    # If the final response is empty but we have streamed text, use the streamed text.
    # This preserves partial responses when the LLM stream completes without a final message.
    text =
      if text == "" and is_binary(socket.assigns[:streaming_text]) and
           socket.assigns[:streaming_text] != "" do
        socket.assigns[:streaming_text]
      else
        text
      end

    Logger.info(
      "[ChatLive] API response received: " <>
        "text=#{String.length(to_string(text))} chars, " <>
        "type=#{response[:type]}, " <>
        "tool_history=#{length(response[:tool_history] || [])}"
    )

    # Session path uses tool_history, legacy uses tool_calls
    tool_uses = response[:tool_history] || response[:tool_calls] || []

    # Detect empty responses (rate-limited or model error)
    if (text == "" or text == nil) and tool_uses == [] do
      error_msg = ChatHelpers.format_query_error(:empty_response)
      {:noreply, assign(socket, loading: false, streaming_text: "", error: error_msg)}
    else
      assistant_msg = %{
        id: "msg-#{System.unique_integer([:positive])}",
        role: :assistant,
        content: text,
        tool_uses: tool_uses,
        timestamp: DateTime.utc_now(),
        model: "#{model_config[:provider]}:#{model_config[:id]}",
        session_id: nil,
        memory_count: length(response[:recalled_memories] || [])
      }

      socket =
        socket
        |> assign(streaming_text: "")
        |> stream_insert(:messages, assistant_msg)
        |> assign(loading: false, query_count: socket.assigns.query_count + 1)
        |> add_tool_use_actions(tool_uses)
        |> maybe_extract_api_usage(response)
        |> maybe_add_recalled_memories_api(response)

      {:noreply, socket}
    end
  end

  def handle_info({:query_result, _backend, {:error, reason}}, socket) do
    error_msg = ChatHelpers.format_query_error(reason)
    {:noreply, assign(socket, loading: false, error: error_msg)}
  end

  # Signal: agent lifecycle events (started, stopped, chat_message)
  def handle_info({:signal_received, %{category: :agent, type: type} = signal}, socket)
      when type in [:started, :stopped, :chat_message] do
    handle_agent_signal(signal, socket)
  end

  # Signal: security authorization pending (tool approval requests).
  #
  # Only insert if the signal is for THIS chat's agent. The previous
  # condition (`if agent_id && signal_agent`) accepted signals for any
  # agent as long as both fields were non-nil — which meant a chat
  # connected to agent X could see approval cards for agent Y that the
  # user couldn't actually approve from there.
  #
  # When agent_id is nil (the chat hasn't connected to an agent yet),
  # we drop the signal — the periodic polling fallback (handle_info
  # :refresh_approvals, every 5s) will pick it up after connect.
  def handle_info(
        {:signal_received, %{category: :security, type: :authorization_pending} = signal},
        socket
      ) do
    agent_id = socket.assigns.agent_id
    signal_agent = get_in(signal.data, [:principal_id]) || get_in(signal.data, ["principal_id"])

    if agent_id && signal_agent == agent_id do
      approval = %{
        id:
          signal.data[:proposal_id] || signal.data["proposal_id"] ||
            "prop-#{System.unique_integer([:positive])}",
        proposer: signal_agent,
        metadata: signal.data,
        created_at: signal.timestamp || DateTime.utc_now()
      }

      {:noreply,
       socket
       |> stream_insert(:approvals, approval)
       |> update(:approvals_count, &(&1 + 1))}
    else
      {:noreply, socket}
    end
  end

  # Signal: all other signals (agent activity, heartbeat, etc.)
  def handle_info({:signal_received, signal}, socket) do
    agent_id = socket.assigns.agent_id

    # Drop high-frequency signals that don't add value to the chat UI
    if signal.type in [:stream_delta, :stream_finish, :checkpoint_saved, :fidelity_resolved] do
      # Only process turn stream deltas (for streaming text display).
      # Heartbeat deltas and other high-frequency signals are dropped entirely.
      source = get_in(signal.data, [:source]) || get_in(signal.data, ["source"])

      socket =
        if signal.type == :stream_delta and source == :turn and socket.assigns[:loading] do
          SignalTracker.process_signal(socket, signal)
        else
          socket
        end

      {:noreply, socket}
    else
      # Backpressure: drop signals when message queue is building up
      {:message_queue_len, queue_len} = Process.info(self(), :message_queue_len)

      if agent_id && queue_len < 100 && signal_matches_agent?(signal, agent_id) do
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
          |> update(:signal_count, &(&1 + 1))
          |> SignalTracker.process_signal(signal)

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    end
  rescue
    e ->
      Logger.warning("[ChatLive] Signal handler crashed: #{Exception.message(e)}")
      {:noreply, socket}
  end

  # Periodic re-sync of pending approvals from Consensus. Defense against
  # signals dropped at the bridge under backpressure (see fetch_pending_approvals).
  def handle_info(:refresh_approvals, socket) do
    case socket.assigns[:agent_id] do
      nil ->
        {:noreply, socket}

      agent_id ->
        approvals = fetch_pending_approvals(agent_id)
        {:noreply, stream(socket, :approvals, approvals, reset: true)}
    end
  rescue
    _ -> {:noreply, socket}
  end

  # Process monitor: agent supervisor crashed or was killed
  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    if pid == socket.assigns[:supervisor_pid] or pid == socket.assigns[:agent] do
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
      agent_id = Map.get(signal.data, :agent_id)
      model_config = Map.get(signal.data, :model_config, %{})
      pid = Map.get(signal.data, :pid)

      if agent_id && pid && Process.alive?(pid) do
        metadata = %{
          model_config: model_config,
          backend: model_config[:backend] || Map.get(model_config, :backend)
        }

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
    role = Map.get(signal.data, :role, :assistant)
    content = Map.get(signal.data, :content, "")
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

      acc
      |> stream_insert(:thinking, entry)
      |> update(:thinking_count, &(&1 + 1))
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

      acc
      |> stream_insert(:memories, entry)
      |> update(:memories_count, &(&1 + 1))
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
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="Agent Chat" subtitle="Interactive conversation with Claude + Memory" />

    <.stats_bar {assigns} />
    <.token_bar {assigns} />

    <%!-- 3-column layout: 20% left | 50% center | 30% right --%>
    <div
      id="chat-grid"
      phx-hook="ResizableColumns"
      data-col-min="150"
      style="display: grid; grid-template-columns: 20% 1fr 30%; margin-top: 0.5rem; height: calc(100vh - 160px); min-height: 400px;"
    >
      <%!-- LEFT PANEL: Approvals + Actions + Heartbeat + Signals --%>
      <div
        id="left-panels"
        phx-hook="ResizableRows"
        data-row-min="40"
        style="display: flex; flex-direction: column; overflow: hidden;"
      >
        <.approvals_panel {assigns} />
        <.actions_panel {assigns} />
        <.heartbeat_panel {assigns} />
        <.signals_panel {assigns} />
      </div>

      <%!-- CENTER: Chat Panel --%>
      <.chat_panel {assigns} />

      <%!-- RIGHT PANEL: Goals + Memories + Thinking --%>
      <div
        id="right-panels"
        phx-hook="ResizableRows"
        data-row-min="40"
        style="display: flex; flex-direction: column; overflow: hidden; min-height: 0;"
      >
        <.goals_panel {assigns} />
        <.memories_panel {assigns} />
        <.thinking_panel {assigns} />
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
    case find_agent_for_session(socket) do
      {:ok, agent_id, pid, metadata} ->
        reconnect_to_agent(socket, agent_id, pid, metadata)

      :not_found ->
        assign(socket, error: "Agent reported running but not found")
    end
  end

  # Find agent scoped to current user's tenant context when available.
  # Falls back to global find_first_agent for backward compatibility.
  defp find_agent_for_session(socket) do
    case Map.get(socket.assigns, :current_agent_id) do
      nil -> Manager.find_first_agent()
      principal_id -> Manager.find_agent_for_principal(principal_id)
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
    # pid from Registry is the BranchSupervisor — monitor it for :DOWN
    Process.monitor(pid)

    model_config = metadata[:model_config] || %{}
    backend = metadata[:backend] || model_config[:backend]
    display_name = metadata[:display_name]

    # Use host_pid as the primary `agent` assign — it's the APIAgent GenServer
    # that handles :query, :memory_stats, etc. The supervisor PID is only for monitoring.
    host_pid = metadata[:host_pid] || pid
    memory_stats = get_memory_stats(host_pid)
    tokens = get_telemetry_tokens(agent_id)
    ChatState.touch_agent(agent_id)

    socket
    |> assign(
      agent: host_pid,
      supervisor_pid: pid,
      agent_id: agent_id,
      display_name: display_name,
      error: nil,
      memory_stats: memory_stats,
      current_model: model_config,
      chat_backend: backend
    )
    |> assign(
      query_count: 0,
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
      hb_total_cost: 0.0,
      selected_heartbeat_model: nil
    )
    |> then(fn socket ->
      # Load recent chat history from SessionStore with pagination
      try do
        sess_id = "agent-session-#{agent_id}"
        history = load_session_history(sess_id, limit: @chat_page_size)
        total = session_message_count(sess_id)

        # Ensure each message has an :id field for streaming
        history_with_ids =
          Enum.map(history, fn msg ->
            Map.put_new(msg, :id, "hist-#{System.unique_integer([:positive])}")
          end)

        oldest_timestamp =
          case history_with_ids do
            [first | _] -> first[:timestamp]
            [] -> nil
          end

        socket
        |> assign(
          chat_history_cursor: oldest_timestamp,
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
    |> assign(
      signal_count: 0,
      thinking_count: 0,
      memories_count: 0,
      llm_interactions_count: 0
    )
    |> stream(:signals, [], reset: true)
    |> stream(:thinking, [], reset: true)
    |> stream(:memories, [], reset: true)
    |> stream(:actions, [], reset: true)
    |> stream(:llm_interactions, [], reset: true)
    # Seed the approvals stream from Consensus so any pending approvals that
    # arrived before this LiveView connected (or that signal-bridge dropped
    # under backpressure) are visible immediately. Signals continue to deliver
    # low-latency updates; this is the polling fallback.
    |> then(fn s ->
      pending = fetch_pending_approvals(agent_id)

      s
      |> assign(:approvals_count, length(pending))
      |> stream(:approvals, pending, reset: true)
    end)
  end

  # Poll Consensus for pending approvals targeting this agent. Used as a
  # defense-in-depth fallback alongside the security.authorization_pending
  # signal subscription, which is lossy by design (subscribe_raw silently
  # drops signals when the LiveView mailbox queue is over the bridge limit,
  # and signals can also race with mount/reconnect timing).
  defp fetch_pending_approvals(nil), do: []

  defp fetch_pending_approvals(agent_id) do
    case safe_consensus_pending() do
      [] ->
        []

      proposals ->
        proposals
        |> Enum.filter(fn p -> Map.get(p, :proposer) == agent_id end)
        |> Enum.map(&proposal_to_approval/1)
    end
  end

  defp safe_consensus_pending do
    Arbor.Consensus.list_pending()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp proposal_to_approval(proposal) do
    %{
      id: proposal.id,
      proposer: proposal.proposer,
      metadata: Map.get(proposal, :metadata, %{}),
      created_at: proposal.created_at
    }
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
    usage =
      case response do
        %{usage: u} when is_map(u) and map_size(u) > 0 -> u
        _ -> response[:usage] || %{}
      end

    input =
      usage[:input_tokens] || usage["input_tokens"] || usage[:prompt_tokens] ||
        usage["prompt_tokens"] || 0

    output =
      usage[:output_tokens] || usage["output_tokens"] || usage[:completion_tokens] ||
        usage["completion_tokens"] || 0

    cached =
      usage[:cache_read_tokens] || usage["cache_read_tokens"] ||
        usage[:cache_read_input_tokens] || usage["cache_read_input_tokens"] || 0

    cost = usage[:cost] || usage["cost"]

    if input > 0 or output > 0 do
      new_input = (socket.assigns[:input_tokens] || 0) + input
      new_output = (socket.assigns[:output_tokens] || 0) + output
      new_cached = (socket.assigns[:cached_tokens] || 0) + cached
      new_count = (socket.assigns[:llm_call_count] || 0) + 1

      cost_assigns =
        if cost do
          prev_cost = socket.assigns[:total_cost] || 0.0
          [total_cost: prev_cost + cost]
        else
          []
        end

      assign(
        socket,
        [
          input_tokens: new_input,
          output_tokens: new_output,
          cached_tokens: new_cached,
          total_tokens: new_input + new_output,
          llm_call_count: new_count
        ] ++ cost_assigns
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

        sock
        |> stream_insert(:memories, entry)
        |> update(:memories_count, &(&1 + 1))
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

  defp apply_token_usage(socket, _agent_id, input, output, cached) do
    new_input = (socket.assigns[:input_tokens] || 0) + input
    new_output = (socket.assigns[:output_tokens] || 0) + output
    new_cached = (socket.assigns[:cached_tokens] || 0) + cached
    new_count = (socket.assigns[:llm_call_count] || 0) + 1

    assign(socket,
      input_tokens: new_input,
      output_tokens: new_output,
      cached_tokens: new_cached,
      llm_call_count: new_count
    )
  end

  # ── Approval Helpers ──────────────────────────────────────────────

  defp safe_consensus_approve(proposal_id, actor_id) do
    coordinator = Arbor.Consensus.Coordinator

    if Code.ensure_loaded?(coordinator) and function_exported?(coordinator, :force_approve, 2) do
      apply(coordinator, :force_approve, [proposal_id, actor_id])
    else
      {:error, :consensus_unavailable}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp safe_consensus_reject(proposal_id, actor_id) do
    coordinator = Arbor.Consensus.Coordinator

    if Code.ensure_loaded?(coordinator) and function_exported?(coordinator, :force_reject, 2) do
      apply(coordinator, :force_reject, [proposal_id, actor_id])
    else
      {:error, :consensus_unavailable}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  # ── SessionStore Helpers ─────────────────────────────────────────

  defp load_session_history(session_id, opts) do
    store = Arbor.Persistence.SessionStore

    if Code.ensure_loaded?(store) and function_exported?(store, :load_recent_for_display, 2) do
      apply(store, :load_recent_for_display, [session_id, opts])
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp session_message_count(session_id) do
    store = Arbor.Persistence.SessionStore

    if Code.ensure_loaded?(store) and function_exported?(store, :message_count_by_session_id, 1) do
      apply(store, :message_count_by_session_id, [session_id])
    else
      0
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp persist_group_message(group_id, msg) do
    store = Arbor.Persistence.SessionStore

    if Code.ensure_loaded?(store) and function_exported?(store, :available?, 0) and
         apply(store, :available?, []) do
      session_id = "group-session-#{group_id}"

      session_uuid =
        case apply(store, :get_session, [session_id]) do
          {:ok, s} ->
            s.id

          {:error, :not_found} ->
            case apply(store, :create_session, [group_id, [session_id: session_id]]) do
              {:ok, s} -> s.id
              _ -> nil
            end
        end

      if session_uuid do
        role = if msg[:role] in [:user, "user"], do: "user", else: "assistant"
        content_text = if is_binary(msg[:content]), do: msg[:content], else: inspect(msg[:content])

        apply(store, :append_entry, [
          session_uuid,
          %{
            entry_type: role,
            role: role,
            content: [%{"type" => "text", "text" => content_text}],
            timestamp: msg[:timestamp] || DateTime.utc_now()
          }
        ])
      end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp get_telemetry_tokens(agent_id) do
    store = Arbor.Common.AgentTelemetry.Store

    if Code.ensure_loaded?(store) do
      case apply(store, :get, [agent_id]) do
        nil ->
          %{input: 0, output: 0, cached: 0, count: 0, last_duration: nil}

        t ->
          %{
            input: t.session_input_tokens,
            output: t.session_output_tokens,
            cached: t.session_cached_tokens,
            count: t.turn_count,
            last_duration: List.first(t.llm_latencies || [])
          }
      end
    else
      %{input: 0, output: 0, cached: 0, count: 0, last_duration: nil}
    end
  rescue
    _ -> %{input: 0, output: 0, cached: 0, count: 0, last_duration: nil}
  end
end
