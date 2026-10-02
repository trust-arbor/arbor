defmodule Arbor.Voice.DeskTest do
  use ExUnit.Case, async: false
  alias Arbor.Voice
  alias Arbor.Voice.DeskCore
  @moduletag :fast
  @moduletag spec: "VOICE-13"
  defmodule F do
    def get(k), do: :ets.lookup_element(:voice_desk_fixture, k, 2)
    def put(k, v), do: :ets.insert(:voice_desk_fixture, {k, v})
    def event(e), do: send(get(:parent), e)
  end

  defmodule Security do
    defdelegate authorize(a, b, c, d), to: Arbor.Voice.Test.ConversationSecurityFixture

    defdelegate authorize_and_issue_delivery_receipt(a, b, c, d),
      to: Arbor.Voice.Test.ConversationSecurityFixture

    defdelegate authorize_and_issue_conversation_receipt(a, b, c, d),
      to: Arbor.Voice.Test.ConversationSecurityFixture

    defdelegate conversation_receipt_owner(a, b, c),
      to: Arbor.Voice.Test.ConversationSecurityFixture

    defdelegate discard_delivery_receipt(a), to: Arbor.Voice.Test.ConversationSecurityFixture

    defdelegate consume_delivery_receipt(a, b, c),
      to: Arbor.Voice.Test.ConversationSecurityFixture

    defdelegate grant_capability_id(a), to: Arbor.Voice.Test.ConversationSecurityFixture

    defdelegate issue_disclosure_capability_id(a),
      to: Arbor.Voice.Test.ConversationSecurityFixture

    defdelegate revoke(a), to: Arbor.Voice.Test.ConversationSecurityFixture
    defdelegate uri_registered?(a), to: Arbor.Voice.Test.ConversationSecurityFixture

    defdelegate validate_disclosure_capability(a, b, c),
      to: Arbor.Voice.Test.ConversationSecurityFixture

    def recheck_conversation_session(_, _, _, _),
      do: if(F.get(:authorized), do: {:ok, :authorized}, else: {:error, :denied})

    def issue_signed_conversation_session(_, _, %{signature: "valid"}), do: {:ok, "fixture-token"}
    def issue_signed_conversation_session(_, _, _), do: {:error, :denied}
  end

  defmodule Comms do
    def resolve_user_engagement(agent, user, _),
      do:
        {:ok,
         %{
           id: "eng_" <> String.duplicate("a", 32),
           agent_id: agent,
           owner_tenant: user,
           scope: :user,
           visibility: :private
         }}
  end

  defmodule Multimedia do
    def capture_pcm(opts) do
      F.event({:capture, opts, self()})
      hold(:capture)

      {:ok,
       %{
         audio: %{
           pcm: :binary.copy(<<1, 0>>, opts[:duration_ms] * 16),
           sample_rate: 16_000,
           channels: 1,
           sample_format: :s16le
         },
         utterance_ended_at: ~U[2026-09-27 12:00:00Z]
       }}
    end

    def play_pcm(audio, opts),
      do:
        (
          F.event({:play, audio, opts, self()})
          hold(:play)
          :ok
        )

    def device_status, do: F.get(:device_status)

    defp hold(k) do
      if F.get(k) == :hold do
        F.put(:device_status, :cleanup_pending)

        receive do
          :release -> :ok
        end
      end
    end
  end

  defmodule Turn do
    def start_owned_desk_session(user, agent, opts, custody),
      do:
        (
          if closed = Map.get(custody, :closed), do: :atomics.put(closed, 1, 0)
          F.event({:session, user, agent, opts[:audio_mode], custody})
          {:ok, :fixture}
        )

    def owned_desk_audio_turn(:fixture, input, opts) do
      case F.get(:turn) do
        :failed_closed -> {:error, :turn_failed, :closed}
        :failed_pending -> {:error, :turn_failed, :cleanup_pending}
        _ -> successful_turn(input, opts)
      end
    end

    defp successful_turn(input, opts) do
      F.event({:turn, input, opts})
      if F.get(:turn) == :revoke, do: F.put(:authorized, false)

      p =
        if F.get(:presentation) == :pcm,
          do: %{
            verdict: {:speak, "Safe response"},
            spoken_text: "Safe response",
            audio: <<7, 0, 8, 0>>,
            format: %{encoding: :pcm, sample_rate: 24_000, channels: 1, sample_format: :s16le}
          },
          else: %{
            verdict: {:screen_only, "Read the screen"},
            spoken_text: "",
            audio: nil,
            format: nil
          }

      {:ok,
       %{
         operation_id: opts[:operation_id],
         reply: "Durable response",
         input_transcript: "Recognized speech",
         presentation: p
       }}
    end

    def stop_owned_desk_session(_) do
      F.event(:session_closed)
      if F.get(:turn) == :failed_pending, do: {:error, :cleanup_pending}, else: :ok
    end
  end

  setup do
    :ets.new(:voice_desk_fixture, [:named_table, :public, :set])

    for {k, v} <- [
          parent: self(),
          authorized: true,
          capture: :ok,
          play: :ok,
          turn: :ok,
          presentation: :pcm,
          device_status: :idle
        ],
        do: F.put(k, v)

    env = [
      security_module: Security,
      desk_multimedia_module: Multimedia,
      desk_voice_module: Turn,
      desk_comms_module: Comms,
      desk_session_options: []
    ]

    prev = for {k, _} <- env, do: {k, Application.fetch_env(:arbor_voice, k)}
    for {k, v} <- env, do: Application.put_env(:arbor_voice, k, v)

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Arbor.Voice.DeskSupervisor),
          is_pid(pid),
          do: DynamicSupervisor.terminate_child(Arbor.Voice.DeskSupervisor, pid)

      for {k, v} <- prev do
        case v do
          {:ok, value} -> Application.put_env(:arbor_voice, k, value)
          :error -> Application.delete_env(:arbor_voice, k)
        end
      end
    end)

    :ok
  end

  defp start(opts \\ []),
    do:
      Voice.start_desk_turn(
        "desk-user",
        "desk-agent",
        Keyword.merge([session_token: "fixture-token", duration_ms: 100], opts)
      )

  defp done(id, n \\ 150)
  defp done(_, 0), do: flunk("desk did not settle")

  defp done(id, n) do
    {:ok, s} = Voice.desk_turn_status(id)

    if s.terminal,
      do: s,
      else:
        (
          Process.sleep(10)
          done(id, n - 1)
        )
  end

  test "authenticated turn captures16k and plays only guarded24k output" do
    assert {:ok, id} = start(input_device: 3, output_device: 4)
    assert %{state: :complete, result: %{disposition: :played}} = state = done(id)
    assert_receive {:capture, [duration_ms: 100, sample_rate: 16_000, device_id: 3], _}

    assert_receive {:turn, %{sample_rate: 16_000},
                    [operation_id: ^id, utterance_ended_at: ~U[2026-09-27 12:00:00Z]]}

    assert_receive {:play, %{pcm: <<7, 0, 8, 0>>, sample_rate: 24_000}, [device_id: 4], _}
    refute inspect(state) =~ "pcm"
    refute Map.has_key?(state.result, :audio)
  end

  test "loopback shares custody without starting Voice or provider" do
    assert {:ok, id} = start(mode: :loopback)

    assert %{
             state: :complete,
             mode: :loopback,
             result: %{capture_frames: 1600, disposition: :played}
           } = done(id)

    assert_receive {:play, %{sample_rate: 16_000}, _, _}
    refute_receive {:session, _, _, _, _}
  end

  test "security regression: revoked conversation cannot play after Voice cleanup" do
    F.put(:turn, :revoke)
    assert {:ok, id} = start()
    assert %{state: :cancelled, error: :conversation_unauthorized} = done(id)
    refute_receive {:play, _, _, _}
  end

  test "screen-only fallback does not invent TTS or playback" do
    F.put(:presentation, :screen)
    assert {:ok, id} = start()
    assert %{state: :complete, result: %{disposition: :screen_only, spoken_text: ""}} = done(id)
    refute_receive {:play, _, _, _}
  end

  test "security regression: killed capture caller remains pending until positive device closure" do
    F.put(:capture, :hold)
    assert {:ok, id} = start()
    assert_receive {:capture, _, worker}
    assert {:error, :cleanup_pending} = Voice.cancel_desk_turn(id)
    Process.sleep(30)
    refute Process.alive?(worker)
    assert {:ok, %{terminal: false, state: :cleanup_pending}} = Voice.desk_turn_status(id)
    F.put(:device_status, :idle)
    assert %{terminal: true, state: :cancelled} = done(id)
    refute_receive {:session, _, _, _, _}
  end

  test "security regression: expired poll lease prevents later turn" do
    F.put(:capture, :hold)
    assert {:ok, id} = start()
    assert_receive {:capture, _, _}
    [{pid, _}] = Registry.lookup(Arbor.Voice.Registry, {:desk, id})
    :sys.replace_state(pid, &%{&1 | lease_until: System.monotonic_time(:millisecond) - 1})
    assert {:ok, %{state: :cleanup_pending}} = Voice.desk_turn_status(id)
    F.put(:device_status, :idle)
    assert %{state: :cancelled, error: :lease_expired} = done(id)
    refute_receive {:turn, _, _}
  end

  test "security regression: options reject remote audio, dual proofs and public overrides" do
    assert {:error, :invalid_desk_options} = start(origin_node: :client@remote)
    assert {:error, :invalid_desk_options} = start(signed_request: %{signature: "valid"})
    assert {:error, :invalid_desk_options} = start(desk_owner: self())
    assert {:error, :invalid_desk_options} = start(multimedia: Multimedia)
    refute_receive {:capture, _, _}
  end

  test "security regression: displayed engagement must match admission before recording" do
    assert {:ok, id} = start(expected_engagement_id: "eng_" <> String.duplicate("b", 32))
    assert %{state: :cancelled, error: :conversation_unauthorized} = done(id)
    refute_receive {:capture, _, _}
    assert {:ok, next} = start(expected_engagement_id: "eng_" <> String.duplicate("a", 32))
    assert %{state: :complete} = done(next)
    assert {:error, :invalid_desk_options} = start(expected_engagement_id: "wrong")
  end

  test "signed proof is exchanged server-side before any device effect" do
    assert {:ok, id} =
             Voice.start_desk_turn("desk-user", "desk-agent",
               signed_request: %{signature: "invalid"},
               duration_ms: 100
             )

    assert %{state: :cancelled, error: :conversation_unauthorized} = done(id)
    refute_receive {:capture, _, _}

    assert {:ok, id} =
             Voice.start_desk_turn("desk-user", "desk-agent",
               signed_request: %{signature: "valid"},
               duration_ms: 100
             )

    assert %{state: :complete} = done(id)
  end

  test "security regression: ordinary status redacts proof and cancellation closes playback" do
    F.put(:play, :hold)
    assert {:ok, id} = start()
    assert_receive {:play, _, _, _}
    [{pid, _}] = Registry.lookup(Arbor.Voice.Registry, {:desk, id})
    refute inspect(:sys.get_status(pid)) =~ "fixture-token"
    refute inspect(:sys.get_status(Process.whereis(Arbor.Voice.Presentation))) =~ "fixture-token"
    assert {:error, :cleanup_pending} = Voice.cancel_desk_turn(id)
    F.put(:device_status, :idle)
    assert done(id).terminal
  end

  test "security regression: confirmed closed provider failure admits another Desk" do
    F.put(:turn, :failed_closed)
    assert {:ok, id} = start()
    assert %{terminal: true, state: :cancelled, error: :turn_failed} = done(id)
    F.put(:turn, :ok)
    assert {:ok, next} = start()
    assert done(next).state == :complete
  end

  test "security regression: revoked authority hides a completed private result" do
    assert {:ok, id} = start()
    assert %{state: :complete, result: %{reply: "Durable response"}} = done(id)
    F.put(:authorized, false)

    assert {:ok, %{terminal: true, result: nil, error: :conversation_unauthorized}} =
             Voice.desk_turn_status(id)
  end

  test "security regression: unknown provider close never becomes terminal from absence" do
    F.put(:turn, :failed_pending)
    assert {:ok, id} = start()
    assert_receive :session_closed
    Process.sleep(30)
    assert {:ok, %{terminal: false, state: :cleanup_pending}} = Voice.desk_turn_status(id)
    assert {:error, :device_busy} = start()
  end

  test "presentation rejects truncated audio and exact host parser stays closed" do
    refute DeskCore.same_host?(:a@one, :b@two)
    assert DeskCore.same_host?(:a@one, :b@one)
    refute DeskCore.same_host?("a@one", :b@one)

    assert {:error, :invalid_presentation} =
             DeskCore.presentation(%{
               verdict: {:speak_truncated, "safe"},
               spoken_text: "safe",
               audio: <<0, 0>>,
               format: %{encoding: :pcm, sample_rate: 24_000, channels: 1, sample_format: :s16le}
             })
  end
end
