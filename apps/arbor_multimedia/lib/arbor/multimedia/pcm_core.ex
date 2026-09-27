defmodule Arbor.Multimedia.PcmCore do
  @moduledoc false
  @capture_limit 2 * 1024 * 1024
  @playback_limit 8 * 1024 * 1024

  def capture(opts) do
    with {:ok, options} <- options(opts, [:duration_ms, :sample_rate, :device_id]),
         duration when is_integer(duration) and duration in 100..30_000 <- options[:duration_ms],
         rate when is_integer(rate) and rate in 8_000..192_000 <- options[:sample_rate],
         true <- rem(duration * rate, 1000) == 0,
         frames = div(duration * rate, 1000),
         true <- frames * 2 <= @capture_limit do
      {:ok,
       %{
         kind: :capture,
         duration_ms: duration,
         sample_rate: rate,
         channels: 1,
         sample_format: :s16le,
         frames: frames,
         device_id: Map.get(options, :device_id, :default)
       }}
    else
      _ -> {:error, :invalid_options}
    end
  end

  def playback(audio, opts) do
    with {:ok, options} <- options(opts, [:device_id]),
         %{pcm: pcm, sample_rate: rate, channels: 1, sample_format: :s16le} <- audio,
         true <- map_size(audio) == 4,
         true <- is_integer(rate) and rate in 8_000..192_000,
         true <- is_binary(pcm) and byte_size(pcm) > 0 and byte_size(pcm) <= @playback_limit,
         true <- rem(byte_size(pcm), 2) == 0 do
      frames = div(byte_size(pcm), 2)

      {:ok,
       %{
         kind: :playback,
         duration_ms: div(frames * 1000 + rate - 1, rate),
         sample_rate: rate,
         channels: 1,
         sample_format: :s16le,
         frames: frames,
         pcm: pcm,
         device_id: Map.get(options, :device_id, :default)
       }}
    else
      _ -> {:error, :invalid_audio}
    end
  end

  def devices(devices) when is_list(devices) and length(devices) <= 128 do
    if Enum.all?(devices, &device?/1) and
         length(Enum.uniq_by(devices, & &1.id)) == length(devices) do
      {:ok, devices}
    else
      {:error, :invalid_devices}
    end
  end

  def devices(_), do: {:error, :invalid_devices}

  def error(reason)
      when reason in [
             :permission_denied,
             :device_unavailable,
             :unsupported_format,
             :device_busy,
             :capture_failed,
             :playback_failed,
             :driver_failed,
             :invalid_devices,
             :invalid_media,
             :timeout,
             :cleanup_pending
           ],
      do: reason

  def error(_), do: :driver_failed

  defp options(opts, allowed) when is_list(opts) and length(opts) <= 3 do
    if Keyword.keyword?(opts) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
         Enum.all?(opts, fn {key, _} -> key in allowed end) and
         device_id?(Keyword.get(opts, :device_id, :default)) do
      {:ok, Map.new(opts)}
    else
      {:error, :invalid_options}
    end
  end

  defp options(_, _), do: {:error, :invalid_options}

  defp device_id?(:default), do: true
  defp device_id?(id), do: is_integer(id) and id >= 0 and id <= 65_535

  defp device?(
         %{
           id: id,
           name: name,
           max_input_channels: input,
           max_output_channels: output,
           default_sample_rate: rate
         } = device
       ) do
    map_size(device) == 5 and is_integer(id) and id in 0..65_535 and
      is_binary(name) and byte_size(name) in 1..256 and String.valid?(name) and
      Enum.all?(String.to_charlist(name), &(&1 >= 32 and &1 not in 127..159)) and
      is_integer(input) and input in 0..256 and is_integer(output) and output in 0..256 and
      is_number(rate) and rate >= 8_000 and rate <= 192_000
  end

  defp device?(_), do: false
end
