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
    # nil target ⇒ start UNATTACHED (no connection until /agent <id>).
    target_agent_id = Keyword.get(opts, :target_agent_id)
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

    {status, messages} =
      if target_agent_id do
        {:connecting, []}
      else
        {:idle, [msg(:system, "Not attached. Use /agent <id> to attach.")]}
      end

    {width, height} = initial_terminal_size()

    %{
      ws: ws,
      # The TermUI runtime + full identity are kept so client-local commands that
      # talk to the gateway out-of-band (e.g. /agents, a signed HTTP GET) can
      # spawn an async fetch and push the result back into this runtime.
      runtime: runtime_name,
      identity: identity,
      identity_id: identity.agent_id,
      agent_id: target_agent_id,
      gateway_url: gateway_url,
      status: status,
      status_detail: nil,
      # Human-friendly name of the attached agent (from the engagement frame);
      # the header shows it instead of the raw agent_<hex> id when known.
      agent_name: nil,
      engagement_id: nil,
      input: "",
      # Input history (newest first) for ↑/↓ recall. `hist_pos` is nil while
      # editing live, or an index into `history` while navigating; `draft` holds
      # the in-progress line so ↓ past the newest entry restores it.
      history: [],
      hist_pos: nil,
      draft: "",
      messages: messages,
      streaming: nil,
      turn: :idle,
      # HITL: tool calls awaiting the user's decision (FIFO; head is prompted),
      # and tools the user chose to always-allow this session.
      pending_approvals: [],
      auto_approve: MapSet.new(),
      # Terminal dimensions. The runtime only emits Event.Resize on CHANGE, so we
      # query the real size up front (falling back to 80x24); resize events keep
      # it current after that. The bordered frame draws to these.
      width: width,
      height: height
    }
  end

  # Best-effort initial terminal size (the runtime's Terminal GenServer). Returns
  # {cols, rows}; falls back to 80x24 if it isn't up yet / can't be read.
  defp initial_terminal_size do
    case TermUI.Terminal.get_terminal_size() do
      {:ok, {rows, cols}} when is_integer(cols) and is_integer(rows) -> {cols, rows}
      _ -> {80, 24}
    end
  catch
    _, _ -> {80, 24}
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
  # ↑/↓ walk the input history; Tab completes a partial slash command.
  def event_to_msg(%Event.Key{key: :up}, _state), do: {:msg, :history_prev}
  def event_to_msg(%Event.Key{key: :down}, _state), do: {:msg, :history_next}
  def event_to_msg(%Event.Key{key: :tab}, _state), do: {:msg, :complete}

  def event_to_msg(%Event.Key{char: char}, _state) when is_binary(char) and char != "",
    do: {:msg, {:char, char}}

  # Terminal resize — track dimensions so the bordered frame redraws to the new
  # width/height.
  def event_to_msg(%Event.Resize{width: w, height: h}, _state), do: {:msg, {:resize, w, h}}

  def event_to_msg(_event, _state), do: :ignore

  # ── update ──────────────────────────────────────────────────────────────────

  @impl true
  def update(:quit, state), do: {state, [Command.quit(:normal)]}

  # Typing/erasing exits history navigation (the line is now a fresh edit).
  def update({:char, c}, state), do: {%{state | input: state.input <> c, hist_pos: nil}}

  def update(:backspace, state) do
    {%{state | input: String.slice(state.input, 0..-2//1), hist_pos: nil}}
  end

  def update(:clear_input, state), do: {%{state | input: "", hist_pos: nil}}

  def update({:resize, w, h}, state), do: {%{state | width: w, height: h}}

  # ↑ — recall an older history entry (saving the live draft on first step).
  def update(:history_prev, %{history: []} = state), do: {state}

  def update(:history_prev, state) do
    pos =
      if state.hist_pos == nil, do: 0, else: min(state.hist_pos + 1, length(state.history) - 1)

    draft = if state.hist_pos == nil, do: state.input, else: state.draft
    {%{state | input: Enum.at(state.history, pos), hist_pos: pos, draft: draft}}
  end

  # ↓ — step toward newer entries; past the newest restores the saved draft.
  def update(:history_next, %{hist_pos: nil} = state), do: {state}

  def update(:history_next, %{hist_pos: 0} = state),
    do: {%{state | input: state.draft, hist_pos: nil}}

  def update(:history_next, state) do
    pos = state.hist_pos - 1
    {%{state | input: Enum.at(state.history, pos), hist_pos: pos}}
  end

  # Tab — complete a partial slash command.
  def update(:complete, state), do: {%{state | input: complete_input(state.input), hist_pos: nil}}

  def update(:submit, %{input: ""} = state), do: {state}

  def update(:submit, %{input: text} = state) do
    state = %{
      state
      | history: push_history(state.history, String.trim(text)),
        hist_pos: nil,
        draft: ""
    }

    case String.trim(text) do
      "/quit" -> {%{state | input: ""}, [Command.quit(:normal)]}
      trimmed -> {handle_input(trimmed, state)}
    end
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
  #
  # `:detached` is the best-effort give-up (initial attach failed): the WSClient
  # has dropped the target, so clear our agent_id too and surface the message.
  def update({:ws_status, :detached, detail}, state) do
    {%{
       state
       | status: :detached,
         status_detail: nil,
         agent_id: nil,
         agent_name: nil,
         turn: :idle,
         streaming: nil,
         messages: state.messages ++ [msg(:system, detail <> " Use /agent <id> to retry.")]
     }}
  end

  def update({:ws_status, status, detail}, state),
    do: {%{state | status: status, status_detail: detail}}

  # Async result of the /agents signed HTTP GET (pushed by the spawned fetch).
  def update({:agents_result, result}, state), do: {render_agents(result, state)}

  # Async results of the lifecycle POSTs (/new, /start, /stop). On success they
  # mutate the attachment (auto-attach for create/start, detach for stop), so
  # they fold into the model AND may issue a WS command.
  def update({:lifecycle_result, op, result}, state), do: {render_lifecycle(op, result, state)}

  # Async results of the /alias HTTP calls (list/set/remove).
  def update({:alias_result, op, result}, state), do: {render_alias(op, result, state)}

  # Server events forwarded by the WS client.
  def update({:server_event, event}, state), do: {handle_event(event, state)}

  def update(_msg, state), do: {state}

  # ── input routing: client-local slash commands, then gateway ───────────────

  # Slash input is matched against the small client-local command set FIRST; an
  # unmatched `/command` falls through to the gateway (the server-slash-command
  # path). Plain text goes to the gateway as a chat message.
  defp handle_input("/agents", state), do: cmd_agents(state)
  defp handle_input("/agent " <> rest, state), do: cmd_agent(String.trim(rest), state)
  defp handle_input("/agent", state), do: cmd_agent("", state)
  defp handle_input("/new " <> rest, state), do: cmd_new(String.trim(rest), state)
  defp handle_input("/new", state), do: cmd_new("", state)
  defp handle_input("/start " <> rest, state), do: cmd_start(String.trim(rest), state)
  defp handle_input("/start", state), do: cmd_start("", state)
  defp handle_input("/stop " <> rest, state), do: cmd_stop(String.trim(rest), state)
  defp handle_input("/stop", state), do: cmd_stop("", state)
  defp handle_input("/connect " <> rest, state), do: cmd_connect(String.trim(rest), state)
  defp handle_input("/connect", state), do: cmd_connect("", state)
  defp handle_input("/alias " <> rest, state), do: cmd_alias(String.trim(rest), state)
  defp handle_input("/alias", state), do: cmd_alias("", state)
  defp handle_input("/help", state), do: cmd_help(state)

  defp handle_input(text, state) do
    # Unmatched local command, or a normal message → forward to the gateway,
    # but only when attached. (/quit is handled in update/2 before we get here.)
    cond do
      not attached?(state) ->
        %{state | input: "", messages: state.messages ++ [msg(:system, not_attached_hint())]}

      true ->
        if connected?(state), do: WSClient.send_command(state.ws, {:send, text})

        %{
          state
          | input: "",
            streaming: nil,
            turn: :thinking,
            messages: state.messages ++ [msg(:you, text)]
        }
    end
  end

  # /agent <id> — set/switch the target agent and (re)connect+attach to it.
  defp cmd_agent("", state) do
    %{state | input: "", messages: state.messages ++ [msg(:system, "usage: /agent <agent_id>")]}
  end

  defp cmd_agent(agent_id, state) do
    if state.ws, do: WSClient.connect_to(state.ws, agent_id)

    # Switching agents is a fresh conversation — reset the transcript.
    %{
      state
      | input: "",
        agent_id: agent_id,
        status: :connecting,
        status_detail: nil,
        engagement_id: nil,
        streaming: nil,
        turn: :idle,
        pending_approvals: [],
        messages: [msg(:system, "Attaching to #{agent_id}…")]
    }
  end

  # /agents — list the agents this client may chat with. A signed HTTP GET (works
  # whether attached or detached), run ASYNC so the UI doesn't block: spawn the
  # fetch, push {:agents_result, …} back into the runtime when it lands, and show
  # a "fetching…" note now.
  defp cmd_agents(state) do
    spawn_agents_fetch(state)

    %{
      state
      | input: "",
        messages: state.messages ++ [msg(:system, "Fetching agents from #{state.gateway_url}…")]
    }
  end

  defp spawn_agents_fetch(%{runtime: runtime, identity: identity, gateway_url: url})
       when not is_nil(runtime) and not is_nil(identity) do
    client = agents_client()

    spawn(fn ->
      result = client.fetch(identity, url)
      TermUI.Runtime.send_message(runtime, :root, {:agents_result, result})
    end)

    :ok
  end

  defp spawn_agents_fetch(_state), do: :ok

  defp agents_client,
    do: Application.get_env(:arbor_tui, :agents_client, ArborTui.AgentsClient)

  # /new <template> [name] — create+start a new agent, then AUTO-ATTACH to it.
  # A signed HTTP POST (works attached or detached), run ASYNC like /agents.
  defp cmd_new("", state) do
    %{
      state
      | input: "",
        messages: state.messages ++ [msg(:system, "usage: /new <template> [name]")]
    }
  end

  defp cmd_new(rest, state) do
    {template, name} =
      case String.split(rest, ~r/\s+/, parts: 2) do
        [t, n] -> {t, n}
        [t] -> {t, nil}
      end

    spawn_lifecycle(state, :new, fn client, identity, url ->
      client.create(identity, url, template, name)
    end)

    %{
      state
      | input: "",
        messages: state.messages ++ [msg(:system, "Creating agent from '#{template}'…")]
    }
  end

  # /start <id> — start an existing stopped agent, then AUTO-ATTACH to it.
  defp cmd_start("", state) do
    %{state | input: "", messages: state.messages ++ [msg(:system, "usage: /start <agent_id>")]}
  end

  defp cmd_start(id, state) do
    spawn_lifecycle(state, {:start, id}, fn client, identity, url ->
      client.start(identity, url, id)
    end)

    %{state | input: "", messages: state.messages ++ [msg(:system, "Starting #{id}…")]}
  end

  # /stop <id> — stop a running agent; if it's the attached one, detach.
  defp cmd_stop("", state) do
    %{state | input: "", messages: state.messages ++ [msg(:system, "usage: /stop <agent_id>")]}
  end

  defp cmd_stop(id, state) do
    spawn_lifecycle(state, {:stop, id}, fn client, identity, url ->
      client.stop(identity, url, id)
    end)

    %{state | input: "", messages: state.messages ++ [msg(:system, "Stopping #{id}…")]}
  end

  # Spawn a lifecycle POST and push {:lifecycle_result, op, result} back into the
  # runtime when it lands — same async pattern as spawn_agents_fetch.
  defp spawn_lifecycle(
         %{runtime: runtime, identity: identity, gateway_url: url},
         op,
         call
       )
       when not is_nil(runtime) and not is_nil(identity) do
    client = lifecycle_client()

    spawn(fn ->
      result = call.(client, identity, url)
      TermUI.Runtime.send_message(runtime, :root, {:lifecycle_result, op, result})
    end)

    :ok
  end

  defp spawn_lifecycle(_state, _op, _call), do: :ok

  defp lifecycle_client,
    do: Application.get_env(:arbor_tui, :lifecycle_client, ArborTui.LifecycleClient)

  # /connect <url> — change the gateway URL and reconnect (re-attach current).
  defp cmd_connect("", state) do
    %{state | input: "", messages: state.messages ++ [msg(:system, "usage: /connect <ws-url>")]}
  end

  defp cmd_connect(url, state) do
    if state.ws, do: WSClient.set_url(state.ws, url)

    note =
      if state.agent_id,
        do: "Reconnecting to #{url}…",
        else: "Gateway set to #{url}. Use /agent <id> to attach."

    status = if state.agent_id, do: :connecting, else: state.status

    %{
      state
      | input: "",
        gateway_url: url,
        status: status,
        status_detail: nil,
        messages: state.messages ++ [msg(:system, note)]
    }
  end

  # /alias — list / set / remove per-principal agent nicknames. Resolution +
  # storage are server-side (so every client sees them); these just call the
  # gateway and render the async result.
  defp cmd_alias("", state) do
    spawn_alias(state, :list, fn c, id, url -> c.list(id, url) end)
    note(state, "Fetching aliases…")
  end

  defp cmd_alias("rm " <> name, state), do: cmd_alias_remove(String.trim(name), state)
  defp cmd_alias("remove " <> name, state), do: cmd_alias_remove(String.trim(name), state)

  defp cmd_alias(rest, state) do
    case String.split(rest, ~r/\s+/, parts: 2) do
      [name, target] ->
        spawn_alias(state, {:set, name}, fn c, id, url -> c.set(id, url, name, target) end)
        note(state, "Saving alias #{name} → #{target}…")

      _ ->
        note(
          state,
          "usage: /alias <name> <id|prefix|name>  ·  /alias rm <name>  ·  /alias (list)"
        )
    end
  end

  defp cmd_alias_remove("", state), do: note(state, "usage: /alias rm <name>")

  defp cmd_alias_remove(name, state) do
    spawn_alias(state, {:remove, name}, fn c, id, url -> c.remove(id, url, name) end)
    note(state, "Removing alias #{name}…")
  end

  defp spawn_alias(%{runtime: runtime, identity: identity, gateway_url: url}, op, call)
       when not is_nil(runtime) and not is_nil(identity) do
    client = aliases_client()

    spawn(fn ->
      result = call.(client, identity, url)
      TermUI.Runtime.send_message(runtime, :root, {:alias_result, op, result})
    end)

    :ok
  end

  defp spawn_alias(_state, _op, _call), do: :ok

  defp aliases_client,
    do: Application.get_env(:arbor_tui, :aliases_client, ArborTui.AliasesClient)

  # A command acknowledgement: clear the input and append a system line.
  defp note(state, text),
    do: %{state | input: "", messages: state.messages ++ [msg(:system, text)]}

  # /help — LOCAL help (client commands); other /commands go to the agent.
  defp cmd_help(state) do
    lines = [
      "Client commands (handled locally):",
      "  /agents              list the agents you can chat with",
      "  /agent <id|name>     attach (id, unique prefix, display_name, or alias)",
      "  /alias [<n> <tgt>]   list, or save a nickname (e.g. /alias r 64b2);  /alias rm <n>",
      "  /new <template> [nm] create+start an agent and attach to it",
      "  /start <id|name>     start a stopped agent and attach to it",
      "  /stop <id|name>      stop a running agent",
      "  /connect <url>       change the gateway URL and reconnect",
      "  /help                this help",
      "  /quit                exit the TUI",
      "Other /commands (e.g. /model, /status) are sent to the attached agent."
    ]

    %{state | input: "", messages: state.messages ++ Enum.map(lines, &msg(:system, &1))}
  end

  # Render the /agents result into the transcript as system lines.
  defp render_agents({:ok, []}, state) do
    %{state | messages: state.messages ++ [msg(:system, "No agents you can chat with.")]}
  end

  defp render_agents({:ok, agents}, state) when is_list(agents) do
    lines =
      Enum.map(agents, fn a ->
        status = if a.running, do: "running", else: "stopped"
        "#{short(a.agent_id)}  #{a.display_name}  #{a.template}  [#{status}]"
      end) ++ ["Use /agent <id> to attach."]

    %{state | messages: state.messages ++ Enum.map(lines, &msg(:system, &1))}
  end

  defp render_agents({:error, reason}, state) do
    %{
      state
      | messages:
          state.messages ++
            [msg(:system, "Couldn't list agents: #{inspect(reason)}")]
    }
  end

  # ── lifecycle results (/new, /start, /stop) ────────────────────────────────

  # /new success: render "Created <id>" and AUTO-ATTACH to the new agent.
  defp render_lifecycle(:new, {:ok, %{"agent_id" => id} = body}, state) do
    name = body["display_name"] || id
    note = "Created #{name} (#{short(id)}). Attaching…"
    attach_to(id, msg(:system, note), state)
  end

  # /start success: AUTO-ATTACH to the started agent.
  defp render_lifecycle({:start, _requested}, {:ok, %{"agent_id" => id}}, state) do
    attach_to(id, msg(:system, "Started #{short(id)}. Attaching…"), state)
  end

  # /stop success: confirm; if the stopped agent is the attached one, detach.
  defp render_lifecycle({:stop, _requested}, {:ok, %{"agent_id" => id}}, state) do
    note = msg(:system, "Stopped #{short(id)}.")

    if state.agent_id == id do
      # Go detached locally; the server-side socket drops as the agent stops, so
      # we don't drive the WSClient here (mirrors the {:ws_status, :detached} path).
      %{
        state
        | agent_id: nil,
          status: :detached,
          status_detail: nil,
          engagement_id: nil,
          streaming: nil,
          turn: :idle,
          pending_approvals: [],
          messages: state.messages ++ [note, msg(:system, "Detached. Use /agent <id> to attach.")]
      }
    else
      %{state | messages: state.messages ++ [note]}
    end
  end

  defp render_lifecycle(op, {:error, reason}, state) do
    %{
      state
      | messages:
          state.messages ++ [msg(:system, "#{op_label(op)} failed: #{reason_text(reason)}")]
    }
  end

  # Catch-all for an unexpected success shape (e.g. missing agent_id).
  defp render_lifecycle(op, {:ok, _other}, state) do
    %{state | messages: state.messages ++ [msg(:system, "#{op_label(op)}: unexpected response")]}
  end

  # ── alias results (/alias) ──────────────────────────────────────────────────

  defp render_alias(:list, {:ok, aliases}, state) when map_size(aliases) == 0 do
    append_system(state, ["No aliases set. /alias <name> <id|prefix|name> to add one."])
  end

  defp render_alias(:list, {:ok, aliases}, state) do
    lines = aliases |> Enum.sort() |> Enum.map(fn {n, id} -> "  #{n} → #{short(id)}" end)
    append_system(state, ["Aliases:" | lines])
  end

  defp render_alias({:set, name}, {:ok, %{"agent_id" => id}}, state),
    do: append_system(state, ["Alias #{name} → #{short(id)}"])

  defp render_alias({:remove, name}, {:ok, _}, state),
    do: append_system(state, ["Removed alias #{name}"])

  defp render_alias(_op, {:error, {:http_error, _status, message}}, state),
    do: append_system(state, ["alias error: #{message}"])

  defp render_alias(_op, {:error, reason}, state),
    do: append_system(state, ["alias error: #{inspect(reason)}"])

  defp append_system(state, lines),
    do: %{state | messages: state.messages ++ Enum.map(lines, &msg(:system, &1))}

  # Switch the target agent and (re)connect+attach — mirrors cmd_agent's attach,
  # but driven from an async result and prepending a custom note. Resets the
  # transcript since attaching is a fresh conversation.
  defp attach_to(id, note, state) do
    if state.ws, do: WSClient.connect_to(state.ws, id)

    %{
      state
      | agent_id: id,
        status: :connecting,
        status_detail: nil,
        engagement_id: nil,
        streaming: nil,
        turn: :idle,
        pending_approvals: [],
        messages: [note]
    }
  end

  defp op_label(:new), do: "Create"
  defp op_label({:start, _}), do: "Start"
  defp op_label({:stop, _}), do: "Stop"

  defp reason_text({:http_error, status, message}), do: "#{message} (HTTP #{status})"
  defp reason_text({:http_status, status}), do: "HTTP #{status}"
  defp reason_text(reason), do: inspect(reason)

  # ── server events ────────────────────────────────────────────────────────

  defp handle_event({:engagement, %{id: id, transcript: transcript} = ev}, state) do
    # A successful attach — persist the agent as the resume hint (best-effort).
    # `state[:state_path]` is nil in production (→ Config.state_path(), the real
    # ~/.arbor/tui.state); tests set it to a tmp path so attach-driven saves never
    # pollute the developer's real state file.
    if state.agent_id,
      do: ArborTui.Config.save_last_agent(state.agent_id, Map.get(state, :state_path))

    %{
      state
      | engagement_id: id,
        agent_name: ev[:display_name],
        messages: transcript_to_messages(transcript)
    }
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
  # Layout: a bordered frame (top border carries the title/agent/status, side
  # borders wrap the wrapped+timestamped transcript, bottom border carries the
  # turn status), with the input line (or HITL approval prompt) below the frame.
  def view(state) do
    w = frame_width(state)
    below = below_frame(state)
    # Fill the screen: interior = height − top border − bottom border − below-frame
    # lines. Painting every row is what stops terminal scrollback bleeding through.
    interior_h = max(frame_height(state) - 2 - length(below), 1)

    body = content_lines(state, w, interior_h)

    stack(:vertical, [frame_top(state, w)] ++ body ++ [frame_bottom(state, w)] ++ below)
  end

  # Terminal dims, clamped so the border math never goes negative on a tiny pane.
  defp frame_width(state), do: max(Map.get(state, :width, 80), 24)
  defp frame_height(state), do: max(Map.get(state, :height, 24), 6)
  defp inner_width(w), do: max(w - 4, 1)

  # ── frame borders ─────────────────────────────────────────────────────────

  defp frame_top(state, w) do
    prefix = "╭─ Arbor "
    status = "#{conn_dot(state.status)} #{status_label(state.status)}#{reconnect_hint(state)}"

    # Show the agent segment only when attached/attaching — otherwise it'd read
    # "not attached … not attached". Prefer the human-friendly name once the
    # engagement frame has supplied it, falling back to the short id.
    suffix =
      if state.agent_id,
        do: " #{state.agent_name || short(state.agent_id)} #{status} ─╮",
        else: " #{status} ─╮"

    text(fill_between(prefix, suffix, w), border_style())
  end

  defp frame_bottom(state, w) do
    detail = if state.status_detail, do: " (#{state.status_detail})", else: ""
    text(fill_between("╰─ #{turn_indicator(state)}#{detail} ", "─╯", w), border_style())
  end

  # prefix + ─ filler + suffix, sized to exactly `w` columns (filler clamped ≥ 0).
  defp fill_between(prefix, suffix, w) do
    gap = w - String.length(prefix) - String.length(suffix)
    prefix <> String.duplicate("─", max(gap, 0)) <> suffix
  end

  # While reconnecting, surface the "attempt N, retrying in …" tail the WSClient
  # stashed in status_detail so the user sees progress, not a frozen client.
  defp reconnect_hint(%{status: :reconnecting, status_detail: detail}) when is_binary(detail),
    do: " · #{detail}"

  defp reconnect_hint(_), do: ""

  defp turn_indicator(%{turn: :thinking}), do: "◐ thinking…"
  defp turn_indicator(_), do: "ready"

  # ── transcript content (bordered, wrapped, role-coloured) ───────────────────

  # column widths inside the frame: HH:MM (5) + gap (2) + role (7) = 14 indent
  @ts_w 5
  @role_w 7
  @text_indent 14

  defp content_lines(state, w, interior_h) do
    rows =
      (state.messages ++ streaming_msgs(state.streaming))
      |> Enum.chunk_by(& &1.role)
      |> Enum.map(&render_group(&1, w))
      |> Enum.intersperse([blank_row(w)])
      |> List.flatten()

    # Keep the newest `interior_h` rows visible (auto-scroll to bottom), then pad
    # the bottom with blank framed rows so the interior always fills the height.
    visible = Enum.take(rows, -interior_h)
    visible ++ List.duplicate(blank_row(w), interior_h - length(visible))
  end

  defp streaming_msgs(nil), do: []

  defp streaming_msgs(t) when is_binary(t),
    do: [%{role: :agent, text: strip_data_tags(t), at: nil}]

  # Defense-in-depth: never display the prompt-injection-defense delimiters
  # (<data_NONCE>) that smaller models sometimes echo into their reply. The
  # orchestrator strips them server-side too, but the gateway's streamed/returned
  # chat text can still carry them, so we scrub at the render boundary. NONCE is
  # the 16-hex tag from Arbor.Common.PromptSanitizer. We drop the WHOLE fenced
  # block (the echoed scaffolding + its junk inner content, e.g. "None"), then any
  # stray unmatched tag, then trim the leading whitespace the removal leaves.
  @data_block_re ~r|<data_([0-9a-fA-F]{16})>.*?</data_\1>|s
  @data_tag_re ~r|</?data_[0-9a-fA-F]{16}>|
  defp strip_data_tags(text) when is_binary(text) do
    text
    |> String.replace(@data_block_re, "")
    |> String.replace(@data_tag_re, "")
    |> String.trim_leading()
  end

  defp strip_data_tags(other), do: other

  # Consecutive messages from the same speaker render as one group: only the
  # first carries the timestamp + role header; the rest are indented under the
  # text column (Slack/Discord-style grouping) for a calmer transcript.
  defp render_group([first | rest], w) do
    message_block(first, w, true) ++ Enum.flat_map(rest, &message_block(&1, w, false))
  end

  # One message → one-or-more bordered rows. With `header?`, the first row carries
  # timestamp + role; without it (a grouped follow-on), every row is indented
  # under the text column. Continuation rows from wrapping are always indented.
  defp message_block(%{role: role, text: body} = m, w, header?) do
    text_area = max(inner_width(w) - @text_indent, 1)
    {label, rstyle} = frame_role(role)
    lines = wrap_text(strip_data_tags(to_string(body)), text_area)

    if header? do
      [first | rest] = lines

      head =
        content_row(pad(m[:at] || "", @ts_w) <> "  " <> pad(label, @role_w) <> first, w, rstyle)

      [head | Enum.map(rest, &indented_row(&1, w, rstyle))]
    else
      Enum.map(lines, &indented_row(&1, w, rstyle))
    end
  end

  defp indented_row(line, w, style),
    do: content_row(String.duplicate(" ", @text_indent) <> line, w, style)

  # A framed row: cyan side borders + the interior padded to the inner width and
  # coloured by the speaker's style (so each row reads as one speaker).
  defp content_row(inner, w, style) do
    stack(:horizontal, [
      text("│ ", border_style()),
      text(pad(inner, inner_width(w)), style || Style.new()),
      text(" │", border_style())
    ])
  end

  defp blank_row(w), do: content_row("", w, nil)

  # ── input / approval (below the frame) ──────────────────────────────────────

  # A pending tool call turns the area below the frame into a modal y/n/a prompt
  # (head of the FIFO queue); otherwise it's the normal input line.
  defp below_frame(%{pending_approvals: [current | rest]}) do
    more = if rest == [], do: "", else: "  (+#{length(rest)} more)"

    [
      text(
        "  🔐 #{current.tool} wants to run#{format_args(current.args)}  (#{short_id(current.proposal_id)})#{more}",
        Style.new() |> Style.fg(:yellow) |> Style.bold()
      ),
      text("  ❯ (y)es   (n)o   (a)lways-allow", Style.new() |> Style.fg(:yellow))
    ]
  end

  defp below_frame(state) do
    cursor = if state.turn == :thinking, do: "", else: "▏"
    [text("  › " <> state.input <> cursor, Style.new() |> Style.bold())]
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp border_style, do: Style.new() |> Style.fg(:cyan)

  defp frame_role(:you), do: {"you", Style.new() |> Style.fg(:green) |> Style.bold()}
  defp frame_role(:agent), do: {"agent", Style.new()}
  defp frame_role(:notification), do: {"note", Style.new() |> Style.fg(:magenta)}
  defp frame_role(:tool), do: {"tool", Style.new() |> Style.fg(:yellow)}
  defp frame_role(:system), do: {"sys", Style.new() |> Style.fg(:bright_black)}
  defp frame_role(_), do: {"", Style.new()}

  # Pad (right) or truncate a string to exactly `n` display columns.
  defp pad(s, n) do
    if String.length(s) > n, do: String.slice(s, 0, n), else: String.pad_trailing(s, n)
  end

  # Greedy word-wrap, preserving explicit newlines as hard breaks. Words longer
  # than the width get their own line (and are truncated by pad/2 at render).
  defp wrap_text("", _w), do: [""]

  defp wrap_text(text, w) do
    text
    |> String.split("\n")
    |> Enum.flat_map(&wrap_line(&1, w))
    |> case do
      [] -> [""]
      lines -> lines
    end
  end

  defp wrap_line(line, w) do
    line
    |> String.split(~r/\s+/, trim: true)
    |> do_wrap(w, "", [])
  end

  defp do_wrap([], _w, "", []), do: [""]
  defp do_wrap([], _w, cur, acc), do: Enum.reverse([cur | acc])
  defp do_wrap([word | rest], w, "", acc), do: do_wrap(rest, w, word, acc)

  defp do_wrap([word | rest], w, cur, acc) do
    if String.length(cur) + 1 + String.length(word) <= w do
      do_wrap(rest, w, cur <> " " <> word, acc)
    else
      do_wrap(rest, w, word, [cur | acc])
    end
  end

  # Stamped at creation (in update/handler context) with the local wall-clock
  # HH:MM, which the framed transcript shows in its timestamp column. NOT called
  # from the pure view — streaming text builds its own unstamped map there.
  defp msg(role, text), do: %{role: role, text: text, at: now_hhmm()}

  defp now_hhmm do
    {_date, {h, m, _s}} = :calendar.local_time()
    "~2..0B:~2..0B" |> :io_lib.format([h, m]) |> IO.iodata_to_binary()
  end

  defp role_atom("user"), do: :you
  defp role_atom(:user), do: :you
  defp role_atom("assistant"), do: :agent
  defp role_atom("system"), do: :system
  defp role_atom(:system), do: :system
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

  # A target agent is set (attached or attaching). When nil, the client is
  # UNATTACHED and a /agent <id> is required before chatting.
  defp attached?(%{agent_id: agent_id}), do: not is_nil(agent_id)

  defp not_attached_hint, do: "Not attached — use /agent <id> first."

  defp conn_dot(:connected), do: "●"
  defp conn_dot(:connecting), do: "◌"
  defp conn_dot(:reconnecting), do: "◍"
  defp conn_dot(_), do: "○"

  defp status_label(:reconnecting), do: "reconnecting…"
  defp status_label(:idle), do: "not attached"
  defp status_label(:detached), do: "not attached"
  defp status_label(status), do: to_string(status)

  defp short(nil), do: "not attached"
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

  # ── input history + completion ──────────────────────────────────────────────

  # Newest first; skip empties and consecutive duplicates.
  defp push_history(history, ""), do: history
  defp push_history([last | _] = history, last), do: history
  defp push_history(history, entry), do: [entry | history]

  # Known slash commands for Tab completion — the client-local set plus the
  # common server-handled ones (CommandIntake routes the latter). Agent-id
  # completion after `/agent `/`/start `/`/stop ` is a follow-up (needs the
  # /agents list cached client-side).
  @slash_commands ~w(/help /agents /agent /alias /new /start /stop /connect /quit
                     /model /status /tools /trust /memory /compact /clear /session)

  # Complete a partial slash-command WORD (before the first space). One match →
  # fill it + a trailing space; several → fill their longest common prefix;
  # otherwise leave the input untouched.
  defp complete_input("/" <> _ = input) do
    if String.contains?(input, " ") do
      input
    else
      case Enum.filter(@slash_commands, &String.starts_with?(&1, input)) do
        [] -> input
        [only] -> only <> " "
        many -> common_prefix(many)
      end
    end
  end

  defp complete_input(input), do: input

  defp common_prefix([first | rest]),
    do: Enum.reduce(rest, first, &common_prefix2/2)

  defp common_prefix2(a, b) do
    Enum.zip(String.graphemes(a), String.graphemes(b))
    |> Enum.take_while(fn {x, y} -> x == y end)
    |> Enum.map_join("", &elem(&1, 0))
  end
end
