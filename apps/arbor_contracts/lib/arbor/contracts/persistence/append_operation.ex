defmodule Arbor.Contracts.Persistence.AppendOperation do
  @moduledoc """
  Stable identity for one EventLog append attempt.

  The submitted event IDs are the durable operation identity. Fingerprints bind
  those IDs to the exact submitted content so reconciliation cannot mistake an
  unrelated event that reused an ID for a successful append.
  """

  use TypedStruct

  @max_attrs 4
  @max_event_ids 1_000
  @attribute_keys %{
    :operation_id => :operation_id,
    "operation_id" => :operation_id,
    :stream_id => :stream_id,
    "stream_id" => :stream_id,
    :event_ids => :event_ids,
    "event_ids" => :event_ids,
    :fingerprints => :fingerprints,
    "fingerprints" => :fingerprints
  }

  @derive Jason.Encoder
  typedstruct enforce: true do
    @typedoc "A bounded, reconcilable append operation"

    field(:operation_id, String.t())
    field(:stream_id, String.t())
    field(:event_ids, [String.t()])
    field(:fingerprints, %{required(String.t()) => String.t()})
  end

  @doc "Construct an append operation from already validated fields."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, :invalid_append_operation}
  def new(attrs) when is_list(attrs) do
    case bounded_attrs(attrs, 0, %{}) do
      {:ok, normalized} -> build(normalized)
      :error -> invalid()
    end
  end

  def new(attrs) when is_map(attrs) do
    if map_size(attrs) <= @max_attrs do
      case bounded_map_attrs(attrs) do
        {:ok, normalized} -> build(normalized)
        :error -> invalid()
      end
    else
      invalid()
    end
  end

  def new(_attrs), do: invalid()

  defp build(%{
         operation_id: operation_id,
         stream_id: stream_id,
         event_ids: event_ids,
         fingerprints: fingerprints
       }) do
    with true <- bounded_binary?(operation_id),
         true <- bounded_binary?(stream_id),
         {:ok, event_count} <- validate_event_ids(event_ids, 0, MapSet.new()),
         true <- valid_fingerprints?(fingerprints, event_ids, event_count) do
      {:ok,
       %__MODULE__{
         operation_id: operation_id,
         stream_id: stream_id,
         event_ids: event_ids,
         fingerprints: fingerprints
       }}
    else
      _invalid -> invalid()
    end
  end

  defp build(_attrs), do: invalid()

  defp bounded_attrs([], _count, attrs), do: {:ok, attrs}
  defp bounded_attrs(_remaining, @max_attrs, _attrs), do: :error

  defp bounded_attrs([{key, value} | rest], count, attrs) do
    with {:ok, normalized_key} <- normalize_key(key),
         false <- Map.has_key?(attrs, normalized_key) do
      bounded_attrs(rest, count + 1, Map.put(attrs, normalized_key, value))
    else
      _invalid -> :error
    end
  end

  defp bounded_attrs(_improper_or_invalid, _count, _attrs), do: :error

  defp bounded_map_attrs(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      with {:ok, normalized_key} <- normalize_key(key),
           false <- Map.has_key?(normalized, normalized_key) do
        {:cont, {:ok, Map.put(normalized, normalized_key, value)}}
      else
        _invalid -> {:halt, :error}
      end
    end)
  end

  defp normalize_key(key) do
    case Map.fetch(@attribute_keys, key) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> :error
    end
  end

  defp validate_event_ids([], count, _seen) when count > 0, do: {:ok, count}
  defp validate_event_ids(_remaining, @max_event_ids, _seen), do: :error

  defp validate_event_ids([event_id | rest], count, seen) do
    if bounded_binary?(event_id) and not MapSet.member?(seen, event_id) do
      validate_event_ids(rest, count + 1, MapSet.put(seen, event_id))
    else
      :error
    end
  end

  defp validate_event_ids(_improper_or_empty, _count, _seen), do: :error

  defp valid_fingerprints?(fingerprints, event_ids, event_count)
       when is_map(fingerprints) and map_size(fingerprints) == event_count do
    Enum.all?(event_ids, fn event_id ->
      case Map.fetch(fingerprints, event_id) do
        {:ok, fingerprint} when is_binary(fingerprint) -> byte_size(fingerprint) == 64
        _missing_or_invalid -> false
      end
    end)
  end

  defp valid_fingerprints?(_fingerprints, _event_ids, _event_count), do: false

  defp bounded_binary?(value) do
    is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 255 and
      String.valid?(value)
  end

  defp invalid, do: {:error, :invalid_append_operation}
end
