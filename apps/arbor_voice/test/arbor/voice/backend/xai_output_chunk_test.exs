defmodule Arbor.Voice.Backend.XaiOutputChunkTest do
  use ExUnit.Case, async: true

  alias Arbor.Voice.Backend.XaiRealtime
  alias Arbor.Voice.BackendWorker
  alias Arbor.Voice.BackendWorker.{EffectRequest, Result}
  alias Arbor.Voice.BackendWorkerSupervisor
  alias Arbor.Voice.Contracts.AudioTurn
  alias Arbor.Voice.{PcmFormat, Redacted}
  alias Arbor.Voice.Session.AudioTurnCore
  alias Arbor.Voice.Test.XaiRealtimeFakeTransport, as: FakeTransport

  @moduletag :fast

  defmodule ScriptedTransport do
    def connect(opts) do
      observer = Keyword.fetch!(opts, :observer)

      frames =
        Arbor.Voice.Backend.XaiOutputChunkTest.frames(Keyword.fetch!(opts, :scenario))

      opts =
        opts
        |> Keyword.put(:frames, frames)
        |> Keyword.put(:on_recv, fn -> send(observer, :scripted_recv) end)
        |> Keyword.put(:on_close, fn ->
          send(observer, :scripted_closed)
          :ok
        end)

      FakeTransport.connect(opts)
    end

    defdelegate send_frame(state, frame, deadline), to: FakeTransport
    defdelegate recv_frame(state, timeout), to: FakeTransport
    defdelegate close(state), to: FakeTransport
  end

  test "valid wire PCM is split without rewriting bytes or overtaking following events" do
    for bytes <- [65_538, 196_610, PcmFormat.max_bytes()] do
      pcm = pcm(bytes)

      following = [
        %{"type" => "response.output_text.delta", "delta" => "Answer"},
        %{
          "type" => "response.function_call_arguments.done",
          "call_id" => "fixture-call",
          "name" => "consult_agent",
          "arguments" => ~s({"message":"fixture"})
        },
        %{"type" => "response.done"}
      ]

      session = configured([audio_frame(pcm) | following])
      {session, chunks} = drain_audio(session, byte_size(pcm))
      assert IO.iodata_to_binary(chunks) == pcm
      assert Enum.all?(chunks, &AudioTurn.output_chunk?/1)
      assert length(chunks) == div(bytes + AudioTurn.max_output_event_bytes() - 1, 65_536)
      assert session.transport_state.frames == following
      assert session.pending_audio == <<>>
      assert {:ok, session, {:output_text_delta, "Answer"}} = XaiRealtime.recv(session, 100)

      assert {:ok, session, {:tool_call, %{id: "fixture-call", name: "consult_agent"}}} =
               XaiRealtime.recv(session, 100)

      assert {:ok, session, {:turn_done, %{text: "Answer"}}} = XaiRealtime.recv(session, 100)
      assert :ok = XaiRealtime.close(session)
    end
  end

  test "security regression: the complete wire blob and format are validated before any split escapes" do
    large = pcm(65_538)
    valid = audio_frame(large)
    parent = self()

    invalid = [
      audio_frame(pcm(PcmFormat.max_bytes() + 2)),
      audio_frame(large <> <<1>>),
      %{valid | "delta" => Base.encode64(large) <> "!"},
      Map.put(valid, "format", %{"type" => "audio/pcm", "rate" => 16_000}),
      Map.put(valid, "output_audio_format", "not specified")
    ]

    for frame <- invalid do
      session =
        configured([frame, %{"type" => "response.done"}],
          on_close: fn state ->
            send(parent, {:closed_remaining, length(state.frames)})
            :ok
          end
        )

      assert {:error, :xai_audio_protocol_error} = XaiRealtime.recv(session, 100)
      assert_receive {:closed_remaining, 1}
    end
  end

  test "pending PCM is redacted and an expired receive preserves it without delivery or transport reads" do
    marker = "distinctive-private-pending-pcm!!"
    secret = marker <> marker
    pcm = :binary.copy(<<0, 0>>, 32_768) <> secret
    session = configured([audio_frame(pcm)], [], fn -> 0 end)
    assert {:ok, session, {:output_audio, first}} = XaiRealtime.recv(session, 100)
    assert byte_size(first) == AudioTurn.max_output_event_bytes()
    assert session.pending_audio == secret
    refute inspect(session, limit: :infinity, printable_limit: :infinity) =~ marker
    assert {:error, :timeout, unchanged} = XaiRealtime.recv(session, 0)
    assert unchanged == session
    assert {:ok, session, {:output_audio, ^secret}} = XaiRealtime.recv(unchanged, 100)
    assert session.pending_audio == <<>>
    assert :ok = XaiRealtime.close(session)
  end

  @tag :integration
  test "real worker normalization and acknowledgements retain split PCM through core completion" do
    {worker, credential} = start_worker(:ordered)
    {:ok, core} = AudioTurnCore.new(PcmFormat.mono_s16le(24_000))

    assert {:ok, transcript} = operation(worker, credential, :recv, [100])
    assert {:continue, core} = AudioTurnCore.reduce(core, transcript)

    {core, chunks} =
      Enum.reduce(1..4, {core, []}, fn _, {core, chunks} ->
        assert {:ok, {:output_audio, chunk} = event} =
                 operation(worker, credential, :recv, [100])

        assert AudioTurn.output_chunk?(chunk)
        assert {:continue, next} = AudioTurnCore.reduce(core, event)
        {next, [chunk | chunks]}
      end)

    assert IO.iodata_to_binary(Enum.reverse(chunks)) == pcm(196_610)

    assert {:ok, {:output_text_delta, "Answer"} = text} =
             operation(worker, credential, :recv, [100])

    assert {:continue, core} = AudioTurnCore.reduce(core, text)

    assert {:ok, {:turn_done, %{text: "Answer"}} = terminal} =
             operation(worker, credential, :recv, [100])

    assert {:done, completed} = AudioTurnCore.reduce(core, terminal)
    chunks = completed |> Redacted.value() |> Map.fetch!(:audio) |> Redacted.value()
    assert IO.iodata_to_binary(chunks) == pcm(196_610)
    close_worker(worker, credential)
  end

  @tag :integration
  test "security regression: normalized provider chunks retain the complete operation byte ceiling" do
    {worker, credential} = start_worker(:overflow)
    {:ok, core} = AudioTurnCore.new(PcmFormat.mono_s16le(24_000))
    assert {:ok, transcript} = operation(worker, credential, :recv, [100])
    assert {:continue, core} = AudioTurnCore.reduce(core, transcript)
    count = div(AudioTurn.max_output_bytes(), AudioTurn.max_output_event_bytes())

    core =
      Enum.reduce(1..count, core, fn _, core ->
        assert {:ok, {:output_audio, chunk} = event} =
                 operation(worker, credential, :recv, [100])

        assert byte_size(chunk) == AudioTurn.max_output_event_bytes()
        assert {:continue, next} = AudioTurnCore.reduce(core, event)
        next
      end)

    assert {:ok, {:output_audio, <<1, 2>>} = overflow} =
             operation(worker, credential, :recv, [100])

    assert {:error, :protocol_error} = AudioTurnCore.reduce(core, overflow)
    close_worker(worker, credential)
  end

  @tag :integration
  test "worker retirement discards a pending remainder without receiving another provider frame" do
    {worker, credential} = start_worker(:ordered)
    assert {:ok, {:input_transcript, _}} = operation(worker, credential, :recv, [100])
    assert {:ok, {:output_audio, _}} = operation(worker, credential, :recv, [100])
    # Configuration acknowledgement, completed STT and the one large wire delta.
    for _ <- 1..3, do: assert_receive(:scripted_recv)
    close_worker(worker, credential)
    assert_receive :scripted_closed
    refute_receive :scripted_recv, 0
    refute Process.alive?(worker)
  end

  # Construct large fixtures inside the backend process: startup options contain
  # only the scenario atom, never large PCM or a closure capturing its bytes.
  def frames(:ordered) do
    [
      %{"type" => "conversation.item.input_audio_transcription.completed", "transcript" => "Ask"},
      audio_frame(pcm(196_610)),
      %{"type" => "response.output_text.delta", "delta" => "Answer"},
      %{"type" => "response.done"}
    ]
  end

  def frames(:overflow) do
    [
      %{"type" => "conversation.item.input_audio_transcription.completed", "transcript" => "Ask"}
      | List.duplicate(audio_frame(pcm(PcmFormat.max_bytes())), 4)
    ] ++ [audio_frame(<<1, 2>>), %{"type" => "response.done"}]
  end

  defp pcm(bytes) do
    limit = AudioTurn.max_output_event_bytes()

    for index <- 0..div(bytes - 1, limit), into: <<>> do
      size = min(limit, bytes - index * limit)
      :binary.copy(<<index, 255 - index>>, div(size, 2))
    end
  end

  defp audio_frame(pcm),
    do: %{"type" => "response.output_audio.delta", "delta" => Base.encode64(pcm)}

  defp configured(frames, opts \\ [], clock \\ fn -> System.monotonic_time(:millisecond) end) do
    assert {:ok, session} =
             XaiRealtime.open(
               transport: FakeTransport,
               transport_opts: Keyword.put(opts, :frames, frames),
               clock_fun: clock,
               effect_authorizer: fn _, _ -> :allow end,
               oauth_resolver: fn :xai -> {:ok, "fixture-token"} end
             )

    assert {:ok, session} = XaiRealtime.configure(session, %{audio_mode: :pcm16})
    session
  end

  defp drain_audio(session, 0), do: {session, []}

  defp drain_audio(session, remaining) do
    assert {:ok, session, {:output_audio, chunk}} = XaiRealtime.recv(session, 100)
    assert AudioTurn.output_chunk?(chunk)
    {session, rest} = drain_audio(session, remaining - byte_size(chunk))
    {session, [chunk | rest]}
  end

  defp start_worker(scenario) do
    supervisor = start_supervised!({BackendWorkerSupervisor, name: nil})

    opts = [
      transport: ScriptedTransport,
      transport_opts: [scenario: scenario, observer: self()],
      oauth_resolver: fn :xai -> {:ok, "fixture-token"} end
    ]

    assert {:ok, worker, credential} =
             BackendWorkerSupervisor.start_worker(
               supervisor,
               self(),
               make_ref(),
               XaiRealtime,
               opts,
               XaiRealtime.egress_route(),
               effect_timeout_ms: 1_000,
               ack_timeout_ms: 2_000
             )

    assert :ok = operation(worker, credential, :open, [])
    assert :ok = operation(worker, credential, :configure, [%{audio_mode: :pcm16}])
    {worker, credential}
  end

  defp operation(worker, credential, operation, args) do
    token = BackendWorker.new_operation_token()

    assert :ok =
             BackendWorker.submit(
               worker,
               credential,
               token,
               System.monotonic_time(:millisecond) + 2_000,
               operation,
               args
             )

    receive_result(worker, credential, token)
  end

  defp receive_result(worker, credential, token) do
    receive do
      %EffectRequest{worker: ^worker, operation_token: ^token} = request ->
        assert {:ok, ^request} = BackendWorker.verify_effect_request(request, credential)
        assert :ok = BackendWorker.reply_effect(request, credential, :allow)
        receive_result(worker, credential, token)

      {:voice_backend_operation_result,
       %Result{worker: ^worker, operation_token: ^token} = result} ->
        assert {:ok, verified} = BackendWorker.verify_result(result, credential)
        assert :ok = BackendWorker.ack(worker, credential, result)
        verified.outcome
    after
      2_000 -> flunk("backend operation did not settle")
    end
  end

  defp close_worker(worker, credential) do
    monitor = Process.monitor(worker)
    assert :ok = operation(worker, credential, :close, [])
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
  end
end
