defmodule Arbor.Voice.AudioTurnIntegrationTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Arbor.Voice
  alias Arbor.Voice.PcmFormat

  alias Arbor.Voice.Test.SessionFakes.{
    FakeCommsSession,
    FakeEngagementStore,
    FakeLedger,
    FakeSignals
  }

  @moduletag :integration
  @moduletag spec: "VOICE-5,VOICE-13"
  @input "input-pcm-privateX"
  @output "output-pcm-privateXX"
  @ended ~U[2026-09-27 12:00:00.125000Z]
  @fixture :voice_audio_turn_integration_fixture

  defmodule Backend do
    @behaviour Arbor.Voice.RealtimeBackend
    def egress_route, do: :none
    def open(opts), do: {:ok, Map.new(opts)}

    def configure(state, config) do
      send(state.parent, {:configured_audio, config})
      {:ok, state}
    end

    def send_text(state, text) do
      send(state.parent, {:sent_text, text})
      {:ok, state}
    end

    def send_audio(state, pcm) do
      send(state.parent, {:sent_audio, pcm})
      {:ok, state}
    end

    def send_tool_result(state, id, output) do
      send(state.parent, {:tool_result, id, output})
      {:ok, state}
    end

    def recv(state, timeout) do
      event =
        Agent.get_and_update(state.queue, fn
          [event | rest] -> {event, rest}
          [] -> {:timeout, []}
        end)

      case event do
        :timeout ->
          Process.sleep(min(timeout, 2))
          {:error, :timeout}

        {:block, tag} ->
          send(state.parent, {:receive_blocked, tag, self()})

          receive do
            {:release, next} -> {:ok, state, next}
          end

        event ->
          {:ok, state, event}
      end
    end

    def close(state) do
      send(state.parent, :audio_closed)
      :ok
    end

    def meta(_),
      do: %{
        backend: :bounded_test_audio,
        mode: :local,
        input_format: PcmFormat.mono_s16le(16_000),
        output_format: PcmFormat.mono_s16le(24_000)
      }
  end

  defmodule Speakable do
    def render(text, _) do
      [{:guard, mode, parent}] = :ets.lookup(:voice_audio_turn_integration_fixture, :guard)
      send(parent, {:rendered, text})

      case mode do
        :plain -> {:speak, text}
        :rewrite -> {:speak, "See your screen."}
        :truncate -> {:speak_truncated, "See your screen."}
        :sensitive -> {:screen_only, "See your screen."}
        :malformed -> :invalid
      end
    end

    def tts_guard!({_tag, text}), do: text
    def tts_guard!(_), do: raise("guard failed")
  end

  defmodule Router do
    defdelegate tools(), to: Arbor.Voice.ToolRouter.PrivateConversation

    def invoke(context, _authority) do
      [{:guard, _, parent}] = :ets.lookup(:voice_audio_turn_integration_fixture, :guard)
      send(parent, {:tool_invoked, context.name})
      {:ok, "Done."}
    end
  end

  defmodule DispatchRouter do
    defdelegate tools(), to: Arbor.Voice.ToolRouter.FrontDesk

    def invoke(_context, _authority),
      do: {:ok, %{"task_id" => "audio-dispatch-1", "status" => "dispatched"}}
  end

  defmodule DelayedAgentFacade do
    def consult_conversation(caller, target, message, _parent_id, opts),
      do: send_message(caller, target, message, opts)

    def send_message(caller, target, message, opts) do
      [{:guard, _, parent}] = :ets.lookup(:voice_audio_turn_integration_fixture, :guard)
      send(parent, {:consultation_started, self(), caller, target, message, opts})

      receive do
        {:complete_consultation, reply} -> {:ok, reply}
      end
    end
  end

  defmodule ConsultationAgent do
    def send_message(_caller, _target, message, _opts) do
      [{:guard, _, parent}] = :ets.lookup(:voice_audio_turn_integration_fixture, :guard)
      send(parent, {:ordinary_delivery, message})
      {:ok, "Ordinary answer"}
    end

    def dispatch_task(_, _, _, _), do: {:error, :unsupported}

    def consult_conversation(caller, target, message, parent_id, opts) do
      [{:guard, _, parent}] = :ets.lookup(:voice_audio_turn_integration_fixture, :guard)
      [{:consult_mode, mode}] = :ets.lookup(:voice_audio_turn_integration_fixture, :consult_mode)
      send(parent, {:private_consultation, self(), caller, target, message, parent_id, opts})

      case mode do
        :error ->
          {:error, :delivery_failed}

        :ambiguous ->
          {:error, :delivery_ambiguous}

        :timeout ->
          receive do
            :never -> {:ok, "unreachable"}
          end

        _ ->
          {:ok, "Grounded private answer"}
      end
    end
  end

  defp install_consultation_agent(mode) do
    previous = Application.fetch_env(:arbor_voice, :agent_module)
    Application.put_env(:arbor_voice, :agent_module, ConsultationAgent)
    :ets.insert(@fixture, {:consult_mode, mode})

    on_exit(fn ->
      case previous do
        {:ok, module} -> Application.put_env(:arbor_voice, :agent_module, module)
        :error -> Application.delete_env(:arbor_voice, :agent_module)
      end
    end)
  end

  defp release_final_audio(queue) do
    Agent.update(queue, fn remaining ->
      remaining ++ [{:output_audio, @output}, {:turn_done, %{text: "The result is ready."}}]
    end)
  end

  setup do
    Arbor.Voice.Test.ConversationSecurityFixture.install()
    :ets.new(@fixture, [:named_table, :public, :set])
    :ets.insert(@fixture, {:guard, :plain, self()})
    {:ok, _} = FakeEngagementStore.start()
    {:ok, _} = FakeLedger.start()
    {:ok, signals} = FakeSignals.start()
    {:ok, recorder} = FakeCommsSession.start_recorder()
    id = "audio-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        id,
        [:arbor_voice, :turn],
        fn event, measurements, metadata, parent ->
          send(parent, {:audio_telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)
    {:ok, recorder: recorder, signals: signals}
  end

  defp start_audio(events, extra \\ [], custody \\ nil) do
    queue = start_supervised!(Supervisor.child_spec({Agent, fn -> events end}, id: make_ref()))
    n = System.unique_integer([:positive])
    key = {"audio_user_#{n}", "agent_#{n}"}
    parent = self()

    opts = [
      session_token: "voice-fixture-proof",
      audio_mode: :pcm16,
      backend: Backend,
      backend_opts: [parent: parent, queue: queue],
      comms: FakeCommsSession,
      engagement_store: FakeEngagementStore,
      ledger: FakeLedger,
      signals: FakeSignals,
      speakable: Speakable,
      tool_router: Router,
      speech_output: fn text ->
        send(parent, {:legacy_speech, text})
        :ok
      end,
      wall_clock: fn -> ~U[2026-09-27 12:00:02.125000Z] end,
      resource_owner_opts: [
        close_timeout_ms: 1_000,
        cleanup_ready_timeout_ms: 200,
        cleanup_attempts: 2,
        cleanup_per_attempt_timeout_ms: 100
      ],
      session_budget_ms: 60_000,
      daily_budget_ms: 3_600_000
    ]

    handle =
      if custody do
        assert {:ok, handle} =
                 Voice.start_owned_desk_session(
                   elem(key, 0),
                   elem(key, 1),
                   Keyword.merge(opts, extra),
                   custody
                 )

        handle
      else
        assert {:ok, ^key} =
                 Voice.start_session(elem(key, 0), elem(key, 1), Keyword.merge(opts, extra))

        nil
      end

    [{session, _}] = Registry.lookup(Arbor.Voice.Registry, key)
    on_exit(fn -> if Process.alive?(session), do: Voice.stop_session(key) end)
    assert_receive {:configured_audio, config}
    assert config.audio_mode == :pcm16
    %{key: key, session: session, queue: queue, handle: handle}
  end

  defp input, do: %{pcm: @input, sample_rate: 16_000, channels: 1, sample_format: :s16le}

  defp run_turn({user, agent}, id \\ "utterance-1"),
    do: Voice.audio_turn(user, agent, input(), operation_id: id, utterance_ended_at: @ended)

  defp final_events do
    [
      {:input_transcript, " Actual utterance. "},
      {:output_audio, @output},
      {:turn_done, %{text: "The result is ready."}}
    ]
  end

  @tag :fast
  test "security regression: revoked Desk lease cannot send PCM before the monitor tick" do
    custody = %{
      pid: self(),
      revoked: :atomics.new(1, []),
      deadline: System.monotonic_time(:millisecond) + 5_000
    }

    %{handle: handle} = start_audio(final_events(), [], custody)
    :atomics.put(custody.revoked, 1, 1)

    assert {:error, _, :closed} =
             Voice.owned_desk_audio_turn(handle, input(),
               operation_id: "desk-revoked",
               utterance_ended_at: @ended
             )

    refute_receive {:sent_audio, _}
    assert :ok = Voice.stop_owned_desk_session(handle)
  end

  @tag :fast
  test "security regression: rejected provider PCM publishes its correlated positive close receipt" do
    queue = start_supervised!({Agent, fn -> [{:output_audio, <<1>>}] end})

    {:ok, owner} =
      Arbor.Voice.ResourceOwner.start(self(), Backend, [parent: self(), queue: queue],
        close_timeout_ms: 1_000
      )

    {:ok, ticket} =
      Arbor.Voice.ResourceOwner.reserve_audio_turn(
        owner,
        PcmFormat.mono_s16le(16_000),
        byte_size(@input),
        1_000
      )

    {:ok, request} = Arbor.Voice.ResourceOwner.handoff_audio(owner, ticket, @input)
    assert {:reply, :ok} = :gen_server.receive_response(request, 1_000)
    assert_receive {:voice_audio_turn_ready, ^ticket}
    {:ok, receive_request} = Arbor.Voice.ResourceOwner.recv_audio_request(owner, ticket, 100)

    assert {:reply, %Arbor.Voice.Redacted{}} =
             :gen_server.receive_response(receive_request, 1_000)

    assert_receive :audio_closed

    assert_receive {:voice_audio_operation_result, ^ticket, {:error, :backend_callback_failed},
                    :ok},
                   1_000
  end

  @tag :fast
  test "owned provider failure carries positive closure after Session retires" do
    custody = %{
      pid: self(),
      revoked: :atomics.new(1, []),
      deadline: System.monotonic_time(:millisecond) + 5_000
    }

    %{handle: handle, session: session} =
      start_audio([{:block, :malformed_late}], [], custody)

    turn =
      Task.async(fn ->
        Voice.owned_desk_audio_turn(handle, input(),
          operation_id: "desk-failure",
          utterance_ended_at: @ended
        )
      end)

    assert_receive {:receive_blocked, :malformed_late, worker}
    owner = :sys.get_state(session).owner
    monitor = Process.monitor(owner)
    :ok = :sys.suspend(session)

    try do
      send(worker, {:release, {:output_audio, <<1>>}})
      assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1_000
    after
      :sys.resume(session)
    end

    assert {:error, :turn_failed, :closed} = Task.await(turn, 2_000)
    assert_receive :audio_closed
    refute Process.alive?(session)
    assert :ok = Voice.stop_owned_desk_session(handle)
  end

  @tag :fast
  test "public PCM turn persists actual STT and timestamp, closes positively, and returns exact guarded media",
       ctx do
    %{key: key, session: session} = start_audio(final_events())
    monitor = Process.monitor(session)
    assert {:ok, result} = run_turn(key)

    assert result == %{
             operation_id: "utterance-1",
             reply: "The result is ready.",
             input_transcript: " Actual utterance. ",
             presentation: %{
               verdict: {:speak, "The result is ready."},
               spoken_text: "The result is ready.",
               audio: @output,
               format: PcmFormat.mono_s16le(24_000)
             }
           }

    assert_receive {:sent_audio, @input}
    assert_receive :audio_closed
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}
    assert [{_, _, user, assistant, []}] = FakeCommsSession.record_calls(ctx.recorder)
    assert user.content == " Actual utterance. "
    assert user.sent_at == @ended
    assert assistant.content == "The result is ready."
    parent_id = user.metadata["voice_parent_id"]
    assert is_binary(parent_id) and Regex.match?(~r/\Avoice_[0-9a-f]{32}\z/, parent_id)
    assert assistant.metadata["voice_parent_id"] == parent_id
    refute parent_id == result.operation_id
    refute inspect({user, assistant}) =~ @input
    refute inspect({user, assistant}) =~ @output
    assert_receive {:audio_telemetry, [:arbor_voice, :turn], measurements, metadata}
    assert Map.keys(measurements) |> Enum.sort() == [:ack_ms, :first_audio_ms, :total_ms]
    assert measurements.ack_ms == nil
    assert measurements.first_audio_ms >= 2_000
    assert measurements.total_ms >= 0

    assert metadata == %{
             kind: :audio,
             status: :success,
             backend: :bounded_test_audio,
             mode: :local
           }

    refute_receive {:audio_telemetry, _, _, _}
    refute_receive {:legacy_speech, _}
    refute inspect(FakeSignals.emissions(ctx.signals)) =~ @output
  end

  @tag :fast
  test "invalid and mismatched input is rejected before admission and telemetry", ctx do
    %{key: {user, agent} = key} = start_audio(final_events())

    for bad <- [
          Map.put(input(), :extra, true),
          %{input() | pcm: <<1>>},
          %{input() | sample_rate: 24_000}
        ] do
      assert {:error, :invalid_audio} =
               Voice.audio_turn(user, agent, bad,
                 operation_id: "invalid",
                 utterance_ended_at: @ended
               )
    end

    assert {:error, :invalid_audio_opts} =
             Voice.audio_turn(user, agent, input(),
               operation_id: "a",
               operation_id: "b",
               utterance_ended_at: @ended
             )

    refute_receive {:sent_audio, _}
    refute_receive {:audio_telemetry, _, _, _}
    assert FakeCommsSession.record_calls(ctx.recorder) == []
    assert {:ok, _} = run_turn(key)
  end

  @tag :fast
  test "PCM session rejects text before provider effects so its audio stream has no prior response",
       ctx do
    %{key: {user, agent} = key} = start_audio(final_events())
    assert {:error, :audio_only_session} = Voice.text_turn(user, agent, "prior text")
    refute_receive {:sent_text, _}
    refute_receive {:sent_audio, _}
    refute_receive {:audio_telemetry, _, _, _}
    assert FakeCommsSession.record_calls(ctx.recorder) == []
    assert {:ok, _} = run_turn(key)
  end

  @tag :fast
  test "guard rewrites, truncation and screen-only verdicts suppress original PCM", ctx do
    # A fresh Session per utterance is part of the bounded public contract.
    for {mode, spoken} <- [
          {:rewrite, "See your screen."},
          {:truncate, "See your screen."},
          {:sensitive, ""},
          {:malformed, ""}
        ] do
      :ets.insert(@fixture, {:guard, mode, self()})
      %{key: key} = start_audio(final_events())
      assert {:ok, result} = run_turn(key)
      assert result.reply == "The result is ready."
      assert %{audio: nil, format: nil, spoken_text: ^spoken} = result.presentation
      assert_receive :audio_closed
      assert_receive {:audio_telemetry, _, %{first_audio_ms: nil}, %{status: :success}}
    end

    assert length(FakeCommsSession.record_calls(ctx.recorder)) == 4
    refute_receive {:legacy_speech, _}
  end

  @tag :fast
  test "completed STT gates tools and final text waits without manufacturing input", ctx do
    %{key: key} = start_audio([{:turn_done, %{text: "Hello"}}, {:block, :stt}])
    task = Task.async(fn -> run_turn(key) end)
    assert_receive {:receive_blocked, :stt, worker}
    assert FakeCommsSession.record_calls(ctx.recorder) == []
    refute_receive {:rendered, _}
    send(worker, {:release, {:input_transcript, "Real captured utterance"}})

    assert {:ok, %{input_transcript: "Real captured utterance", presentation: %{audio: nil}}} =
             Task.await(task, 2_000)
  end

  @tag :fast
  test "tool before completed STT fails closed before invocation or append", ctx do
    secret = "private-before-stt-tool-sentinel"
    call = %{id: secret, name: "consult_agent", arguments: %{"message" => secret}}
    %{key: key} = start_audio([{:tool_call, call} | final_events()])

    log = capture_log(fn -> assert {:error, :turn_failed} = run_turn(key) end)
    assert log =~ "stage=audio_reduce reason=tool_before_completed_transcript"
    refute log =~ secret
    refute log =~ @input
    refute log =~ @output
    assert_receive :audio_closed
    refute_receive {:tool_invoked, _}
    assert FakeCommsSession.record_calls(ctx.recorder) == []
    refute_receive {:rendered, _}
  end

  @tag :fast
  test "tool after terminal awaiting STT preserves refusal and logs the first failing gate",
       ctx do
    secret = "private-terminal-tool-sentinel"
    call = %{id: secret, name: "consult_agent", arguments: %{"message" => secret}}
    %{key: key} = start_audio([{:turn_done, %{text: secret}}, {:tool_call, call}])

    log = capture_log(fn -> assert {:error, :turn_failed} = run_turn(key) end)
    assert log =~ "stage=audio_reduce reason=event_after_terminal"
    refute log =~ "reason=tool_before_completed_transcript"
    refute log =~ secret
    refute log =~ @input
    assert_receive :audio_closed
    refute_receive {:tool_invoked, _}
    assert FakeCommsSession.record_calls(ctx.recorder) == []
    refute_receive {:rendered, _}
  end

  @tag :fast
  test "tool wave discards intermediate PCM and keeps completed STT for the final wave", ctx do
    call = %{id: "after_stt", name: "consult_agent", arguments: %{"message" => "Check"}}

    events = [
      {:input_transcript, "Check the result"},
      {:output_audio, <<1, 2>>},
      {:tool_call, call},
      {:turn_done, %{text: "Checking"}},
      {:output_audio, @output},
      {:turn_done, %{text: "The result is ready."}}
    ]

    %{key: key} = start_audio(events)
    assert {:ok, result} = run_turn(key)
    assert result.input_transcript == "Check the result"
    assert result.presentation.audio == @output
    assert_receive {:tool_invoked, "consult_agent"}
    assert_receive {:tool_result, "after_stt", _}
    assert [{_, _, user, _, _}] = FakeCommsSession.record_calls(ctx.recorder)
    assert user.content == "Check the result"
  end

  @tag :fast
  @tag :voice_single_consultation
  test "security regression: private audio consults completed STT once across repeated and distinct provider IDs",
       ctx do
    install_consultation_agent(:success)
    transcript = "Keep the exact spoken question."

    first = %{
      id: "consult-first",
      name: "consult_agent",
      arguments: %{"message" => "provider paraphrase"}
    }

    second = %{first | id: "consult-second", arguments: %{"message" => "different paraphrase"}}

    %{key: {user, agent} = key, queue: queue} =
      start_audio(
        [
          {:input_transcript, transcript},
          {:tool_call, first},
          {:tool_call, first},
          {:tool_call, second},
          {:turn_done, %{text: "intermediate"}}
        ],
        tool_router: Arbor.Voice.ToolRouter.PrivateConversation
      )

    turn = Task.async(fn -> run_turn(key) end)
    assert_receive {:private_consultation, _, ^user, ^agent, message, parent_id, opts}, 1_000
    assert message.content == transcript
    assert message.sent_at == @ended
    assert message.sender_id == user
    assert message.engagement_id == nil
    assert Regex.match?(~r/\Avoice_[0-9a-f]{32}\z/, parent_id)
    assert Keyword.fetch!(opts, :session_token) == "voice-fixture-proof"
    assert is_binary(Keyword.fetch!(opts, :expected_engagement_id))
    assert_receive {:tool_result, "consult-first", first_output}, 1_000

    assert Jason.decode!(first_output) == %{
             "success" => true,
             "result" => %{"reply" => "Grounded private answer"}
           }

    assert_receive {:tool_result, "consult-second", second_output}, 1_000
    assert Jason.decode!(second_output) == %{"code" => "consultation_already_requested"}
    refute_receive {:tool_result, "consult-first", _}, 25
    refute_receive {:private_consultation, _, _, _, _, _, _}, 25
    refute_receive {:ordinary_delivery, _}, 25

    release_final_audio(queue)
    assert {:ok, result} = Task.await(turn, 2_000)
    assert result.input_transcript == transcript
    assert result.reply == "The result is ready."
    assert result.presentation.audio == @output

    assert [{_, _, recorded_user, recorded_assistant, []}] =
             FakeCommsSession.record_calls(ctx.recorder)

    assert recorded_user.content == transcript
    assert recorded_user.metadata["voice_parent_id"] == parent_id
    assert recorded_assistant.metadata["voice_parent_id"] == parent_id
    assert_receive :audio_closed
  end

  @tag :fast
  test "failed ambiguous timed-out and invalid first consultations cannot reopen the slot", ctx do
    install_consultation_agent(:error)

    for mode <- [:error, :ambiguous, :timeout, :invalid] do
      :ets.insert(@fixture, {:consult_mode, mode})
      args = if mode == :invalid, do: %{"message" => ""}, else: %{"message" => "paraphrase"}
      first = %{id: "first-#{mode}", name: "consult_agent", arguments: args}
      second = %{id: "second-#{mode}", name: "consult_agent", arguments: %{"message" => "retry"}}

      %{key: key, queue: queue} =
        start_audio(
          [
            {:input_transcript, "Authoritative #{mode}"},
            {:tool_call, first},
            {:turn_done, %{text: "intermediate"}}
          ],
          tool_router: Arbor.Voice.ToolRouter.PrivateConversation,
          tool_router_timeout_ms: 100,
          progress_threshold_ms: 100
        )

      turn = Task.async(fn -> run_turn(key) end)

      if mode != :invalid do
        assert_receive {:private_consultation, worker, _, _, _, _, _}, 1_000

        if mode == :timeout do
          monitor = Process.monitor(worker)
          assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
        end
      end

      first_id = first.id
      assert_receive {:tool_result, ^first_id, output}, 1_000
      code = if mode == :timeout, do: "tool_timeout", else: "tool_error"
      assert Jason.decode!(output) == %{"code" => code}

      Agent.update(queue, fn remaining ->
        remaining ++
          [
            {:tool_call, second},
            {:tool_call, second},
            {:turn_done, %{text: "intermediate"}}
          ]
      end)

      second_id = second.id
      assert_receive {:tool_result, ^second_id, output}, 1_000
      assert Jason.decode!(output) == %{"code" => "consultation_already_requested"}
      refute_receive {:private_consultation, _, _, _, _, _, _}, 25
      refute_receive {:ordinary_delivery, _}, 25
      release_final_audio(queue)
      assert {:ok, %{presentation: %{audio: @output}}} = Task.await(turn, 2_000)
      assert_receive :audio_closed
    end

    calls = FakeCommsSession.record_calls(ctx.recorder)
    assert length(calls) == 4

    parent_ids =
      Enum.map(calls, fn {_, _, user, assistant, []} ->
        assert assistant.metadata["voice_parent_id"] == user.metadata["voice_parent_id"]
        user.metadata["voice_parent_id"]
      end)

    assert length(Enum.uniq(parent_ids)) == 4
  end

  @tag :fast
  test "explicit FrontDesk audio retains ordinary consultation input and delivery" do
    install_consultation_agent(:success)

    call = %{
      id: "front-desk",
      name: "consult_agent",
      arguments: %{"message" => "Explicit provider query"}
    }

    %{key: key, queue: queue} =
      start_audio(
        [
          {:input_transcript, "Different captured speech"},
          {:tool_call, call},
          {:turn_done, %{text: "intermediate"}}
        ],
        tool_router: Arbor.Voice.ToolRouter.FrontDesk
      )

    turn = Task.async(fn -> run_turn(key) end)
    assert_receive {:ordinary_delivery, message}, 1_000
    assert message.content == "Explicit provider query"
    assert_receive {:tool_result, "front-desk", _}, 1_000
    refute_receive {:private_consultation, _, _, _, _, _, _}, 25
    release_final_audio(queue)
    assert {:ok, _} = Task.await(turn, 2_000)
    assert_receive :audio_closed
  end

  @tag :slow
  @tag timeout: 20_000
  test "default consultation timeout permits a full agent turn beyond five seconds and retires its timer",
       ctx do
    previous = Application.fetch_env(:arbor_voice, :agent_module)
    Application.put_env(:arbor_voice, :agent_module, DelayedAgentFacade)

    on_exit(fn ->
      case previous do
        {:ok, module} -> Application.put_env(:arbor_voice, :agent_module, module)
        :error -> Application.delete_env(:arbor_voice, :agent_module)
      end
    end)

    call = %{
      id: "default-consultation",
      name: "consult_agent",
      arguments: %{"message" => "Check"}
    }

    events = [
      {:input_transcript, "Check the result"},
      {:tool_call, call},
      {:turn_done, %{text: "Checking"}}
    ]

    # No timeout override: exercise the public facade's default resolution and
    # production consultation router/authority with the existing security fixture.
    %{key: {user, agent} = key, session: session, queue: queue} =
      start_audio(events, tool_router: Arbor.Voice.ToolRouter.PrivateConversation)

    session_ref = Process.monitor(session)
    turn = Task.async(fn -> run_turn(key) end)
    assert_receive {:consultation_started, worker, ^user, ^agent, message, opts}, 1_000
    worker_ref = Process.monitor(worker)
    assert {:links, [owner]} = Process.info(worker, :links)
    owner_ref = Process.monitor(owner)
    assert message.content == "Check the result"
    assert message.sent_at == @ended

    # The old default produces a timeout output and kills this real tool worker
    # during this barrier. Completion is released only after that old deadline.
    refute_receive {:tool_result, "default-consultation", _}, 5_250
    assert Process.alive?(worker)
    assert Keyword.fetch!(opts, :timeout) in 15_001..60_000
    send(worker, {:complete_consultation, "Grounded answer"})

    assert_receive {:tool_result, "default-consultation", output}, 1_000

    assert Jason.decode!(output) == %{
             "success" => true,
             "result" => %{"reply" => "Grounded answer"}
           }

    # Provider final output follows the successfully delivered consultation.
    Agent.update(queue, fn remaining ->
      remaining ++ [{:output_audio, @output}, {:turn_done, %{text: "The result is ready."}}]
    end)

    assert {:ok, result} = Task.await(turn, 2_000)
    assert result.reply == "The result is ready."
    assert result.presentation.audio == @output
    assert result.input_transcript == "Check the result"
    assert length(FakeCommsSession.record_calls(ctx.recorder)) == 1
    assert_receive :audio_closed
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 1_000
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 1_000
    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}, 1_000
    # The timer-owning process is gone; it cannot publish a late timeout.
    refute_receive {:tool_result, "default-consultation", _}, 50
  end

  @tag :fast
  test "tool activation after its original deadline never starts router work" do
    observer = self()
    token = make_ref()
    deadline = System.monotonic_time(:millisecond) + 50

    {owner, monitor} =
      spawn_monitor(fn ->
        Arbor.Voice.ToolCallOwner.run(%{
          session_pid: observer,
          generation: 1,
          call_id: "expired-activation",
          token: token,
          router: Router,
          context: %{name: "expired-activation"},
          authority: %{},
          deadline_ms: deadline
        })
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    # Admission delay counts against the original deadline; activation cannot
    # mint a fresh relative allowance or invoke the router after expiry.
    refute_receive {:tool_invoked, "expired-activation"}, 75
    assert System.monotonic_time(:millisecond) >= deadline
    send(owner, {:activate, token})
    assert_receive {:tool_outcome, 1, "expired-activation", ^token, output}, 1_000
    assert Jason.decode!(output) == %{"code" => "tool_timeout"}
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1_000
    refute_receive {:tool_invoked, "expired-activation"}
  end

  @tag :fast
  test "configured consultation and audio allowances share one shrinking deadline through final reply",
       ctx do
    install_delayed_agent()
    call = %{id: "short-success", name: "consult_agent", arguments: %{"message" => "Check"}}

    %{key: key, session: session, queue: queue} =
      start_audio(
        [{:input_transcript, "Check"}, {:tool_call, call}, {:turn_done, %{text: "Checking"}}],
        tool_router: Arbor.Voice.ToolRouter.PrivateConversation,
        tool_router_timeout_ms: 1_500,
        audio_turn_timeout_ms: 3_000,
        progress_threshold_ms: 50
      )

    task = Task.async(fn -> run_turn(key) end)
    assert_receive {:consultation_started, worker, _, _, _, opts}, 1_000
    worker_ref = Process.monitor(worker)
    %{turn: turn, session_deadline_ms: session_deadline} = :sys.get_state(session)
    assert turn.ticket.deadline_ms == turn.deadline_ms
    assert turn.deadline_ms <= session_deadline
    assert (turn.deadline_ms - System.monotonic_time(:millisecond)) in 1..3_000
    assert opts[:timeout] in 1..1_500
    refute_receive {:tool_result, "short-success", _}, 100
    assert Process.alive?(worker)
    send(worker, {:complete_consultation, "Grounded answer"})
    assert_receive {:tool_result, "short-success", output}, 1_000
    assert Jason.decode!(output)["success"] == true
    release_final_audio(queue)
    assert {:ok, %{presentation: %{audio: @output}}} = Task.await(task, 2_000)
    assert_receive :audio_closed
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 1_000
    assert length(FakeCommsSession.record_calls(ctx.recorder)) == 1
    refute_receive {:tool_result, "short-success", _}
  end

  @tag :fast
  test "short consultation expiry kills its exact worker and still allows a final timeout reply",
       ctx do
    install_delayed_agent()
    call = %{id: "short-timeout", name: "consult_agent", arguments: %{"message" => "Check"}}

    %{key: key, queue: queue} =
      start_audio(
        [{:input_transcript, "Check"}, {:tool_call, call}, {:turn_done, %{text: "Checking"}}],
        tool_router: Arbor.Voice.ToolRouter.PrivateConversation,
        tool_router_timeout_ms: 500,
        audio_turn_timeout_ms: 3_000,
        progress_threshold_ms: 50
      )

    task = Task.async(fn -> run_turn(key) end)
    assert_receive {:consultation_started, worker, _, _, _, opts}, 1_000
    worker_ref = Process.monitor(worker)
    assert opts[:timeout] in 1..500
    assert_receive {:tool_result, "short-timeout", output}, 1_500
    assert Jason.decode!(output) == %{"code" => "tool_timeout"}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 1_000
    send(worker, {:complete_consultation, "Too late"})
    release_final_audio(queue)
    assert {:ok, _} = Task.await(task, 2_000)
    assert_receive :audio_closed
    assert length(FakeCommsSession.record_calls(ctx.recorder)) == 1
    refute_receive {:tool_result, "short-timeout", _}
  end

  @tag :fast
  test "short audio expiry bounds a longer consultation and discards its late result", ctx do
    install_delayed_agent()
    call = %{id: "audio-deadline", name: "consult_agent", arguments: %{"message" => "Check"}}

    %{key: key, session: session} =
      start_audio(
        [{:input_transcript, "Check"}, {:tool_call, call}, {:turn_done, %{text: "Checking"}}],
        tool_router: Arbor.Voice.ToolRouter.PrivateConversation,
        tool_router_timeout_ms: 2_000,
        audio_turn_timeout_ms: 500,
        progress_threshold_ms: 50
      )

    session_ref = Process.monitor(session)
    task = Task.async(fn -> run_turn(key) end)
    assert_receive {:consultation_started, worker, _, _, _, opts}, 1_000
    worker_ref = Process.monitor(worker)
    %{turn: turn} = :sys.get_state(session)
    assert turn.ticket.deadline_ms == turn.deadline_ms
    assert opts[:timeout] in 1..500
    assert {:error, reason} = Task.await(task, 2_000)
    assert reason in [:turn_timeout, :turn_failed, :cleanup_pending]
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
    assert_receive {:DOWN, ^session_ref, :process, ^session, _}, 2_000
    # A callback killed at the deadline may conservatively report cleanup_pending;
    # it must never publish a successful turn or late tool result.
    send(worker, {:complete_consultation, "Too late"})
    assert FakeCommsSession.record_calls(ctx.recorder) == []
    refute_receive {:tool_result, "audio-deadline", _}
  end

  defp install_delayed_agent do
    previous = Application.fetch_env(:arbor_voice, :agent_module)
    Application.put_env(:arbor_voice, :agent_module, DelayedAgentFacade)

    on_exit(fn ->
      case previous do
        {:ok, module} -> Application.put_env(:arbor_voice, :agent_module, module)
        :error -> Application.delete_env(:arbor_voice, :agent_module)
      end
    end)
  end

  @tag :fast
  test "security regression: bounded receive cancellation discards late output, closes, and permits retry",
       ctx do
    custody = %{
      pid: self(),
      revoked: :atomics.new(1, []),
      deadline: System.monotonic_time(:millisecond) + 5_000
    }

    %{key: {user, agent}, handle: handle, session: session} =
      start_audio([{:block, :bounded_cancel}], [], custody)

    turn =
      Task.async(fn ->
        Voice.owned_desk_audio_turn(handle, input(),
          operation_id: "utterance-1",
          utterance_ended_at: @ended
        )
      end)

    assert_receive {:receive_blocked, :bounded_cancel, worker}
    owner = :sys.get_state(session).owner
    cancel = Task.async(fn -> Voice.cancel_audio_turn(user, agent, "utterance-1") end)
    # Test-only synchronization observes the actual resource fence before
    # releasing the backend; elapsed time alone is not evidence of cancellation.
    assert :ok = await_owner_closing(owner, System.monotonic_time(:millisecond) + 500)
    send(worker, {:release, {:output_audio, @output}})
    assert :ok = Task.await(cancel, 2_000)
    assert {:error, :audio_cancelled, :closed} = Task.await(turn, 2_000)
    assert_receive :audio_closed
    assert :ok = Voice.stop_owned_desk_session(handle)
    assert FakeCommsSession.record_calls(ctx.recorder) == []
    refute_receive {:rendered, _}
    %{key: next} = start_audio(final_events())
    assert {:ok, _} = run_turn(next)
  end

  @tag :fast
  test "exact-operation cancellation remains serviceable while receive is blocked and rejects late output",
       ctx do
    %{key: {user, agent} = key, session: session} = start_audio([{:block, :cancel}])
    task = Task.async(fn -> run_turn(key) end)
    assert_receive {:receive_blocked, :cancel, worker}
    worker_monitor = Process.monitor(worker)
    assert {:ok, _} = Voice.session_status(key)
    assert {:error, :not_found} = Voice.cancel_audio_turn(user, agent, "wrong-operation")
    assert Process.alive?(worker)
    assert {:error, :cleanup_pending} = Voice.cancel_audio_turn(user, agent, "utterance-1")
    assert {:error, :cleanup_pending} = Task.await(task, 2_000)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}
    send(worker, {:release, {:turn_done, %{text: "Too late"}}})
    assert FakeCommsSession.record_calls(ctx.recorder) == []
    refute_receive {:rendered, _}
    refute Process.alive?(session)
    assert_receive {:audio_telemetry, _, _, %{status: :cleanup_pending}}
    refute_receive {:audio_telemetry, _, _, _}
  end

  @tag :fast
  test "stop, caller death and hard timeout retire a blocked receive with one terminal telemetry",
       ctx do
    for action <- [:stop, :caller_death, :hard_timeout] do
      %{key: key, session: session} = start_audio([{:block, action}])
      parent = self()
      caller = spawn(fn -> send(parent, {:audio_reply, action, run_turn(key)}) end)
      assert_receive {:receive_blocked, ^action, worker}
      mon = Process.monitor(worker)

      case action do
        :stop -> assert {:error, :cleanup_pending} = Voice.stop_session(key)
        :caller_death -> Process.exit(caller, :kill)
        :hard_timeout -> send(session, :hard_timeout)
      end

      assert_receive {:DOWN, ^mon, :process, ^worker, :killed}, 2_000
      assert_receive {:audio_telemetry, _, _, %{kind: :audio}}, 2_000
      refute_receive {:audio_telemetry, _, _, _}
    end

    assert FakeCommsSession.record_calls(ctx.recorder) == []
  end

  @tag :fast
  test "buffered PCM is redacted from Session inspection and output never precedes durable acknowledgement",
       ctx do
    events = [{:input_transcript, "Real input"}, {:output_audio, @output}, {:block, :inspect}]
    %{key: key, session: session} = start_audio(events)
    task = Task.async(fn -> run_turn(key) end)
    assert_receive {:receive_blocked, :inspect, worker}
    refute inspect(:sys.get_state(session), limit: :infinity) =~ @input
    refute inspect(:sys.get_state(session), limit: :infinity) =~ @output
    refute inspect(:sys.get_status(session), limit: :infinity) =~ @output
    FakeCommsSession.set_record_waiter(ctx.recorder, self())
    FakeCommsSession.set_record_mode(ctx.recorder, :block)
    send(worker, {:release, {:turn_done, %{text: "The result is ready."}}})
    assert_receive {:record_entered, ^session}
    refute_receive {:rendered, _}
    refute_receive :audio_closed
    assert Task.yield(task, 0) == nil
    send(session, :release_record)
    assert {:ok, %{presentation: %{audio: @output}}} = Task.await(task, 2_000)
  end

  @tag :fast
  test "transcript failure prevents rendering, PCM release and success but still closes", ctx do
    %{key: key} = start_audio(final_events())
    FakeCommsSession.set_record_result(ctx.recorder, {:error, :offline})

    log = capture_log(fn -> assert {:error, :transcript_record_failed} = run_turn(key) end)
    assert log =~ "stage=audio_persistence reason=transcript_record_failed"
    refute log =~ "Actual utterance."
    refute log =~ "The result is ready."
    refute log =~ @input
    refute log =~ @output
    assert_receive :audio_closed
    refute_receive {:rendered, _}
    refute_receive {:legacy_speech, _}
    assert_receive {:audio_telemetry, _, _, %{status: :transcript_record_failed}}
  end

  @tag :fast
  test "owner total deadline survives the successful send and kills a blocked receive" do
    queue = start_supervised!({Agent, fn -> [{:block, :total_deadline}] end})

    {:ok, owner} =
      Arbor.Voice.ResourceOwner.start(self(), Backend, [parent: self(), queue: queue],
        close_timeout_ms: 1_000,
        cleanup_ready_timeout_ms: 200,
        cleanup_per_attempt_timeout_ms: 100
      )

    {:ok, ticket} =
      Arbor.Voice.ResourceOwner.reserve_audio_turn(
        owner,
        PcmFormat.mono_s16le(16_000),
        byte_size(@input),
        150
      )

    {:ok, request} = Arbor.Voice.ResourceOwner.handoff_audio(owner, ticket, @input)
    assert {:reply, :ok} = :gen_server.receive_response(request, 1_000)
    assert_receive {:voice_audio_turn_ready, ^ticket}
    {:ok, receive_request} = Arbor.Voice.ResourceOwner.recv_audio_request(owner, ticket, 100)
    assert_receive {:receive_blocked, :total_deadline, worker}
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000

    assert_receive {:voice_audio_operation_result, ^ticket, {:error, :owner_timeout},
                    {:error, :cleanup_pending}},
                   1_000

    assert {:reply, %Arbor.Voice.Redacted{}} =
             :gen_server.receive_response(receive_request, 1_000)

    refute_receive {:voice_audio_operation_result, ^ticket, _, _}
  end

  @tag :fast
  test "D1 authoritative dispatch confirmation replaces provider text and suppresses its PCM",
       ctx do
    call = %{id: "dispatch", name: "dispatch_coding_task", arguments: %{"task" => "Fix the test"}}

    events = [
      {:input_transcript, "Fix the test"},
      {:tool_call, call},
      {:turn_done, %{text: "Starting"}},
      {:output_audio, @output},
      {:turn_done, %{text: "I already fixed everything."}}
    ]

    %{key: key} = start_audio(events, tool_router: DispatchRouter)
    assert {:ok, result} = run_turn(key)
    expected = Arbor.Voice.Session.ManagedDispatchCore.confirmation_sentence()
    assert result.reply == expected

    assert result.presentation == %{
             verdict: {:speak, expected},
             spoken_text: expected,
             audio: nil,
             format: nil
           }

    assert [{_, _, _, assistant, _}] = FakeCommsSession.record_calls(ctx.recorder)
    assert assistant.content == expected
    assert_receive {:audio_telemetry, _, %{first_audio_ms: nil}, %{status: :success}}
    refute_receive {:legacy_speech, _}
  end

  @tag :fast
  test "Session operation deadline fences pending STT independently of the longer session budget",
       ctx do
    %{key: key, session: session} =
      start_audio([{:turn_done, %{text: "Waiting for input"}}, {:block, :pending_stt}])

    task = Task.async(fn -> run_turn(key) end)
    assert_receive {:receive_blocked, :pending_stt, worker}
    %{turn: turn} = :sys.get_state(session)
    assert Process.read_timer(turn.deadline_timer) in 1..60_000
    assert turn.deadline_ms > System.monotonic_time(:millisecond)
    monitor = Process.monitor(worker)
    send(session, {:audio_turn_deadline, turn.generation, turn.deadline_token})
    assert {:error, :cleanup_pending} = Task.await(task, 2_000)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert FakeCommsSession.record_calls(ctx.recorder) == []
    assert_receive {:audio_telemetry, _, _, %{status: :cleanup_pending}}
  end

  defp await_owner_closing(owner, deadline) do
    cond do
      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      :sys.get_state(owner).phase == :closing ->
        :ok

      true ->
        receive do
        after
          1 -> await_owner_closing(owner, deadline)
        end
    end
  catch
    :exit, _ -> :owner_exited
  end
end
