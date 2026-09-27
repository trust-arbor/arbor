defmodule Arbor.Voice.PcmFormat do
  @moduledoc false

  @max_bytes 2 * 1024 * 1024
  @format_keys [:channels, :encoding, :sample_format, :sample_rate]
  @meta_keys [:backend, :input_format, :mode, :output_format]

  @type t :: %{encoding: :pcm, sample_format: :s16le, channels: 1, sample_rate: pos_integer()}

  def max_bytes, do: @max_bytes

  def mono_s16le(rate),
    do: %{encoding: :pcm, sample_format: :s16le, channels: 1, sample_rate: rate}

  def validate(%{encoding: :pcm, sample_format: :s16le, channels: 1, sample_rate: rate} = format)
      when is_integer(rate) and rate in 8_000..192_000 do
    if Enum.sort(Map.keys(format)) == @format_keys, do: :ok, else: {:error, :invalid_audio_format}
  end

  def validate(_), do: {:error, :invalid_audio_format}

  def validate_pair(%{input_format: nil, output_format: nil} = pair) when map_size(pair) == 2,
    do: :ok

  def validate_pair(%{input_format: input, output_format: output} = pair)
      when map_size(pair) == 2 do
    with :ok <- validate(input), :ok <- validate(output), do: :ok
  end

  def validate_pair(_), do: {:error, :invalid_audio_format}

  def validate_meta(%{backend: backend, mode: mode, input_format: _, output_format: _} = meta)
      when is_atom(backend) and backend not in [nil, true, false] and mode in [:local, :cloud] do
    with true <- Enum.sort(Map.keys(meta)) == @meta_keys,
         :ok <- validate_pair(Map.take(meta, [:input_format, :output_format])) do
      :ok
    else
      _ -> {:error, :invalid_backend_meta}
    end
  end

  def validate_meta(_), do: {:error, :invalid_backend_meta}

  def validate_byte_count(bytes)
      when is_integer(bytes) and bytes > 0 and bytes <= @max_bytes and
             rem(bytes, 2) == 0,
      do: :ok

  def validate_byte_count(_), do: {:error, :invalid_audio}

  def validate_pcm(pcm) when is_binary(pcm), do: validate_byte_count(byte_size(pcm))
  def validate_pcm(_), do: {:error, :invalid_audio}

  def configured_formats(config) when is_map(config) do
    case Map.fetch(config, :audio) do
      :error ->
        {:ok, :unspecified}

      {:ok, nil} ->
        {:ok, %{input_format: nil, output_format: nil}}

      {:ok, %{input_format: input, output_format: output}} ->
        pair = %{input_format: input, output_format: output}
        with :ok <- validate_pair(pair), do: {:ok, pair}

      _ ->
        {:error, :invalid_audio_format}
    end
  end

  def configured_formats(_), do: {:error, :invalid_audio_format}

  def matches_request(:unspecified, meta), do: validate_meta(meta)

  def matches_request(requested, meta) do
    with :ok <- validate_pair(requested),
         :ok <- validate_meta(meta),
         true <- Map.take(meta, [:input_format, :output_format]) == requested do
      :ok
    else
      _ -> {:error, :audio_format_mismatch}
    end
  end

  def decode_base64(encoded) when is_binary(encoded) do
    with true <- byte_size(encoded) <= div(@max_bytes + 2, 3) * 4,
         {:ok, pcm} <- Base.decode64(encoded),
         :ok <- validate_pcm(pcm) do
      {:ok, pcm}
    else
      _ -> {:error, :invalid_audio}
    end
  end

  def decode_base64(_), do: {:error, :invalid_audio}
end
