defmodule Arbor.Voice.AudioTurnIntegrationTest do
  use ExUnit.Case, async: false

  alias Arbor.Voice
  alias Arbor.Voice.PcmFormat

  alias Arbor.Voice.Test.SessionFakes.{
    FakeCommsSession,
    FakeEngagementStore,
    FakeLedger,
    FakeSignals
  }

  @moduletag :integration
  @moduletag :fast
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

  defp start_audio(events, extra \\ []) do
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

    assert {:ok, ^key} =
             Voice.start_session(elem(key, 0), elem(key, 1), Keyword.merge(opts, extra))

    [{session, _}] = Registry.lookup(Arbor.Voice.Registry, key)
    on_exit(fn -> if Process.alive?(session), do: Voice.stop_session(key) end)
    assert_receive {:configured_audio, config}
    assert config.audio_mode == :pcm16
    %{key: key, session: session, queue: queue}
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

  test "tool before completed STT fails closed before invocation or append", ctx do
    call = %{id: "before_stt", name: "consult_agent", arguments: %{"message" => "Hello"}}
    %{key: key} = start_audio([{:tool_call, call} | final_events()])
    assert {:error, :turn_failed} = run_turn(key)
    refute_receive {:tool_invoked, _}
    assert FakeCommsSession.record_calls(ctx.recorder) == []
    refute_receive {:rendered, _}
  end

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

  test "exact-operation cancellation remains serviceable while receive is blocked and rejects late output",
       ctx do
    %{key: {user, agent} = key, session: session} = start_audio([{:block, :cancel}])
    task = Task.async(fn -> run_turn(key) end)
    assert_receive {:receive_blocked, :cancel, worker}
    worker_monitor = Process.monitor(worker)
    assert {:ok, _} = Voice.session_status(key)
    assert {:error, :not_found} = Voice.cancel_audio_turn(user, agent, "wrong-operation")
    assert Process.alive?(worker)
    assert :ok = Voice.cancel_audio_turn(user, agent, "utterance-1")
    assert {:error, :audio_cancelled} = Task.await(task, 2_000)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}
    send(worker, {:release, {:turn_done, %{text: "Too late"}}})
    assert FakeCommsSession.record_calls(ctx.recorder) == []
    refute_receive {:rendered, _}
    refute Process.alive?(session)
    assert_receive {:audio_telemetry, _, _, %{status: :audio_cancelled}}
    refute_receive {:audio_telemetry, _, _, _}
  end

  test "stop, caller death and hard timeout retire a blocked receive with one terminal telemetry",
       ctx do
    for action <- [:stop, :caller_death, :hard_timeout] do
      %{key: key, session: session} = start_audio([{:block, action}])
      parent = self()
      caller = spawn(fn -> send(parent, {:audio_reply, action, run_turn(key)}) end)
      assert_receive {:receive_blocked, ^action, worker}
      mon = Process.monitor(worker)

      case action do
        :stop -> assert :ok = Voice.stop_session(key)
        :caller_death -> Process.exit(caller, :kill)
        :hard_timeout -> send(session, :hard_timeout)
      end

      assert_receive {:DOWN, ^mon, :process, ^worker, :killed}, 2_000
      assert_receive {:audio_telemetry, _, _, %{kind: :audio}}, 2_000
      refute_receive {:audio_telemetry, _, _, _}
    end

    assert FakeCommsSession.record_calls(ctx.recorder) == []
  end

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

  test "transcript failure prevents rendering, PCM release and success but still closes", ctx do
    %{key: key} = start_audio(final_events())
    FakeCommsSession.set_record_result(ctx.recorder, {:error, :offline})
    assert {:error, :transcript_record_failed} = run_turn(key)
    assert_receive :audio_closed
    refute_receive {:rendered, _}
    refute_receive {:legacy_speech, _}
    assert_receive {:audio_telemetry, _, _, %{status: :transcript_record_failed}}
  end

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
    assert_receive {:voice_audio_operation_result, ^ticket, {:error, :owner_timeout}, :ok}, 1_000

    assert {:reply, %Arbor.Voice.Redacted{}} =
             :gen_server.receive_response(receive_request, 1_000)

    refute_receive {:voice_audio_operation_result, ^ticket, _, _}
  end

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

  test "Session operation deadline fences pending STT independently of the longer session budget",
       ctx do
    %{key: key, session: session} =
      start_audio([{:turn_done, %{text: "Waiting for input"}}, {:block, :pending_stt}])

    task = Task.async(fn -> run_turn(key) end)
    assert_receive {:receive_blocked, :pending_stt, worker}
    %{turn: turn} = :sys.get_state(session)
    assert Process.read_timer(turn.deadline_timer) in 1..30_000
    assert turn.deadline_ms > System.monotonic_time(:millisecond)
    monitor = Process.monitor(worker)
    send(session, {:audio_turn_deadline, turn.generation, turn.deadline_token})
    assert {:error, :turn_timeout} = Task.await(task, 2_000)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert FakeCommsSession.record_calls(ctx.recorder) == []
    assert_receive {:audio_telemetry, _, _, %{status: :turn_timeout}}
  end
end
