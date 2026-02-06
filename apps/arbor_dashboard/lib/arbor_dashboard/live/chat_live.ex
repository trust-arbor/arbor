defmodule Arbor.Dashboard.Live.ChatLive do
  @moduledoc """
  Agent chat interface.

  Interactive conversation with Arbor agents, displaying thinking blocks,
  signal emissions, and response streaming.
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
        show_thinking: true
      )
      |> stream(:messages, [])
      |> stream(:signals, [])
      |> stream(:thinking, [])

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
        socket =
          socket
          |> assign(agent: agent, agent_id: agent_id, error: nil)
          |> stream(:messages, [], reset: true)
          |> stream(:signals, [], reset: true)
          |> stream(:thinking, [], reset: true)

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

    {:noreply, assign(socket, agent: nil, agent_id: nil, session_id: nil)}
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

  @impl true
  def handle_info({:query, agent, prompt}, socket) do
    case Claude.query(agent, prompt, timeout: 180_000) do
      {:ok, response} ->
        # Add assistant message
        assistant_msg = %{
          id: "msg-#{System.unique_integer([:positive])}",
          role: :assistant,
          content: response.text,
          timestamp: DateTime.utc_now(),
          model: response.model,
          session_id: response.session_id
        }

        # Add thinking blocks if present
        thinking_blocks =
          case response.thinking do
            nil -> []
            [] -> []
            blocks -> blocks
          end

        socket =
          socket
          |> stream_insert(:messages, assistant_msg)
          |> assign(loading: false, session_id: response.session_id)

        socket =
          Enum.reduce(thinking_blocks, socket, fn block, acc ->
            thinking_entry = %{
              id: "think-#{System.unique_integer([:positive])}",
              text: block.text || "",
              has_signature: block.signature != nil,
              timestamp: DateTime.utc_now()
            }

            stream_insert(acc, :thinking, thinking_entry)
          end)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           loading: false,
           error: "Query failed: #{inspect(reason)}"
         )}
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

      {:noreply, stream_insert(socket, :signals, signal_entry)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="Agent Chat" subtitle="Interactive conversation with Claude" />

    <div style="display: grid; grid-template-columns: 1fr 300px; gap: 1rem; margin-top: 1rem; height: calc(100vh - 180px);">
      <%!-- Main chat area --%>
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
          <div :if={@agent != nil} style="display: flex; align-items: center; gap: 1rem; width: 100%;">
            <.badge label={"Agent: #{@agent_id}"} color={:green} />
            <.badge
              :if={@session_id}
              label={"Session: #{String.slice(@session_id || "", 0..7)}..."}
              color={:blue}
            />
            <div style="flex: 1;"></div>
            <button
              phx-click="stop-agent"
              style="padding: 0.5rem 1rem; background: var(--aw-error, #ff4a4a); border: none; border-radius: 4px; color: white; cursor: pointer;"
            >
              Stop
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
            <div :if={msg[:model]} style="margin-top: 0.25rem;">
              <.badge label={to_string(msg.model)} color={:gray} />
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

      <%!-- Side panel --%>
      <div style="display: flex; flex-direction: column; gap: 1rem; overflow-y: auto;">
        <%!-- Thinking blocks --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 8px; overflow: hidden;">
          <div
            phx-click="toggle-thinking"
            style="padding: 0.75rem 1rem; border-bottom: 1px solid var(--aw-border, #333); cursor: pointer; display: flex; justify-content: space-between; align-items: center;"
          >
            <strong>🧠 Thinking</strong>
            <span style="color: var(--aw-text-muted, #888);">
              {if @show_thinking, do: "▼", else: "▶"}
            </span>
          </div>
          <div
            :if={@show_thinking}
            id="thinking-container"
            phx-update="stream"
            style="max-height: 250px; overflow-y: auto; padding: 0.5rem;"
          >
            <div
              :for={{dom_id, block} <- @streams.thinking}
              id={dom_id}
              style="margin-bottom: 0.5rem; padding: 0.5rem; border-radius: 4px; background: rgba(138, 43, 226, 0.1); font-size: 0.85em;"
            >
              <div style="display: flex; justify-content: space-between; margin-bottom: 0.25rem;">
                <.badge :if={block.has_signature} label="signed" color={:purple} />
                <span style="color: var(--aw-text-muted, #888); font-size: 0.85em;">
                  {format_time(block.timestamp)}
                </span>
              </div>
              <p style="color: var(--aw-text-muted, #888); white-space: pre-wrap; margin: 0;">
                {Helpers.truncate(block.text, 200)}
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

        <%!-- Signals --%>
        <div style="border: 1px solid var(--aw-border, #333); border-radius: 8px; overflow: hidden; flex: 1;">
          <div style="padding: 0.75rem 1rem; border-bottom: 1px solid var(--aw-border, #333);">
            <strong>📡 Signals</strong>
          </div>
          <div
            id="signals-container"
            phx-update="stream"
            style="max-height: 300px; overflow-y: auto; padding: 0.5rem;"
          >
            <div
              :for={{dom_id, sig} <- @streams.signals}
              id={dom_id}
              style="margin-bottom: 0.5rem; padding: 0.5rem; border-radius: 4px; background: rgba(74, 158, 255, 0.1); font-size: 0.85em;"
            >
              <div style="display: flex; align-items: center; gap: 0.25rem;">
                <.badge label={to_string(sig.category)} color={:blue} />
                <span style="font-weight: 500;">{sig.event}</span>
              </div>
              <div style="color: var(--aw-text-muted, #888); font-size: 0.85em; margin-top: 0.25rem;">
                {format_time(sig.timestamp)}
              </div>
            </div>
          </div>
          <div style="padding: 0.5rem; text-align: center;">
            <.empty_state
              :if={stream_empty?(@streams.signals)}
              icon="📡"
              title="No signals"
              hint="Agent signals appear here"
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
    case signal.metadata do
      %{agent_id: ^agent_id} -> true
      %{"agent_id" => ^agent_id} -> true
      _ -> false
    end
  end

  defp stream_empty?(%Phoenix.LiveView.LiveStream{inserts: []}), do: true
  defp stream_empty?(_), do: false

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
