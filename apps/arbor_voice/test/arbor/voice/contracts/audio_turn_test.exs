defmodule Arbor.Voice.Contracts.AudioTurnTest do
  use ExUnit.Case, async: true
  alias Arbor.Voice.Contracts.AudioTurn
  alias Arbor.Voice.Redacted
  @moduletag :fast
  @moduletag spec: "VOICE-5"

  test "input admits the stricter duration or byte ceiling without exposing retained PCM" do
    for rate <- [8_000, 16_000, 24_000, 192_000] do
      maximum = min(AudioTurn.max_input_bytes(), rate * 2 * 60)
      pcm = :binary.copy(<<128, 255>>, div(maximum, 2))
      input = %{pcm: pcm, sample_rate: rate, channels: 1, sample_format: :s16le}
      assert {:ok, redacted} = AudioTurn.new(input)
      assert Redacted.value(redacted).pcm == pcm
      assert inspect(redacted) == "#Redacted<>"
      assert {:error, :invalid_audio} = AudioTurn.new(%{input | pcm: pcm <> <<1, 2>>})
    end
  end

  test "closed input refuses shape, format and byte violations" do
    valid = %{pcm: <<1, 2>>, sample_rate: 16_000, channels: 1, sample_format: :s16le}

    for invalid <- [
          nil,
          Map.delete(valid, :sample_format),
          Map.put(valid, :encoding, :pcm),
          %{valid | channels: 2},
          %{valid | sample_rate: 16_000.0},
          %{valid | pcm: <<>>},
          %{valid | pcm: <<1>>},
          %{valid | sample_format: :float32},
          Map.new(valid, fn {k, v} -> {to_string(k), v} end)
        ] do
      assert {:error, :invalid_audio} = AudioTurn.new(invalid)
    end
  end

  test "operation options preserve actual utterance evidence and reject ambiguity" do
    ended_at = ~U[2026-09-27 12:34:56.123456Z]
    valid = [operation_id: "audio_123", utterance_ended_at: ended_at]

    assert {:ok, %{operation_id: "audio_123", utterance_ended_at: ^ended_at}} =
             AudioTurn.options(valid)

    for opts <- [
          [],
          valid ++ [operation_id: "audio_456"],
          valid ++ [future: true],
          Keyword.put(valid, :operation_id, ""),
          Keyword.put(valid, :operation_id, <<255>>),
          Keyword.put(valid, :operation_id, String.duplicate("a", 257)),
          Keyword.put(valid, :utterance_ended_at, %{ended_at | day: 32}),
          Keyword.put(valid, :utterance_ended_at, %{ended_at | utc_offset: 3_600}),
          Keyword.put(valid, :utterance_ended_at, "2026-09-27")
        ] do
      assert {:error, :invalid_audio_opts} = AudioTurn.options(opts)
    end
  end

  test "output enforces per-event and cumulative byte bounds before flattening" do
    chunk = :binary.copy(<<1, 2>>, div(AudioTurn.max_output_event_bytes(), 2))
    chunks = List.duplicate(chunk, div(AudioTurn.max_output_bytes(), byte_size(chunk)))
    assert {:ok, pcm} = AudioTurn.output_pcm(chunks)
    assert byte_size(pcm) == AudioTurn.max_output_bytes()

    for invalid <- [
          [],
          chunks ++ [<<1, 2>>],
          [chunk <> <<1, 2>>],
          [<<1>>],
          [<<>>],
          [[<<1, 2>>]],
          [<<1, 2>> | :invalid],
          <<1, 2>>
        ] do
      assert {:error, :invalid_audio} = AudioTurn.output_pcm(invalid)
    end
  end
end
