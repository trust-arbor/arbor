defmodule ConversationKit.Arbor.ControlsTest do
  use ExUnit.Case, async: true
  alias ConversationKit.Arbor
  alias ConversationKit.Arbor.Connection
  @moduletag :fast
  @eng "eng_0123456789abcdef0123456789abcdef"

  defp window,
    do: %{
      engagement_id: @eng,
      entries: [],
      head: 0,
      first: 0,
      last: 0,
      has_older: false,
      has_newer: false
    }

  defp activity(id \\ "cmd", ordinal \\ 1),
    do: %{
      command_id: id,
      task_id: "private_task",
      delivery_status: :dispatch_started,
      cancellation: %{status: :none},
      admitted_cursor: ordinal,
      execution: :running,
      preview: "preview",
      preview_truncated: false,
      progress: %{type: :stage_started, node_id: "question"}
    }

  defp page(records \\ [activity()]),
    do: %{
      commands: records,
      source_watermark: 10,
      index_watermark: 9,
      incomplete: true,
      has_more: false,
      next_cursor: nil,
      engagement_id: @eng,
      truncated: false
    }

  defp prompt(id \\ "request", command \\ "cmd"),
    do: %{
      command_id: command,
      request_id: id,
      operation_id: "op_#{id}",
      revision: 1,
      kind: "choice",
      status: :pending,
      text: "Choose",
      choices: [%{id: "one", label: "Same"}, %{id: "two", label: "Same"}],
      deadline_unix_ms: 9_000_000
    }

  defp envelope(command, prompts),
    do: %{command_id: command, engagement_id: @eng, interactions: prompts}

  defp answer(input),
    do:
      Map.take(input, [:command_id, :request_id, :operation_id, :revision])
      |> Map.merge(%{engagement_id: @eng, status: :responded})

  defp input,
    do: %{
      command_id: "cmd",
      request_id: "request",
      operation_id: "op_request",
      revision: 1,
      choice_id: "two"
    }

  defp client(host) do
    owner = self()

    {:ok, client} =
      Arbor.new(
        "human",
        "agent",
        fn context ->
          send(owner, {:proof, context})
          {:ok, [session_token: "private"]}
        end,
        transport: fn context, _ -> host.(context) end
      )

    {:ok, client, _} = Arbor.window(client)
    client
  end

  defp host(context) do
    case context.operation do
      :window ->
        {:ok, window()}

      :activity ->
        {:ok, page()}

      :interactions ->
        {:ok, envelope(context.input, [prompt()])}

      :interaction_choice ->
        {:ok, answer(context.input)}

      :cancel ->
        {:ok,
         %{
           command_id: context.input,
           task_id: "private_task",
           engagement_id: @eng,
           delivery_status: :dispatch_started,
           cancellation: %{status: :requested},
           termination_observation: :unconfirmed
         }}
    end
  end

  test "fresh scoped proof for every control read and action with no optimistic consumption" do
    client = client(&host/1)
    assert {:ok, observed} = Arbor.controls(client)
    assert {:ok, ^observed, %{"status" => "responded"}} = Arbor.answer_choice(observed, input())

    assert {:ok, ^observed,
            %{
              "delivery_status" => "dispatch_started",
              "cancellation" => %{"status" => "requested"}
            }} = Arbor.cancel(observed, "cmd")

    assert [%{"actionable" => true, "choices" => [%{"label" => "Same"}, %{"label" => "Same"}]}] =
             Arbor.controls_projection(observed)["interactions"]

    for operation <- [:window, :activity, :interactions, :interaction_choice, :cancel] do
      assert_receive {:proof, %{operation: ^operation, target: "agent", options: opts} = context}
      assert map_size(context) == 5
      assert opts[:expected_engagement_id] == if(operation == :window, do: nil, else: @eng)
    end

    assert observed.controls_discovery.incomplete
    assert inspect(observed) == "#ConversationKit.Arbor.Client<private>"
    display = JSON.encode!(Arbor.controls_projection(observed))

    for private <- ["private_task", "session_token", "caller", "source", "callback"],
        do: refute(display =~ private)
  end

  test "security regression empty prompt response must correlate exact command and scope" do
    for changed <- [
          %{command_id: "other"},
          %{engagement_id: "eng_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
          %{source: "forged"}
        ] do
      client =
        client(fn context ->
          if context.operation == :window,
            do: {:ok, window()},
            else: {:ok, Map.merge(envelope("cmd", []), changed)}
        end)

      assert {:error, :invalid_control_response} = Arbor.interactions(client, "cmd")
    end

    client =
      client(fn context ->
        if context.operation == :window, do: {:ok, window()}, else: {:ok, envelope("cmd", [])}
      end)

    assert {:ok, ^client, []} = Arbor.interactions(client, "cmd")
  end

  test "security regression answer correlation and closed integer revision fail before accepting evidence" do
    client =
      client(fn context ->
        if context.operation == :window,
          do: {:ok, window()},
          else: {:ok, %{answer(context.input) | operation_id: "other"}}
      end)

    assert {:error, :invalid_control_response} = Arbor.answer_choice(client, input())

    float_reply = %{
      client
      | transport: fn context, _ -> {:ok, %{answer(context.input) | revision: 1.0}} end
    }

    assert {:error, :invalid_control_response} = Arbor.answer_choice(float_reply, input())

    for invalid <- [
          Map.put(input(), :revision, 1.0),
          Map.put(input(), :task_id, "forged"),
          Map.put(input(), :revision, 2)
        ] do
      assert {:error, :invalid_control_request} = Arbor.answer_choice(client, invalid)
    end

    assert_receive {:proof, %{operation: :window}}
    assert_receive {:proof, %{operation: :interaction_choice}}
    assert_receive {:proof, %{operation: :interaction_choice}}
    refute_receive {:proof, _}
  end

  test "aggregate stops at 256 KiB and fifty prompts without following activity pages" do
    owner = self()

    records =
      for n <- 8..1//-1, do: %{activity("cmd_#{n}", n) | preview: String.duplicate("x", 15_000)}

    client =
      client(fn context ->
        case context.operation do
          :window ->
            {:ok, window()}

          :activity ->
            send(owner, :activity_read)

            {:ok,
             %{
               page(records)
               | has_more: true,
                 next_cursor: %{admitted_event_number: 1, command_id: "cmd_1"}
             }}

          :interactions ->
            send(owner, :prompts_read)

            prompts =
              for n <- 1..32,
                  do: %{
                    prompt("#{context.input}_#{n}", context.input)
                    | text: String.duplicate("p", 3800)
                  }

            {:ok, envelope(context.input, prompts)}
        end
      end)

    assert {:ok, observed} = Arbor.controls(client)
    assert length(observed.controls["activities"]) == 8
    assert length(observed.controls["interactions"]) in 1..49
    assert byte_size(JSON.encode!(observed.controls)) <= 262_144
    assert observed.controls_discovery.truncated and observed.controls_discovery.has_more
    assert_receive :activity_read
    refute_receive :activity_read
    assert_receive :prompts_read
    assert_receive :prompts_read
    refute_receive :prompts_read
  end

  defp command(status, cursor, cancellation) do
    %{
      id: "cmd",
      name: "chat.send",
      text: "Hello",
      principal_id: "human",
      agent_id: "agent",
      engagement_id: @eng,
      status: status,
      outcome: if(status == :uncertain, do: %{status: :uncertain, reason: :delivery_unknown}),
      admitted_cursor: 1,
      updated_cursor: cursor,
      cancellation: cancellation
    }
  end

  defp journal(events),
    do: %{
      engagement_id: @eng,
      events: events,
      cursor: length(events),
      head: length(events),
      has_more: false
    }

  defp event(kind, command),
    do: %{
      id: "event_#{command.updated_cursor}",
      cursor: command.updated_cursor,
      kind: kind,
      command: command
    }

  test "v2 journal preserves uncertain delivery through cancellation requested and confirmed" do
    events = [
      event("admitted", command(:admitted, 1, %{status: :none})),
      event("dispatch_started", command(:dispatch_started, 2, %{status: :none})),
      event("settled", command(:uncertain, 3, %{status: :none})),
      event("cancel_requested", command(:uncertain, 4, %{status: :requested})),
      event(
        "cancel_acknowledged",
        command(:uncertain, 5, %{status: :confirmed, termination: :engine_terminated})
      )
    ]

    {:ok, client} =
      Arbor.new("human", "agent", fn _ -> {:ok, [session_token: "private"]} end,
        transport: fn context, _ ->
          case context.operation do
            :history ->
              {:ok, %{engagement_id: @eng, entries: [], cursor: 0, head: 0, has_more: false}}

            :events ->
              {:ok, journal(events)}
          end
        end
      )

    assert {:ok, next} = Arbor.sync(client)
    assert next.commands["cmd"]["status"] == "uncertain"

    assert next.commands["cmd"]["cancellation"] == %{
             "status" => "confirmed",
             "termination" => "engine_terminated"
           }

    assert Arbor.position(next).commands == 5
    refute JSON.encode!(Arbor.projection(next)) =~ "termination"
  end

  test "security regression v2 journal refuses dispatch after cancellation without partial cursor adoption" do
    events = [
      event("admitted", command(:admitted, 1, %{status: :none})),
      event("cancel_requested", command(:admitted, 2, %{status: :requested})),
      event("dispatch_started", command(:dispatch_started, 3, %{status: :requested}))
    ]

    {:ok, client} =
      Arbor.new("human", "agent", fn _ -> {:ok, [session_token: "private"]} end,
        transport: fn context, _ ->
          if context.operation == :history,
            do: {:ok, %{engagement_id: @eng, entries: [], cursor: 0, head: 0, has_more: false}},
            else: {:ok, journal(events)}
        end
      )

    assert {:error, :invalid_command_transition} = Arbor.sync(client)
    assert Arbor.position(client).commands == 0
  end

  defp connection(host, opts \\ []) do
    owner = self()

    {:ok, pid} =
      Connection.start(
        [
          caller: "human",
          target: "agent",
          proof_provider: fn _ -> {:ok, [session_token: "private"]} end,
          poll_interval_ms: 60_000,
          adapter_options: [transport: fn context, _ -> host.(context, owner) end]
        ] ++ opts
      )

    on_exit(fn -> Connection.close(pid) end)
    pid
  end

  defp await(pid, predicate) do
    receive do
      {:conversation_updated, ^pid, snapshot} ->
        if predicate.(snapshot), do: snapshot, else: await(pid, predicate)
    after
      2000 -> flunk("snapshot did not arrive")
    end
  end

  test "security regression queued choice is checked against the completed fresh read and only one action queues" do
    store = start_supervised!({Agent, fn -> %{reads: 0, status: :pending} end})

    pid =
      connection(fn context, owner ->
        case context.operation do
          :window ->
            count =
              Agent.get_and_update(store, fn state ->
                {state.reads, %{state | reads: state.reads + 1}}
              end)

            if count == 1 do
              send(owner, {:blocked, self()})

              receive do
                :release -> :ok
              end
            end

            {:ok, window()}

          :activity ->
            {:ok, page()}

          :interactions ->
            {:ok, envelope("cmd", [%{prompt() | status: Agent.get(store, & &1.status)}])}

          :interaction_choice ->
            send(owner, :effect)
            {:ok, answer(context.input)}
        end
      end)

    await(pid, & &1.controls_available)
    Connection.act(pid, :refresh)
    assert_receive {:blocked, worker}
    Connection.act(pid, :choose, input())
    Connection.act(pid, :choose, input())
    assert Connection.snapshot(pid).busy
    assert Connection.snapshot(pid).controls_available
    Agent.update(store, &%{&1 | status: :abandoned})
    send(worker, :release)
    snapshot = await(pid, &(not &1.busy and not is_nil(&1.error)))
    assert [%{"actionable" => false, "status" => "abandoned"}] = snapshot.controls["interactions"]
    refute_receive :effect
  end

  test "unconfirmed answers clear actionable controls, require explicit fresh read and never retry automatically" do
    pid =
      connection(fn context, owner ->
        if context.operation == :interaction_choice do
          send(owner, :answer_attempt)
          {:error, :transport_timeout}
        else
          host(context)
        end
      end)

    await(pid, & &1.controls_available)
    Connection.act(pid, :choose, input())
    assert_receive :answer_attempt
    snapshot = await(pid, &(not &1.busy and not &1.controls_available))
    assert snapshot.controls["interactions"] == []
    assert snapshot.connected
    Connection.act(pid, :choose, input())
    refute_receive :answer_attempt
    Connection.act(pid, :refresh)
    await(pid, & &1.controls_available)
    Connection.act(pid, :choose, input())
    assert_receive :answer_attempt
  end

  test "terminal Connection requires browser review while browser eligibility still leaves host authorization intact" do
    pid =
      connection(fn context, owner ->
        if context.operation == :interactions,
          do: {:ok, envelope("cmd", [%{prompt() | kind: "approval"}])},
          else:
            (
              if context.operation == :interaction_approval, do: send(owner, :approval_attempt)
              host(context)
            )
      end)

    snapshot = await(pid, & &1.controls_available)
    refute snapshot.approval_answer_allowed
    approval = Map.drop(input(), [:choice_id]) |> Map.merge(%{decision: "approved", note: ""})
    Connection.act(pid, :approve, approval)
    snapshot = await(pid, &(not is_nil(&1.error)))
    assert snapshot.error =~ "browser review"
    refute_receive :approval_attempt
  end

  test "bounded aggregate skips queued and unobserved prompt reads while preserving cancellation eligibility" do
    owner = self()

    client =
      client(fn context ->
        case context.operation do
          :window ->
            {:ok, window()}

          :activity ->
            assert context.options[:limit] == 8

            {:ok,
             page([
               %{activity("queued", 2) | execution: :queued},
               %{activity("unknown", 1) | execution: :not_observed, delivery_status: :uncertain}
             ])}

          :interactions ->
            send(owner, :unexpected_prompt_read)
            {:ok, envelope(context.input, [])}
        end
      end)

    assert {:ok, next} = Arbor.controls(client)
    assert next.controls["interactions"] == []
    assert next.controls_discovery.incomplete
    assert Enum.all?(Arbor.controls_projection(next)["activities"], & &1["cancel_actionable"])
    refute_receive :unexpected_prompt_read
    assert {:error, :invalid_control_request} = Arbor.controls(client, limit: 9)
  end

  test "fifty prompt cap stops aggregation without retaining the overflowing response" do
    client =
      client(fn context ->
        case context.operation do
          :window ->
            {:ok, window()}

          :activity ->
            {:ok, page([activity("new", 2), activity("old", 1)])}

          :interactions ->
            {:ok,
             envelope(
               context.input,
               for(n <- 1..32, do: prompt("#{context.input}_#{n}", context.input))
             )}
        end
      end)

    assert {:ok, next} = Arbor.controls(client)
    assert length(next.controls["interactions"]) == 50
    assert next.controls_discovery.truncated
    assert byte_size(JSON.encode!(next.controls)) <= 262_144
  end

  test "v2 journal records completed delivery independently of a later cancellation request" do
    completed = %{
      command(:uncertain, 3, %{status: :none})
      | status: :completed,
        outcome: %{status: :completed, text: "Done"}
    }

    events = [
      event("admitted", command(:admitted, 1, %{status: :none})),
      event("dispatch_started", command(:dispatch_started, 2, %{status: :none})),
      event("settled", completed),
      event("cancel_requested", %{
        completed
        | updated_cursor: 4,
          cancellation: %{status: :requested}
      })
    ]

    {:ok, client} =
      Arbor.new("human", "agent", fn _ -> {:ok, [session_token: "private"]} end,
        transport: fn context, _ ->
          if context.operation == :history,
            do: {:ok, %{engagement_id: @eng, entries: [], cursor: 0, head: 0, has_more: false}},
            else: {:ok, journal(events)}
        end
      )

    assert {:ok, next} = Arbor.sync(client)

    assert %{
             "status" => "completed",
             "result_text" => "Done",
             "cancellation" => %{"status" => "requested"}
           } = next.commands["cmd"]

    assert {:ok, _, %{"status" => "completed"}} =
             Arbor.command(
               %{
                 next
                 | transport: fn _, _ ->
                     {:ok, %{completed | updated_cursor: 4, cancellation: %{status: :requested}}}
                   end
               },
               "cmd"
             )
  end

  test "unavailable control refresh clears stale actions while revocation clears all private data" do
    store = start_supervised!({Agent, fn -> :available end})

    pid =
      connection(fn context, _ ->
        case {context.operation, Agent.get(store, & &1)} do
          {:activity, :unavailable} -> {:error, :conversation_unavailable}
          {:activity, :revoked} -> {:error, :unauthorized}
          _ -> host(context)
        end
      end)

    await(pid, & &1.controls_available)
    Agent.update(store, fn _ -> :unavailable end)
    Connection.act(pid, :refresh)
    snapshot = await(pid, &(not &1.busy and not &1.controls_available))
    assert snapshot.connected and not snapshot.private_cleared
    assert snapshot.controls["blocks"] == []
    Agent.update(store, fn _ -> :revoked end)
    Connection.act(pid, :refresh)
    snapshot = await(pid, & &1.private_cleared)
    refute snapshot.connected
    assert snapshot.engagement_id == nil and snapshot.controls["blocks"] == []
  end

  test "trusted browser eligibility still requires the actual host human approval authorization" do
    pid =
      connection(
        fn context, owner ->
          case context.operation do
            :interactions ->
              {:ok, envelope("cmd", [%{prompt() | kind: "approval"}])}

            :interaction_approval ->
              send(owner, {:approval_proof_operation, context})
              {:error, :unauthorized}

            _ ->
              host(context)
          end
        end,
        approval_answer_allowed: true
      )

    assert await(pid, & &1.controls_available).approval_answer_allowed
    approval = Map.drop(input(), [:choice_id]) |> Map.merge(%{decision: "approved", note: ""})
    Connection.act(pid, :approve, approval)

    assert_receive {:approval_proof_operation,
                    %{
                      operation: :interaction_approval,
                      input: %{decision: :approve},
                      options: [expected_engagement_id: @eng]
                    }}

    assert await(pid, & &1.private_cleared).controls["blocks"] == []
  end

  test "request rework reaches the public approval boundary with exact scoped proof" do
    store = start_supervised!({Agent, fn -> :permitted end})

    pid =
      connection(
        fn context, owner ->
          case context.operation do
            :interactions ->
              {:ok, envelope("cmd", [%{prompt() | kind: "approval"}])}

            :interaction_approval ->
              send(owner, {:rework_proof_operation, context})

              if Agent.get(store, & &1) == :permitted,
                do: {:ok, answer(context.input)},
                else: {:error, :unauthorized}

            _ ->
              host(context)
          end
        end,
        approval_answer_allowed: true
      )

    assert await(pid, & &1.controls_available).approval_answer_allowed

    rework =
      Map.drop(input(), [:choice_id]) |> Map.merge(%{decision: "rework", note: "Revise 東京 🌲"})

    Connection.act(pid, :approve, %{rework | revision: 2})
    refute_receive {:rework_proof_operation, _}, 100
    Connection.act(pid, :approve, rework)

    assert_receive {:rework_proof_operation,
                    %{
                      operation: :interaction_approval,
                      caller: "human",
                      target: "agent",
                      input: %{
                        decision: :rework,
                        note: "Revise 東京 🌲",
                        command_id: "cmd",
                        request_id: "request",
                        operation_id: "op_request",
                        revision: 1
                      },
                      options: [expected_engagement_id: @eng]
                    }}

    await(pid, &(not &1.busy and &1.controls_available))
    Agent.update(store, fn _ -> :denied end)
    Connection.act(pid, :approve, rework)
    assert_receive {:rework_proof_operation, %{input: %{decision: :rework}}}
    assert await(pid, & &1.private_cleared).controls["blocks"] == []
  end

  test "older activity discovery is independent of history and latest explicitly resets its cursor" do
    owner = self()

    pid =
      connection(fn context, _ ->
        case context.operation do
          :activity ->
            send(owner, {:activity_cursor, context.options[:cursor]})

            if context.options[:cursor],
              do: {:ok, page([activity("old", 1)])},
              else:
                {:ok,
                 %{
                   page([activity("new", 2)])
                   | has_more: true,
                     next_cursor: %{admitted_event_number: 2, command_id: "new"}
                 }}

          :interactions ->
            {:ok, envelope(context.input, [prompt("#{context.input}_prompt", context.input)])}

          _ ->
            host(context)
        end
      end)

    initial = await(pid, & &1.controls_available)
    assert initial.controls_discovery.has_more
    assert_receive {:activity_cursor, nil}
    Connection.act(pid, :more_activity)

    older =
      await(
        pid,
        &(not &1.busy and
            Enum.any?(&1.controls["activities"], fn a -> a["command_id"] == "old" end))
      )

    assert_receive {:activity_cursor, %{admitted_event_number: 2, command_id: "new"}}
    assert older.window == initial.window
    assert [%{"command_id" => "old", "actionable" => true}] = older.controls["interactions"]
    Connection.act(pid, :latest_activity)

    await(
      pid,
      &(not &1.busy and Enum.any?(&1.controls["activities"], fn a -> a["command_id"] == "new" end))
    )

    assert_receive {:activity_cursor, nil}
  end

  test "owner death kills a blocked control read and cannot resurrect a prompt worker" do
    observer = self()

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, pid} =
      Connection.start(
        [
          caller: "human",
          target: "agent",
          proof_provider: fn _ -> {:ok, [session_token: "private"]} end,
          adapter_options: [
            transport: fn context, _ ->
              if context.operation == :activity do
                send(observer, {:blocked_control, self()})

                receive do
                  :release -> {:ok, page()}
                end
              else
                host(context)
              end
            end
          ]
        ],
        owner
      )

    monitor = Process.monitor(pid)
    assert_receive {:blocked_control, worker}
    worker_monitor = Process.monitor(worker)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}
    refute Process.alive?(worker)
  end

  defp wire_json(value) when is_map(value),
    do: Map.new(value, fn {key, value} -> {Atom.to_string(key), wire_json(value)} end)

  defp wire_json(value) when is_list(value), do: Enum.map(value, &wire_json/1)
  defp wire_json(value) when value in [nil, true, false], do: value
  defp wire_json(value) when is_atom(value), do: Atom.to_string(value)
  defp wire_json(value), do: value

  defp fill_text(records, key, remaining, maximum) do
    Enum.map_reduce(records, remaining, fn record, left ->
      size = min(left, maximum)
      {Map.put(record, key, String.duplicate("x", size)), left - size}
    end)
    |> elem(0)
  end

  test "two maximum host128KiB pages admit every first-command prompt within the aggregate budget" do
    records = for n <- 8..1//-1, do: %{activity("cmd_#{n}", n) | preview: ""}
    available = 131_072 - byte_size(JSON.encode!(wire_json(page(records))))
    records = fill_text(records, :preview, available, 32_768)
    raw_activity = page(records)
    prompts = for n <- 1..32, do: %{prompt("request_#{n}", "cmd_8") | text: ""}
    available = 131_072 - byte_size(JSON.encode!(wire_json(envelope("cmd_8", prompts))))
    prompts = fill_text(prompts, :text, available, 4096)
    raw_prompts = envelope("cmd_8", prompts)
    assert byte_size(JSON.encode!(wire_json(raw_activity))) == 131_072
    assert byte_size(JSON.encode!(wire_json(raw_prompts))) == 131_072

    client =
      client(fn context ->
        case context.operation do
          :window ->
            {:ok, window()}

          :activity ->
            {:ok, raw_activity}

          :interactions ->
            {:ok,
             if(context.input == "cmd_8", do: raw_prompts, else: envelope(context.input, []))}
        end
      end)

    assert {:ok, next} = Arbor.controls(client)
    assert length(next.controls["interactions"]) == 32
    assert Enum.all?(next.controls["interactions"], &(&1["command_id"] == "cmd_8"))
    assert byte_size(JSON.encode!(next.controls)) <= 262_144
    assert next.controls_discovery.next_cursor == nil
  end
end
