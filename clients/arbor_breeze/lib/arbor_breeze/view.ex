defmodule ArborBreeze.View do
  use Breeze.View
  import Breeze.Blocks, only: [textarea: 1, scroll: 1, list: 1]
  alias ArborBreeze.{Controller, Drafts, Editor, TerminalText}
  alias ConversationKit.Arbor

  @impl true
  def mount(options, term) do
    controller = Keyword.fetch!(options, :controller)
    {:ok, snapshot} = Controller.subscribe(controller)

    {:ok,
     assign(term,
       controller: controller,
       controller_ref: Process.monitor(controller),
       snapshot: snapshot,
       editor: Editor.new(),
       browsing: false,
       paste_notice: nil,
       local_notice: nil,
       controls_open: false,
       notices_open: false,
       control_selected: nil,
       control_rows: control_rows(snapshot),
       drafts: Drafts.new(),
       draft_scope: draft_scope(snapshot),
       draft_principal: if(draft_scope(snapshot), do: elem(draft_scope(snapshot), 1)),
       target_input: snapshot.navigation.hint || "",
       target_selected: nil
     )}
  end

  @impl true
  def handle_info({:arbor_breeze_updated, controller, snapshot}, term)
      when controller == term.assigns.controller do
    previous_navigation = term.assigns.snapshot.navigation
    previous = term.assigns.editor
    scope = draft_scope(snapshot)
    old_scope = term.assigns.draft_scope

    drafts =
      cond do
        snapshot.private_cleared or
            (scope != nil and term.assigns.draft_principal != nil and
               elem(scope, 1) != term.assigns.draft_principal) ->
          Drafts.clear(term.assigns.drafts)

        old_scope != scope and old_scope != nil ->
          Drafts.put(term.assigns.drafts, old_scope, previous.draft)

        true ->
          term.assigns.drafts
      end

    editor =
      if old_scope != scope,
        do: Editor.draft(Editor.new(), Drafts.get(drafts, scope)),
        else: Editor.observe(previous, snapshot)

    rows = control_rows(snapshot)
    selected = term.assigns.control_selected
    retained = if Enum.any?(rows, &(&1.id == selected)), do: selected, else: nil
    changed = rows != term.assigns.control_rows

    term =
      assign(term,
        snapshot: snapshot,
        editor: editor,
        control_rows: rows,
        control_selected: retained,
        drafts: drafts,
        draft_scope: scope,
        draft_principal: if(scope, do: elem(scope, 1), else: term.assigns.draft_principal),
        target_selected:
          if(term.assigns.snapshot.navigation.generation == snapshot.navigation.generation,
            do: term.assigns.target_selected
          )
      )

    term = if changed and is_nil(retained), do: reset(term, "controls"), else: term

    term =
      if snapshot.private_cleared do
        term
        |> assign(
          browsing: false,
          controls_open: false,
          notices_open: false,
          control_selected: nil
        )
        |> reset("transcript")
        |> reset("controls")
        |> reset("notices")
        |> focus("draft")
      else
        term
      end

    term =
      if snapshot.private_cleared or previous.draft != editor.draft,
        do: reset(term, "draft"),
        else: term

    term =
      if snapshot.navigation.directory != previous_navigation.directory or
           snapshot.navigation.generation != previous_navigation.generation or
           snapshot.navigation.rows != previous_navigation.rows,
         do:
           term
           |> reset("targets")
           |> reset("draft")
           |> focus(if(snapshot.navigation.directory, do: "target", else: "draft")),
         else: term

    {:noreply, term}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, term)
      when ref == term.assigns.controller_ref,
      do: {:stop, assign(term, editor: Editor.new())}

  def handle_info({:breeze_paste_rejected, reason}, term),
    do: {:noreply, assign(term, paste_notice: paste_notice(reason))}

  def handle_info(_, term), do: {:noreply, term}

  @impl true
  def handle_event("chat:draft", %{value: text}, term) do
    case Arbor.classify_composer_input(text) do
      {:error, :invalid_input} ->
        route_input(term, text)

      _ ->
        {:noreply,
         assign(term, editor: Editor.draft(term.assigns.editor, text), paste_notice: nil)}
    end
  end

  def handle_event("chat:send", %{value: text}, term), do: route_input(term, text)

  def handle_event("chat:send", _params, term), do: send_draft(term)

  def handle_event("targets:select", %{value: selected}, term),
    do: {:noreply, assign(term, target_selected: selected)}

  def handle_event("target:change", %{value: text}, term) do
    if is_binary(text) and byte_size(text) <= 256 and String.valid?(text),
      do: {:noreply, assign(term, target_input: text)},
      else: {:noreply, term}
  end

  def handle_event("target:attach", %{value: token}, term), do: attach(term, token)

  def handle_event(:input, %{"key" => "Enter"} = params, %{focused: "targets"} = term) do
    nav = term.assigns.snapshot.navigation

    row =
      Enum.find(
        nav.rows,
        &(target_row_id(nav.generation, &1.agent_id) == term.assigns.target_selected)
      )

    if not is_nil(row) and params["ctrlKey"] not in [true, "true"] and
         params["shiftKey"] not in [true, "true"],
       do: attach(term, row.agent_id),
       else: {:noreply, term}
  end

  def handle_event(:input, %{"key" => "F2"}, term), do: directory(term)

  def handle_event(:input, %{"key" => "Escape"}, %{assigns: %{local_notice: notice}} = term)
      when not is_nil(notice),
      do:
        {:noreply,
         term
         |> assign(local_notice: nil)
         |> focus(if(term.assigns.snapshot.navigation.directory, do: "target", else: "draft"))}

  def handle_event(
        :input,
        %{"key" => "Escape"},
        %{assigns: %{snapshot: %{navigation: %{directory: true, bound: true}}}} = term
      ) do
    case Controller.act(term.assigns.controller, :back) do
      :ok -> {:noreply, term |> assign(local_notice: nil) |> focus("draft")}
      {:error, reason} -> local_notice(term, navigation_notice(reason))
    end
  end

  def handle_event("controls:select", %{value: selected}, term),
    do: {:noreply, term |> assign(control_selected: selected) |> reset("control-detail")}

  def handle_event(:input, %{"key" => "Enter"} = params, %{focused: "controls"} = term) do
    if params["ctrlKey"] in [true, "true"] or params["shiftKey"] in [true, "true"],
      do: {:noreply, term},
      else: activate_control(term)
  end

  def handle_event(:input, %{"key" => "Escape"}, %{assigns: %{controls_open: true}} = term),
    do: {:noreply, term |> assign(controls_open: false) |> focus("draft")}

  def handle_event(:input, %{"key" => "Escape"}, %{assigns: %{notices_open: true}} = term),
    do: {:noreply, term |> assign(notices_open: false) |> focus("draft")}

  def handle_event(:input, %{"key" => "F13"}, term), do: open_notices(term)

  def handle_event(:input, %{"key" => "F7", "shiftKey" => true}, term), do: open_notices(term)

  def handle_event(:input, %{"key" => "PageUp"}, %{assigns: %{notices_open: true}} = term),
    do: action(term, :older_notices)

  def handle_event(:input, %{"key" => "Home"}, %{assigns: %{notices_open: true}} = term),
    do: action(term, :latest_notices)

  def handle_event(:input, %{"key" => "F7"}, term) do
    selected = term.assigns.control_selected

    current =
      if Enum.any?(term.assigns.control_rows, &(&1.id == selected)), do: selected, else: nil

    term =
      term
      |> assign(
        controls_open: true,
        notices_open: false,
        control_selected: current,
        local_notice: nil
      )
      |> focus("controls")

    {:noreply, if(is_nil(current), do: reset(term, "controls"), else: term)}
  end

  def handle_event(:input, %{"key" => "F1"}, term), do: route_input(term, "/help")

  def handle_event(:input, %{"key" => "F8"}, term), do: action(term, :more_activity)
  def handle_event(:input, %{"key" => "F12"}, term), do: action(term, :latest_activity)
  def handle_event(:input, %{"key" => "Escape"}, term), do: {:stop, term}

  def handle_event(:input, %{"key" => "Enter", "ctrlKey" => true}, %{focused: "draft"} = term),
    do: send_draft(term)

  def handle_event(:input, %{"key" => "F3"}, term), do: action(term, :refresh)
  def handle_event(:input, %{"key" => "F4"}, term), do: action(term, :disconnect)
  def handle_event(:input, %{"key" => "F5"}, term), do: action(term, :reconnect)
  def handle_event(:input, %{"key" => "F6"}, term), do: action(term, :retry)
  def handle_event(:input, %{"key" => "F9"}, term), do: action(term, :older)
  def handle_event(:input, %{"key" => "F10"}, term), do: action(term, :newer)
  def handle_event(:input, %{"key" => "F11"}, term), do: action(term, :latest)
  def handle_event(_, _, term), do: {:noreply, term}

  defp open_notices(term),
    do:
      {:noreply,
       term
       |> assign(notices_open: true, controls_open: false, local_notice: nil)
       |> focus("notices")}

  defp action(term, action) do
    result = Controller.act(term.assigns.controller, action)

    browsing =
      cond do
        action == :latest -> false
        action == :older and term.assigns.snapshot.window.has_older -> true
        true -> term.assigns.browsing
      end

    term = assign(term, browsing: browsing)

    term =
      if action in [:older, :newer, :latest],
        do: reset(term, "transcript"),
        else: term

    term = if action in [:older_notices, :latest_notices], do: reset(term, "notices"), else: term

    if result == :ok,
      do: {:noreply, term},
      else: local_notice(term, navigation_notice(:navigation_busy))
  end

  defp activate_control(term) do
    snapshot = term.assigns.snapshot
    row = Enum.find(term.assigns.control_rows, &(&1.id == term.assigns.control_selected))

    if control_actionable?(snapshot, row) do
      :ok = Controller.act(term.assigns.controller, row.action, row.input)
    end

    {:noreply, term}
  end

  defp control_actionable?(snapshot, row),
    do:
      row && row.action && snapshot.connected && not snapshot.busy &&
        Map.get(snapshot, :controls_available, false)

  defp control_rows(snapshot) do
    controls = Map.get(snapshot, :controls, %{"activities" => [], "interactions" => []})

    if snapshot.connected && Map.get(snapshot, :controls_available, false) do
      activities =
        Enum.map(controls["activities"], fn activity ->
          %{
            id: "activity:" <> activity["command_id"],
            label: "Work " <> activity["command_id"] <> " · " <> activity["execution_text"],
            detail: activity_detail(activity),
            action: if(activity["cancel_actionable"], do: :cancel, else: nil),
            input: %{command_id: activity["command_id"]}
          }
        end)

      prompts =
        Enum.flat_map(controls["interactions"], fn prompt ->
          input =
            Map.new(
              for key <- [:command_id, :request_id, :operation_id, :revision],
                  do: {key, prompt[Atom.to_string(key)]}
            )

          detail =
            prompt["text"] <>
              "\nStatus: " <> prompt["status"] <> " · revision " <> to_string(prompt["revision"])

          if prompt["protected"] do
            [
              %{
                id: row_id("review", input),
                label: "Permission review · " <> prompt["command_id"],
                detail:
                  detail <>
                    "\nReview in an authenticated browser with approval permission.\n" <>
                    (snapshot[:review_path] || "Open this conversation in your Arbor browser."),
                action: nil,
                input: nil
              }
            ]
          else
            Enum.map(Enum.with_index(prompt["choices"], 1), fn {choice, index} ->
              choice_input = Map.put(input, :choice_id, choice["id"])

              %{
                id: row_id("choice", choice_input),
                label: "Answer " <> to_string(index) <> ": " <> choice["label"],
                detail: detail,
                action: if(prompt["actionable"], do: :choose, else: nil),
                input: choice_input
              }
            end)
          end
        end)

      activities ++ prompts
    else
      []
    end
  end

  defp row_id(prefix, input),
    do: prefix <> ":" <> Base.url_encode64(JSON.encode!(input), padding: false)

  defp activity_detail(activity) do
    progress =
      case activity["progress"] do
        nil ->
          ""

        %{"type" => type, "node_id" => node} ->
          "\n" <> String.replace(type, "_", " ") <> if(node, do: ": " <> node, else: "")
      end

    activity["delivery_text"] <>
      "\n" <>
      activity["execution_text"] <>
      "\n" <>
      activity["cancellation_text"] <>
      progress <>
      if(activity["preview"] == "",
        do: "",
        else:
          "\nResponse preview" <>
            if(activity["preview_truncated"], do: " (partial)", else: "") <>
            ":\n" <> activity["preview"]
      )
  end

  defp selected_control(rows, id), do: Enum.find(rows, &(&1.id == id))

  defp controls_status(snapshot) do
    cond do
      not snapshot.connected ->
        "Current work unavailable while disconnected"

      snapshot.busy ->
        "Updating current work · actions paused"

      not Map.get(snapshot, :controls_available, false) ->
        "Current work could not be checked · F3 refresh"

      Map.get(snapshot, :controls_discovery, %{})[:incomplete] or
          Map.get(snapshot, :controls_discovery, %{})[:truncated] ->
        "Partial current work view · F8 earlier · F12 latest"

      Map.get(snapshot, :controls_discovery, %{})[:has_more] ->
        "More current work available · F8 earlier · F12 latest"

      true ->
        "Current work · F12 latest"
    end
  end

  defp send_draft(term), do: route_input(term, term.assigns.editor.draft)

  defp route_input(term, text) do
    case Arbor.classify_composer_input(text) do
      {:message, original} ->
        submit_message(assign(term, editor: Editor.draft(term.assigns.editor, original)))

      {:local, :quit} ->
        {:stop, term}

      {:local, :help} ->
        local_notice(
          term,
          "Local conversation commands\n/help — show this help\n/quit — close the terminal and its connection\n/retry — check the saved request with its original ID\n/refresh, /disconnect, /reconnect\n/older, /newer, /latest — bounded history\n/work — exact choices, cancellation and browser review\n/more-work, /latest-work — bounded work discovery\n/notices — read-only notices; PageUp older, Home latest\n/agents — show signed target directory or human sign-in guidance\n/attach TOKEN — explicitly select a target; pending work blocks switching\nAgent lifecycle management requires the authorized Console or CLI.\nRuntime slash commands are unavailable here.\nEscape dismisses help; your draft stays local."
        )

      {:local, :agents} ->
        directory(term)

      {:local, {:attach, token}} ->
        attach(term, token)

      {:local, :work} ->
        handle_event(:input, %{"key" => "F7"}, term)

      {:local, :notices} ->
        handle_event(:input, %{"key" => "F13"}, term)

      {:local, action} ->
        action(term, action)

      {:unavailable, :management} ->
        local_notice(
          term,
          "Agent management is unavailable in this conversation.\nUse the authorized Console or CLI.\nA chat session does not grant management permission."
        )

      {:unavailable, :runtime_command} ->
        local_notice(
          term,
          "Runtime slash commands are unavailable in this conversation.\nUse /help for local commands. Nothing was sent to the agent."
        )

      {:error, :invalid_input} ->
        local_notice(
          term,
          "Input must be valid UTF-8 and at most 32 KiB. Nothing was sent to the agent."
        )
    end
  end

  defp directory(term) do
    case Controller.act(term.assigns.controller, :directory) do
      :ok ->
        {:noreply,
         term
         |> assign(
           local_notice: nil,
           controls_open: false,
           notices_open: false,
           target_selected: nil
         )
         |> reset("targets")
         |> focus("target")}

      {:error, reason} ->
        local_notice(term, navigation_notice(reason))
    end
  end

  defp attach(term, token) do
    input = %{target: token, generation: term.assigns.snapshot.navigation.generation}

    case Controller.act(term.assigns.controller, :attach, input) do
      :ok ->
        {:noreply, assign(term, local_notice: nil, controls_open: false, notices_open: false)}

      {:error, reason} ->
        local_notice(term, navigation_notice(reason))
    end
  end

  defp draft_scope(%{
         navigation: %{bound: true, gateway: url, principal: principal, target: target}
       }) do
    scope = {url, principal, target}
    if Drafts.scope?(scope), do: scope
  end

  defp draft_scope(_), do: nil

  defp sign_in_text(instructions, width) do
    TerminalText.literal(
      "Sign in at " <> instructions.verification_uri <> "\nCode: " <> instructions.user_code
    )
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      line
      |> String.graphemes()
      |> Enum.chunk_every(max(width - 3, 1))
      |> Enum.map_join("\n", &Enum.join/1)
    end)
  end

  defp navigation_text(mode, width), do: local_text(navigation_title(mode), width)
  defp navigation_notice_text(notice, width), do: local_text(navigation_notice(notice), width)

  defp navigation_title(:signed),
    do:
      "Signed target directory · F2 loads/refreshes. Select or enter a token; Enter explicitly attaches."

  defp navigation_title(_),
    do:
      "Human chat only. Get an exact agent ID from the authenticated Home at /home; Enter starts a fresh browser sign-in. Tab focuses these scrollable instructions."

  defp navigation_info_height(height, :signed), do: min(max(div(height - 14, 2), 2), 7)
  defp navigation_info_height(height, _), do: max(height - 14, 1)

  defp target_label(row),
    do:
      TerminalText.literal(
        row.display_name <>
          " · " <> row.agent_id <> if(row.running, do: " · running", else: " · stopped")
      )

  defp target_row_id(generation, target), do: to_string(generation) <> ":" <> target

  defp navigation_notice(:delivery_pending),
    do:
      "Finish or reconcile the current request with /retry before switching. Its owner and request ID were retained."

  defp navigation_notice(:cleanup_unconfirmed),
    do:
      "The previous connection cleanup was not confirmed. No new conversation was attached. Close this terminal and check access before signing in again."

  defp navigation_notice(:exact_target_required),
    do:
      "Human chat sign-in requires an exact agent ID from the authenticated Home. A chat lease cannot list, resolve or manage agents."

  defp navigation_notice(:stale_selection),
    do: "The target selection changed. Select the current exact target and attach again."

  defp navigation_notice(:navigation_unavailable),
    do:
      "Target navigation is unavailable in this embedded conversation. Use the authorized Console or CLI."

  defp navigation_notice(:login_failed),
    do:
      "Target sign-in could not complete. Select the exact target and start a new browser sign-in."

  defp navigation_notice(_),
    do:
      "Target navigation could not complete. No new conversation was attached; check access and try explicitly again."

  defp local_notice(term, text),
    do:
      {:noreply,
       term
       |> assign(local_notice: text, controls_open: false, notices_open: false)
       |> reset("local-notice")
       |> focus(if(term.assigns.snapshot.navigation.directory, do: "target", else: "draft"))}

  defp submit_message(term) do
    id = "terminal_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    case Editor.submit(term.assigns.editor, term.assigns.snapshot, id) do
      {:send, request, editor} ->
        :ok = Controller.act(term.assigns.controller, :send, request)
        {:noreply, assign(term, editor: editor, local_notice: nil)}

      {:ignored, editor} ->
        {:noreply, assign(term, editor: editor)}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      Map.put(
        assigns,
        :selected_control,
        selected_control(assigns.control_rows, assigns.control_selected)
      )

    ~H"""
    <box class="w-screen h-screen">
      <box class="w-full height-1 overflow-hidden text-green font-bold">
        ARBOR / BREEZE · conversation
      </box>
      <box class="w-full height-1 overflow-hidden">{connection_status(@snapshot, @browsing)}</box>
      <box
        :if={@snapshot.navigation.directory && is_nil(@local_notice)}
        class={"w-full height-#{max(@breeze.terminal.height - 14, 1)}"}
      >
        <.scroll
          id="navigation-info"
          class={"height-#{navigation_info_height(@breeze.terminal.height, @snapshot.navigation.mode)}"}
        >
          <box>{navigation_text(@snapshot.navigation.mode, @breeze.terminal.width)}</box>
          <box>Gateway: {TerminalText.literal(@snapshot.navigation.gateway)}</box>
          <box :if={@snapshot.navigation.hint}>
            Remembered target hint: {TerminalText.literal(@snapshot.navigation.hint)} · explicit attach required
          </box>
          <box :if={@snapshot.navigation.busy}>Target request in progress · no new chat send</box>
          <box :if={@snapshot.navigation.notice}>
            {navigation_notice_text(@snapshot.navigation.notice, @breeze.terminal.width)}
          </box>
          <box :if={@snapshot.navigation.truncated}>
            Directory truncated · enter an exact ID or alias
          </box>
          <box :if={@snapshot.navigation.sign_in}>
            {sign_in_text(@snapshot.navigation.sign_in, @breeze.terminal.width)}
          </box>
        </.scroll>
        <.list
          :if={@snapshot.navigation.mode == :signed}
          id="targets"
          class={"w-full height-#{max(@breeze.terminal.height - 14 - navigation_info_height(@breeze.terminal.height, :signed), 1)} border focus:border-green"}
          list-selected={@target_selected}
          br-change="targets:select"
        >
          <:item
            :for={row <- @snapshot.navigation.rows}
            value={target_row_id(@snapshot.navigation.generation, row.agent_id)}
          >
            {target_label(row)}
          </:item>
        </.list>
      </box>
      <.scroll
        :if={!@snapshot.navigation.directory && !@controls_open && !@notices_open && is_nil(@local_notice)}
        id="transcript"
        class={"height-#{max(@breeze.terminal.height - 14, 1)}"}
        scroll-autoscroll="bottom"
      >
        <box
          :for={message <- @snapshot.projection["messages"]}
          :if={@snapshot.connected}
          class="min-height-2"
        >
          <box class="text-green">{TerminalText.literal(message["role"])}</box>
          <box :if={message["status_text"]} class="text-yellow">
            {TerminalText.literal(message["status_text"])}
          </box>
          <box>{TerminalText.literal(message["text"])}</box>
        </box>
      </.scroll>
      <box
        :if={!@snapshot.navigation.directory && @controls_open && is_nil(@local_notice)}
        class={"w-full height-#{max(@breeze.terminal.height - 14, 1)}"}
      >
        <box class="w-full height-1 overflow-hidden text-green">{controls_status(@snapshot)}</box>
        <.list
          id="controls"
          class={"w-full height-#{min(max(div(@breeze.terminal.height - 14, 2), 3), 8)} border focus:border-green"}
          list-selected={@control_selected}
          br-change="controls:select"
        >
          <:item :for={row <- @control_rows} value={row.id}>{TerminalText.literal(row.label)}</:item>
        </.list>
        <.scroll
          id="control-detail"
          class={"w-full height-#{max(@breeze.terminal.height - 15 - min(max(div(@breeze.terminal.height - 14, 2), 3), 8), 1)}"}
        >
          <box :if={@selected_control}>{TerminalText.literal(@selected_control.detail)}</box>
          <box :if={control_actionable?(@snapshot, @selected_control)}>
            Enter requests {if @selected_control.action == :cancel do
              "cancellation"
            else
              "this answer"
            end}; wait for the host result.
          </box>
          <box :if={is_nil(@selected_control)}>
            Select current work with arrow keys. No action is selected.
          </box>
        </.scroll>
      </box>
      <box
        :if={!@snapshot.navigation.directory && @notices_open && is_nil(@local_notice)}
        class={"w-full height-#{max(@breeze.terminal.height - 14, 1)}"}
      >
        <box class="w-full height-1 overflow-hidden text-green">{notice_status(@snapshot)}</box>
        <.scroll id="notices" class={"w-full height-#{max(@breeze.terminal.height - 15, 1)}"}>
          <box :for={notice <- Map.get(@snapshot.projection, "notices", [])} class="min-height-3">
            <box class="text-green">{notice_label(notice)}</box>
            <box>{TerminalText.literal(notice["text"])}</box>
          </box>
        </.scroll>
      </box>
      <.scroll
        :if={@local_notice}
        id="local-notice"
        class={"height-#{max(@breeze.terminal.height - 14, 1)}"}
      >
        <box>{local_text(@local_notice, @breeze.terminal.width)}</box>
      </.scroll>
      <box class="w-full height-1 overflow-hidden">
        {if @browsing do
          "Browsing history"
        else
          "Recent messages"
        end} · {length(@snapshot.projection["messages"])} displayed
      </box>
      <box class="w-full height-1 overflow-hidden">
        F7 work · Shift+F7 notices · F9/F10/F11 history · Tab focus
      </box>
      <box class="w-full height-1 overflow-hidden text-red">
        {TerminalText.literal(@snapshot.error || @paste_notice || "")}
      </box>
      <box class="w-full height-1 overflow-hidden">{delivery_status(@snapshot)}</box>
      <.textarea
        :if={@snapshot.navigation.directory}
        id="target"
        class="w-full height-5 border focus:border-green"
        textarea-value={@target_input}
        textarea-placeholder="Exact target or signed alias · Enter explicitly attaches"
        textarea-submit-on-enter={true}
        br-change="target:change"
        br-submit="target:attach"
        default-focus
      />
      <.textarea
        :if={!@snapshot.navigation.directory}
        id="draft"
        class="w-full height-5 border focus:border-green"
        textarea-value={@editor.draft}
        textarea-placeholder="Message · Enter send · Shift+Enter newline"
        textarea-submit-on-enter={true}
        br-change="chat:draft"
        br-submit="chat:send"
        default-focus
      />
      <box class="w-full height-1 overflow-hidden">
        F3 refresh · F4 disconnect · F5 reconnect · F6 check / retry
      </box>
      <box class="w-full height-1 overflow-hidden">
        F1 /help · F2 targets · Esc panel/back/exit · Text only
      </box>
    </box>
    """
  end

  # Local guidance contains no host data. Wrap its static paragraphs so narrow
  # terminals can read the whole explanation through the native scroll region.
  defp local_text(text, width) do
    width = max(width - 2, 1)

    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      line
      |> String.split(" ")
      |> Enum.reduce("", fn word, acc ->
        current = acc |> String.split("\n") |> List.last()

        cond do
          acc == "" -> word
          String.length(current) + 1 + String.length(word) <= width -> acc <> " " <> word
          true -> acc <> "\n" <> word
        end
      end)
    end)
    |> TerminalText.literal()
  end

  defp notice_label(notice),
    do: TerminalText.literal(notice["kind"] <> " · " <> notice["timestamp"])

  defp notice_status(snapshot) do
    case Map.get(snapshot, :notices_status, :unavailable) do
      :checking ->
        "Checking notices · read only"

      :available ->
        if(Map.get(snapshot.projection, "notices", []) == [], do: "No notices", else: "Notices") <>
          " through #{snapshot.notice_window.through} · head #{snapshot.notice_window.head} · PageUp older · Home latest"

      :unsupported ->
        "Notices require a human identity"

      _ ->
        "Notices unavailable · F3 refresh"
    end
  end

  defp connection_status(%{connected: false}, _browsing), do: "Disconnected · F5 reconnect"
  defp connection_status(_snapshot, true), do: "Connected · browsing history · F11 latest"
  defp connection_status(_snapshot, false), do: "Connected · following host"

  defp paste_notice(:too_large),
    do: "Paste exceeds the 32 KiB turn limit; split it into smaller messages."

  defp paste_notice(:incomplete), do: "Paste did not finish. Try pasting again."
  defp paste_notice(:target_changed), do: "The input changed while pasting. Paste again."
  defp paste_notice(_), do: "Paste could not be inserted. Try again."

  defp delivery_status(%{pending_id: id}) when not is_nil(id),
    do: "Admission unconfirmed · F6 checks the saved request"

  defp delivery_status(%{receipt: %{"status" => status}}), do: "Delivery " <> status
  defp delivery_status(%{send_allowed: false}), do: "Waiting for the host; your draft stays local"
  defp delivery_status(_), do: "Ready"
end
