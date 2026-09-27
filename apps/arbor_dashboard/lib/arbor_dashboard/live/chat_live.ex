defmodule Arbor.Dashboard.Live.ChatLive do
  @moduledoc """
  Agent chat interface.

  Authenticated private conversations with Arbor agents, displaying durable
  transcript entries and command delivery state through the public Agent API.
  """

  use Phoenix.LiveView

  import Arbor.Web.Components
  import Arbor.Dashboard.Live.ChatLive.Components

  alias Arbor.Common.CommandIntake
  alias Arbor.Contracts.Commands.{Context, Result}
  alias Arbor.Dashboard.ChatState
  alias Arbor.Dashboard.Live.ChatLive.{Conversation, GroupChat}

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
        agent_host_pid: nil,
        agent_supervisor_pid: nil,
        agent_id: nil,
        display_name: nil,
        session_id: nil,
        input: "",
        loading: false,
        error: nil,
        available_models: available_models,
        current_model: nil,
        chat_runtime: nil,
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
        approvals_count: 0,
        known_approval_ids: MapSet.new(),
        # Phase 2c — runtime is :arbor by default; updated when the user
        # runs /runtime acp or /model X runtime=acp. Session-level
        # propagation is the scheduled follow-up at line ~1350.
        runtime: :arbor
      )
      |> assign(GroupChat.init_assigns())
      |> stream(:messages, [])
      |> stream(:signals, [])
      |> stream(:thinking, [])
      |> stream(:memories, [])
      |> stream(:actions, [])
      |> stream(:llm_interactions, [])
      |> stream(:approvals, [])
      |> Conversation.mount()

    # Reconnect to existing agent if one is running
    socket =
      case existing_agent do
        {:ok, agent_id, pid, metadata} ->
          reconnect_to_agent(socket, agent_id, pid, metadata)

        :not_found ->
          socket
      end

    # Private updates only come from authenticated conversation reads.
    if connected?(socket) do
      :timer.send_interval(1_000, :refresh_conversation)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"agent_id" => agent_id}, _uri, socket) do
    # Skip if we're already connected to this agent.
    #
    # NOTE: previously this read `socket.assigns.agent`, which was a host
    # PID — comparing it to the agent_id string from URL params always
    # returned false. The "skip if same" optimization was silently broken.
    # Discovered 2026-04-09 during the assign rename. Now reads :agent_id
    # (the stable identity string).
    if socket.assigns[:agent_id] == agent_id do
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
  def handle_event("stop-agent", _params, socket) do
    {:noreply,
     assign(socket,
       error:
         "Stop the agent from the Agents dashboard; private chat does not grant lifecycle authority."
     )}
  end

  def handle_event("update-input", %{"message" => value}, socket) do
    {:noreply, assign(socket, input: value)}
  end

  def handle_event("update-input", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("send-message", params, socket) do
    input = String.trim(Map.get(params, "message", socket.assigns.input))
    socket = assign(socket, input: input)

    cond do
      input == "" ->
        {:noreply, socket}

      socket.assigns.group_mode ->
        {:noreply,
         assign(socket,
           error:
             "Group chat is unavailable in this private conversation. Use the Channels dashboard."
         )}

      # Single-agent mode (existing flow)
      socket.assigns.agent_id != nil ->
        # Local /help is available during a pending turn. Other slash commands
        # report that their authenticated operation contract is unavailable.
        case CommandIntake.classify(input) do
          {:command, _, _} ->
            handle_slash_command(input, socket)

          {:prompt, _} ->
            {:noreply, Conversation.submit(socket, input, params["command_id"])}
        end

      # Local /help works without an attached agent. Runtime commands remain
      # unavailable, and prompts explain how to attach before sending.
      true ->
        case CommandIntake.classify(input) do
          {:command, _, _} ->
            handle_slash_command(input, socket)

          {:prompt, _} ->
            socket =
              socket
              |> stream_insert_command_error(
                "No agent connected. Type /help to see available commands, or start an agent first."
              )
              |> assign(input: "")

            {:noreply, socket}
        end
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
    {:noreply,
     assign(socket, show_completed_goals: !socket.assigns.show_completed_goals, agent_goals: [])}
  end

  def handle_event("toggle-llm-panel", _params, socket) do
    {:noreply, assign(socket, show_llm_panel: !socket.assigns.show_llm_panel)}
  end

  def handle_event("load-more-messages", _params, socket) do
    {:noreply,
     socket
     |> Conversation.refresh()
     |> push_event("messages-loaded", %{count: 0})}
  end

  def handle_event("conversation:restore", params, socket) do
    {:noreply, Conversation.restore(socket, params)}
  end

  def handle_event("conversation:reconnect", _params, socket) do
    {:noreply, Conversation.reconnect(socket)}
  end

  def handle_event("conversation:retry", _params, socket) do
    {:noreply, Conversation.retry(socket)}
  end

  def handle_event("conversation:new-message", _params, socket) do
    {:noreply, Conversation.dismiss(socket)}
  end

  def handle_event(event, _params, socket)
      when event in [
             "approve-tool",
             "always-allow-tool",
             "deny-tool",
             "approve-interaction",
             "reject-interaction"
           ] do
    {:noreply,
     assign(socket,
       error:
         "Approvals are unavailable in this private conversation; use an authorized approval channel."
     )}
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

  def handle_event(event, _params, socket)
      when event in [
             "show-group-modal",
             "show-join-groups",
             "join-group",
             "toggle-group-agent",
             "update-group-name",
             "confirm-create-group",
             "cancel-group-modal",
             "leave-group"
           ] do
    {:noreply,
     assign(socket,
       error:
         "Group chat is unavailable in this private conversation. Use the Channels dashboard."
     )}
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  @impl true
  # Legacy agent-wide response and signal payloads are not private-conversation
  # authority. Only authenticated transcript/journal reads may populate chat.
  def handle_info({:query_result, _runtime, _result}, socket), do: {:noreply, socket}

  def handle_info(:refresh_conversation, socket) do
    {:noreply, Conversation.refresh(socket)}
  end

  # These channels do not carry a freshly authenticated private conversation
  # scope. They cannot publish content or grant/answer approvals in this view.
  def handle_info({:signal_received, _signal}, socket), do: {:noreply, socket}
  def handle_info({:dashboard_interaction, _interaction}, socket), do: {:noreply, socket}
  def handle_info(:refresh_approvals, socket), do: {:noreply, socket}

  # Process monitor: agent supervisor crashed or was killed
  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    if pid == socket.assigns[:agent_supervisor_pid] or pid == socket.assigns[:agent_host_pid] do
      {:noreply, assign(socket, agent_host_pid: nil, agent_supervisor_pid: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header
      title="Agent Chat"
      subtitle="Private conversation with durable delivery status"
    />

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

  # ── Slash Command Intake (added 2026-04-09 — see slash-commands.md v2) ─

  # Only local /help reaches CommandIntake; runtime commands require their own
  # authenticated operation contracts before this chat can execute them.
  defp handle_slash_command(input, socket) do
    if List.first(String.split(input)) == "/help" do
      run_local_help(input, socket)
    else
      {:noreply,
       assign(socket,
         error:
           "This chat cannot authorize runtime slash commands yet. Use the agent controls; /help remains available."
       )}
    end
  end

  defp run_local_help(input, socket) do
    context = Context.new(origin: :dashboard, user_id: socket.assigns[:current_agent_id])

    case CommandIntake.handle(input, context, fn _ -> {:error, :unexpected_prompt} end) do
      {:command_result, %Result{} = result} ->
        {:noreply,
         socket |> stream_insert_command_result(result) |> assign(input: "", error: nil)}

      _ ->
        {:noreply, assign(socket, error: "Help is temporarily unavailable.")}
    end
  end

  defp stream_insert_command_result(socket, %Result{text: text}) do
    msg = %{
      id: "msg-#{System.unique_integer([:positive])}",
      role: :assistant,
      content: text,
      timestamp: DateTime.utc_now()
    }

    stream_insert(socket, :messages, msg)
  end

  defp stream_insert_command_error(socket, message) do
    msg = %{
      id: "msg-#{System.unique_integer([:positive])}",
      role: :assistant,
      content: "⚠️  " <> message,
      timestamp: DateTime.utc_now()
    }

    stream_insert(socket, :messages, msg)
  end

  # ── Agent Lifecycle Helpers ──────────────────────────────────────────

  # Find agent scoped to current user's tenant context when available.
  # An anonymous browser never selects a global agent.
  defp find_agent_for_session(socket) do
    case Map.get(socket.assigns, :current_agent_id) do
      nil -> :not_found
      principal_id -> Arbor.Agent.find_agent_for_principal(principal_id)
    end
  end

  # A chat capability authorizes conversation, not starting or resuming agents.
  # Resolve private history first; never turn a URL parameter into lifecycle work.
  defp connect_or_resume_agent(socket, agent_id) do
    socket = socket |> assign(agent_id: agent_id) |> Conversation.connect()

    if socket.assigns.conversation_authorized do
      attach_running_agent(socket, agent_id)
    else
      socket
    end
  end

  # A durable transcript remains readable while the runtime or its registry is
  # down. Optional live metadata must never discard an authorized history page.
  defp attach_running_agent(socket, agent_id) do
    case Arbor.Agent.lookup(agent_id) do
      {:ok, %{pid: pid, metadata: metadata}} when is_pid(pid) ->
        metadata = metadata || %{}
        Process.monitor(pid)

        assign(socket,
          agent_host_pid: metadata[:host_pid] || pid,
          agent_supervisor_pid: pid,
          display_name: metadata[:display_name],
          current_model: metadata[:model_config] || %{},
          chat_runtime: metadata[:runtime] || :arbor
        )

      _ ->
        assign(socket, error: "The agent is not running. Start it from the Agents dashboard.")
    end
  rescue
    _ ->
      assign(socket,
        error: "The agent runtime is unavailable. Saved conversation history remains readable."
      )
  catch
    :exit, _ ->
      assign(socket,
        error: "The agent runtime is unavailable. Saved conversation history remains readable."
      )
  end

  defp reconnect_to_agent(socket, agent_id, pid, metadata) do
    Process.monitor(pid)
    metadata = metadata || %{}
    ChatState.touch_agent(agent_id)

    socket
    |> assign(
      agent_id: agent_id,
      agent_host_pid: metadata[:host_pid] || pid,
      agent_supervisor_pid: pid,
      display_name: metadata[:display_name],
      current_model: metadata[:model_config] || %{},
      chat_runtime: metadata[:runtime] || :arbor,
      error: nil
    )
    |> Conversation.connect()
  end

  # ── Model Config Helpers ─────────────────────────────────────────────

  # `default_models/0` and `:available_models` are kept as assigns even
  # though Phase 2c removed the model dropdown — they're still consumed
  # by chat_controls/1 for the heartbeat-model selector and by other
  # callers (currently none, but the assigns are forward-compat for
  # operator dashboards that read what's configured).

  defp default_models do
    [
      %{id: "haiku", label: "Haiku (fast)", provider: :anthropic, runtime: :acp},
      %{id: "sonnet", label: "Sonnet (balanced)", provider: :anthropic, runtime: :acp},
      %{id: "opus", label: "Opus (powerful)", provider: :anthropic, runtime: :acp}
    ]
  end
end
