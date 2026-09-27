defmodule Arbor.Voice.PcmFormatTest do
  use ExUnit.Case, async: true
  alias Arbor.Voice.PcmFormat
  @moduletag :fast
  @moduletag spec: "VOICE-5"

  test "exact PCM authority admits only bounded mono s16le atom descriptors" do
    for rate <- [8_000, 16_000, 24_000, 192_000],
        do: assert(:ok == PcmFormat.validate(PcmFormat.mono_s16le(rate)))

    valid = PcmFormat.mono_s16le(16_000)

    for malformed <- [
          nil,
          %{},
          Map.delete(valid, :channels),
          Map.put(valid, :extra, true),
          %{valid | channels: 2},
          %{valid | encoding: "pcm"},
          %{valid | sample_format: :f32le},
          %{valid | sample_rate: 7_999},
          %{valid | sample_rate: 192_001},
          %{valid | sample_rate: 16_000.0},
          Map.new(valid, fn {k, v} -> {to_string(k), v} end)
        ] do
      assert {:error, :invalid_audio_format} = PcmFormat.validate(malformed)
    end
  end

  test "metadata and requested formats independently prove input and output" do
    input = PcmFormat.mono_s16le(16_000)
    output = PcmFormat.mono_s16le(24_000)
    meta = %{backend: :test, mode: :local, input_format: input, output_format: output}
    assert :ok = PcmFormat.validate_meta(meta)
    assert :ok = PcmFormat.matches_request(%{input_format: input, output_format: output}, meta)

    assert {:error, :audio_format_mismatch} =
             PcmFormat.matches_request(
               %{input_format: output, output_format: output},
               meta
             )

    assert :ok = PcmFormat.validate_meta(%{meta | input_format: nil, output_format: nil})

    for changed <- [
          %{meta | input_format: nil},
          %{meta | output_format: nil},
          Map.put(meta, :input_rate, 16_000),
          Map.put(meta, :backend, false)
        ] do
      assert {:error, :invalid_backend_meta} = PcmFormat.validate_meta(changed)
    end

    assert {:error, :invalid_audio_format} =
             PcmFormat.configured_formats(%{audio: %{audio_mode: :pcm}})
  end

  test "PCM and base64 reject empty odd malformed and oversized data" do
    maximum = :binary.copy(<<1, 2>>, div(PcmFormat.max_bytes(), 2))

    for pcm <- [<<0, 0>>, <<255, 127, 0, 128>>, maximum] do
      assert :ok = PcmFormat.validate_pcm(pcm)
      assert {:ok, ^pcm} = PcmFormat.decode_base64(Base.encode64(pcm))
    end

    for pcm <- [<<>>, <<1>>, maximum <> <<1, 2>>, nil, []],
        do: assert({:error, :invalid_audio} == PcmFormat.validate_pcm(pcm))

    for encoded <- [
          nil,
          1,
          "",
          "!not-base64!",
          Base.encode64(<<1>>),
          Base.encode64(maximum <> <<1, 2>>)
        ],
        do: assert({:error, :invalid_audio} == PcmFormat.decode_base64(encoded))
  end
end
