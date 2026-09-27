defmodule Arbor.Voice.Session.AudioTurnCoreTest do
  use ExUnit.Case, async: true
  alias Arbor.Voice.Contracts.AudioTurn
  alias Arbor.Voice.PcmFormat
  alias Arbor.Voice.Redacted
  alias Arbor.Voice.Session.AudioTurnCore
  @moduletag :fast
  @moduletag spec: "VOICE-5,VOICE-13"
  @tool %{id: "call_1", name: "consult_agent", arguments: %{"message" => "status?"}}

  defp core do
    {:ok, core} = AudioTurnCore.new(PcmFormat.mono_s16le(24_000))
    core
  end

  test "actual completed transcript is retained verbatim and duplicate completion is idempotent" do
    assert {:continue, state} = AudioTurnCore.reduce(core(), {:input_transcript, " Hello. "})
    assert {:continue, ^state} = AudioTurnCore.reduce(state, {:input_transcript, " Hello. "})
    assert {:error, :protocol_error} = AudioTurnCore.reduce(state, {:input_transcript, "Hello."})

    assert {:done, completed} =
             AudioTurnCore.reduce(state, {:turn_done, %{text: "Good morning."}})

    assert Redacted.value(completed).input_transcript == " Hello. "
    assert inspect(completed) == "#Redacted<>"
  end

  test "no tools are admitted before completed STT and partial transcript events confer no authority" do
    assert {:error, :protocol_error} = AudioTurnCore.reduce(core(), {:tool_call, @tool})

    assert {:error, :protocol_error} =
             AudioTurnCore.reduce(core(), {:input_transcript_delta, "Hello"})

    for transcript <- ["", "  ", <<255>>, String.duplicate("a", 8193)] do
      assert {:error, :protocol_error} =
               AudioTurnCore.reduce(core(), {:input_transcript, transcript})
    end
  end

  test "a final response waits for actual STT instead of manufacturing user content" do
    assert {:continue, waiting} = AudioTurnCore.reduce(core(), {:turn_done, %{text: "Hello!"}})
    assert {:error, :protocol_error} = AudioTurnCore.reduce(waiting, {:tool_call, @tool})
    assert {:done, completed} = AudioTurnCore.reduce(waiting, {:input_transcript, "Good morning"})

    assert %{input_transcript: "Good morning", provider_text: "Hello!"} =
             Redacted.value(completed)
  end

  test "tool-bearing waves discard intermediate text and PCM while preserving the transcript" do
    {:continue, state} = AudioTurnCore.reduce(core(), {:input_transcript, "What changed?"})
    {:continue, state} = AudioTurnCore.reduce(state, {:output_audio, <<1, 2>>})
    {:continue, state} = AudioTurnCore.reduce(state, {:output_text_delta, "I will check."})
    {:admit_tool, state, @tool} = AudioTurnCore.reduce(state, {:tool_call, @tool})
    {:continue, state} = AudioTurnCore.reduce(state, {:output_audio, <<3, 4>>})
    {:cycle_reset, state} = AudioTurnCore.reduce(state, {:turn_done, %{text: "Intermediate"}})
    {:continue, state} = AudioTurnCore.reduce(state, {:output_audio, <<5, 6>>})
    {:done, completed} = AudioTurnCore.reduce(state, {:turn_done, %{text: "The build passed."}})
    result = Redacted.value(completed)
    assert result.input_transcript == "What changed?"
    assert result.provider_text == "The build passed."
    assert Redacted.value(result.audio) == [<<5, 6>>]
    assert result.audio_bytes == 2
    assert inspect(state) == "#Redacted<>"
  end

  test "discarded waves still count toward the operation output ceiling" do
    {:continue, state} = AudioTurnCore.reduce(core(), {:input_transcript, "Check"})
    {:admit_tool, state, _} = AudioTurnCore.reduce(state, {:tool_call, @tool})
    chunk = :binary.copy(<<1, 2>>, div(AudioTurn.max_output_event_bytes(), 2))

    state =
      Enum.reduce(1..128, state, fn _, acc ->
        {:continue, next} = AudioTurnCore.reduce(acc, {:output_audio, chunk})
        next
      end)

    {:cycle_reset, state} = AudioTurnCore.reduce(state, {:turn_done, %{text: "Intermediate"}})
    assert {:error, :protocol_error} = AudioTurnCore.reduce(state, {:output_audio, <<1, 2>>})
  end

  test "deltas can provide final text but never masquerade as provider terminal text for audio" do
    {:continue, state} = AudioTurnCore.reduce(core(), {:input_transcript, "Hello"})
    {:continue, state} = AudioTurnCore.reduce(state, {:output_text_delta, "Hi"})
    {:done, completed} = AudioTurnCore.reduce(state, {:turn_done, %{text: ""}})
    assert %{provider_text: "Hi", provider_terminal_text: ""} = Redacted.value(completed)
  end

  test "invalid state or audio returns only a content-free protocol error" do
    for state <- [nil, Redacted.new(%{}), Redacted.new(%{secret: "private"})],
        do:
          assert(
            {:error, :protocol_error} == AudioTurnCore.reduce(state, {:output_audio, <<1, 2>>})
          )

    for pcm <- [<<>>, <<1>>, :binary.copy(<<1, 2>>, 32_769), "private-odd"] do
      assert {:error, :protocol_error} = AudioTurnCore.reduce(core(), {:output_audio, pcm})
    end
  end
end
