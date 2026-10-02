defmodule Arbor.Multimedia.NativeCollector do
  @moduledoc false
  use Membrane.Sink, sensitive: true

  def_options(
    token: [spec: binary()],
    stream_token: [spec: binary()],
    frames: [spec: pos_integer()],
    sample_rate: [spec: pos_integer()]
  )

  def_input_pad(:input, flow_control: :auto, accepted_format: Membrane.RawAudio)

  @impl true
  def handle_init(_, options),
    do:
      {[],
       Map.merge(Map.from_struct(options), %{
         bytes: 0,
         format: false,
         admitted: false,
         failed: false
       })}

  @impl true
  def handle_setup(_, state),
    do: {[setup: :incomplete, notify_parent: {:arbor_media_ready, state.token, self()}], state}

  @impl true
  def handle_parent_notification({:admit, token}, _, %{token: token, admitted: false} = state),
    do: {[setup: :complete], %{state | admitted: true}}

  def handle_parent_notification(_, _, state), do: {[], state}
  @impl true
  def handle_stream_format(:input, format, _, state) do
    if format == %Membrane.RawAudio{
         channels: 1,
         sample_format: :s16le,
         sample_rate: state.sample_rate
       }, do: {[], %{state | format: true}}, else: invalid(state)
  end

  @impl true
  def handle_buffer(:input, %Membrane.Buffer{payload: pcm, metadata: metadata}, _, state) do
    if state.admitted and state.format and not state.failed and is_binary(pcm) and
         byte_size(pcm) > 0 and
         rem(byte_size(pcm), 2) == 0 and state.bytes + byte_size(pcm) <= state.frames * 2 and
         metadata[:portaudio_stream_token] == state.stream_token do
      {[notify_parent: {:arbor_pcm, state.token, self(), pcm}],
       %{state | bytes: state.bytes + byte_size(pcm)}}
    else
      invalid(state)
    end
  end

  defp invalid(%{failed: true} = state), do: {[], state}

  defp invalid(state),
    do: {[notify_parent: {:arbor_invalid, state.token, self()}], %{state | failed: true}}
end
