defmodule Arbor.Multimedia.NativePipeline do
  @moduledoc false
  use Membrane.Pipeline, sensitive: true
  alias Arbor.Multimedia.{NativeCollector, NativeSource, Redacted}

  @impl true
  def handle_init(_, %Redacted{value: {owner, token}}) do
    {[], %{owner: owner, monitor: Process.monitor(owner), token: token, configured: false}}
  end

  @impl true
  def handle_setup(_, state), do: {[setup: :incomplete], state}

  @impl true
  def handle_info(
        {:configure, token, %Redacted{value: config}},
        _,
        %{token: token, configured: false} = state
      ) do
    device_opts = [
      executor_identity: config.identity,
      startup_token: config.startup,
      stream_token: config.stream,
      portaudio_buffer_size: 256,
      device_id: config.device_id
    ]

    common = [
      token: token,
      stream_token: config.stream,
      frames: config.frames,
      sample_rate: config.sample_rate
    ]

    spec =
      case config.kind do
        :capture ->
          source =
            struct!(
              Membrane.PortAudio.Source,
              device_opts ++
                [
                  max_frames: config.frames,
                  channels: 1,
                  sample_format: :s16le,
                  sample_rate: config.sample_rate
                ]
            )

          child(:device, source) |> child(:collector, struct!(NativeCollector, common))

        :playback ->
          sink = struct!(Membrane.PortAudio.Sink, device_opts ++ [expected_frames: config.frames])
          child(:feeder, struct!(NativeSource, common)) |> child(:device, sink)
      end

    {[spec: spec, setup: :complete], %{state | configured: true}}
  end

  def handle_info(
        {:control, token, name, %Redacted{value: notification}},
        _,
        %{token: token} = state
      )
      when name in [:device, :collector, :feeder],
      do: {[notify_child: {name, notification}], state}

  def handle_info({:DOWN, monitor, :process, _, _}, _, %{monitor: monitor} = state),
    do: {[terminate: :normal], state}

  def handle_info(_, _, state), do: {[], state}

  @impl true
  def handle_child_notification(notification, name, _, state) do
    send(state.owner, {:native_pipeline, state.token, self(), name, Redacted.new(notification)})
    {[], state}
  end
end
