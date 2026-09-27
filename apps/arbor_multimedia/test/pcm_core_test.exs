defmodule Arbor.Multimedia.PcmCoreTest do
  use ExUnit.Case, async: true
  @moduletag :fast
  alias Arbor.Multimedia.{OperationCore, PcmCore}

  test "capture validates exact integral frames and byte ceiling" do
    assert {:ok, %{frames: 800, device_id: :default}} =
             PcmCore.capture(duration_ms: 100, sample_rate: 8_000)

    assert {:ok, %{frames: 1_048_576}} = PcmCore.capture(duration_ms: 8_192, sample_rate: 128_000)
    assert {:ok, %{frames: 240_000}} = PcmCore.capture(duration_ms: 30_000, sample_rate: 8_000)
    assert {:ok, %{frames: 19_200}} = PcmCore.capture(duration_ms: 100, sample_rate: 192_000)

    for opts <- [
          [duration_ms: 100, sample_rate: 7_999],
          [duration_ms: 30_001, sample_rate: 8_000],
          [duration_ms: 99, sample_rate: 8_000],
          [duration_ms: 101, sample_rate: 44_100],
          [duration_ms: 30_000, sample_rate: 192_000],
          [duration_ms: 8_193, sample_rate: 128_000],
          [duration_ms: 100, sample_rate: 192_001],
          [duration_ms: 100, sample_rate: 8_000, device_id: -1],
          [duration_ms: 100, sample_rate: 8_000, device_id: 65_536]
        ] do
      assert {:error, :invalid_options} = PcmCore.capture(opts)
    end
  end

  test "public options are a duplicate-free closed keyword list without executable values" do
    for opts <- [
          nil,
          %{},
          [{"sample_rate", 8_000}],
          [sample_rate: 8_000, sample_rate: 8_000],
          [duration_ms: 100, sample_rate: 8_000, driver: SomeModule],
          [duration_ms: 100, sample_rate: 8_000, device_id: self()],
          [duration_ms: 100, sample_rate: 8_000, device_id: fn -> :ok end]
        ] do
      assert {:error, :invalid_options} = PcmCore.capture(opts)
    end
  end

  test "playback validates exact shape, bytes, rate and channel format" do
    audio = %{pcm: <<1, 2>>, sample_rate: 8_000, channels: 1, sample_format: :s16le}
    assert {:ok, %{frames: 1, duration_ms: 1}} = PcmCore.playback(audio, [])

    assert {:ok, %{frames: 4_194_304, duration_ms: 524_288}} =
             PcmCore.playback(%{audio | pcm: :binary.copy(<<0>>, 8 * 1024 * 1024)}, [])

    for bad <- [
          Map.put(audio, :pcm, <<>>),
          Map.put(audio, :pcm, <<1>>),
          Map.put(audio, :pcm, :binary.copy(<<0>>, 8 * 1024 * 1024 + 2)),
          Map.put(audio, :sample_rate, 0),
          Map.put(audio, :channels, 2),
          Map.put(audio, :sample_format, :f32),
          Map.put(audio, :duration_ms, 10),
          nil
        ] do
      assert {:error, :invalid_audio} = PcmCore.playback(bad, [])
    end

    assert {:error, :invalid_audio} = PcmCore.playback(audio, driver: SomeModule)
    assert {:error, :invalid_audio} = PcmCore.playback(audio, device_id: 0, device_id: 0)
  end

  test "device data is bounded UTF-8 with unique identifiers and a closed shape" do
    device = %{
      id: 0,
      name: "Built-in",
      max_input_channels: 1,
      max_output_channels: 2,
      default_sample_rate: 48_000.0
    }

    assert {:ok, [^device]} = PcmCore.devices([device])
    assert {:ok, _} = PcmCore.devices(for id <- 0..127, do: %{device | id: id})

    for bad <- [
          [device, device],
          List.duplicate(device, 129),
          Enum.map(0..128, &%{device | id: &1}),
          [Map.put(device, :name, <<255>>)],
          [Map.put(device, :name, String.duplicate("a", 257))],
          [Map.put(device, :name, "bad" <> <<0>>)],
          [Map.put(device, :name, "escape" <> <<27>> <> "[31m")],
          [Map.put(device, :name, "line\nfeed")],
          [Map.put(device, :name, "delete" <> <<127>>)],
          [Map.put(device, :name, "control" <> <<155::utf8>>)],
          [Map.put(device, :max_input_channels, 257)],
          [Map.put(device, :pcm, "secret")],
          :bad
        ] do
      assert {:error, :invalid_devices} = PcmCore.devices(bad)
    end
  end

  test "capture joins completion count and bytes in either order but still requires close" do
    {:ok, spec} = PcmCore.capture(duration_ms: 100, sample_rate: 8_000)
    pcm = :binary.copy(<<1, 2>>, 800)
    now = ~U[2026-09-27 00:00:00Z]

    for events <- [[{:pcm, pcm}, {:complete, 800}], [{:complete, 800}, {:pcm, pcm}]] do
      {state, effects} =
        Enum.reduce(events, {OperationCore.new(spec), []}, fn event, {state, _} ->
          OperationCore.event(state, event, now)
        end)

      assert effects == [:close]
      refute state.closed
      assert {:ok, %{audio: %{pcm: ^pcm}, utterance_ended_at: ^now}} = state.result
      assert {%{closed: true}, [:settle]} = OperationCore.event(state, {:closed, :ok}, now)
    end
  end

  test "mismatched, overflowing and empty media cannot succeed; identical completion is idempotent" do
    {:ok, spec} = PcmCore.capture(duration_ms: 100, sample_rate: 8_000)

    for event <- [
          {:complete, 799},
          {:pcm, <<>>},
          {:pcm, <<1>>},
          {:pcm, :binary.copy(<<0>>, 1602)},
          :unexpected
        ] do
      assert {%{result: {:error, :invalid_media}, cancelled: true}, [:close]} =
               OperationCore.event(OperationCore.new(spec), event, ~U[2026-09-27 00:00:00Z])
    end

    {:ok, spec} =
      PcmCore.playback(
        %{pcm: <<1, 2>>, sample_rate: 8_000, channels: 1, sample_format: :s16le},
        []
      )

    {state, [:close]} = OperationCore.event(OperationCore.new(spec), {:complete, 1}, nil)

    assert {^state, []} = OperationCore.event(state, {:complete, 1}, nil)

    assert {%{result: {:error, :invalid_media}}, [:close]} =
             OperationCore.event(state, {:complete, 2}, nil)
  end
end
