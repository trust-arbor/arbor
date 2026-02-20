defmodule Arbor.Common.Sanitizers.Deserialization do
  @moduledoc """
  Sanitizer for insecure deserialization attacks.

  Validates and safely deserializes binary (ETF) and JSON data.
  For ETF binaries, uses `:erlang.binary_to_term/2` with `[:safe]`
  to prevent atom creation attacks. For JSON, validates depth and
  element count post-decode.

  Sets bit 7 on the taint sanitizations bitmask.

  ## Options

  - `:format` — `:etf` or `:json` (default: `:json`)
  - `:max_depth` — maximum nesting depth (default: 32)
  - `:max_size` — maximum total element count (default: 10_000)
  - `:max_byte_size` — maximum input byte size (default: 10_485_760 / 10MB)
  """

  @behaviour Arbor.Contracts.Security.Sanitizer

  alias Arbor.Contracts.Security.Taint

  import Bitwise

  @bit 0b10000000
  @default_max_depth 32
  @default_max_size 10_000
  @default_max_byte_size 10_485_760

  @impl true
  @spec sanitize(term(), Taint.t(), keyword()) ::
          {:ok, term(), Taint.t()} | {:error, term()}
  def sanitize(value, %Taint{} = taint, opts \\ []) when is_binary(value) do
    format = Keyword.get(opts, :format, :json)
    max_byte_size = Keyword.get(opts, :max_byte_size, @default_max_byte_size)

    if byte_size(value) > max_byte_size do
      {:error, {:too_large, byte_size(value), max_byte_size}}
    else
      case format do
        :etf -> deserialize_etf(value, taint)
        :json -> deserialize_json(value, taint, opts)
      end
    end
  end

  @impl true
  @spec detect(term()) :: {:safe, float()} | {:unsafe, [String.t()]}
  def detect(value) when is_binary(value) do
    found =
      [
        {byte_size(value) > @default_max_byte_size, "excessive_size"},
        {looks_like_etf?(value), "binary_term_format"}
      ]

    patterns = for {true, name} <- found, do: name

    case patterns do
      [] -> {:safe, 1.0}
      _ -> {:unsafe, patterns}
    end
  end

  def detect(_), do: {:safe, 1.0}

  # -- Private ---------------------------------------------------------------

  defp deserialize_etf(value, taint) do
    decoded = :erlang.binary_to_term(value, [:safe])
    updated_taint = %{taint | sanitizations: bor(taint.sanitizations, @bit)}
    {:ok, decoded, updated_taint}
  rescue
    ArgumentError ->
      {:error, {:unsafe_term, "Binary contains unsafe terms (atom creation or references)"}}
  end

  defp deserialize_json(value, taint, opts) do
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    max_size = Keyword.get(opts, :max_size, @default_max_size)

    case Jason.decode(value) do
      {:ok, decoded} ->
        with :ok <- validate_depth(decoded, max_depth),
             :ok <- validate_size(decoded, max_size) do
          updated_taint = %{taint | sanitizations: bor(taint.sanitizations, @bit)}
          {:ok, decoded, updated_taint}
        end

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:json_decode_error, Exception.message(error)}}
    end
  end

  @doc false
  @spec validate_depth(term(), non_neg_integer()) :: :ok | {:error, term()}
  def validate_depth(data, max_depth) do
    if depth(data) > max_depth do
      {:error, {:max_depth_exceeded, max_depth}}
    else
      :ok
    end
  end

  @doc false
  @spec validate_size(term(), non_neg_integer()) :: :ok | {:error, term()}
  def validate_size(data, max_size) do
    count = element_count(data)

    if count > max_size do
      {:error, {:max_size_exceeded, count, max_size}}
    else
      :ok
    end
  end

  defp depth(data) when is_map(data) do
    if map_size(data) == 0 do
      1
    else
      1 + (data |> Map.values() |> Enum.map(&depth/1) |> Enum.max())
    end
  end

  defp depth(data) when is_list(data) do
    if data == [] do
      1
    else
      1 + (data |> Enum.map(&depth/1) |> Enum.max())
    end
  end

  defp depth(_), do: 0

  defp element_count(data) when is_map(data) do
    map_size(data) + (data |> Map.values() |> Enum.map(&element_count/1) |> Enum.sum())
  end

  defp element_count(data) when is_list(data) do
    length(data) + (data |> Enum.map(&element_count/1) |> Enum.sum())
  end

  defp element_count(_), do: 1

  # ETF magic number: 131 (version tag for External Term Format)
  defp looks_like_etf?(<<131, _::binary>>), do: true
  defp looks_like_etf?(_), do: false
end
