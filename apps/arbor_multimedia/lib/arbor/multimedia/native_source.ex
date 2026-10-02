defmodule Arbor.Multimedia.NativeSource do
  @moduledoc false
  use Membrane.Source, sensitive: true
  alias Arbor.Multimedia.Redacted

  def_options(
    token: [spec: binary()],
    stream_token: [spec: binary()],
    frames: [spec: pos_integer()],
    sample_rate: [spec: pos_integer()]
  )

  def_output_pad(:output,
    flow_control: :manual,
    demand_unit: :bytes,
    accepted_format: Membrane.RawAudio
  )

  @impl true
  def handle_init(_, options),
    do:
      {[],
       Map.merge(Map.from_struct(options), %{
         payload: nil,
         admitted: false,
         playing: false,
         demand: 0,
         offset: 0,
         finished: false
       })}

  @impl true
  def handle_setup(_, state),
    do: {[setup: :incomplete, notify_parent: {:arbor_media_ready, state.token, self()}], state}

  @impl true
  def handle_parent_notification({:admit, token}, _, %{token: token, admitted: false} = state),
    do: {[setup: :complete], %{state | admitted: true}}

  def handle_parent_notification(
        {:payload, token, %Redacted{value: pcm}},
        _,
        %{token: token, admitted: true, payload: nil, finished: false} = state
      )
      when is_binary(pcm) do
    if byte_size(pcm) == state.frames * 2,
      do: emit(%{state | payload: pcm}),
      else: {[notify_parent: {:arbor_invalid, token, self()}], state}
  end

  def handle_parent_notification(_, _, state), do: {[], state}
  @impl true
  def handle_playing(_, state) do
    {[
       stream_format:
         {:output,
          %Membrane.RawAudio{channels: 1, sample_rate: state.sample_rate, sample_format: :s16le}}
     ], %{state | playing: true}}
  end

  @impl true
  def handle_demand(:output, amount, :bytes, _, state), do: emit(%{state | demand: amount})

  defp emit(%{payload: pcm, playing: true, finished: false, demand: demand} = state)
       when is_binary(pcm) and demand >= 2 do
    bytes = min(min(div(demand, 2) * 2, 4096), byte_size(pcm) - state.offset)
    chunk = binary_part(pcm, state.offset, bytes)
    offset = state.offset + bytes
    buffer = {:buffer, {:output, %Membrane.Buffer{payload: chunk}}}

    if offset == byte_size(pcm),
      do:
        {[buffer, end_of_stream: :output],
         %{state | payload: nil, offset: offset, finished: true, demand: 0}},
      else: {[buffer, redemand: :output], %{state | offset: offset, demand: demand - bytes}}
  end

  defp emit(state), do: {[], state}
end
