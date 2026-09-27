defmodule Arbor.Voice.Contracts.AudioTurn do
  @moduledoc """
  Pure, closed data bounds for one PCM turn. This module does not authenticate
  a capture, conversation or provider format; the owning boundary supplies those
  facts. Raw media is wrapped immediately after validation for private retention.
  """

  alias Arbor.Voice.PcmFormat
  alias Arbor.Voice.Redacted

  @max_input_bytes 2 * 1024 * 1024
  @max_input_seconds 60
  @max_output_event_bytes 65_536
  @max_output_bytes 8 * 1024 * 1024
  @max_text_bytes 8192
  @max_operation_id_bytes 256

  @type input :: %{
          pcm: binary(),
          sample_rate: pos_integer(),
          channels: 1,
          sample_format: :s16le
        }
  @type verdict :: {:speak | :speak_truncated | :screen_only, String.t()}
  @type presentation :: %{
          verdict: verdict(),
          spoken_text: String.t(),
          audio: binary() | nil,
          format: PcmFormat.t() | nil
        }
  @type result :: %{
          operation_id: String.t(),
          reply: String.t(),
          input_transcript: String.t(),
          presentation: presentation()
        }

  def max_input_bytes, do: @max_input_bytes
  def max_input_seconds, do: @max_input_seconds
  def max_output_event_bytes, do: @max_output_event_bytes
  def max_output_bytes, do: @max_output_bytes
  def max_text_bytes, do: @max_text_bytes
  def max_operation_id_bytes, do: @max_operation_id_bytes

  @doc "Validate and redact a closed bounded input, without claiming its source."
  @spec new(term()) :: {:ok, Redacted.t()} | {:error, :invalid_audio}
  def new(%{pcm: pcm, sample_rate: rate, channels: channels, sample_format: sample} = input)
      when map_size(input) == 4 do
    format = %{encoding: :pcm, sample_rate: rate, channels: channels, sample_format: sample}

    with :ok <- PcmFormat.validate(format),
         :ok <- PcmFormat.validate_pcm(pcm),
         true <- byte_size(pcm) <= rate * 2 * @max_input_seconds do
      {:ok, Redacted.new(%{pcm: pcm, format: format})}
    else
      _ -> {:error, :invalid_audio}
    end
  end

  def new(_), do: {:error, :invalid_audio}

  @doc "Validate exact duplicate-free operation options. The timestamp is supplied evidence."
  @spec options(term()) ::
          {:ok, %{operation_id: String.t(), utterance_ended_at: DateTime.t()}}
          | {:error, :invalid_audio_opts}
  def options([_, _] = opts) do
    with true <- Keyword.keyword?(opts),
         true <- Enum.sort(Keyword.keys(opts)) == [:operation_id, :utterance_ended_at],
         id <- Keyword.fetch!(opts, :operation_id),
         ended_at <- Keyword.fetch!(opts, :utterance_ended_at),
         true <- operation_id?(id),
         true <- utc_datetime?(ended_at) do
      {:ok, %{operation_id: id, utterance_ended_at: ended_at}}
    else
      _ -> {:error, :invalid_audio_opts}
    end
  end

  def options(_), do: {:error, :invalid_audio_opts}

  def operation_id?(id) when is_binary(id) and byte_size(id) in 1..@max_operation_id_bytes,
    do: String.valid?(id) and String.trim(id) != ""

  def operation_id?(_), do: false

  def text?(text) when is_binary(text) and byte_size(text) in 1..@max_text_bytes,
    do: String.valid?(text) and String.trim(text) != ""

  def text?(_), do: false

  def output_chunk?(chunk) when is_binary(chunk),
    do: byte_size(chunk) in 2..@max_output_event_bytes and rem(byte_size(chunk), 2) == 0

  def output_chunk?(_), do: false

  @doc "Check bounded flat binary iodata before allocating the final PCM binary."
  @spec output_pcm(term()) :: {:ok, binary()} | {:error, :invalid_audio}
  def output_pcm(chunks) do
    case output_size(chunks, 0) do
      {:ok, bytes} when bytes > 0 -> {:ok, IO.iodata_to_binary(chunks)}
      _ -> {:error, :invalid_audio}
    end
  end

  defp output_size([], bytes), do: {:ok, bytes}

  defp output_size([chunk | rest], bytes) do
    if output_chunk?(chunk) and bytes + byte_size(chunk) <= @max_output_bytes do
      output_size(rest, bytes + byte_size(chunk))
    else
      {:error, :invalid_audio}
    end
  end

  defp output_size(_, _), do: {:error, :invalid_audio}

  defp utc_datetime?(%DateTime{
         calendar: Calendar.ISO,
         time_zone: zone,
         zone_abbr: "UTC",
         utc_offset: 0,
         std_offset: 0,
         year: year,
         month: month,
         day: day,
         hour: hour,
         minute: minute,
         second: second,
         microsecond: microsecond
       })
       when zone in ["Etc/UTC", "UTC"] do
    Calendar.ISO.valid_date?(year, month, day) and
      Calendar.ISO.valid_time?(hour, minute, second, microsecond)
  rescue
    _ -> false
  end

  defp utc_datetime?(_), do: false
end
