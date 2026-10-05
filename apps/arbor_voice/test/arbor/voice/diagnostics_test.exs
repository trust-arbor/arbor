defmodule Arbor.Voice.DiagnosticsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Arbor.Voice.Contracts.AudioTurn
  alias Arbor.Voice.Diagnostics
  alias Arbor.Voice.PcmFormat
  alias Arbor.Voice.Redacted
  alias Arbor.Voice.Session.AudioTurnCore

  @moduletag :fast

  defmodule WaitingRouter do
    def invoke(%{observer: observer}, _authority) do
      send(observer, {:router_waiting, self()})

      receive do
        :release -> {:ok, "released"}
      end
    end
  end

  test "security regression: tool timeout logs no context and preserves terminal outcome" do
    secret = "private-tool-arguments-authority-sentinel"
    observer = self()
    token = make_ref()

    log =
      capture_log(fn ->
        {owner, monitor} =
          spawn_monitor(fn ->
            Arbor.Voice.ToolCallOwner.run(%{
              session_pid: observer,
              generation: 1,
              call_id: secret,
              token: token,
              router: WaitingRouter,
              context: %{observer: observer, arguments: secret},
              authority: %{private: secret},
              deadline_ms: System.monotonic_time(:millisecond) + 100
            })
          end)

        try do
          send(owner, {:activate, token})
          assert_receive {:router_waiting, worker}, 1_000
          worker_monitor = Process.monitor(worker)
          assert_receive {:tool_outcome, 1, ^secret, ^token, output}, 1_000
          assert Jason.decode!(output) == %{"code" => "tool_timeout"}
          assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1_000
          assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 1_000
          refute Process.alive?(worker)
        after
          if Process.alive?(owner), do: Process.exit(owner, :kill)
        end
      end)

    assert log =~ "stage=tool_execution reason=tool_timeout"
    refute log =~ secret
  end

  test "bounded failure stages preserve the original result and distinguish startup failures" do
    log =
      capture_log(fn ->
        assert {:error, :disabled} =
                 Diagnostics.observe(:budget_readiness, {:error, :disabled})

        assert :ok = Diagnostics.failure(:backend_open, {:error, :backend_effect_denied})
        assert :ok = Diagnostics.failure(:backend_configure, :backend_partial_failure)
      end)

    assert log =~ "stage=budget_readiness reason=disabled"
    assert log =~ "stage=backend_open reason=backend_effect_denied"
    assert log =~ "stage=backend_configure reason=backend_partial_failure"
  end

  test "security regression: unknown diagnostic values cannot disclose private content" do
    secret = "diagnostic-private-PCM-proof-transcript-sentinel"

    values = [
      secret,
      %{proof: secret},
      {:error, {:provider_failure, secret}},
      RuntimeError.exception(secret),
      :diagnostic_private_unknown_atom
    ]

    log =
      capture_log(fn ->
        for value <- values do
          assert :ok = Diagnostics.failure(value, value)
          assert {:error, ^value} = Diagnostics.observe(:backend_open, {:error, value})
        end
      end)

    assert length(Regex.scan(~r/stage=unknown reason=unclassified/, log)) == length(values)
    assert length(Regex.scan(~r/stage=backend_open reason=unclassified/, log)) == length(values)
    refute log =~ secret
    refute log =~ "provider_failure"
    refute log =~ "diagnostic_private_unknown_atom"
    refute log =~ "RuntimeError"

    assert capture_log(fn ->
             assert {:ok, ^secret} = Diagnostics.observe(:backend_open, {:ok, secret})
           end) == ""
  end

  test "invalid desk options log configuration failure without changing the closed refusal" do
    secret = "invalid-desk-options-private-sentinel"

    custody = %{
      pid: self(),
      revoked: :atomics.new(1, []),
      deadline: System.monotonic_time(:millisecond) + 10_000
    }

    log =
      capture_log(fn ->
        assert {:error, :start_failed, :closed} =
                 Arbor.Voice.start_owned_desk_session(
                   "diagnostic-user",
                   "diagnostic-agent",
                   [unexpected: secret],
                   custody
                 )
      end)

    assert log =~ "stage=desk_configuration reason=invalid_opts"
    refute log =~ secret
    refute log =~ "diagnostic-user"
    refute log =~ "diagnostic-agent"
  end

  test "security regression: failure expectations preserve results without logging private terms" do
    secret = "private-final-authority-and-provider-sentinel"

    results = [
      {:error, :conversation_unauthorized},
      {:error, :turn_failed, %{proof: secret}},
      false,
      %{provider_response: secret}
    ]

    log =
      capture_log(fn ->
        for result <- results do
          assert Diagnostics.expect(:audio_final_authority, result, :ok) === result
        end
      end)

    assert log =~ "stage=audio_final_authority reason=conversation_unauthorized"
    assert log =~ "stage=audio_final_authority reason=turn_failed"
    assert length(Regex.scan(~r/stage=audio_final_authority reason=unclassified/, log)) == 2
    refute log =~ secret
    refute log =~ "provider_response"
    refute log =~ "proof"

    assert capture_log(fn ->
             assert :healthy = Diagnostics.expect(:audio_final_authority, :healthy, :healthy)
             assert true == Diagnostics.expect(:audio_final_liveness, true, true)
             assert :ok = Diagnostics.expect(:audio_persistence, :ok, :ok)
           end) == ""
  end

  test "security regression: rejected audio events expose only categories in reducer guard order" do
    secret = "private-transcript-tool-arguments-and-PCM-sentinel"
    {:ok, fresh} = AudioTurnCore.new(PcmFormat.mono_s16le(24_000))
    {:continue, spoken} = AudioTurnCore.reduce(fresh, {:input_transcript, secret})
    {:continue, terminal} = AudioTurnCore.reduce(fresh, {:turn_done, %{text: secret}})
    tool = {:tool_call, %{id: secret, name: "consult_agent", arguments: %{"message" => secret}}}

    cases = [
      {fresh, tool, :tool_before_completed_transcript},
      {terminal, tool, :event_after_terminal},
      {terminal, {:output_audio, %{private: secret}}, :event_after_terminal},
      {fresh, {:input_transcript, <<255>> <> secret}, :input_transcript_invalid_utf8},
      {spoken, {:output_audio, secret <> secret <> <<0>>}, :output_audio_odd_bytes},
      {spoken, {:output_text_delta, %{private: secret}}, :invalid_output_text},
      {spoken, {:tool_call, %{id: secret, name: secret, arguments: secret}}, :invalid_tool_call},
      {spoken, {:turn_done, %{text: %{private: secret}}}, :invalid_terminal_event},
      {fresh, {:error, %{code: secret, message: secret}}, :provider_error_event},
      {fresh, {:unknown_event, %{private: secret}}, :invalid_backend_event}
    ]

    log =
      capture_log(fn ->
        for {core, event, _reason} <- cases do
          assert {:error, :protocol_error} = AudioTurnCore.reduce(core, event)
          assert :ok = Diagnostics.audio_rejected(core, event)
        end
      end)

    for {_core, _event, reason} <- cases do
      assert log =~ "stage=audio_reduce reason=#{reason}"
    end

    refute log =~ secret
    refute log =~ "consult_agent"
    refute log =~ "arguments"
    refute log =~ "message"
  end

  test "security regression: rejected transcript shapes expose bounded content-free categories" do
    secret = "private-input-transcript-sentinel"
    {:ok, core} = AudioTurnCore.new(PcmFormat.mono_s16le(24_000))

    cases = [
      {%{private: secret}, :input_transcript_nonbinary},
      {nil, :input_transcript_nonbinary},
      {String.to_charlist(secret), :input_transcript_nonbinary},
      {"", :input_transcript_empty},
      {String.pad_trailing(secret, AudioTurn.max_text_bytes() + 1, "x"),
       :input_transcript_oversized},
      {<<255>> <> String.pad_trailing(secret, AudioTurn.max_text_bytes() + 1, "x"),
       :input_transcript_oversized},
      {<<255>> <> secret, :input_transcript_invalid_utf8},
      {" \t\n\r\u2003", :input_transcript_blank},
      {String.duplicate(" ", AudioTurn.max_text_bytes()), :input_transcript_blank}
    ]

    for {transcript, reason} <- cases do
      event = {:input_transcript, transcript}

      log =
        capture_log(fn ->
          assert {:error, :protocol_error} = AudioTurnCore.reduce(core, event)
          assert :ok = Diagnostics.audio_rejected(core, event)
        end)

      assert log =~ "stage=audio_reduce reason=#{reason}"
      refute log =~ secret
      refute log =~ "private:"
    end
  end

  test "security regression: conflicting transcript completion is redacted and exact duplicates remain accepted" do
    previous = "private-original-transcript-sentinel"
    changed = "private-conflicting-transcript-sentinel"
    {:ok, fresh} = AudioTurnCore.new(PcmFormat.mono_s16le(24_000))
    {:continue, core} = AudioTurnCore.reduce(fresh, {:input_transcript, previous})

    assert capture_log(fn ->
             assert {:continue, ^core} = AudioTurnCore.reduce(core, {:input_transcript, previous})
           end) == ""

    log =
      capture_log(fn ->
        event = {:input_transcript, changed}
        assert {:error, :protocol_error} = AudioTurnCore.reduce(core, event)
        assert :ok = Diagnostics.audio_rejected(core, event)
        assert {:continue, ^core} = AudioTurnCore.reduce(core, {:input_transcript, previous})
      end)

    assert log =~ "stage=audio_reduce reason=input_transcript_conflicting"
    refute log =~ previous
    refute log =~ changed
  end

  test "security regression: malformed audio core cannot be diagnosed as a conflicting transcript" do
    previous = "private-malformed-core-original-sentinel"
    changed = "private-malformed-core-incoming-sentinel"
    {:ok, fresh} = AudioTurnCore.new(PcmFormat.mono_s16le(24_000))
    {:continue, core} = AudioTurnCore.reduce(fresh, {:input_transcript, previous})

    malformed = [
      nil,
      Redacted.new(%{transcript: previous}),
      Redacted.new(Map.put(Redacted.value(core), :audio_bytes, -1)),
      Redacted.new(Map.put(Redacted.value(core), :transcript, <<255>> <> previous))
    ]

    log =
      capture_log(fn ->
        for invalid <- malformed do
          event = {:input_transcript, changed}
          assert {:error, :protocol_error} = AudioTurnCore.reduce(invalid, event)
          assert :ok = Diagnostics.audio_rejected(invalid, event)
        end
      end)

    assert length(Regex.scan(~r/stage=audio_reduce reason=invalid_input_transcript/, log)) ==
             length(malformed)

    refute log =~ "input_transcript_conflicting"
    refute log =~ previous
    refute log =~ changed
  end

  test "security regression: rejected output audio shapes expose only bounded categories" do
    secret = "private-output-PCM-sentinel"
    {:ok, core} = AudioTurnCore.new(PcmFormat.mono_s16le(24_000))

    cases = [
      {%{private: secret}, :output_audio_nonbinary},
      {nil, :output_audio_nonbinary},
      {[secret], :output_audio_nonbinary},
      {<<>>, :output_audio_empty},
      {<<1>>, :output_audio_odd_bytes},
      {secret <> secret <> <<0>>, :output_audio_odd_bytes},
      {String.pad_trailing(secret, AudioTurn.max_output_event_bytes() + 1, "x"),
       :output_audio_oversized}
    ]

    for {chunk, reason} <- cases do
      event = {:output_audio, chunk}

      log =
        capture_log(fn ->
          assert {:error, :protocol_error} = AudioTurnCore.reduce(core, event)
          assert :ok = Diagnostics.audio_rejected(core, event)
        end)

      assert log =~ "stage=audio_reduce reason=#{reason}"
      refute log =~ secret
      refute log =~ "private:"
    end
  end

  test "output audio accepts the cumulative boundary and diagnoses the next two bytes" do
    secret = "private-boundary-PCM-sentinel"
    {:ok, fresh} = AudioTurnCore.new(PcmFormat.mono_s16le(24_000))
    core = fill_output_audio(fresh, secret)
    assert Redacted.value(core).audio_bytes == AudioTurn.max_output_bytes()
    assert Redacted.value(core).total_audio_bytes == AudioTurn.max_output_bytes()
    event = {:output_audio, <<0, 0>>}

    log =
      capture_log(fn ->
        assert {:error, :protocol_error} = AudioTurnCore.reduce(core, event)
        assert :ok = Diagnostics.audio_rejected(core, event)
        assert {:continue, ^core} = AudioTurnCore.reduce(core, {:output_text_delta, ""})
      end)

    assert log =~ "stage=audio_reduce reason=output_audio_total_byte_limit"
    refute log =~ secret
  end

  test "discarded tool-wave audio consumes the cumulative bound across a cycle reset" do
    secret = "private-discarded-PCM-and-tool-sentinel"
    {:ok, fresh} = AudioTurnCore.new(PcmFormat.mono_s16le(24_000))
    {:continue, spoken} = AudioTurnCore.reduce(fresh, {:input_transcript, secret})
    call = %{id: secret, name: "consult_agent", arguments: %{"message" => secret}}
    {:admit_tool, wave, ^call} = AudioTurnCore.reduce(spoken, {:tool_call, call})
    core = fill_output_audio(wave, secret)
    assert Redacted.value(core).audio_bytes == 0
    assert Redacted.value(core).audio_rev == []
    assert Redacted.value(core).total_audio_bytes == AudioTurn.max_output_bytes()
    {:cycle_reset, reset} = AudioTurnCore.reduce(core, {:turn_done, %{text: ""}})
    event = {:output_audio, <<0, 0>>}

    log =
      capture_log(fn ->
        for current <- [core, reset] do
          assert {:error, :protocol_error} = AudioTurnCore.reduce(current, event)
          assert :ok = Diagnostics.audio_rejected(current, event)
        end
      end)

    assert length(Regex.scan(~r/stage=audio_reduce reason=output_audio_total_byte_limit/, log)) ==
             2

    refute log =~ secret
    refute log =~ "consult_agent"
    refute log =~ "message"
  end

  test "security regression: malformed audio core cannot be diagnosed as the cumulative byte limit" do
    secret = "private-malformed-audio-core-sentinel"
    {:ok, fresh} = AudioTurnCore.new(PcmFormat.mono_s16le(24_000))
    core = fill_output_audio(fresh, secret)
    state = Redacted.value(core)

    malformed = [
      nil,
      Redacted.new(%{total_audio_bytes: AudioTurn.max_output_bytes()}),
      Redacted.new(%{state | audio_bytes: -1}),
      Redacted.new(%{state | total_audio_bytes: AudioTurn.max_output_bytes() + 2}),
      Redacted.new(%{state | text: nil}),
      Redacted.new(%{state | transcript: <<255>> <> secret})
    ]

    log =
      capture_log(fn ->
        for invalid <- malformed do
          event = {:output_audio, <<0, 0>>}
          assert {:error, :protocol_error} = AudioTurnCore.reduce(invalid, event)
          assert :ok = Diagnostics.audio_rejected(invalid, event)
        end
      end)

    assert length(Regex.scan(~r/stage=audio_reduce reason=invalid_output_audio/, log)) ==
             length(malformed)

    refute log =~ "output_audio_total_byte_limit"
    refute log =~ secret
  end

  defp fill_output_audio(core, secret) do
    chunk = secret <> :binary.copy(<<0>>, AudioTurn.max_output_event_bytes() - byte_size(secret))
    count = div(AudioTurn.max_output_bytes(), byte_size(chunk))

    Enum.reduce(1..count, core, fn _, current ->
      assert {:continue, next} = AudioTurnCore.reduce(current, {:output_audio, chunk})
      next
    end)
  end

  test "security regression: presentation observations log only fixed reasons without failure labels" do
    previous = Logger.get_module_level(Diagnostics)
    :ok = Logger.put_module_level(Diagnostics, :info)

    on_exit(fn ->
      case previous do
        [{Diagnostics, level}] -> Logger.put_module_level(Diagnostics, level)
        [] -> Logger.delete_module_level(Diagnostics)
      end
    end)

    secret = "private-presentation-text-audio-proof-ID-sentinel"

    reasons = [
      :audio_retained,
      :invalid_guard,
      :screen_only_classification,
      :truncated_guard,
      :raw_text_mismatch,
      :guard_text_mismatch,
      :format_mismatch,
      :provider_audio_absent,
      :invalid_provider_audio,
      :invalid_presentation_input,
      :presentation_authority_unavailable,
      :presentation_error
    ]

    log =
      capture_log(fn ->
        for reason <- reasons do
          assert :ok = Diagnostics.presentation_observation(reason)
        end

        for unknown <- [secret, %{proof: secret}, {:error, secret}, :unknown_private_reason] do
          assert :ok = Diagnostics.presentation_observation(unknown)
        end
      end)

    for reason <- reasons do
      assert log =~ "presentation observation reason=#{reason}"
    end

    assert length(Regex.scan(~r/presentation observation reason=unclassified/, log)) == 4
    refute log =~ "operation failed"
    refute log =~ secret
    refute log =~ "proof"
    refute log =~ "unknown_private_reason"
  end
end
