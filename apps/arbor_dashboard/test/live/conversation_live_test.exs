defmodule Arbor.Dashboard.Live.ConversationLiveTest do
  use Arbor.Dashboard.ConnCase, async: false
  @moduletag :fast
  @engagement "eng_11111111111111111111111111111111"

  defmodule Host do
    def conversation_window(caller, target, opts) do
      request(:window, caller, target, opts, fn state ->
        head = Keyword.get(opts, :through, List.last(state.entries).entry_ordinal)
        entries = Enum.filter(state.entries, &(&1.entry_ordinal <= head))

        selected =
          cond do
            before = opts[:before] ->
              entries |> Enum.filter(&(&1.entry_ordinal < before)) |> Enum.take(-opts[:limit])

            after_cursor = opts[:after] ->
              entries
              |> Enum.filter(&(&1.entry_ordinal > after_cursor))
              |> Enum.take(opts[:limit])

            true ->
              Enum.take(entries, -opts[:limit])
          end

        first = if selected == [], do: 0, else: hd(selected).entry_ordinal
        last = if selected == [], do: 0, else: List.last(selected).entry_ordinal

        {:ok,
         %{
           engagement_id: state.engagement,
           entries: selected,
           head: head,
           first: first,
           last: last,
           has_older: Enum.any?(entries, &(&1.entry_ordinal < first)),
           has_newer: Enum.any?(entries, &(&1.entry_ordinal > last))
         }}
      end)
    end

    def submit_conversation_command(caller, target, command, opts) do
      request({:submit, command}, caller, target, opts, fn state ->
        if state.fail_submit,
          do: {:error, :conversation_unavailable},
          else: {:ok, receipt(state, command)}
      end)
    end

    def conversation_command(caller, target, id, opts) do
      request({:command, id}, caller, target, opts, fn _state -> {:error, :not_found} end)
    end

    def conversation_activity(caller, target, opts) do
      request(:activity, caller, target, opts, fn state ->
        if state.controls_unavailable,
          do: {:error, :conversation_unavailable},
          else:
            {:ok,
             %{
               commands: state.activities,
               source_watermark: if(state.discovery_incomplete, do: 10, else: 9),
               index_watermark: 9,
               incomplete: state.discovery_incomplete,
               has_more: false,
               next_cursor: nil,
               engagement_id: state.engagement,
               truncated: false
             }}
      end)
    end

    def conversation_interactions(caller, target, id, opts) do
      request({:interactions, id}, caller, target, opts, fn state ->
        {:ok,
         %{
           command_id: id,
           engagement_id: state.engagement,
           interactions: Enum.filter(state.prompts, &(&1.command_id == id))
         }}
      end)
    end

    def cancel_conversation_command(caller, target, id, opts) do
      request({:cancel, id}, caller, target, opts, fn state ->
        activity = Enum.find(state.activities, &(&1.command_id == id))

        if activity do
          {pid, owner} = Application.fetch_env!(:arbor_dashboard, :surface_fixture)
          send(owner, {:control_effect, :cancel, id})

          Agent.update(pid, fn current ->
            %{
              current
              | activities:
                  Enum.map(current.activities, fn value ->
                    if value.command_id == id,
                      do: %{value | cancellation: %{status: :requested}},
                      else: value
                  end)
            }
          end)

          {:ok,
           %{
             command_id: id,
             task_id: activity.task_id,
             delivery_status: activity.delivery_status,
             cancellation: %{status: :requested},
             termination_observation: :unconfirmed,
             engagement_id: state.engagement
           }}
        else
          {:error, :not_found}
        end
      end)
    end

    def answer_conversation_choice(caller, target, input, opts),
      do: answer(:choose, caller, target, input, opts)

    def answer_conversation_approval(caller, target, input, opts),
      do: answer(:approve, caller, target, input, opts)

    defp answer(kind, caller, target, input, opts) do
      request({kind, input}, caller, target, opts, fn state ->
        prompt =
          Enum.find(state.prompts, fn prompt ->
            Enum.all?(
              [:command_id, :request_id, :operation_id, :revision],
              &(prompt[&1] == input[&1])
            )
          end)

        permitted = kind != :approve or state.approval_permission

        if prompt && prompt.status == :pending && permitted do
          {pid, owner} = Application.fetch_env!(:arbor_dashboard, :surface_fixture)
          send(owner, {:control_effect, kind, input})

          Agent.update(pid, fn current ->
            %{
              current
              | prompts:
                  Enum.map(current.prompts, fn value ->
                    if value.request_id == input.request_id,
                      do: %{value | status: :responded},
                      else: value
                  end)
            }
          end)

          {:ok,
           %{
             command_id: input.command_id,
             engagement_id: state.engagement,
             request_id: input.request_id,
             operation_id: input.operation_id,
             revision: input.revision,
             status: :responded
           }}
        else
          {:error, :unauthorized}
        end
      end)
    end

    defp receipt(state, command) do
      %{
        id: command.id,
        name: "chat.send",
        text: command.text,
        principal_id: "human_ui",
        agent_id: "agent_ui",
        engagement_id: state.engagement,
        status: :admitted,
        outcome: nil,
        admitted_cursor: 1,
        updated_cursor: 1
      }
    end

    defp request(operation, caller, target, opts, run) do
      {pid, owner} = Application.fetch_env!(:arbor_dashboard, :surface_fixture)
      state = Agent.get(pid, & &1)
      send(owner, {:host, operation, caller, target, opts})

      if state.hold_operation == operation do
        Agent.update(pid, &%{&1 | hold_operation: nil})
        send(owner, {:host_blocked, operation, self()})

        receive do
          :release_host -> :ok
        after
          3_000 -> raise "host fixture not released"
        end
      end

      state = Agent.get(pid, & &1)

      result =
        cond do
          not state.allowed or caller != "human_ui" or target != "agent_ui" or
              opts[:session_token] != "proof" ->
            {:error, :unauthorized}

          opts[:expected_engagement_id] && opts[:expected_engagement_id] != state.engagement ->
            {:error, :conversation_scope_changed}

          true ->
            run.(state)
        end

      if operation == :window and opts[:limit] == 1 and state.flip_after_access do
        Agent.update(
          pid,
          &%{&1 | engagement: "eng_22222222222222222222222222222222", flip_after_access: false}
        )
      end

      result
    end
  end

  defmodule Voice do
    def desk_recording_options, do: {:ok, %{default_ms: 12_000, min_ms: 100, max_ms: 30_000}}

    def start_desk_turn(caller, target, opts) do
      {_pid, owner} = Application.fetch_env!(:arbor_dashboard, :surface_fixture)
      send(owner, {:voice_start, caller, target, opts})
      {:ok, String.duplicate("v", 43)}
    end

    def desk_turn_status(_), do: {:ok, %{terminal: false, state: :capture}}
    def cancel_desk_turn(_), do: {:error, :cleanup_pending}
  end

  setup do
    settings = [conversation_api: Host, voice_api: Voice, local_voice_controls: true]

    previous =
      Map.new(
        [:surface_fixture | Keyword.keys(settings)],
        &{&1, Application.fetch_env(:arbor_dashboard, &1)}
      )

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             allowed: true,
             engagement: @engagement,
             entries: Enum.map(1..75, &entry/1),
             fail_submit: false,
             flip_after_access: false,
             activities: [],
             prompts: [],
             approval_permission: true,
             controls_unavailable: false,
             discovery_incomplete: false,
             hold_operation: nil
           }
         end}
      )

    for {key, value} <- settings, do: Application.put_env(:arbor_dashboard, key, value)
    Application.put_env(:arbor_dashboard, :surface_fixture, {state, self()})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, old} -> Application.put_env(:arbor_dashboard, key, old)
          :error -> Application.delete_env(:arbor_dashboard, key)
        end
      end
    end)

    %{state: state}
  end

  defp entry(n),
    do: %{
      id: "row-#{n}",
      role: if(rem(n, 2) == 0, do: "assistant", else: "user"),
      content: "Message #{n}: café 東京 🌿",
      timestamp: "2026-10-02T00:00:00Z",
      entry_ordinal: n
    }

  defp open(conn) do
    conn =
      conn
      |> Plug.Conn.put_private(:live_view_connect_info, %{
        peer_data: %{address: {127, 0, 0, 1}},
        uri: %URI{host: "localhost"},
        x_headers: [{"x-arbor-voice-direct", "true"}]
      })
      |> Plug.Test.init_test_session(%{"agent_id" => "human_ui", "session_token" => "proof"})

    live(conn, "/conversation/agent_ui")
  end

  defp await(view, predicate, tries \\ 200)
  defp await(_, _, 0), do: flunk("conversation did not reach expected display state")

  defp await(view, predicate, tries) do
    html = render(view)

    if predicate.(html),
      do: html,
      else:
        (
          Process.sleep(10)
          await(view, predicate, tries - 1)
        )
  end

  defp activity(id, status \\ :dispatch_started, execution \\ :running) do
    %{
      command_id: id,
      task_id: "private_task_" <> id,
      delivery_status: status,
      cancellation: %{status: :none},
      admitted_cursor: 1,
      execution: execution,
      preview: "Live response café 東京",
      preview_truncated: true,
      progress: %{type: :stage_started, node_id: "compute"}
    }
  end

  defp prompt(kind \\ "choice", revision \\ 1) do
    %{
      command_id: "work_1",
      request_id: "request_1",
      operation_id: "operation_1",
      revision: revision,
      kind: kind,
      status: :pending,
      text:
        if(kind == "approval",
          do: "Original principal agent_ui\nResource arbor://action/test\nAction counted.test",
          else: "Choose a path café 東京"
        ),
      choices:
        if(kind == "approval",
          do: [],
          else: [%{id: "first", label: "Same label"}, %{id: "second", label: "Same label"}]
        ),
      deadline_unix_ms: 9_999_999_999_999
    }
  end

  defp choice_input(revision \\ "1", choice \\ "second"),
    do: %{
      "command_id" => "work_1",
      "request_id" => "request_1",
      "operation_id" => "operation_1",
      "revision" => revision,
      "choice_id" => choice
    }

  test "mounted retained partial replies show their status beside the unchanged transcript",
       %{conn: conn, state: state} do
    statuses = %{68 => "complete", 70 => "cancelled", 72 => "interrupted", 74 => "failed"}

    Agent.update(state, fn current ->
      entries =
        Enum.map(current.entries, fn entry ->
          case statuses[entry.entry_ordinal] do
            nil -> entry
            status -> Map.put(entry, :status, status)
          end
        end)

      %{current | entries: entries}
    end)

    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "Cancelled · partial response"))

    assert has_element?(
             view,
             "#conversation-message-row-70 [data-conversation-message-status=cancelled]",
             "Cancelled · partial response"
           )

    assert has_element?(view, "#conversation-message-row-70", "Message 70: café 東京 🌿")

    assert has_element?(
             view,
             "#conversation-message-row-72 [data-conversation-message-status=interrupted]",
             "Interrupted · partial response"
           )

    assert has_element?(
             view,
             "#conversation-message-row-74 [data-conversation-message-status=failed]",
             "Response failed"
           )

    refute has_element?(view, "#conversation-message-row-68 [data-conversation-message-status]")
    refute has_element?(view, "#conversation-message-row-66 [data-conversation-message-status]")
    refute_received {:voice_start, _, _, _}
  end

  test "mounted local help and refusals stay available while busy or disconnected without submitting",
       %{conn: conn, state: state} do
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "conversation-message-row-75"))
    render_change(view, "update-input", %{"message" => "newer café 東京 draft"})
    Agent.update(state, &%{&1 | hold_operation: :window})
    render_click(view, "conversation:refresh", %{})
    assert_receive {:host_blocked, :window, worker}
    render_submit(view, "send-message", %{"message" => "  /help", "command_id" => "local-marker"})
    assert_push_event(view, "conversation-clear-pending", %{id: "local-marker"})
    assert has_element?(view, "#conversation-local-notice", "Local commands")
    assert has_element?(view, "textarea", "newer café 東京 draft")

    render_submit(view, "send-message", %{
      "message" => " /model dangerous",
      "command_id" => "local-refusal"
    })

    assert has_element?(view, "#conversation-local-notice", "Nothing was sent")

    render_submit(view, "send-message", %{
      "message" => "/agents stop private",
      "command_id" => "local-management"
    })

    assert has_element?(view, "#conversation-local-notice", "does not grant management")
    refute_receive {:host, {:submit, _}, _, _, _}, 100
    send(worker, :release_host)
    render_click(view, "conversation:disconnect", %{})
    await(view, &String.contains?(&1, "Disconnected"))
    render_click(element(view, "button[phx-click='conversation:help']"))
    assert has_element?(view, "#conversation-local-notice", "Local commands")
    render_submit(view, "send-message", %{"message" => "/quit", "command_id" => "local-quit"})
    assert has_element?(view, "#conversation-local-notice", "Close this browser tab")
    assert has_element?(view, "textarea", "newer café 東京 draft")
    refute_receive {:host, {:submit, _}, _, _, _}, 100
  end

  test "mounted navigation stays local guidance while busy and preserves the independent draft",
       %{conn: conn, state: state} do
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "conversation-message-row-75"))
    render_change(view, "update-input", %{"message" => "independent 東京 draft"})
    Agent.update(state, &%{&1 | hold_operation: :window})
    render_click(view, "conversation:refresh", %{})
    assert_receive {:host_blocked, :window, worker}

    for text <- ["  /agents", "/attach Voice 東京 agent"] do
      render_submit(view, "send-message", %{
        "message" => text,
        "command_id" => "navigation-marker"
      })

      assert has_element?(view, "#conversation-local-notice", "authenticated Home at /home")
      assert has_element?(view, "textarea", "independent 東京 draft")
    end

    refute_receive {:host, {:submit, _}, _, _, _}, 100
    send(worker, :release_host)
  end

  test "local help, restore and slash retry preserve an unresolved original request and a newer draft",
       %{conn: conn, state: state} do
    Agent.update(state, &%{&1 | fail_submit: true})
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "conversation-message-row-75"))
    text = "  café 東京\nsecond line  "
    render_submit(view, "send-message", %{"message" => text, "command_id" => "local-original"})
    assert_receive {:host, {:submit, %{id: "local-original", text: ^text}}, _, _, _}
    await(view, &String.contains?(&1, "Delivery is unconfirmed"))
    render_change(view, "update-input", %{"message" => "independent newer draft"})
    render_submit(view, "send-message", %{"message" => "/help", "command_id" => "local-original"})
    refute_push_event(view, "conversation-clear-pending", %{id: "local-original"})

    render_click(view, "conversation:restore", %{
      "id" => "local-restored-slash",
      "text" => "\t/unknown"
    })

    assert_push_event(view, "conversation-clear-pending", %{id: "local-restored-slash"})
    Agent.update(state, &%{&1 | fail_submit: false})

    render_submit(view, "send-message", %{
      "message" => " /retry",
      "command_id" => "local-original"
    })

    assert_receive {:host, {:command, "local-original"}, _, _, _}
    assert_receive {:host, {:submit, %{id: "local-original", text: ^text}}, _, _, _}
    assert_push_event(view, "conversation-completed", %{id: "local-original", text: ^text})
    assert has_element?(view, "textarea", "independent newer draft")
    refute_receive {:host, {:submit, %{text: "/help"}}, _, _, _}, 100
  end

  test "security regression: native empty button metadata permits exact choice and cancellation while other extras fail closed",
       %{conn: conn, state: state} do
    Agent.update(
      state,
      &%{&1 | activities: [activity("work_1", :uncertain)], prompts: [prompt()]}
    )

    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "Same label"))

    choice = %{
      "command_id" => "work_1",
      "request_id" => "request_1",
      "operation_id" => "operation_1",
      "revision" => "1",
      "choice_id" => "second"
    }

    cancel = %{"command_id" => "work_1"}

    for {event, input} <- [{"conversation:choose", choice}, {"conversation:cancel", cancel}] do
      render_click(view, event, Map.put(input, "value", "nonempty"))
      render_click(view, event, input |> Map.put("value", "") |> Map.put("extra", "arbitrary"))
      refute_receive {:control_effect, _, _}, 100
    end

    render_click(view, "conversation:choose", Map.put(choice, "value", ""))

    assert_receive {:control_effect, :choose,
                    %{
                      command_id: "work_1",
                      request_id: "request_1",
                      operation_id: "operation_1",
                      revision: 1,
                      choice_id: "second"
                    }}

    await(view, &String.contains?(&1, "responded"))
    render_click(view, "conversation:cancel", Map.put(cancel, "value", ""))
    assert_receive {:control_effect, :cancel, "work_1"}

    assert await(view, &String.contains?(&1, "termination unconfirmed")) =~
             "Execution observed running"
  end

  test "mounted native work requests the exact duplicate-label choice without altering browsing or draft",
       %{conn: conn, state: state} do
    Agent.update(
      state,
      &%{
        &1
        | activities: [activity("work_1", :uncertain)],
          prompts: [prompt()],
          discovery_incomplete: true
      }
    )

    {:ok, view, _} = open(conn)
    html = await(view, &String.contains?(&1, "Choose a path"))
    assert html =~ "Delivery outcome uncertain"
    assert html =~ "Execution observed running"
    assert html =~ "Cancellation not requested"
    assert html =~ "stage started: compute"
    assert html =~ "Response preview (partial)"
    assert html =~ "partial view of current work"

    assert length(
             Floki.find(Floki.parse_document!(html), "button[phx-click='conversation:choose']")
           ) == 2

    render_click(view, "conversation:older", %{})
    await(view, &String.contains?(&1, "conversation-message-row-36"))
    render_change(view, "update-input", %{"message" => "independent newer draft"})
    render_click(view, "conversation:choose", choice_input())

    assert_receive {:control_effect, :choose,
                    %{
                      command_id: "work_1",
                      request_id: "request_1",
                      operation_id: "operation_1",
                      revision: 1,
                      choice_id: "second"
                    }}

    html = await(view, &String.contains?(&1, "responded"))
    assert html =~ "conversation-message-row-36"
    refute html =~ "conversation-message-row-75"
    assert html =~ ~s(data-mode="browsing")
    assert has_element?(view, "#conversation-message-input", "independent newer draft")
    assert_receive {:host, {:choose, _}, "human_ui", "agent_ui", opts}
    assert opts[:session_token] == "proof"
    assert opts[:expected_engagement_id] == @engagement
  end

  test "mounted cancellation retains uncertain running work until the host confirms termination",
       %{conn: conn, state: state} do
    Agent.update(state, &%{&1 | activities: [activity("work_1", :uncertain)], prompts: []})
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "Request cancellation"))
    render_click(view, "conversation:cancel", %{"command_id" => "work_1"})
    assert_receive {:control_effect, :cancel, "work_1"}
    html = await(view, &String.contains?(&1, "termination unconfirmed"))
    assert html =~ "Execution observed running"
    assert html =~ "Delivery outcome uncertain"
    refute html =~ "Cancellation confirmed"
    refute has_element?(view, "button[phx-click='conversation:cancel']")
  end

  test "security regression: stale choices, busy duplicate intents and revoked access admit no additional effect",
       %{conn: conn, state: state} do
    Agent.update(state, &%{&1 | activities: [activity("work_1")], prompts: [prompt()]})
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "revision 1"))
    render_click(view, "conversation:choose", choice_input("2"))
    refute_receive {:control_effect, :choose, _}, 100
    input = choice_input()
    # A real in-flight worker holds the first answer; the mounted UI disables every control.
    atom_input = %{
      command_id: "work_1",
      request_id: "request_1",
      operation_id: "operation_1",
      revision: 1,
      choice_id: "second"
    }

    Agent.update(state, &%{&1 | hold_operation: {:choose, atom_input}})
    render_click(view, "conversation:choose", input)
    assert_receive {:host_blocked, {:choose, ^atom_input}, worker}
    await(view, &String.contains?(&1, ~s(aria-busy="true")))
    render_click(view, "conversation:choose", choice_input("1", "first"))
    render_click(view, "conversation:cancel", %{"command_id" => "work_1"})
    send(worker, :release_host)
    assert_receive {:control_effect, :choose, ^atom_input}
    refute_receive {:control_effect, :cancel, _}, 100
    refute_receive {:control_effect, :choose, _}, 100
    Agent.update(state, &%{&1 | allowed: false})
    render_click(view, "conversation:cancel", %{"command_id" => "work_1"})
    html = await(view, &String.contains?(&1, "Private data was cleared"))
    refute html =~ "Live response"
    refute html =~ "Choose a path"
    refute_receive {:control_effect, :cancel, _}, 100
  end

  test "protected browser decisions use exact original-action prompt and fresh host permission",
       %{conn: conn, state: state} do
    Agent.update(state, &%{&1 | activities: [activity("work_1")], prompts: [prompt("approval")]})
    {:ok, view, _} = open(conn)
    html = await(view, &String.contains?(&1, "Original principal agent_ui"))
    assert html =~ "arbor://action/test"
    assert has_element?(view, "form[phx-submit='conversation:approve'] select option[value='']")

    input =
      choice_input()
      |> Map.delete("choice_id")
      |> Map.merge(%{"decision" => "approved", "note" => "Reviewed exact action"})

    render_submit(view, "conversation:approve", input)

    assert_receive {:control_effect, :approve,
                    %{
                      decision: :approve,
                      note: "Reviewed exact action",
                      command_id: "work_1",
                      request_id: "request_1",
                      operation_id: "operation_1",
                      revision: 1
                    }}

    await(view, &String.contains?(&1, "responded"))
    refute has_element?(view, "form[phx-submit='conversation:approve']")
  end

  test "protected browser rework submits the selected decision with exact prompt identity",
       %{conn: conn, state: state} do
    Agent.update(state, &%{&1 | activities: [activity("work_1")], prompts: [prompt("approval")]})
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "Original principal agent_ui"))

    assert has_element?(
             view,
             "form[phx-submit='conversation:approve'] option[value='rework']",
             "Request rework"
           )

    input =
      choice_input()
      |> Map.delete("choice_id")
      |> Map.merge(%{"decision" => "rework", "note" => "Revise 東京 🌲"})

    render_submit(view, "conversation:approve", Map.put(input, "revision", "2"))
    refute_receive {:control_effect, :approve, _}, 100
    assert has_element?(view, "#conversation-review-request_1-1")
    view |> form("#conversation-review-request_1-1", input) |> render_submit()

    assert_receive {:control_effect, :approve,
                    %{
                      decision: :rework,
                      note: "Revise 東京 🌲",
                      command_id: "work_1",
                      request_id: "request_1",
                      operation_id: "operation_1",
                      revision: 1
                    }}

    await(view, &String.contains?(&1, "responded"))
    refute has_element?(view, "#conversation-review-request_1-1")
    render_submit(view, "conversation:approve", input)
    refute_receive {:control_effect, :approve, _}, 100
  end

  test "review drafts retain blurred decision and note across polling and clear on exact prompt replacement",
       %{
         conn: conn,
         state: state
       } do
    Agent.update(state, &%{&1 | activities: [activity("work_1")], prompts: [prompt("approval")]})
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "conversation-review-request_1-1"))

    input =
      choice_input()
      |> Map.delete("choice_id")
      |> Map.merge(%{"decision" => "rework", "note" => "Keep blurred note 東京 🌲"})

    render_change(
      view,
      "conversation:review-change",
      Map.merge(input, %{"_target" => ["decision"], "_unused_note" => ""})
    )

    assert has_element?(view, "#conversation-review-request_1-1 option[value='rework'][selected]")

    assert has_element?(
             view,
             "#conversation-review-request_1-1 textarea",
             "Keep blurred note 東京 🌲"
           )

    Agent.update(state, &%{&1 | hold_operation: :window})
    render_click(view, "conversation:refresh", %{})
    assert_receive {:host_blocked, :window, worker}
    await(view, fn _ -> has_element?(view, "#conversation-controls[aria-busy='true']") end)
    assert has_element?(view, "#conversation-review-request_1-1 option[value='rework'][selected]")

    assert has_element?(
             view,
             "#conversation-review-request_1-1 textarea",
             "Keep blurred note 東京 🌲"
           )

    refute has_element?(view, "#conversation-review-request_1-1 button[disabled]")
    send(worker, :release_host)
    await(view, fn _ -> has_element?(view, "#conversation-controls[aria-busy='false']") end)
    assert has_element?(view, "#conversation-review-request_1-1 option[value='rework'][selected]")

    assert has_element?(
             view,
             "#conversation-review-request_1-1 textarea",
             "Keep blurred note 東京 🌲"
           )

    next =
      prompt("approval")
      |> Map.merge(%{request_id: "request_2", operation_id: "operation_2"})

    Agent.update(state, &%{&1 | prompts: [next]})
    render_click(view, "conversation:refresh", %{})
    await(view, &String.contains?(&1, "conversation-review-request_2-1"))
    refute has_element?(view, "#conversation-review-request_1-1")
    assert has_element?(view, "#conversation-review-request_2-1 option[value=''][selected]")
    refute render(view) =~ "Keep blurred note 東京 🌲"
    render_submit(view, "conversation:approve", input)
    refute_receive {:control_effect, :approve, _}, 100
  end

  test "security regression: explicit review during a background read queues once with fresh exact membership",
       %{
         conn: conn,
         state: state
       } do
    Agent.update(state, &%{&1 | activities: [activity("work_1")], prompts: [prompt("approval")]})
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "conversation-review-request_1-1"))

    input =
      choice_input()
      |> Map.delete("choice_id")
      |> Map.merge(%{"decision" => "rework", "note" => "One exact read-queued review"})

    Agent.update(state, &%{&1 | hold_operation: :window})
    render_click(view, "conversation:refresh", %{})
    assert_receive {:host_blocked, :window, worker}
    await(view, fn _ -> has_element?(view, "#conversation-controls[aria-busy='true']") end)
    refute has_element?(view, "#conversation-review-request_1-1 button[disabled]")
    render_submit(view, "conversation:approve", input)

    await(view, fn _ ->
      has_element?(view, "#conversation-review-request_1-1 button[disabled]")
    end)

    render_submit(view, "conversation:approve", input)
    render_submit(view, "conversation:approve", Map.put(input, "session_token", "forged"))
    refute_receive {:control_effect, :approve, _}, 100
    send(worker, :release_host)

    assert_receive {:control_effect, :approve,
                    %{
                      decision: :rework,
                      note: "One exact read-queued review",
                      command_id: "work_1",
                      request_id: "request_1",
                      operation_id: "operation_1",
                      revision: 1
                    }}

    refute_receive {:control_effect, :approve, _}, 100
    await(view, &String.contains?(&1, "responded"))
  end

  test "security regression: a read-queued review cannot answer a replacement prompt", %{
    conn: conn,
    state: state
  } do
    Agent.update(state, &%{&1 | activities: [activity("work_1")], prompts: [prompt("approval")]})
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "conversation-review-request_1-1"))

    input =
      choice_input()
      |> Map.delete("choice_id")
      |> Map.merge(%{"decision" => "approved", "note" => "Old exact prompt"})

    Agent.update(state, &%{&1 | hold_operation: :window})
    render_click(view, "conversation:refresh", %{})
    assert_receive {:host_blocked, :window, worker}
    await(view, fn _ -> has_element?(view, "#conversation-controls[aria-busy='true']") end)
    render_submit(view, "conversation:approve", input)

    await(view, fn _ ->
      has_element?(view, "#conversation-review-request_1-1 button[disabled]")
    end)

    next =
      prompt("approval")
      |> Map.merge(%{request_id: "request_2", operation_id: "operation_2"})

    Agent.update(state, &%{&1 | prompts: [next]})
    send(worker, :release_host)
    await(view, &String.contains?(&1, "conversation-review-request_2-1"))
    refute_receive {:control_effect, :approve, _}, 100
    assert has_element?(view, "#conversation-review-request_2-1 option[value=''][selected]")
    refute render(view) =~ "Old exact prompt"
  end

  test "security regression: bounded review change rejects foreign metadata and revocation clears private draft",
       %{
         conn: conn,
         state: state
       } do
    Agent.update(state, &%{&1 | activities: [activity("work_1")], prompts: [prompt("approval")]})
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "conversation-review-request_1-1"))

    input =
      choice_input()
      |> Map.delete("choice_id")
      |> Map.merge(%{"decision" => "denied", "note" => "Private review note 東京"})

    change = Map.put(input, "_target", ["note"])
    render_change(view, "conversation:review-change", change)

    assert has_element?(
             view,
             "#conversation-review-request_1-1 textarea",
             "Private review note 東京"
           )

    for rejected <- [
          Map.put(change, "session_token", "forged"),
          Map.put(change, "_target", ["request_id"]),
          Map.put(change, "_unused_note", "nonempty"),
          Map.put(change, "revision", "2"),
          Map.put(change, "request_id", "foreign"),
          Map.put(change, "decision", "automatic"),
          Map.put(change, "note", String.duplicate("x", 4097))
        ] do
      render_change(view, "conversation:review-change", rejected)

      assert has_element?(
               view,
               "#conversation-review-request_1-1 textarea",
               "Private review note 東京"
             )

      assert has_element?(
               view,
               "#conversation-review-request_1-1 option[value='denied'][selected]"
             )
    end

    refute_receive {:control_effect, :approve, _}, 100
    Agent.update(state, &%{&1 | allowed: false})
    render_click(view, "conversation:refresh", %{})
    html = await(view, &String.contains?(&1, "Private data was cleared"))
    refute html =~ "Private review note 東京"
    refute has_element?(view, "#conversation-review-request_1-1")
    render_change(view, "conversation:review-change", change)
    render_submit(view, "conversation:approve", input)
    refute render(view) =~ "Private review note 東京"
    refute_receive {:control_effect, :approve, _}, 100
  end

  test "security regression: visible protected decisions grant no approval permission", %{
    conn: conn,
    state: state
  } do
    Agent.update(
      state,
      &%{
        &1
        | activities: [activity("work_1")],
          prompts: [prompt("approval")],
          approval_permission: false
      }
    )

    for decision <- ~w(approved denied rework) do
      {:ok, view, _} = open(conn)
      await(view, &String.contains?(&1, "Original principal agent_ui"))

      input =
        choice_input()
        |> Map.delete("choice_id")
        |> Map.merge(%{"decision" => decision, "note" => ""})

      render_submit(view, "conversation:approve", Map.put(input, "session_token", "forged"))
      refute_receive {:host, {:approve, _}, _, _, _}, 100
      render_submit(view, "conversation:approve", input)
      assert_receive {:host, {:approve, _}, "human_ui", "agent_ui", opts}
      assert opts[:session_token] == "proof"
      refute_receive {:control_effect, :approve, _}, 100
      await(view, &String.contains?(&1, "Private data was cleared"))
    end
  end

  test "unavailable work removes all controls while retaining the authorized transcript and draft",
       %{conn: conn, state: state} do
    Agent.update(state, &%{&1 | activities: [activity("work_1")], prompts: [prompt()]})
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "Choose a path"))
    render_change(view, "update-input", %{"message" => "retained draft"})
    Agent.update(state, &%{&1 | controls_unavailable: true})
    html = await(view, &String.contains?(&1, "Current work could not be checked"))
    assert html =~ "Message 75"
    assert has_element?(view, "#conversation-message-input", "retained draft")
    refute has_element?(view, "button[phx-click='conversation:choose']")
    refute has_element?(view, "button[phx-click='conversation:cancel']")
  end

  test "bounded canonical windows navigate older, newer and latest without replaying all history",
       %{conn: conn} do
    {:ok, view, _} = open(conn)
    html = await(view, &String.contains?(&1, "conversation-message-row-75"))
    assert length(Floki.find(Floki.parse_document!(html), "[data-conversation-message]")) == 20
    refute html =~ "conversation-message-row-55"
    refute html =~ "value=\"proof\""
    assert_received {:host, :window, "human_ui", "agent_ui", access}
    assert access[:limit] == 1
    assert_receive {:host, :window, "human_ui", "agent_ui", page}
    assert page[:limit] == 20
    assert page[:expected_engagement_id] == @engagement

    render_click(view, "conversation:older", %{})
    html = await(view, &String.contains?(&1, "conversation-message-row-36"))
    assert length(Floki.find(Floki.parse_document!(html), "[data-conversation-message]")) == 20
    refute html =~ "conversation-message-row-75"
    render_click(view, "conversation:disconnect", %{})
    await(view, &String.contains?(&1, "conversation:reconnect"))
    render_click(view, "conversation:reconnect", %{})

    html =
      await(view, fn html ->
        document = Floki.parse_document!(html)

        String.contains?(html, "conversation:disconnect") and
          Floki.find(document, "button[phx-click='conversation:older'][disabled]") == []
      end)

    assert html =~ "conversation-message-row-36"
    refute html =~ "conversation-message-row-75"
    assert html =~ "data-mode=\"browsing\""
    render_click(view, "conversation:newer", %{})
    await(view, &String.contains?(&1, "conversation-message-row-75"))
    render_click(view, "conversation:latest", %{})
    assert await(view, &String.contains?(&1, "data-mode=\"latest\"")) =~ "Message 75"
  end

  test "unknown admission retries the same ID and text while acknowledgement preserves a newer draft",
       %{conn: conn, state: state} do
    Agent.update(state, &%{&1 | fail_submit: true})
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "conversation-message-row-75"))
    render_change(view, "update-input", %{"message" => "Hello 東京"})

    render_submit(view, "send-message", %{
      "message" => "Hello 東京",
      "command_id" => "browser-request-1"
    })

    assert_receive {:host, {:submit, %{id: "browser-request-1", text: "Hello 東京"}}, "human_ui",
                    "agent_ui", _}

    await(view, &String.contains?(&1, "Delivery is unconfirmed"))
    render_change(view, "update-input", %{"message" => "newer draft"})

    render_submit(view, "send-message", %{
      "message" => "newer draft",
      "command_id" => "different-id"
    })

    refute_receive {:host, {:submit, %{id: "different-id"}}, _, _, _}
    Agent.update(state, &%{&1 | fail_submit: false})
    render_click(view, "conversation:retry", %{})
    assert_receive {:host, {:command, "browser-request-1"}, "human_ui", "agent_ui", _}

    assert_receive {:host, {:submit, %{id: "browser-request-1", text: "Hello 東京"}}, "human_ui",
                    "agent_ui", _}

    assert_push_event(view, "conversation-completed", %{id: "browser-request-1", text: "Hello 東京"})

    html = await(view, &String.contains?(&1, "Message received"))
    assert has_element?(view, "textarea", "newer draft")
    assert length(Floki.find(Floki.parse_document!(html), "[data-conversation-message]")) == 20
  end

  test "security regression: idle access loss clears messages, server draft and browser storage",
       %{conn: conn, state: state} do
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "conversation-message-row-75"))
    render_change(view, "update-input", %{"message" => "private draft"})
    Agent.update(state, &%{&1 | allowed: false})
    html = await(view, &String.contains?(&1, "Private data was cleared"))
    refute html =~ "Message 75"
    refute html =~ "private draft"
    assert_push_event(view, "conversation-access-denied", %{})
    assert has_element?(view, "textarea[disabled]")
  end

  test "security regression: initial window cannot cross the independently checked engagement", %{
    conn: conn,
    state: state
  } do
    Agent.update(state, &%{&1 | flip_after_access: true})
    {:ok, view, _} = open(conn)
    html = await(view, &String.contains?(&1, "Private data was cleared"))
    refute html =~ "Message 75"
    assert has_element?(view, "textarea[disabled]")
  end

  test "voice uses selected duration and a fresh bounded public scope check", %{conn: conn} do
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "conversation-message-row-75"))
    render_change(view, "voice:duration", %{"seconds" => "20"})
    render_click(view, "voice:talk", %{"session_token" => "forged", "duration_ms" => "1"})
    assert_receive {:voice_start, "human_ui", "agent_ui", opts}
    assert opts[:duration_ms] == 20_000
    assert opts[:session_token] == "proof"
    assert opts[:expected_engagement_id] == @engagement
    # The fresh check is additional to the initial unbound check.
    assert_receive {:host, :window, "human_ui", "agent_ui",
                    [expected_engagement_id: @engagement, session_token: "proof", limit: 1]}
  end

  test "security regression: voice cannot use an earlier authorized display after revocation", %{
    conn: conn,
    state: state
  } do
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "conversation-message-row-75"))
    Agent.update(state, &%{&1 | allowed: false})
    render_click(view, "voice:talk", %{})
    refute_received {:voice_start, _, _, _}
    refute render(view) =~ "Message 75"
    assert has_element?(view, "textarea[disabled]")
  end

  test "foreign connection updates cannot enter the current transcript", %{conn: conn} do
    {:ok, view, _} = open(conn)
    await(view, &String.contains?(&1, "conversation-message-row-75"))
    send(view.pid, {:conversation_updated, self(), %{projection: "foreign-private-sentinel"}})
    html = render(view)
    assert html =~ "Message 75"
    refute html =~ "foreign-private-sentinel"
  end
end
