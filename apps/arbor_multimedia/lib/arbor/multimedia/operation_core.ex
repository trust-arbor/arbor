defmodule Arbor.Multimedia.OperationCore do
  @moduledoc false
  alias Arbor.Multimedia.PcmCore

  def new(spec) do
    %{
      spec: spec,
      chunks: [],
      bytes: 0,
      completed: false,
      ended_at: nil,
      result: nil,
      closed: false,
      cancelled: false
    }
  end

  def event(%{cancelled: true} = state, {:closed, :ok}, _now),
    do: {%{state | closed: true}, [:settle]}

  def event(%{cancelled: true} = state, _, _now), do: {state, []}

  def event(%{spec: %{kind: :capture}, completed: completed} = state, {:pcm, pcm}, _now)
      when is_binary(pcm) do
    bytes = state.bytes + byte_size(pcm)

    if byte_size(pcm) > 0 and rem(byte_size(pcm), 2) == 0 and bytes <= state.spec.frames * 2 do
      next = %{state | chunks: [:binary.copy(pcm) | state.chunks], bytes: bytes}
      if completed, do: complete_capture(next), else: {next, []}
    else
      fail(state, :invalid_media)
    end
  end

  def event(%{completed: true, spec: %{frames: frames}} = state, {:complete, frames}, _now),
    do: {state, []}

  def event(
        %{completed: false, spec: %{kind: :capture, frames: frames}} = state,
        {:complete, frames},
        ended_at
      ) do
    complete_capture(%{state | completed: true, ended_at: ended_at})
  end

  def event(
        %{completed: false, spec: %{kind: :playback, frames: frames}} = state,
        {:complete, frames},
        _now
      ),
      do: {%{state | completed: true, result: :ok}, [:close]}

  def event(%{completed: false, spec: %{kind: :devices}} = state, {:devices, devices}, _now) do
    case PcmCore.devices(devices) do
      {:ok, devices} -> {%{state | completed: true, result: {:ok, devices}}, [:close]}
      {:error, reason} -> fail(state, reason)
    end
  end

  def event(state, {:closed, :ok}, _now) do
    if state.result == nil do
      {%{state | closed: true, chunks: [], result: {:error, :invalid_media}}, [:settle]}
    else
      {%{state | closed: true}, [:settle]}
    end
  end

  def event(state, {:closed, _}, _now), do: {state, []}
  def event(state, {:error, reason}, _now), do: fail(state, PcmCore.error(reason))
  def event(state, _, _now), do: fail(state, :invalid_media)

  def cancel(%{cancelled: true} = state, _reason), do: {state, []}

  def cancel(state, reason) do
    {%{
       state
       | cancelled: true,
         chunks: [],
         spec: Map.delete(state.spec, :pcm),
         result: {:error, reason}
     }, [:close]}
  end

  defp complete_capture(state) do
    if state.bytes == state.spec.frames * 2 do
      audio = %{
        pcm: state.chunks |> Enum.reverse() |> :erlang.iolist_to_binary(),
        sample_rate: state.spec.sample_rate,
        channels: 1,
        sample_format: :s16le
      }

      {%{state | chunks: [], result: {:ok, %{audio: audio, utterance_ended_at: state.ended_at}}},
       [:close]}
    else
      {state, []}
    end
  end

  defp fail(state, reason), do: cancel(state, reason)
end
