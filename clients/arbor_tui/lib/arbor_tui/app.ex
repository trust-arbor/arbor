defmodule ArborTui.App do
  @moduledoc """
  The TermUI (Elm Architecture) root component for the Arbor chat client.

  Single-column coding-agent-TUI layout: a header (agent identity + connection),
  a scrolling transcript, a status line (turn state), and an input line. The
  Arbor distinctive is that proactive `💭` notifications from the agent's
  heartbeat interleave into the same transcript, visually distinct — the
  continuous mind made visible.

  State flow:
    * `init/1` spawns the `ArborTui.WSClient` (which connects + attaches) and
      keeps its pid for outbound commands.
    * `event_to_msg/2` turns key events into messages (input is managed in-model
      for full control — no stateful widget).
    * `update/2` folds key messages, `{:ws_status, ...}`, and
      `{:server_event, event}` (pushed by the WS client) into the model.
    * `view/1` renders the model.
  """

  use TermUI.Elm

  require Logger

  alias ArborTui.WSClient
  alias TermUI.{Command, Event}
  # NOTE: the renderer + view helpers use TermUI.Renderer.Style, NOT TermUI.Style
  # — they are distinct structs and the renderer pattern-matches the former, so a
  # TermUI.Style here crashes create_cell/2 at render time (not at compile time).
  alias TermUI.Renderer.Style

  # ── init ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    identity = Keyword.fetch!(opts, :identity)
    target_agent_id = Keyword.fetch!(opts, :target_agent_id)
    runtime_name = Keyword.fetch!(opts, :runtime_name)
    gateway_url = Keyword.fetch!(opts, :gateway_url)

    ws =
      case WSClient.start_link(
             runtime: runtime_name,
             identity: identity,
             gateway_url: gateway_url,
             target_agent_id: target_agent_id
           ) do
        {:ok, pid} -> pid
        _ -> nil
      end

    %{
      ws: ws,
      identity_id: identity.agent_id,
      agent_id: target_agent_id,
      gateway_url: gateway_url,
      status: :connecting,
      status_detail: nil,
      engagement_id: nil,
      input: "",
      messages: [],
      streaming: nil,
      turn: :idle,
      # HITL: tool calls awaiting the user's decision (FIFO; head is prompted),
      # and tools the user chose to always-allow this session.
      pending_approvals: [],
      auto_approve: MapSet.new()
    }
  end

  # ── event → msg ────────────────────────────────────────────────────────────

  @impl true
  # Ctrl+C always quits, even mid-approval. (`in` over a variable isn't allowed
  # in a guard, so the ctrl check is in the body.)
  def event_to_msg(%Event.Key{key: :c, modifiers: mods}, state) do
    cond do
      :ctrl in mods -> {:msg, :quit}
      match?(%{pending_approvals: [_ | _]}, state) -> :ignore
      true -> {:msg, {:char, "c"}}
    end
  end

  # Approval mode: while a tool call awaits a decision, y/n/a resolve it and
  # every other key is swallowed (the prompt is modal until you choose).
  def event_to_msg(%Event.Key{char: c}, %{pending_approvals: [_ | _]}) when c in ["y", "Y"],
    do: {:msg, {:approval, :approve}}

  def event_to_msg(%Event.Key{char: c}, %{pending_approvals: [_ | _]}) when c in ["n", "N"],
    do: {:msg, {:approval, :deny}}

  def event_to_msg(%Event.Key{char: c}, %{pending_approvals: [_ | _]}) when c in ["a", "A"],
    do: {:msg, {:approval, :always}}

  def event_to_msg(%Event.Key{}, %{pending_approvals: [_ | _]}), do: :ignore

  # Normal input.
  def event_to_msg(%Event.Key{key: :enter}, _state), do: {:msg, :submit}
  def event_to_msg(%Event.Key{key: :backspace}, _state), do: {:msg, :backspace}
  def event_to_msg(%Event.Key{key: :escape}, _state), do: {:msg, :clear_input}

  def event_to_msg(%Event.Key{char: char}, _state) when is_binary(char) and char != "",
    do: {:msg, {:char, char}}

  def event_to_msg(_event, _state), do: :ignore

  # ── update ──────────────────────────────────────────────────────────────────

  @impl true
  def update(:quit, state), do: {state, [Command.quit(:normal)]}

  def update({:char, c}, state), do: {%{state | input: state.input <> c}}

  def update(:backspace, state) do
    {%{state | input: String.slice(state.input, 0..-2//1)}}
  end

  def update(:clear_input, state), do: {%{state | input: ""}}

  def update(:submit, %{input: ""} = state), do: {state}

  def update(:submit, %{input: text} = state) do
    if connected?(state), do: WSClient.send_command(state.ws, {:send, text})

    {%{
       state
       | input: "",
         streaming: nil,
         turn: :thinking,
         messages: state.messages ++ [msg(:you, text)]
     }}
  end

  # HITL: resolve the head pending approval via y/n/a.
  def update({:approval, decision}, %{pending_approvals: [current | rest]} = state) do
    proposal_id = current.proposal_id
    tool = current.tool

    {command, note, auto} =
      case decision do
        :approve ->
          {{:approve, proposal_id}, "✓ approved #{tool}", state.auto_approve}

        :deny ->
          {{:deny, proposal_id}, "✗ denied #{tool}", state.auto_approve}

        :always ->
          {{:approve, proposal_id}, "✓ approved #{tool} (always)",
           MapSet.put(state.auto_approve, tool)}
      end

    if connected?(state), do: WSClient.send_command(state.ws, command)

    {%{
       state
       | pending_approvals: rest,
         auto_approve: auto,
         messages: state.messages ++ [msg(:system, note)]
     }}
  end

  def update({:approval, _decision}, state), do: {state}

  # Connection lifecycle from the WS client.
  def update({:ws_status, status, detail}, state),
    do: {%{state | status: status, status_detail: detail}}

  # Server events forwarded by the WS client.
  def update({:server_event, event}, state), do: {handle_event(event, state)}

  def update(_msg, state), do: {state}

  # ── server events ────────────────────────────────────────────────────────

  defp handle_event({:engagement, %{id: id, transcript: transcript}}, state) do
    %{state | engagement_id: id, messages: transcript_to_messages(transcript)}
  end

  defp handle_event({:delta, text}, state) do
    %{state | streaming: (state.streaming || "") <> text, turn: :thinking}
  end

  defp handle_event({:message, message}, state) do
    role = role_atom(message["role"] || message[:role] || "assistant")
    content = message["content"] || message[:content] || ""

    %{state | streaming: nil, messages: state.messages ++ [msg(role, content)]}
  end

  defp handle_event({:notification, %{text: text}}, state) do
    %{state | messages: state.messages ++ [msg(:notification, text)]}
  end

  defp handle_event({:tool_use, tool}, state) do
    name = tool["name"] || tool[:name] || "tool"
    %{state | messages: state.messages ++ [msg(:tool, to_string(name))]}
  end

  defp handle_event({:turn_complete, _usage}, state), do: %{state | turn: :idle, streaming: nil}

  defp handle_event({:engagements, _list}, state), do: state

  # HITL: a tool call needs approval.
  defp handle_event({:approval_request, %{proposal_id: id, tool: tool} = req}, state) do
    cond do
      Enum.any?(state.pending_approvals, &(&1.proposal_id == id)) ->
        state

      MapSet.member?(state.auto_approve, tool) ->
        if connected?(state), do: WSClient.send_command(state.ws, {:approve, id})
        %{state | messages: state.messages ++ [msg(:system, "auto-approved #{tool}")]}

      true ->
        %{state | pending_approvals: state.pending_approvals ++ [req]}
    end
  end

  # Pending approvals synced on (re)attach.
  defp handle_event({:approvals, list}, state) do
    existing = MapSet.new(state.pending_approvals, & &1.proposal_id)

    new =
      list
      |> Enum.map(fn a ->
        %{
          proposal_id: a["proposal_id"] || a[:proposal_id],
          tool: a["tool"] || a[:tool] || "tool",
          args: a["args"] || a[:args] || %{}
        }
      end)
      |> Enum.reject(fn a ->
        is_nil(a.proposal_id) or MapSet.member?(existing, a.proposal_id) or
          MapSet.member?(state.auto_approve, a.tool)
      end)

    %{state | pending_approvals: state.pending_approvals ++ new}
  end

  defp handle_event({:approval_resolved, %{proposal_id: id}}, state) do
    %{state | pending_approvals: Enum.reject(state.pending_approvals, &(&1.proposal_id == id))}
  end

  defp handle_event({:error, reason}, state) do
    %{state | turn: :idle, messages: state.messages ++ [msg(:system, "error: #{reason}")]}
  end

  defp handle_event(_other, state), do: state

  # ── view ──────────────────────────────────────────────────────────────────

  @impl true
  def view(state) do
    stack(:vertical, [header(state), text(""), transcript(state), text("")] ++ footer(state))
  end

  # When a tool call is awaiting a decision, the footer becomes a modal approval
  # prompt (head of the queue); otherwise the normal status + input lines.
  defp footer(%{pending_approvals: [current | rest]}) do
    more = if rest == [], do: "", else: "  (+#{length(rest)} more)"

    [
      text(
        "🔐 #{current.tool} wants to run#{format_args(current.args)}  (#{short_id(current.proposal_id)})#{more}",
        Style.new() |> Style.fg(:yellow) |> Style.bold()
      ),
      text("❯ (y)es   (n)o   (a)lways-allow", Style.new() |> Style.fg(:yellow))
    ]
  end

  defp footer(state), do: [status_line(state), input_line(state)]

  defp header(state) do
    text(
      "┌ Arbor · #{short(state.agent_id)} · #{conn_dot(state.status)} #{status_label(state.status)}#{reconnect_hint(state)} ─",
      Style.new() |> Style.fg(:cyan) |> Style.bold()
    )
  end

  # While reconnecting, surface the "attempt N, retrying in …" tail the WSClient
  # stashed in status_detail so the user sees progress, not a frozen client.
  defp reconnect_hint(%{status: :reconnecting, status_detail: detail}) when is_binary(detail),
    do: " · #{detail}"

  defp reconnect_hint(_), do: ""

  defp transcript(state) do
    lines = Enum.map(state.messages, &message_line/1)
    lines = lines ++ streaming_lines(state.streaming)
    stack(:vertical, if(lines == [], do: [text("")], else: lines))
  end

  defp streaming_lines(nil), do: []

  defp streaming_lines(text) when is_binary(text),
    do: [message_line(msg(:agent, text))]

  defp message_line(%{role: role, text: body}) do
    {prefix, style} = role_style(role)
    text(prefix <> body, style)
  end

  defp status_line(state) do
    indicator =
      case state.turn do
        :thinking -> "◐ thinking…"
        _ -> "ready"
      end

    detail = if state.status_detail, do: " (#{state.status_detail})", else: ""

    text(
      "├─ #{indicator}#{detail}",
      Style.new() |> Style.fg(:bright_black)
    )
  end

  defp input_line(state) do
    cursor = if state.turn == :thinking, do: "", else: "▏"
    text("› " <> state.input <> cursor, Style.new() |> Style.bold())
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp role_style(:you), do: {"you   ▏ ", Style.new() |> Style.fg(:green) |> Style.bold()}
  defp role_style(:agent), do: {"agent ▏ ", Style.new()}
  defp role_style(:notification), do: {"💭 agent ▏ ", Style.new() |> Style.fg(:magenta)}
  defp role_style(:tool), do: {"⚡ ", Style.new() |> Style.fg(:yellow)}
  defp role_style(:system), do: {"• ", Style.new() |> Style.fg(:red)}
  defp role_style(_), do: {"  ", Style.new()}

  defp msg(role, text), do: %{role: role, text: text}

  defp role_atom("user"), do: :you
  defp role_atom(:user), do: :you
  defp role_atom("assistant"), do: :agent
  defp role_atom(_), do: :agent

  defp transcript_to_messages(transcript) when is_list(transcript) do
    Enum.map(transcript, fn entry ->
      role = role_atom(entry["role"] || entry[:role] || "assistant")
      msg(role, entry["content"] || entry[:content] || "")
    end)
  end

  defp transcript_to_messages(_), do: []

  defp connected?(%{status: :connected}), do: true
  defp connected?(_), do: false

  defp conn_dot(:connected), do: "●"
  defp conn_dot(:connecting), do: "◌"
  defp conn_dot(:reconnecting), do: "◍"
  defp conn_dot(_), do: "○"

  defp status_label(:reconnecting), do: "reconnecting…"
  defp status_label(status), do: to_string(status)

  defp short("agent_" <> rest), do: "agent_" <> String.slice(rest, 0, 6) <> "…"
  defp short(other) when is_binary(other), do: other
  defp short(_), do: "?"

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 14)
  defp short_id(_), do: "?"

  defp format_args(args) when is_map(args) and map_size(args) > 0 do
    inner =
      args
      |> Enum.map(fn {k, v} -> "#{k}: #{inspect(v)}" end)
      |> Enum.join(", ")

    " — #{inner}"
  end

  defp format_args(_), do: ""
end
