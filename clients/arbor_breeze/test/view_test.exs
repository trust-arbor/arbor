defmodule ArborBreeze.ViewTest do
  use ExUnit.Case, async: true
  alias ArborBreeze.{Controller, View}

  defmodule Host do
    @engagement "eng_0123456789abcdef0123456789abcdef"

    def start(count) do
      observer = self()

      Agent.start_link(fn ->
        %{
          entries: for(n <- 1..count, do: entry(n, "history #{n}", "assistant")),
          commands: %{},
          calls: [],
          mode: :normal,
          cursor: 0,
          activities: [],
          prompts: [],
          controls_unavailable: false,
          hold: nil,
          observer: observer
        }
      end)
    end

    def options(host) do
      [
        caller: "human_fixture",
        target: "agent_fixture",
        poll_interval_ms: 100,
        proof_provider: fn _ -> {:ok, [session_token: "private-fixture-proof"]} end,
        adapter_options: [transport: fn context, proof -> request(host, context, proof) end]
      ]
    end

    def controls(host, activities, prompts),
      do: Agent.update(host, &%{&1 | activities: activities, prompts: prompts})

    def mode(host, mode), do: Agent.update(host, &%{&1 | mode: mode})
    def calls(host), do: Agent.get(host, & &1.calls)
    def entries(host), do: Agent.get(host, & &1.entries)

    def append(host, text),
      do:
        Agent.update(host, fn state ->
          %{
            state
            | entries: state.entries ++ [entry(length(state.entries) + 1, text, "assistant")]
          }
        end)

    defp request(host, context, session_token: "private-fixture-proof") do
      state = Agent.get(host, & &1)

      if state.hold == context.operation do
        Agent.update(host, &%{&1 | hold: nil})
        send(state.observer, {:native_host_blocked, context.operation, self()})

        receive do
          :release_host -> :ok
        after
          3_000 -> raise "native host not released"
        end
      end

      Agent.get_and_update(host, fn state ->
        state = %{state | calls: state.calls ++ [context]}

        if state.mode == :denied do
          {{:error, :unauthorized}, state}
        else
          respond(context, state)
        end
      end)
    end

    defp respond(%{operation: :window, options: opts}, state) do
      head = opts[:through] || length(state.entries)
      eligible = Enum.filter(state.entries, &(&1.entry_ordinal <= head))
      limit = opts[:limit]

      entries =
        cond do
          opts[:before] ->
            eligible |> Enum.filter(&(&1.entry_ordinal < opts[:before])) |> Enum.take(-limit)

          Keyword.has_key?(opts, :after) ->
            eligible |> Enum.filter(&(&1.entry_ordinal > opts[:after])) |> Enum.take(limit)

          true ->
            Enum.take(eligible, -limit)
        end

      first = if entries == [], do: 0, else: hd(entries).entry_ordinal
      last = if entries == [], do: 0, else: List.last(entries).entry_ordinal

      page = %{
        engagement_id: @engagement,
        entries: entries,
        head: head,
        first: first,
        last: last,
        has_older: Enum.any?(eligible, &(&1.entry_ordinal < first)),
        has_newer: Enum.any?(eligible, &(&1.entry_ordinal > last))
      }

      {{:ok, page}, state}
    end

    # Existing fixture intentionally lacks notices; refuse this optional read
    # without crashing its shared Agent state. Notice behavior has its own suite.
    defp respond(%{operation: :notices}, state),
      do: {{:error, :unsupported_conversation_capability}, state}

    defp respond(%{operation: :activity}, state) do
      if state.controls_unavailable do
        {{:error, :conversation_unavailable}, state}
      else
        {{:ok,
          %{
            commands: state.activities,
            source_watermark: 9,
            index_watermark: 9,
            incomplete: false,
            has_more: false,
            next_cursor: nil,
            engagement_id: @engagement,
            truncated: false
          }}, state}
      end
    end

    defp respond(%{operation: :interactions, input: id}, state),
      do:
        {{:ok,
          %{
            interactions: Enum.filter(state.prompts, &(&1.command_id == id)),
            command_id: id,
            engagement_id: @engagement
          }}, state}

    defp respond(%{operation: :cancel, input: id}, state) do
      activity = Enum.find(state.activities, &(&1.command_id == id))

      if activity do
        send(state.observer, {:native_effect, :cancel, id})

        activities =
          Enum.map(state.activities, fn value ->
            if value.command_id == id,
              do: %{value | cancellation: %{status: :requested}},
              else: value
          end)

        {{:ok,
          %{
            command_id: id,
            task_id: activity.task_id,
            delivery_status: activity.delivery_status,
            cancellation: %{status: :requested},
            termination_observation: :unconfirmed,
            engagement_id: @engagement
          }}, %{state | activities: activities}}
      else
        {{:error, :not_found}, state}
      end
    end

    defp respond(%{operation: :interaction_choice, input: input}, state) do
      prompt =
        Enum.find(state.prompts, fn prompt ->
          Enum.all?(
            [:command_id, :request_id, :operation_id, :revision],
            &(prompt[&1] == input[&1])
          )
        end)

      if prompt && prompt.status == :pending &&
           Enum.any?(prompt.choices, &(&1.id == input.choice_id)) do
        send(state.observer, {:native_effect, :choose, input})

        prompts =
          Enum.map(state.prompts, fn value ->
            if value.request_id == input.request_id,
              do: %{value | status: :responded},
              else: value
          end)

        {{:ok,
          %{
            command_id: input.command_id,
            engagement_id: @engagement,
            request_id: input.request_id,
            operation_id: input.operation_id,
            revision: input.revision,
            status: :responded
          }}, %{state | prompts: prompts}}
      else
        {{:error, :unauthorized}, state}
      end
    end

    defp respond(%{operation: :submit, input: %{id: id, text: text}}, state) do
      case state.commands[id] do
        nil ->
          response = "Host answer to " <> text
          ordinal = length(state.entries) + 1

          command = %{
            id: id,
            name: "chat.send",
            text: text,
            principal_id: "human_fixture",
            agent_id: "agent_fixture",
            engagement_id: @engagement,
            status: :completed,
            outcome: %{status: :completed, text: response},
            admitted_cursor: state.cursor + 1,
            updated_cursor: state.cursor + 3
          }

          next = %{
            state
            | entries:
                state.entries ++
                  [entry(ordinal, text, "user"), entry(ordinal + 1, response, "assistant")],
              commands: Map.put(state.commands, id, command),
              cursor: state.cursor + 3,
              mode: :normal
          }

          if state.mode == :uncertain_once,
            do: {{:error, :transport_timeout}, next},
            else: {{:ok, command}, next}

        command ->
          {{:ok, command}, state}
      end
    end

    defp respond(%{operation: :command, input: id}, state),
      do:
        {if(state.commands[id], do: {:ok, state.commands[id]}, else: {:error, :not_found}), state}

    defp entry(ordinal, text, role),
      do: %{
        id: "host_#{ordinal}",
        role: role,
        content: text,
        timestamp: "2026-10-02T00:00:00Z",
        entry_ordinal: ordinal
      }
  end

  defp start(count \\ 60, connection_overrides \\ []) do
    {:ok, host} = Host.start(count)

    {:ok, controller} =
      Controller.start(
        connection_options: Keyword.merge(Host.options(host), connection_overrides)
      )

    session = Breeze.Test.start!(View, size: {100, 28}, start_opts: [controller: controller])

    on_exit(fn ->
      # The view can finish while the released test helper is between its
      # alive? check and stop call. Only that exact already-dead outcome is
      # successful cleanup; other stop failures still fail the test.
      try do
        Breeze.Test.stop(session)
      catch
        :exit, {:noproc, {GenServer, :stop, _args}} -> :ok
      end

      Controller.close(controller)
      if Process.alive?(host), do: Agent.stop(host)
    end)

    eventually(fn -> assigns(session).snapshot.connected end)
    Breeze.Test.render_text!(session)
    assert Breeze.Test.focused(session) == "draft"
    {host, controller, session}
  end

  defp assigns(session), do: Breeze.Test.metadata(session).assigns

  # Test.input accepts decoded key events. Ordinary typing is one grapheme per
  # key; combined text uses the public Breeze.Implicit batch event contract.
  defp type_text(session, text),
    do: Enum.each(String.graphemes(text), &Breeze.Test.input(session, &1))

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: assert(fun.(), "Native surface never reached the required state")

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, attempts - 1)
        )
  end

  defp activity(id \\ "work_1") do
    %{
      command_id: id,
      task_id: "private_task_" <> id,
      delivery_status: :uncertain,
      cancellation: %{status: :none},
      admitted_cursor: 1,
      execution: :running,
      preview: "Live response café 東京",
      preview_truncated: true,
      progress: %{type: :stage_started, node_id: "compute"}
    }
  end

  defp prompt(revision \\ 1, kind \\ "choice") do
    %{
      command_id: "work_1",
      request_id: "request_#{revision}",
      operation_id: "operation_#{revision}",
      revision: 1,
      kind: kind,
      status: :pending,
      text: "Choose café 東京",
      choices:
        if(kind == "approval",
          do: [],
          else: [%{id: "first", label: "Same label"}, %{id: "second", label: "Same label"}]
        ),
      deadline_unix_ms: 9_999_999_999_999
    }
  end

  test "native retained partial replies show their status without changing text or sending a turn" do
    {host, _controller, session} = start(1)

    entries =
      for {status, ordinal} <- Enum.with_index(~w(cancelled interrupted complete), 2) do
        %{
          id: "host_#{ordinal}",
          role: "assistant",
          content: "history #{ordinal}",
          timestamp: "2026-10-02T00:00:00Z",
          entry_ordinal: ordinal,
          status: status
        }
      end

    Agent.update(host, &%{&1 | entries: &1.entries ++ entries})

    Breeze.Test.input(session, "F3")
    eventually(fn -> Breeze.Test.render_text!(session) =~ "Cancelled · partial response" end)
    frame = Breeze.Test.render_text!(session)
    assert frame =~ "Interrupted · partial response"
    assert frame =~ "history 1"
    assert frame =~ "history 2"
    assert frame =~ "history 3"
    assert frame =~ "history 4"

    assert Enum.count(
             assigns(session).snapshot.projection["messages"],
             &Map.has_key?(&1, "status_text")
           ) == 2

    assert assigns(session).snapshot.projection["speech"] == []
    refute Enum.any?(Host.calls(host), &(&1.operation == :submit))
  end

  test "native local commands preserve saved delivery and help works during a blocked read and disconnect" do
    {host, _controller, session} = start()
    Host.mode(host, :uncertain_once)
    type_text(session, "  café 東京")
    Breeze.Test.input(session, %{"key" => "Enter", "shiftKey" => true})
    type_text(session, "second line  ")
    text = assigns(session).editor.draft
    Breeze.Test.input(session, "Enter")
    eventually(fn -> not is_nil(assigns(session).snapshot.pending_id) end)
    id = assigns(session).snapshot.pending_id
    Breeze.Test.event(session, "chat:draft", %{value: "independent newer draft"})
    Agent.update(host, &%{&1 | hold: :window})
    Breeze.Test.input(session, "F3")
    assert_receive {:native_host_blocked, :window, worker}
    Breeze.Test.input(session, "F1")
    assert Breeze.Test.render_text!(session) =~ "Local conversation commands"
    assert assigns(session).snapshot.pending_id == id
    assert assigns(session).editor.submitted.id == id
    assert length(Enum.filter(Host.calls(host), &(&1.operation == :submit))) == 1
    Breeze.Test.event(session, "chat:send", %{value: "\t/model bad"})
    assert Breeze.Test.render_text!(session) =~ "Nothing was sent"
    Breeze.Test.event(session, "chat:send", %{value: "/agents stop private"})
    assert Breeze.Test.render_text!(session) =~ "does not grant management"
    assert assigns(session).snapshot.pending_id == id
    send(worker, :release_host)
    eventually(fn -> not assigns(session).snapshot.busy end)
    Breeze.Test.event(session, "chat:send", %{value: "/retry"})
    eventually(fn -> assigns(session).snapshot.pending_id == nil end)
    assert Enum.any?(Host.calls(host), &(&1.operation == :command and &1.input == id))

    assert [%{input: %{id: ^id, text: ^text}}] =
             Enum.filter(Host.calls(host), &(&1.operation == :submit))

    assert assigns(session).editor.draft == "independent newer draft"
    Breeze.Test.event(session, "chat:send", %{value: "/disconnect"})
    eventually(fn -> not assigns(session).snapshot.connected end)
    Breeze.Test.event(session, "chat:send", %{value: "/help"})
    assert Breeze.Test.render_text!(session) =~ "Local conversation commands"
    Breeze.Test.input(session, "Escape")
    assert Breeze.Test.focused(session) == "draft"
    Breeze.Test.event(session, "chat:send", %{value: "/reconnect"})
    eventually(fn -> assigns(session).snapshot.connected end)
    Breeze.Test.event(session, "chat:send", %{value: "/older"})
    eventually(fn -> assigns(session).browsing end)
    Breeze.Test.event(session, "chat:send", %{value: "/latest"})
    eventually(fn -> not assigns(session).browsing end)
    Breeze.Test.event(session, "chat:send", %{value: "/work"})
    assert Breeze.Test.focused(session) == "controls"

    refute Enum.any?(
             Host.calls(host),
             &(&1.operation == :submit and
                 String.starts_with?(String.trim_leading(&1.input.text), "/"))
           )
  end

  test "native invalid input cannot replace the draft or create a host command" do
    {host, _controller, session} = start()
    type_text(session, "retained café 東京")

    for input <- [nil, <<255>>, String.duplicate("x", 32_769)] do
      Breeze.Test.event(session, "chat:draft", %{value: input})
      Breeze.Test.event(session, "chat:send", %{value: input})
      assert assigns(session).editor.draft == "retained café 東京"
      assert Breeze.Test.render_text!(session) =~ "Input must be valid UTF-8"
    end

    refute Enum.any?(Host.calls(host), &(&1.operation == :submit))
  end

  test "typed native help remains local and quit performs ordinary surface cleanup" do
    {host, controller, session} = start()
    type_text(session, "  /help")
    Breeze.Test.input(session, "Enter")
    assert Breeze.Test.render_text!(session) =~ "Local conversation commands"
    assert assigns(session).editor.draft == "  /help"
    refute Enum.any?(Host.calls(host), &(&1.operation == :submit))
    monitor = Process.monitor(controller)
    Breeze.Test.event(session, "chat:send", %{value: "/quit"})
    assert_receive {:DOWN, ^monitor, :process, ^controller, :normal}
  end

  test "native work focus submits the exact duplicate-label choice and preserves the multiline draft" do
    {host, _controller, session} = start()
    Host.controls(host, [activity()], [prompt()])
    eventually(fn -> length(assigns(session).control_rows) == 3 end)
    type_text(session, "independent 東京")
    Breeze.Test.input(session, %{"key" => "Enter", "shiftKey" => true})
    type_text(session, "second line")
    draft = assigns(session).editor.draft
    Breeze.Test.input(session, "F7")
    Breeze.Test.render_text!(session)
    assert Breeze.Test.focused(session) == "controls"
    Breeze.Test.input(session, "ArrowDown")
    Breeze.Test.input(session, "ArrowDown")
    Breeze.Test.input(session, "ArrowDown")
    assert Breeze.Test.render_text!(session) =~ "Answer 2: Same label"
    Breeze.Test.input(session, "Enter")

    assert_receive {:native_effect, :choose,
                    %{
                      command_id: "work_1",
                      request_id: "request_1",
                      operation_id: "operation_1",
                      revision: 1,
                      choice_id: "second"
                    }}

    eventually(fn ->
      Enum.any?(
        assigns(session).snapshot.controls["interactions"],
        &(&1["status"] == "responded")
      )
    end)

    assert assigns(session).editor.draft == draft
    Breeze.Test.input(session, "Escape")
    assert Breeze.Test.focused(session) == "draft"
    assert assigns(session).editor.draft == draft

    assert [%{input: %{choice_id: "second"}}] =
             Enum.filter(Host.calls(host), &(&1.operation == :interaction_choice))

    refute Enum.any?(Host.calls(host), &(&1.operation == :submit))
  end

  test "native choice readiness reflects the actual blocked read before exact answer activation" do
    assert_control_readiness(:choose)
  end

  test "native cancellation readiness reflects the actual blocked read before exact cancellation" do
    assert_control_readiness(:cancel)
  end

  defp assert_control_readiness(action) do
    # A long polling interval makes this a deterministic held-read transition,
    # not a race against the next background refresh or a timing-only retry.
    {host, _controller, session} = start(60, poll_interval_ms: 60_000)
    session = Breeze.Test.resize(session, {100, 40})
    eventually(fn -> not assigns(session).snapshot.busy end)
    Host.controls(host, [activity()], if(action == :choose, do: [prompt()], else: []))
    Breeze.Test.input(session, "F3")

    eventually(fn ->
      assigns(session).control_rows != [] and not assigns(session).snapshot.busy
    end)

    type_text(session, "retained draft café 東京")
    Breeze.Test.input(session, "F7")
    Breeze.Test.render_text!(session)
    Breeze.Test.input(session, "ArrowDown")
    if action == :choose, do: Breeze.Test.input(session, "ArrowDown")
    selected = assigns(session).control_selected

    caption =
      if action == :choose, do: "Enter requests this answer", else: "Enter requests cancellation"

    assert Breeze.Test.render_text!(session) =~ caption

    Agent.update(host, &%{&1 | hold: :window})
    Breeze.Test.input(session, "F3")
    assert_receive {:native_host_blocked, :window, worker}
    eventually(fn -> assigns(session).snapshot.busy end)

    try do
      frame = Breeze.Test.render_text!(session)
      assert frame =~ "Updating current work · actions paused"
      refute frame =~ "Enter requests"
      assert assigns(session).control_selected == selected
      assert assigns(session).editor.draft == "retained draft café 東京"
      Breeze.Test.input(session, "Enter")
      refute Enum.any?(Host.calls(host), &(&1.operation in [:cancel, :interaction_choice]))
    after
      send(worker, :release_host)
    end

    eventually(fn -> not assigns(session).snapshot.busy end)
    assert assigns(session).control_selected == selected
    assert Breeze.Test.render_text!(session) =~ caption
    Breeze.Test.input(session, "Enter")

    if action == :choose do
      assert_receive {:native_effect, :choose,
                      %{
                        command_id: "work_1",
                        request_id: "request_1",
                        operation_id: "operation_1",
                        revision: 1,
                        choice_id: "first"
                      }}
    else
      assert_receive {:native_effect, :cancel, "work_1"}
    end

    assert assigns(session).editor.draft == "retained draft café 東京"
  end

  test "native cancellation keeps uncertain running work until a positive host termination" do
    {host, _controller, session} = start()
    Host.controls(host, [activity()], [])
    eventually(fn -> length(assigns(session).control_rows) == 1 end)
    Breeze.Test.input(session, "F7")
    Breeze.Test.render_text!(session)
    Breeze.Test.input(session, "ArrowDown")
    Breeze.Test.input(session, "Enter")
    assert_receive {:native_effect, :cancel, "work_1"}

    eventually(fn ->
      assigns(session).snapshot.controls["activities"] |> hd() |> Map.fetch!("cancellation") == %{
        "status" => "requested"
      }
    end)

    frame = Breeze.Test.render_text!(session)
    assert frame =~ "Execution observed running"
    assert frame =~ "Delivery outcome uncertain"
    assert frame =~ "termination unconfirmed"
    refute frame =~ "Cancellation confirmed"
    Breeze.Test.input(session, "Enter")
    refute_receive {:native_effect, :cancel, _}, 100
  end

  test "security regression: changed prompt retires selected identity and busy/revoked controls admit no second effect" do
    {host, _controller, session} = start()
    Host.controls(host, [activity()], [prompt()])
    eventually(fn -> length(assigns(session).control_rows) == 3 end)
    Breeze.Test.input(session, "F7")
    Breeze.Test.render_text!(session)
    Breeze.Test.input(session, "ArrowDown")
    Breeze.Test.input(session, "ArrowDown")
    old = assigns(session).control_selected
    Host.controls(host, [activity()], [prompt(2)])
    eventually(fn -> assigns(session).control_selected == nil end)
    Breeze.Test.input(session, "Enter")
    refute_receive {:native_effect, _, _}, 100
    Breeze.Test.event(session, "controls:select", %{value: old})
    Breeze.Test.input(session, "Enter")
    refute_receive {:native_effect, _, _}, 100
    Breeze.Test.input(session, "F7")
    Breeze.Test.render_text!(session)
    Breeze.Test.input(session, "ArrowDown")
    Breeze.Test.input(session, "ArrowDown")
    Agent.update(host, &%{&1 | hold: :interaction_choice})
    Breeze.Test.input(session, "Enter")
    assert_receive {:native_host_blocked, :interaction_choice, worker}
    eventually(fn -> assigns(session).snapshot.busy end)
    Breeze.Test.input(session, "ArrowDown")
    Breeze.Test.input(session, "Enter")
    send(worker, :release_host)

    assert_receive {:native_effect, :choose,
                    %{request_id: "request_2", operation_id: "operation_2", revision: 1}}

    refute_receive {:native_effect, _, _}, 100
    Host.mode(host, :denied)
    eventually(fn -> assigns(session).snapshot.private_cleared end)
    assert assigns(session).control_rows == []
    assert assigns(session).editor.draft == ""
    refute Breeze.Test.render_text!(session) =~ "Choose café"
    Breeze.Test.input(session, "F7")
    Breeze.Test.render_text!(session)
    Breeze.Test.input(session, "Enter")
    refute_receive {:native_effect, _, _}, 100
  end

  test "security regression: protected prompt remains review-only and literal OSC/CSI never reaches the native frame" do
    {host, _controller, session} = start()
    session = Breeze.Test.resize(session, {100, 40})

    attack =
      "Original principal agent_fixture\nResource arbor://action/test\nAction test\n" <>
        <<27>> <> "]52;c;clipboard" <> <<7>> <> " 東京\n" <> <<155::utf8>> <> "2J"

    Host.controls(host, [activity()], [%{prompt(1, "approval") | text: attack}])
    eventually(fn -> length(assigns(session).control_rows) == 2 end)
    Breeze.Test.input(session, "F7")
    Breeze.Test.render_text!(session)
    Breeze.Test.input(session, "ArrowDown")
    Breeze.Test.input(session, "ArrowDown")
    frame = Breeze.Test.render_text!(session)
    assert frame =~ "Original principal agent_fixture"
    assert frame =~ "/conversation/agent_fixture"
    assert frame =~ "\\u001B]52"
    assert frame =~ "東京"
    raw_frame = Breeze.Test.render!(session)
    refute raw_frame =~ <<27>> <> "]52"
    refute raw_frame =~ <<155::utf8>>
    Breeze.Test.input(session, "Enter")
    refute_receive {:native_effect, _, _}, 100
    refute Enum.any?(Host.calls(host), &(&1.operation == :interaction_approval))
  end

  test "security regression: the raw native transcript cannot emit host OSC or C1 controls" do
    {host, _controller, session} = start()

    attack =
      "literal marker " <>
        <<27>> <> "]52;c;clipboard" <> <<7>> <> " café 東京 " <> <<155::utf8>> <> "2J"

    Host.append(host, attack)

    eventually(fn ->
      Enum.any?(assigns(session).snapshot.projection["messages"], &(&1["text"] == attack))
    end)

    raw_frame = Breeze.Test.render!(session)
    refute raw_frame =~ <<27>> <> "]52"
    refute raw_frame =~ <<155::utf8>>
    assert raw_frame =~ "\\u001B]52"
    assert Breeze.Test.render_text!(session) =~ "café 東京"
  end

  test "actual native textarea edits Unicode, newline and decoded text batch across resize and focus" do
    {host, _controller, session} = start()
    type_text(session, "日本語 👋")
    Breeze.Test.input(session, %{"key" => "Enter", "shiftKey" => true})
    Breeze.Test.input(session, %{"key" => "paste é", "__batched_printable__" => true})
    Breeze.Test.input(session, %{"key" => "Enter", "shiftKey" => true})
    type_text(session, "middle line")
    Breeze.Test.input(session, %{"key" => "Enter", "shiftKey" => true})
    type_text(session, "next line")
    Breeze.Test.input(session, %{"key" => "Enter", "shiftKey" => true})
    type_text(session, "last line")
    text = "日本語 👋\npaste é\nmiddle line\nnext line\nlast line"
    assert assigns(session).editor.draft == text

    session = Breeze.Test.resize(session, {36, 20})
    frame = Breeze.Test.render_text!(session)
    assert frame =~ "last line"
    refute frame =~ "日本語"
    Enum.each(1..4, fn _ -> Breeze.Test.input(session, "ArrowUp") end)
    assert Breeze.Test.render_text!(session) =~ "日本語"
    assert assigns(session).editor.draft == text
    Enum.each(1..4, fn _ -> Breeze.Test.input(session, "ArrowDown") end)
    assert Breeze.Test.render_text!(session) =~ "last line"
    Breeze.Test.focus(session, "transcript")
    Breeze.Test.input(session, "ArrowUp")
    assert assigns(session).editor.draft == text
    Breeze.Test.focus(session, "draft")
    Breeze.Test.input(session, "Enter")
    eventually(fn -> assigns(session).editor.draft == "" end)
    assert [%{input: %{text: ^text}}] = Enum.filter(Host.calls(host), &(&1.operation == :submit))

    eventually(fn ->
      Enum.any?(assigns(session).snapshot.projection["messages"], &(&1["text"] == text))
    end)

    assert Enum.any?(Host.entries(host), &(&1.content == text and &1.role == "user"))
    assert assigns(session).snapshot.receipt["status"] == "completed"
  end

  test "uncertain admission keeps the draft and checks the same ID before retry" do
    {host, _controller, session} = start()
    Host.mode(host, :uncertain_once)
    type_text(session, "uncertain 日本語")
    Breeze.Test.input(session, "Enter")

    eventually(fn ->
      not is_nil(assigns(session).snapshot.pending_id) and not assigns(session).snapshot.busy
    end)

    id = assigns(session).snapshot.pending_id
    assert assigns(session).editor.draft == "uncertain 日本語"
    type_text(session, " changed")
    Breeze.Test.input(session, "Enter")
    assert length(Enum.filter(Host.calls(host), &(&1.operation == :submit))) == 1
    assert assigns(session).snapshot.pending_id == id
    Breeze.Test.input(session, "F6")

    eventually(fn ->
      assigns(session).snapshot.pending_id == nil and assigns(session).editor.submitted == nil
    end)

    assert assigns(session).editor.draft == "uncertain 日本語 changed"
    assert Enum.any?(Host.calls(host), &(&1.operation == :command and &1.input == id))
    assert length(Enum.filter(Host.calls(host), &(&1.operation == :submit))) == 1

    assert Enum.count(Host.entries(host), &(&1.role == "user" and &1.content == "uncertain 日本語")) ==
             1
  end

  test "automatic host updates and authenticated access loss clear active native state" do
    {host, _controller, session} = start()
    Host.append(host, "new authoritative message")

    eventually(fn ->
      Enum.any?(
        assigns(session).snapshot.projection["messages"],
        &(&1["text"] == "new authoritative message")
      )
    end)

    type_text(session, "private unsent draft")
    assert assigns(session).editor.draft == "private unsent draft"
    Host.mode(host, :denied)
    eventually(fn -> assigns(session).snapshot.private_cleared end)
    assert %{draft: "", submitted: nil} = assigns(session).editor
    assert assigns(session).snapshot.projection["messages"] == []
    frame = Breeze.Test.render_text!(session)
    refute frame =~ "private unsent draft"
    refute frame =~ "new authoritative message"
    refute inspect(assigns(session)) =~ "private-fixture-proof"
  end

  test "older newer latest controls read bounded host windows without full replay" do
    {host, _controller, session} = start()
    assert assigns(session).snapshot.window.first == 41
    assert length(assigns(session).snapshot.projection["messages"]) == 20
    Breeze.Test.input(session, "F9")
    eventually(fn -> assigns(session).snapshot.window.first == 21 end)
    reads = length(Host.calls(host))
    Breeze.Test.input(session, "F3")
    eventually(fn -> length(Host.calls(host)) > reads and not assigns(session).snapshot.busy end)
    assert assigns(session).snapshot.window.first == 21
    assert assigns(session).browsing
    assert Breeze.Test.render_text!(session) =~ "browsing history"
    Breeze.Test.input(session, "F4")
    eventually(fn -> not assigns(session).snapshot.connected end)
    Breeze.Test.input(session, "F5")
    eventually(fn -> assigns(session).snapshot.connected end)
    assert assigns(session).snapshot.window.first == 21
    assert assigns(session).browsing
    Breeze.Test.input(session, "F10")
    eventually(fn -> assigns(session).snapshot.window.first == 41 end)
    assert assigns(session).browsing
    refute Breeze.Test.render_text!(session) =~ "following host"
    Breeze.Test.input(session, "F9")
    eventually(fn -> assigns(session).snapshot.window.first == 21 end)
    Breeze.Test.input(session, "F11")
    eventually(fn -> assigns(session).snapshot.window.first == 41 end)
    refute assigns(session).browsing
    assert Breeze.Test.render_text!(session) =~ "history 60"
    Breeze.Test.focus(session, "transcript")
    Breeze.Test.input(session, "Home")
    assert Breeze.Test.render_text!(session) =~ "history 41"
    refute Breeze.Test.render_text!(session) =~ "history 60"
    Breeze.Test.input(session, "End")
    assert Breeze.Test.render_text!(session) =~ "history 60"

    assert Enum.all?(
             Enum.filter(Host.calls(host), &(&1.operation == :window)),
             &(&1.options[:limit] == 20)
           )
  end

  test "manual disconnect retains the native draft and reconnect reconstructs the host window" do
    {_host, _controller, session} = start()
    type_text(session, "retained draft")
    Breeze.Test.input(session, "F4")
    eventually(fn -> not assigns(session).snapshot.connected end)
    assert assigns(session).editor.draft == "retained draft"
    frame = Breeze.Test.render_text!(session)
    refute frame =~ "history 60"
    Breeze.Test.input(session, "F5")
    eventually(fn -> assigns(session).snapshot.connected end)
    assert assigns(session).editor.draft == "retained draft"
    assert Breeze.Test.render_text!(session) =~ "history 60"
  end

  test "the controller permits commands only from its subscribed surface and closes its resources" do
    parent = self()
    {:ok, host} = Host.start(20)

    {:ok, controller} =
      Controller.start(
        connection_options: Host.options(host),
        on_close: fn -> send(parent, :closed) end
      )

    session = Breeze.Test.start!(View, start_opts: [controller: controller])

    assert Controller.act(controller, :send, %{id: "foreign", text: "foreign"}) ==
             {:error, :not_surface_owner}

    assert Controller.subscribe(controller) == {:error, :not_surface_owner}
    monitor = Process.monitor(controller)
    Breeze.Test.stop(session)
    assert_receive {:DOWN, ^monitor, :process, ^controller, :normal}
    assert_receive :closed
    assert Enum.all?(Host.calls(host), &(&1.operation != :submit))
    Agent.stop(host)
  end

  test "native paste rejection explains the bound while preserving the draft and command boundary" do
    {host, _controller, session} = start()
    type_text(session, "retained draft")
    Breeze.Test.info(session, {:breeze_paste_rejected, :too_large})
    assert Breeze.Test.render_text!(session) =~ "Paste exceeds the 32 KiB turn limit"
    assert assigns(session).editor.draft == "retained draft"
    refute Enum.any?(Host.calls(host), &(&1.operation == :submit))
    type_text(session, "x")
    assert assigns(session).paste_notice == nil
  end
end
