defmodule Arbor.Contracts.Coding.CanonicalJson do
  @moduledoc """
  One canonical JSON encoding for every digest and signed document in the
  coding contracts: compact, UTF-8, object keys sorted bytewise at every level,
  arrays in the given order.

  Encoding goes through `Jason.OrderedObject`, so the sort order survives
  encoding for any map size (a plain map rebuilt from sorted entries loses the
  order again above 32 keys). `canonical?/2` tells a parser whether a JSON text
  is exactly this encoding of its own decoded value — which also rejects
  duplicate members, since a duplicate collapses on decode and no longer
  re-encodes to the same bytes.
  """

  @doc "Encode `value` canonically. Fails on anything Jason cannot encode."
  @spec encode(term()) :: {:ok, binary()} | {:error, :not_encodable}
  def encode(value) do
    case Jason.encode(ordered(value)) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, :not_encodable}
    end
  rescue
    _ -> {:error, :not_encodable}
  end

  @doc "Encode `value` canonically or raise."
  @spec encode!(term()) :: binary()
  def encode!(value) do
    case encode(value) do
      {:ok, encoded} -> encoded
      {:error, reason} -> raise ArgumentError, "not canonically encodable: #{inspect(reason)}"
    end
  end

  @doc "True when `json` is byte-for-byte the canonical encoding of `decoded`."
  @spec canonical?(binary(), term()) :: boolean()
  def canonical?(json, decoded) when is_binary(json) do
    case encode(decoded) do
      {:ok, ^json} -> true
      _ -> false
    end
  end

  def canonical?(_json, _decoded), do: false

  defp ordered(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), ordered(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value
end
