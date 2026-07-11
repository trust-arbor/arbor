defmodule Arbor.LLM.Boundary do
  @moduledoc false

  alias Arbor.LLM.{Response, ResponseBudget, StreamEvent}

  @max_response_bytes 16_777_216
  @max_stream_event_bytes 1_048_576
  @max_embedding_inputs 2_048
  @max_embedding_dimensions 8_192
  @max_embedding_input_bytes 4_194_304
  @max_embedding_text_bytes 2_097_152
  @max_numeric_magnitude 1.0e100
  @signed_64_max 9_223_372_036_854_775_807
  @signed_64_min -9_223_372_036_854_775_808
  @response_limits [
    max_bytes: @max_response_bytes,
    max_nodes: 100_000,
    max_depth: 32,
    max_map_keys: 10_000,
    max_list_items: 100_000
  ]
  @event_limits [
    max_bytes: @max_stream_event_bytes,
    max_nodes: 10_000,
    max_depth: 32,
    max_map_keys: 2_000,
    max_list_items: 10_000
  ]
  @finish_reasons [:stop, :length, :tool_calls, :content_filter, :error, :other]
  @stream_types [:start, :delta, :tool_call, :tool_result, :step_finish, :finish, :error]

  @spec completion(term(), term()) :: {:ok, Response.t()} | {:error, term()}
  def completion(result, opts \\ []) do
    with {:ok, maximum} <- response_maximum(opts) do
      case result do
        {:ok, %Response{} = response} -> validate_response(response, maximum)
        {:error, reason} -> validate_adapter_error(reason)
        other -> {:error, {:invalid_completion_result, bounded_shape(other)}}
      end
    end
  end

  @spec stream_event(term(), term()) :: {:ok, StreamEvent.t()} | {:error, term()}
  def stream_event(event, opts \\ []) do
    with {:ok, maximum} <- stream_event_maximum(opts),
         {:ok, normalized} <- normalize_stream_event(event),
         true <- normalized.type in @stream_types or {:error, :invalid_stream_event_type},
         :ok <-
           ResponseBudget.validate(Map.from_struct(normalized),
             max_bytes: maximum,
             max_nodes: 10_000,
             max_depth: 32,
             max_map_keys: 2_000,
             max_list_items: 10_000
           ) do
      {:ok, normalized}
    else
      {:error, reason} -> {:error, {:invalid_stream_event, reason}}
    end
  end

  @spec embedding_inputs(term()) :: :ok | {:error, term()}
  def embedding_inputs(texts), do: validate_embedding_inputs(texts, 0, 0)

  @spec embedding_response(term(), term()) ::
          {:ok, [[number()]], map()} | {:error, term()}
  def embedding_response(body, expected_count)
      when is_integer(expected_count) and expected_count > 0 and
             expected_count <= @max_embedding_inputs do
    with :ok <- ResponseBudget.validate(body, @response_limits),
         {:ok, entries, usage} <- embedding_entries(body, expected_count),
         :ok <- validate_usage(usage),
         {:ok, indexed, dimensions, count} <-
           collect_embedding_entries(entries, expected_count, %{}, nil, 0),
         true <-
           count == expected_count or {:error, {:unexpected_embedding_count, expected_count}},
         true <-
           map_size(indexed) == expected_count or
             {:error, {:embedding_indices_incomplete, expected_count}},
         true <- (is_integer(dimensions) and dimensions > 0) or {:error, :empty_embedding_vector} do
      ordered = for index <- 0..(expected_count - 1), do: Map.fetch!(indexed, index)
      {:ok, ordered, usage}
    end
  end

  def embedding_response(_body, _expected_count),
    do: {:error, {:invalid_expected_embedding_count, @max_embedding_inputs}}

  defp validate_response(response, maximum) do
    projection = Map.from_struct(response)

    with :ok <- bounded_utf8(response.text, :text, maximum, false),
         :ok <- optional_bounded_utf8(response.reasoning_content, :reasoning_content, maximum),
         :ok <- optional_bounded_utf8(response.session_id, :session_id, 4_096),
         true <- response.finish_reason in @finish_reasons or {:error, :invalid_finish_reason},
         :ok <- validate_usage(response.usage),
         :ok <- validate_warning_list(response.warnings, 0),
         :ok <- validate_optional_list(response.thinking, :thinking),
         :ok <- validate_optional_map(response.raw, :raw),
         :ok <- validate_proper_list(response.content_parts, :content_parts),
         :ok <-
           ResponseBudget.validate(projection,
             max_bytes: maximum,
             max_nodes: 100_000,
             max_depth: 32,
             max_map_keys: 10_000,
             max_list_items: 100_000
           ) do
      {:ok, response}
    else
      {:error, reason} -> {:error, {:invalid_completion_response, reason}}
    end
  end

  defp validate_adapter_error(reason) do
    case ResponseBudget.validate(reason,
           max_bytes: 65_536,
           max_nodes: 2_000,
           max_depth: 8,
           max_map_keys: 256,
           max_list_items: 2_000
         ) do
      :ok -> {:error, reason}
      {:error, _invalid} -> {:error, {:invalid_adapter_error, bounded_shape(reason)}}
    end
  end

  defp normalize_stream_event(%StreamEvent{} = event), do: {:ok, event}

  defp normalize_stream_event(%{type: type, data: data}) when is_atom(type),
    do: {:ok, %StreamEvent{type: type, data: data}}

  defp normalize_stream_event(%{"type" => type, "data" => data}) when is_binary(type) do
    case Enum.find(@stream_types, &(Atom.to_string(&1) == type)) do
      nil -> {:error, :invalid_stream_event_type}
      atom -> {:ok, %StreamEvent{type: atom, data: data}}
    end
  end

  defp normalize_stream_event(_event), do: {:error, :stream_event_required}

  defp embedding_entries(%{"data" => entries} = body, _expected_count),
    do: indexed_entries(entries, Map.get(body, "usage", %{}))

  defp embedding_entries(%{data: entries} = body, _expected_count),
    do: indexed_entries(entries, Map.get(body, :usage, %{}))

  defp embedding_entries(%{indexed_embeddings: entries} = body, _expected_count),
    do: indexed_entries(entries, Map.get(body, :usage, %{}))

  defp embedding_entries(%{"indexed_embeddings" => entries} = body, _expected_count),
    do: indexed_entries(entries, Map.get(body, "usage", %{}))

  defp embedding_entries(%{embeddings: [vector]} = body, 1),
    do: {:ok, [%{index: 0, embedding: vector}], Map.get(body, :usage, %{})}

  defp embedding_entries(%{"embeddings" => [vector]} = body, 1),
    do: {:ok, [%{"index" => 0, "embedding" => vector}], Map.get(body, "usage", %{})}

  defp embedding_entries(%{embeddings: _vectors}, expected_count) when expected_count > 1,
    do: {:error, :indexed_embeddings_required_for_batch}

  defp embedding_entries(%{"embeddings" => _vectors}, expected_count) when expected_count > 1,
    do: {:error, :indexed_embeddings_required_for_batch}

  defp embedding_entries(_body, _expected_count), do: {:error, :unexpected_embed_response}

  defp indexed_entries(entries, usage) when is_list(entries) and is_map(usage),
    do: {:ok, entries, usage}

  defp indexed_entries(_entries, usage) when not is_map(usage),
    do: {:error, :embedding_usage_must_be_map}

  defp indexed_entries(_entries, _usage), do: {:error, :proper_embedding_entries_required}

  defp collect_embedding_entries([], _expected_count, indexed, dimensions, count),
    do: {:ok, indexed, dimensions, count}

  defp collect_embedding_entries(_entries, _expected_count, _indexed, _dimensions, count)
       when count >= @max_embedding_inputs,
       do: {:error, {:embedding_vector_count_exceeded, @max_embedding_inputs}}

  defp collect_embedding_entries([entry | rest], expected_count, indexed, dimensions, count)
       when is_map(entry) do
    index = Map.get(entry, "index", Map.get(entry, :index))
    vector = Map.get(entry, "embedding", Map.get(entry, :embedding))

    with :ok <- validate_embedding_index(index, expected_count, indexed),
         {:ok, next_dimensions} <- validate_embedding_vector(vector, 0),
         true <-
           is_nil(dimensions) or dimensions == next_dimensions or
             {:error, {:embedding_dimension_mismatch, dimensions, next_dimensions}} do
      collect_embedding_entries(
        rest,
        expected_count,
        Map.put(indexed, index, vector),
        next_dimensions,
        count + 1
      )
    end
  end

  defp collect_embedding_entries(
         [_entry | _rest],
         _expected_count,
         _indexed,
         _dimensions,
         _count
       ),
       do: {:error, :embedding_entry_requires_index_and_vector}

  defp collect_embedding_entries(_improper, _expected_count, _indexed, _dimensions, _count),
    do: {:error, :proper_embedding_entries_required}

  defp validate_embedding_index(index, expected_count, indexed) do
    cond do
      not is_integer(index) -> {:error, :embedding_index_must_be_integer}
      index < 0 or index >= expected_count -> {:error, {:embedding_index_out_of_bounds, index}}
      Map.has_key?(indexed, index) -> {:error, {:duplicate_embedding_index, index}}
      true -> :ok
    end
  end

  defp validate_embedding_vector([], 0), do: {:error, :empty_embedding_vector}
  defp validate_embedding_vector([], dimensions), do: {:ok, dimensions}

  defp validate_embedding_vector(_vector, dimensions)
       when dimensions >= @max_embedding_dimensions,
       do: {:error, {:embedding_dimensions_exceeded, @max_embedding_dimensions}}

  defp validate_embedding_vector([value | rest], dimensions) do
    if bounded_number?(value),
      do: validate_embedding_vector(rest, dimensions + 1),
      else: {:error, :bounded_finite_numeric_embedding_required}
  end

  defp validate_embedding_vector(_improper_or_non_list, _dimensions),
    do: {:error, :proper_embedding_vector_required}

  defp validate_embedding_inputs([], _count, _bytes), do: {:error, :embedding_texts_required}

  defp validate_embedding_inputs(_texts, count, _bytes) when count >= @max_embedding_inputs,
    do: {:error, {:embedding_input_count_exceeded, @max_embedding_inputs}}

  defp validate_embedding_inputs([text | rest], count, bytes) when is_binary(text) do
    next_bytes = bytes + byte_size(text)

    cond do
      byte_size(text) > @max_embedding_text_bytes ->
        {:error, {:embedding_text_bytes_exceeded, @max_embedding_text_bytes}}

      next_bytes > @max_embedding_input_bytes ->
        {:error, {:embedding_input_bytes_exceeded, @max_embedding_input_bytes}}

      not String.valid?(text) ->
        {:error, :valid_utf8_embedding_text_required}

      rest == [] ->
        :ok

      true ->
        validate_embedding_inputs(rest, count + 1, next_bytes)
    end
  end

  defp validate_embedding_inputs([_invalid | _rest], _count, _bytes),
    do: {:error, :binary_embedding_text_required}

  defp validate_embedding_inputs(_improper_or_non_list, _count, _bytes),
    do: {:error, :proper_embedding_text_list_required}

  defp validate_usage(usage) when is_map(usage) do
    with :ok <- ResponseBudget.validate(usage, @event_limits) do
      validate_numeric_tree([usage])
    end
  end

  defp validate_usage(_usage), do: {:error, :usage_must_be_map}

  defp validate_numeric_tree([]), do: :ok

  defp validate_numeric_tree([value | rest]) when is_map(value) do
    validate_numeric_tree(Map.values(value) ++ rest)
  end

  defp validate_numeric_tree([value | rest]) when is_list(value) do
    case proper_reverse(value, []) do
      {:ok, values} -> validate_numeric_tree(values ++ rest)
      :error -> {:error, :proper_usage_list_required}
    end
  end

  defp validate_numeric_tree([value | rest]) when is_integer(value) do
    if value >= @signed_64_min and value <= @signed_64_max,
      do: validate_numeric_tree(rest),
      else: {:error, :bounded_usage_number_required}
  end

  defp validate_numeric_tree([value | rest]) when is_float(value) do
    if bounded_number?(value),
      do: validate_numeric_tree(rest),
      else: {:error, :bounded_usage_number_required}
  end

  defp validate_numeric_tree([value | rest])
       when is_binary(value) or is_atom(value) or is_boolean(value) or is_nil(value),
       do: validate_numeric_tree(rest)

  defp validate_numeric_tree([_invalid | _rest]), do: {:error, :invalid_usage_value}

  defp proper_reverse([], acc), do: {:ok, acc}
  defp proper_reverse([head | tail], acc), do: proper_reverse(tail, [head | acc])
  defp proper_reverse(_improper, _acc), do: :error

  defp bounded_number?(value) when is_integer(value),
    do: value >= @signed_64_min and value <= @signed_64_max

  defp bounded_number?(value) when is_float(value),
    do: ResponseBudget.finite_number?(value) and abs(value) <= @max_numeric_magnitude

  defp bounded_number?(_value), do: false

  defp response_maximum(opts),
    do: bounded_option(opts, [:max_response_bytes, :max_output_bytes], @max_response_bytes)

  defp stream_event_maximum(opts),
    do: bounded_option(opts, [:max_stream_event_bytes], @max_stream_event_bytes)

  defp bounded_option(opts, keys, hard_maximum) do
    with {:ok, options} <- collect_options(opts, %{}, 0) do
      case first_option(keys, options) do
        :missing ->
          {:ok, hard_maximum}

        {:ok, supplied} when is_integer(supplied) and supplied > 0 ->
          {:ok, min(supplied, hard_maximum)}

        {:ok, _supplied} ->
          {:error, :positive_boundary_limit_required}
      end
    end
  end

  defp first_option([], _options), do: :missing

  defp first_option([key | rest], options) do
    case Map.fetch(options, key) do
      {:ok, value} -> {:ok, value}
      :error -> first_option(rest, options)
    end
  end

  defp collect_options([], options, _count), do: {:ok, options}
  defp collect_options(_opts, _options, count) when count >= 128, do: {:error, :too_many_options}

  defp collect_options([{key, value} | rest], options, count) when is_atom(key),
    do: collect_options(rest, Map.put(options, key, value), count + 1)

  defp collect_options(_improper_or_non_keyword, _options, _count),
    do: {:error, :keyword_options_required}

  defp bounded_utf8(value, _field, maximum, _allow_nil?)
       when is_binary(value) and byte_size(value) <= maximum do
    if String.valid?(value), do: :ok, else: {:error, :valid_utf8_required}
  end

  defp bounded_utf8(nil, _field, _maximum, true), do: :ok

  defp bounded_utf8(_value, field, maximum, _allow_nil),
    do: {:error, {field, :bounded_string_required, maximum}}

  defp optional_bounded_utf8(value, field, maximum), do: bounded_utf8(value, field, maximum, true)

  defp validate_warning_list([], _count), do: :ok

  defp validate_warning_list(_warnings, count) when count >= 1_000,
    do: {:error, :too_many_warnings}

  defp validate_warning_list([warning | rest], count) when is_binary(warning) do
    with :ok <- bounded_utf8(warning, :warning, 16_384, false) do
      validate_warning_list(rest, count + 1)
    end
  end

  defp validate_warning_list(_improper_or_invalid, _count),
    do: {:error, :bounded_warning_list_required}

  defp validate_optional_list(nil, _field), do: :ok
  defp validate_optional_list(value, field), do: validate_proper_list(value, field)

  defp validate_optional_map(nil, _field), do: :ok
  defp validate_optional_map(value, _field) when is_map(value), do: :ok
  defp validate_optional_map(_value, field), do: {:error, {field, :map_required}}

  defp validate_proper_list(value, _field) when is_list(value), do: :ok
  defp validate_proper_list(_value, field), do: {:error, {field, :proper_list_required}}

  defp bounded_shape(value) when is_atom(value), do: value
  defp bounded_shape({tag, _value}) when is_atom(tag), do: tag
  defp bounded_shape(%{__struct__: module}), do: module
  defp bounded_shape(value) when is_map(value), do: :map
  defp bounded_shape(value) when is_list(value), do: :list
  defp bounded_shape(_value), do: :term
end
