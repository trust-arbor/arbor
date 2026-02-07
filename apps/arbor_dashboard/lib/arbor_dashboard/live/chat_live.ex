defmodule Arbor.Dashboard.Live.ChatLive do
  @moduledoc """
  Agent chat interface.

  Interactive conversation with Arbor agents, displaying thinking blocks,
  recalled memories, signal emissions, and response streaming.
  """

  use Phoenix.LiveView

  import Arbor.Web.Components

  alias Arbor.Agent.Claude
  alias Arbor.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    subscription_id =
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
        subscription_id: subscription_id,
        # Panel visibility toggles
        show_thinking: true,
        show_memories: true,
        show_actions: true,
        show_thoughts: true,
        # Memory state
        memory_stats: nil,
        # Working memory thoughts
        working_thoughts: [],
        # Token tracking (when available)
        total_tokens: 0,
        query_count: 0
      )
      |> stream(:messages, [])
      |> stream(:signals, [])
      |> stream(:thinking, [])
      |> stream(:memories, [])
      |> stream(:actions, [])

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
  def handle_event("start-agent", %{"model" => model}, socket) do
    model_atom = String.to_existing_atom(model)
    agent_id = "chat-#{System.unique_integer([:positive])}"

    case Claude.start_link(id: agent_id, model: model_atom, capture_thinking: true) do
      {:ok, agent} ->
        # Get initial memory stats
        memory_stats = get_memory_stats(agent)

        socket =
          socket
          |> assign(agent: agent, agent_id: agent_id, error: nil, memory_stats: memory_stats)
          |> assign(query_count: 0, working_thoughts: [])
          |> stream(:messages, [], reset: true)
          |> stream(:signals, [], reset: true)
          |> stream(:thinking, [], reset: true)
          |> stream(:memories, [], reset: true)
          |> stream(:actions, [], reset: true)

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

    {:noreply, assign(socket, agent: nil, agent_id: nil, session_id: nil, memory_stats: nil)}
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

  @impl true
  def handle_info({:query, agent, prompt}, socket) do
    case Claude.query(agent, prompt, timeout: 180_000) do
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
        event: signal.event,
        timestamp: signal.timestamp,
        metadata: signal.metadata
      }

      socket = stream_insert(socket, :signals, signal_entry)

      # Also process action signals
      socket = maybe_add_action(socket, signal)

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

    <%!-- Stats bar when agent is active --%>
    <div
      :if={@agent}
      style="display: flex; gap: 0.5rem; flex-wrap: wrap; padding: 0.5rem 1rem; margin-top: 0.5rem; border: 1px solid var(--aw-border, #333); border-radius: 8px;"
    >
      <.badge label={"Agent: #{@agent_id}"} color={:green} />
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
    </div>

    <%!-- 3-column layout: left (signals+actions) | center (chat) | right (thinking+memory) --%>
    <div style="display: grid; grid-template-columns: 280px 1fr 320px; gap: 1rem; margin-top: 0.75rem; height: calc(100vh - 200px);">
      <%!-- LEFT PANEL: Signals + Actions --%>
      <div style="display: flex; flex-direction: column; gap: 0.75rem; overflow-y: auto;">
        <%!-- Signal Stream --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 8px; overflow: hidden; flex: 1; min-height: 200px;">
          <div style="padding: 0.75rem 1rem; border-bottom: 1px solid var(--aw-border, #333); display: flex; justify-content: space-between; align-items: center;">
            <strong>📡 Signal Stream</strong>
            <span style="color: #22c55e; font-size: 0.75em;">● LIVE</span>
          </div>
          <div
            id="signals-container"
            phx-update="stream"
            style="max-height: 300px; overflow-y: auto; padding: 0.5rem;"
          >
            <div
              :for={{dom_id, sig} <- @streams.signals}
              id={dom_id}
              style="margin-bottom: 0.5rem; padding: 0.5rem; border-radius: 4px; background: rgba(74, 255, 158, 0.1); font-size: 0.85em;"
            >
              <div style="display: flex; align-items: center; gap: 0.25rem;">
                <span style="font-size: 1em;">{signal_icon(sig.category)}</span>
                <span style="font-weight: 500; flex: 1;">{sig.event}</span>
                <span style="color: var(--aw-text-muted, #888); font-size: 0.8em;">
                  {format_time(sig.timestamp)}
                </span>
              </div>
            </div>
          </div>
          <div style="padding: 0.5rem; text-align: center;">
            <.empty_state
              :if={stream_empty?(@streams.signals)}
              icon="📡"
              title="Waiting for signals..."
              hint=""
            />
          </div>
        </div>

        <%!-- Recent Actions --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 8px; overflow: hidden;">
          <div
            phx-click="toggle-actions"
            style="padding: 0.75rem 1rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
          >
            <strong>⚡ Recent Actions</strong>
            <span style="color: var(--aw-text-muted, #888);">
              {if @show_actions, do: "▼", else: "▶"}
            </span>
          </div>
          <div
            :if={@show_actions}
            id="actions-container"
            phx-update="stream"
            style="max-height: 200px; overflow-y: auto; padding: 0.5rem;"
          >
            <div
              :for={{dom_id, action} <- @streams.actions}
              id={dom_id}
              style={"margin-bottom: 0.5rem; padding: 0.5rem; border-radius: 4px; font-size: 0.85em; " <> action_style(action.outcome)}
            >
              <div style="display: flex; align-items: center; gap: 0.25rem;">
                <span>⚡</span>
                <span style="font-weight: 500; flex: 1;">{action.name}</span>
                <.badge label={to_string(action.outcome)} color={outcome_color(action.outcome)} />
              </div>
            </div>
          </div>
          <div :if={@show_actions} style="padding: 0.5rem; text-align: center;">
            <.empty_state
              :if={stream_empty?(@streams.actions)}
              icon="⚡"
              title="No actions yet..."
              hint=""
            />
          </div>
        </div>
      </div>

      <%!-- CENTER: Chat Panel --%>
      <div style="display: flex; flex-direction: column; border: 1px solid var(--aw-border, #333); border-radius: 8px; overflow: hidden;">
        <%!-- Agent controls --%>
        <div style="padding: 0.75rem 1rem; border-bottom: 1px solid var(--aw-border, #333); display: flex; align-items: center; gap: 1rem;">
          <div :if={@agent == nil}>
            <form phx-submit="start-agent" style="display: flex; gap: 0.5rem;">
              <select
                name="model"
                style="padding: 0.5rem; border-radius: 4px; background: var(--aw-bg, #1a1a1a); border: 1px solid var(--aw-border, #333); color: inherit;"
              >
                <option value="haiku">Haiku (fast)</option>
                <option value="sonnet">Sonnet (balanced)</option>
                <option value="opus">Opus (powerful)</option>
              </select>
              <button
                type="submit"
                style="padding: 0.5rem 1rem; background: var(--aw-accent, #4a9eff); border: none; border-radius: 4px; color: white; cursor: pointer;"
              >
                Start Agent
              </button>
            </form>
          </div>
          <div
            :if={@agent != nil}
            style="display: flex; align-items: center; gap: 0.5rem; width: 100%;"
          >
            <span style="color: var(--aw-text-muted, #888);">Chat with Claude</span>
            <div style="flex: 1;"></div>
            <button
              phx-click="stop-agent"
              style="padding: 0.5rem 1rem; background: var(--aw-error, #ff4a4a); border: none; border-radius: 4px; color: white; cursor: pointer;"
            >
              Stop Agent
            </button>
          </div>
        </div>

        <%!-- Messages --%>
        <div
          id="messages-container"
          phx-update="stream"
          style="flex: 1; overflow-y: auto; padding: 1rem;"
        >
          <div
            :for={{dom_id, msg} <- @streams.messages}
            id={dom_id}
            style={"margin-bottom: 1rem; padding: 0.75rem; border-radius: 8px; " <> message_style(msg.role)}
          >
            <div style="display: flex; justify-content: space-between; margin-bottom: 0.25rem;">
              <strong>{role_label(msg.role)}</strong>
              <span style="color: var(--aw-text-muted, #888); font-size: 0.85em;">
                {format_time(msg.timestamp)}
              </span>
            </div>
            <div style="white-space: pre-wrap;">{msg.content}</div>
            <div
              :if={msg[:model] || msg[:memory_count]}
              style="margin-top: 0.5rem; display: flex; gap: 0.5rem;"
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
        <div :if={@loading} style="padding: 1rem; border-top: 1px solid var(--aw-border, #333);">
          <span style="color: var(--aw-text-muted, #888);">🤔 Thinking...</span>
        </div>

        <%!-- Error display --%>
        <div
          :if={@error}
          style="padding: 0.75rem 1rem; background: rgba(255, 74, 74, 0.1); color: var(--aw-error, #ff4a4a); border-top: 1px solid var(--aw-error, #ff4a4a);"
        >
          {@error}
        </div>

        <%!-- Input area --%>
        <form
          phx-submit="send-message"
          phx-change="update-input"
          style="padding: 0.75rem 1rem; border-top: 1px solid var(--aw-border, #333); display: flex; gap: 0.5rem;"
        >
          <input
            type="text"
            name="message"
            value={@input}
            placeholder={if @agent, do: "Type a message...", else: "Start an agent first"}
            disabled={@agent == nil or @loading}
            style="flex: 1; padding: 0.5rem 0.75rem; border-radius: 4px; background: var(--aw-bg, #1a1a1a); border: 1px solid var(--aw-border, #333); color: inherit;"
            autocomplete="off"
          />
          <button
            type="submit"
            disabled={@agent == nil or @loading or @input == ""}
            style={"padding: 0.5rem 1rem; border: none; border-radius: 4px; color: white; cursor: " <> if(@agent && !@loading, do: "pointer", else: "not-allowed") <> "; background: " <> if(@agent && !@loading, do: "var(--aw-accent, #4a9eff)", else: "var(--aw-text-muted, #888)") <> ";"}
          >
            Send
          </button>
        </form>
      </div>

      <%!-- RIGHT PANEL: Thinking + Memory --%>
      <div style="display: flex; flex-direction: column; gap: 0.75rem; overflow-y: auto;">
        <%!-- Working Thoughts panel --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 8px; overflow: hidden;">
          <div
            phx-click="toggle-thoughts"
            style="padding: 0.75rem 1rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
          >
            <strong>💭 Recent Thinking</strong>
            <span style="color: var(--aw-text-muted, #888);">
              {if @show_thoughts, do: "▼", else: "▶"}
            </span>
          </div>
          <div :if={@show_thoughts} style="max-height: 180px; overflow-y: auto; padding: 0.5rem;">
            <div
              :for={thought <- @working_thoughts}
              style="margin-bottom: 0.5rem; padding: 0.5rem; border-radius: 4px; background: rgba(255, 165, 0, 0.1); font-size: 0.85em;"
            >
              <span>💭</span>
              <span style="color: var(--aw-text-muted, #888); white-space: pre-wrap;">
                {Helpers.truncate(thought.content, 120)}
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

        <%!-- Extended Thinking blocks --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 8px; overflow: hidden;">
          <div
            phx-click="toggle-thinking"
            style="padding: 0.75rem 1rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
          >
            <strong>🧠 Extended Thinking</strong>
            <span style="color: var(--aw-text-muted, #888);">
              {if @show_thinking, do: "▼", else: "▶"}
            </span>
          </div>
          <div
            :if={@show_thinking}
            id="thinking-container"
            phx-update="stream"
            style="max-height: 200px; overflow-y: auto; padding: 0.5rem;"
          >
            <div
              :for={{dom_id, block} <- @streams.thinking}
              id={dom_id}
              style="margin-bottom: 0.5rem; padding: 0.5rem; border-radius: 4px; background: rgba(74, 158, 255, 0.1); font-size: 0.85em;"
            >
              <div style="display: flex; justify-content: space-between; margin-bottom: 0.25rem;">
                <.badge :if={block.has_signature} label="signed" color={:blue} />
                <span style="color: var(--aw-text-muted, #888); font-size: 0.85em;">
                  {format_time(block.timestamp)}
                </span>
              </div>
              <p style="color: var(--aw-text-muted, #888); white-space: pre-wrap; margin: 0;">
                {Helpers.truncate(block.text, 150)}
              </p>
            </div>
          </div>
          <div :if={@show_thinking} style="padding: 0.5rem; text-align: center;">
            <.empty_state
              :if={stream_empty?(@streams.thinking)}
              icon="🧠"
              title="No thinking yet"
              hint="Thinking blocks appear after queries"
            />
          </div>
        </div>

        <%!-- Recalled Memories --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 8px; overflow: hidden; flex: 1; min-height: 150px;">
          <div
            phx-click="toggle-memories"
            style="padding: 0.75rem 1rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
          >
            <strong>📝 Memory Notes</strong>
            <span style="color: var(--aw-text-muted, #888);">
              {if @show_memories, do: "▼", else: "▶"}
            </span>
          </div>
          <div
            :if={@show_memories}
            id="memories-container"
            phx-update="stream"
            style="max-height: 200px; overflow-y: auto; padding: 0.5rem;"
          >
            <div
              :for={{dom_id, memory} <- @streams.memories}
              id={dom_id}
              style="margin-bottom: 0.5rem; padding: 0.5rem; border-radius: 4px; background: rgba(138, 43, 226, 0.1); font-size: 0.85em;"
            >
              <div style="display: flex; align-items: center; gap: 0.25rem; margin-bottom: 0.25rem;">
                <span>📝</span>
                <.badge
                  :if={memory.score}
                  label={"score: #{Float.round(memory.score, 2)}"}
                  color={:purple}
                />
              </div>
              <p style="color: var(--aw-text-muted, #888); white-space: pre-wrap; margin: 0;">
                {Helpers.truncate(memory.content, 150)}
              </p>
            </div>
          </div>
          <div :if={@show_memories} style="padding: 0.5rem; text-align: center;">
            <.empty_state
              :if={stream_empty?(@streams.memories)}
              icon="📝"
              title="No memories recalled"
              hint="Relevant memories appear here"
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
    event = to_string(signal.event)

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
      _ -> to_string(signal.event)
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
end
