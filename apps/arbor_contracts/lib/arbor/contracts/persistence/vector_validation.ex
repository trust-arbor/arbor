defmodule Arbor.Contracts.Persistence.VectorValidation do
  @moduledoc false

  alias Arbor.Contracts.Security.TaintEnvelope

  @sha256_pattern ~r/\A[0-9a-f]{64}\z/

  @spec normalize_attrs(term(), map(), [atom()]) :: {:ok, map()} | :error
  def normalize_attrs(attrs, aliases, required_keys)
      when is_map(attrs) and not is_struct(attrs) do
    if map_size(attrs) == length(required_keys) do
      attrs
      |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, normalized} ->
        with {:ok, normalized_key} <- Map.fetch(aliases, key),
             false <- Map.has_key?(normalized, normalized_key) do
          {:cont, {:ok, Map.put(normalized, normalized_key, value)}}
        else
          _invalid -> {:halt, :error}
        end
      end)
      |> require_exact_keys(required_keys)
    else
      :error
    end
  end

  def normalize_attrs(attrs, aliases, required_keys) when is_list(attrs) do
    collect_attrs(attrs, aliases, required_keys, %{}, 0)
  end

  def normalize_attrs(_attrs, _aliases, _required_keys), do: :error

  @spec canonical_payload(term()) :: {:ok, term(), binary()} | {:error, atom()}
  def canonical_payload(payload) do
    with {:ok, bytes} <- TaintEnvelope.canonical_json(payload),
         {:ok, normalized} <- Jason.decode(bytes) do
      {:ok, normalized, bytes}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _invalid -> {:error, :invalid_payload}
    end
  rescue
    _error -> {:error, :invalid_payload}
  catch
    _kind, _reason -> {:error, :invalid_payload}
  end

  @spec payload_limits() :: map()
  def payload_limits, do: TaintEnvelope.limits()

  @spec normalize_vector(term(), pos_integer()) ::
          {:ok, [float()], binary()} | {:error, :invalid_vector}
  def normalize_vector(vector, dimensions) when is_list(vector) and is_integer(dimensions) do
    normalize_vector_items(vector, dimensions, 0, [], [], false)
  end

  def normalize_vector(_vector, _dimensions), do: {:error, :invalid_vector}

  @spec normalize_float32(term()) :: {:ok, float(), binary()} | {:error, :invalid_float}
  def normalize_float32(value) when is_integer(value) or is_float(value) do
    float = if is_integer(value), do: value * 1.0, else: value
    encoded = <<float::float-size(32)>>
    <<_sign::1, exponent::8, fraction::23>> = encoded

    cond do
      exponent == 255 ->
        {:error, :invalid_float}

      exponent == 0 and fraction == 0 ->
        {:ok, 0.0, <<0::size(32)>>}

      true ->
        <<normalized::float-size(32)>> = encoded
        {:ok, normalized, encoded}
    end
  rescue
    _error -> {:error, :invalid_float}
  catch
    _kind, _reason -> {:error, :invalid_float}
  end

  def normalize_float32(_value), do: {:error, :invalid_float}

  @spec valid_text?(term(), pos_integer()) :: boolean()
  def valid_text?(value, max_bytes) when is_binary(value) and is_integer(max_bytes) do
    size = byte_size(value)

    size > 0 and size <= max_bytes and String.valid?(value) and String.trim(value) != ""
  end

  def valid_text?(_value, _max_bytes), do: false

  @spec valid_digest?(term()) :: boolean()
  def valid_digest?(value) when is_binary(value) and byte_size(value) == 64 do
    String.valid?(value) and Regex.match?(@sha256_pattern, value)
  end

  def valid_digest?(_value), do: false

  @spec sha256(iodata()) :: String.t()
  def sha256(data) do
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end

  @spec fingerprint([binary()]) :: String.t()
  def fingerprint(parts) do
    encoded = ["arbor_vector_operation_v1", Enum.map(parts, &encode_part/1)]
    sha256(encoded)
  end

  defp collect_attrs([], _aliases, required_keys, normalized, count)
       when count == length(required_keys) do
    require_exact_keys({:ok, normalized}, required_keys)
  end

  defp collect_attrs([], _aliases, _required_keys, _normalized, _count), do: :error

  defp collect_attrs(_remaining, _aliases, required_keys, _normalized, count)
       when count >= length(required_keys),
       do: :error

  defp collect_attrs([{key, value} | rest], aliases, required_keys, normalized, count) do
    with {:ok, normalized_key} <- Map.fetch(aliases, key),
         false <- Map.has_key?(normalized, normalized_key) do
      collect_attrs(
        rest,
        aliases,
        required_keys,
        Map.put(normalized, normalized_key, value),
        count + 1
      )
    else
      _invalid -> :error
    end
  end

  defp collect_attrs(_improper, _aliases, _required_keys, _normalized, _count), do: :error

  defp require_exact_keys({:ok, attrs}, required_keys) do
    if Enum.all?(required_keys, &Map.has_key?(attrs, &1)), do: {:ok, attrs}, else: :error
  end

  defp require_exact_keys(:error, _required_keys), do: :error

  defp normalize_vector_items([], dimensions, dimensions, values, bytes, true) do
    {:ok, Enum.reverse(values), bytes |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp normalize_vector_items([], _dimensions, _count, _values, _bytes, _non_zero?),
    do: {:error, :invalid_vector}

  defp normalize_vector_items(
         _remaining,
         dimensions,
         dimensions,
         _values,
         _bytes,
         _non_zero?
       ),
       do: {:error, :invalid_vector}

  defp normalize_vector_items(
         [value | rest],
         dimensions,
         count,
         values,
         bytes,
         non_zero?
       ) do
    case normalize_float32(value) do
      {:ok, normalized, encoded} ->
        normalize_vector_items(
          rest,
          dimensions,
          count + 1,
          [normalized | values],
          [encoded | bytes],
          non_zero? or normalized != 0.0
        )

      {:error, :invalid_float} ->
        {:error, :invalid_vector}
    end
  end

  defp normalize_vector_items(
         _improper,
         _dimensions,
         _count,
         _values,
         _bytes,
         _non_zero?
       ),
       do: {:error, :invalid_vector}

  defp encode_part(part) when is_binary(part), do: [<<byte_size(part)::unsigned-size(32)>>, part]
end
