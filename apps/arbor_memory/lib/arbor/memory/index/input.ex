defmodule Arbor.Memory.Index.Input do
  @moduledoc false

  alias Arbor.Contracts.Persistence.{VectorOperation, VectorRecord}

  @max_vector_items 4_096
  @max_recall_limit 1_000
  @max_warm_limit 1_000
  @max_filter_items 256
  @transport_overhead_bytes 128

  @spec index(term(), term(), term()) ::
          {:ok, {String.t(), map(), keyword()}} | {:error, term()}
  def index(content, metadata, opts) do
    with :ok <- validate_content(content),
         {:ok, metadata_bytes} <- validate_metadata(metadata),
         {:ok, opts, embedding_bytes} <-
           validate_embedding_opts(opts, [:embedding, :type, :source]),
         true <-
           byte_size(content) + metadata_bytes + embedding_bytes + @transport_overhead_bytes <=
             VectorOperation.limits().max_batch_bytes do
      {:ok, {content, metadata, opts}}
    else
      false -> invalid(:invalid_content)
      {:error, _reason} = error -> error
      _invalid -> invalid(:invalid_content)
    end
  end

  @spec batch(term(), term()) :: {:ok, {[{String.t(), map()}], keyword()}} | {:error, term()}
  def batch(items, opts) do
    with {:ok, opts, embedding_bytes} <- validate_embedding_opts(opts, [:embedding]),
         {:ok, items, count, payload_bytes} <- validate_batch_items(items),
         true <- count > 0 and count <= VectorOperation.limits().max_batch_operations,
         true <-
           payload_bytes + count * (embedding_bytes + @transport_overhead_bytes) <=
             VectorOperation.limits().max_batch_bytes do
      {:ok, {items, opts}}
    else
      false -> {:error, :invalid_batch}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_batch}
    end
  end

  @spec recall(term(), term()) :: {:ok, {String.t(), keyword()}} | {:error, term()}
  def recall(query, opts) do
    with :ok <- validate_content(query),
         {:ok, opts, _embedding_bytes} <-
           validate_embedding_opts(opts, [:embedding, :limit, :threshold, :type, :types]),
         :ok <- validate_limit(Keyword.get(opts, :limit, 10), @max_recall_limit),
         :ok <- validate_threshold(Keyword.get(opts, :threshold, 0.3)),
         :ok <- validate_filter(Keyword.get(opts, :type)),
         :ok <- validate_filters(Keyword.get(opts, :types)) do
      {:ok, {query, opts}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_recall}
    end
  end

  @spec delete(term()) :: {:ok, String.t()} | {:error, :invalid_entry_identity}
  def delete(entry_id) do
    if valid_text?(entry_id, VectorRecord.limits().id_bytes),
      do: {:ok, entry_id},
      else: {:error, :invalid_entry_identity}
  end

  @spec get(term()) :: {:ok, String.t()} | {:error, :not_found}
  def get(entry_id) do
    if valid_text?(entry_id, VectorRecord.limits().id_bytes),
      do: {:ok, entry_id},
      else: {:error, :not_found}
  end

  @spec warm(term()) :: {:ok, keyword()} | {:error, :invalid_options}
  def warm(opts) do
    with {:ok, opts} <- exact_keyword(opts, [:limit, :query]),
         :ok <- validate_limit(Keyword.get(opts, :limit, 1_000), @max_warm_limit),
         :ok <- validate_optional_query(Keyword.get(opts, :query)) do
      {:ok, Keyword.put_new(opts, :limit, 1_000)}
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  @spec sync(term()) :: {:ok, keyword()} | {:error, :invalid_options}
  def sync(opts) do
    case exact_keyword(opts, []) do
      {:ok, opts} -> {:ok, opts}
      _invalid -> {:error, :invalid_options}
    end
  end

  defp validate_batch_items(items), do: validate_batch_items(items, [], 0, 0)

  defp validate_batch_items([], acc, count, bytes),
    do: {:ok, Enum.reverse(acc), count, bytes}

  defp validate_batch_items([{content, metadata} = item | rest], acc, count, bytes)
       when count < 100 do
    with :ok <- validate_content(content),
         {:ok, metadata_bytes} <- validate_metadata(metadata) do
      validate_batch_items(
        rest,
        [item | acc],
        count + 1,
        bytes + byte_size(content) + metadata_bytes
      )
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_batch}
    end
  end

  defp validate_batch_items(_improper_or_oversized, _acc, _count, _bytes),
    do: {:error, :invalid_batch}

  defp validate_content(content) when is_binary(content) do
    with true <- String.valid?(content),
         true <- String.trim(content) != "",
         {:ok, _bytes} <- VectorRecord.canonical_payload_bytes(content) do
      :ok
    else
      _invalid -> invalid(:invalid_content)
    end
  end

  defp validate_content(_content), do: invalid(:invalid_content)

  defp validate_metadata(metadata) when is_map(metadata) and not is_struct(metadata) do
    case VectorRecord.canonical_payload_bytes(metadata) do
      {:ok, bytes} -> {:ok, byte_size(bytes)}
      {:error, _reason} -> invalid(:invalid_metadata)
    end
  end

  defp validate_metadata(_metadata), do: invalid(:invalid_metadata)

  defp validate_embedding_opts(opts, allowed) do
    with {:ok, opts} <- exact_keyword(opts, allowed),
         {:ok, embedding_bytes} <- validate_optional_embedding(Keyword.get(opts, :embedding)) do
      {:ok, opts, embedding_bytes}
    else
      {:error, :invalid_embedding} -> invalid(:invalid_embedding)
      _invalid -> {:error, :invalid_options}
    end
  end

  defp validate_optional_embedding(nil), do: {:ok, VectorRecord.dimensions() * 4}
  defp validate_optional_embedding(embedding), do: validate_vector(embedding, 0, false)

  defp validate_vector([], count, true) when count > 0, do: {:ok, count * 4}
  defp validate_vector([], _count, _nonzero), do: {:error, :invalid_embedding}

  defp validate_vector([value | rest], count, nonzero) when count < @max_vector_items do
    case normalize_float32(value) do
      {:ok, normalized} -> validate_vector(rest, count + 1, nonzero or normalized != 0.0)
      :error -> {:error, :invalid_embedding}
    end
  end

  defp validate_vector(_improper_or_oversized, _count, _nonzero),
    do: {:error, :invalid_embedding}

  defp normalize_float32(value) when is_integer(value) or is_float(value) do
    float = if is_integer(value), do: value * 1.0, else: value
    encoded = <<float::float-size(32)>>
    <<_sign::1, exponent::8, _fraction::23>> = encoded

    if exponent == 255 do
      :error
    else
      <<normalized::float-size(32)>> = encoded
      {:ok, normalized}
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp normalize_float32(_value), do: :error

  defp exact_keyword(opts, allowed) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- length(opts) == map_size(Map.new(opts)),
         true <- Enum.all?(opts, fn {key, _value} -> key in allowed end) do
      {:ok, opts}
    else
      _invalid -> {:error, :invalid_options}
    end
  rescue
    _error -> {:error, :invalid_options}
  end

  defp exact_keyword(_opts, _allowed), do: {:error, :invalid_options}

  defp validate_limit(limit, max) when is_integer(limit) and limit > 0 and limit <= max, do: :ok
  defp validate_limit(_limit, _max), do: {:error, :invalid_options}

  defp validate_threshold(value) when is_integer(value), do: validate_threshold(value * 1.0)

  defp validate_threshold(value) when is_float(value) do
    if value >= -1.0 and value <= 1.0, do: :ok, else: {:error, :invalid_options}
  end

  defp validate_threshold(_value), do: {:error, :invalid_options}

  defp validate_filter(nil), do: :ok
  defp validate_filter(value) when is_atom(value), do: validate_filter(Atom.to_string(value))

  defp validate_filter(value) when is_binary(value) do
    if valid_text?(value, VectorRecord.limits().category_bytes),
      do: :ok,
      else: {:error, :invalid_options}
  end

  defp validate_filter(_value), do: {:error, :invalid_options}

  defp validate_filters(nil), do: :ok
  defp validate_filters(filters), do: validate_filters(filters, 0)

  defp validate_filters([], count) when count > 0, do: :ok

  defp validate_filters([filter | rest], count) when count < @max_filter_items do
    with :ok <- validate_filter(filter), do: validate_filters(rest, count + 1)
  end

  defp validate_filters(_improper_or_oversized, _count), do: {:error, :invalid_options}

  defp validate_optional_query(nil), do: :ok
  defp validate_optional_query(query), do: validate_content(query)

  defp valid_text?(value, max_bytes) when is_binary(value) do
    size = byte_size(value)
    size > 0 and size <= max_bytes and String.valid?(value) and String.trim(value) != ""
  end

  defp valid_text?(_value, _max_bytes), do: false

  defp invalid(reason), do: {:error, {:invalid_legacy_embedding, reason}}
end
