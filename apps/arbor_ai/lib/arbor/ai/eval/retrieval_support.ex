defmodule Arbor.AI.Eval.RetrievalSupport do
  @moduledoc false

  @max_index_bytes 16_777_216
  @max_index_entries 2_000
  @max_vector_dimensions 8_192
  @max_vector_component_abs 1.0e6

  @positive_integer_limits %{
    top_k: 100,
    candidate_k: 500,
    max_desc_chars: 4_096,
    timeout: 300_000,
    judge_timeout: 300_000,
    max_tokens: 16_384
  }

  @type action :: %{
          module: String.t(),
          description: String.t(),
          embeddings: %{optional(String.t()) => [number()]}
        }

  @spec validate_opts(term()) :: :ok | {:error, term()}
  def validate_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: :ok, else: {:error, {:invalid_options, :keyword_required}}
  end

  def validate_opts(_opts), do: {:error, {:invalid_options, :keyword_required}}

  @spec extract_prompt(term()) :: {:ok, String.t()} | {:error, term()}
  def extract_prompt(%{"prompt" => prompt}) when is_binary(prompt) and prompt != "",
    do: validate_utf8(prompt, {:invalid_input, :valid_utf8_prompt_required})

  def extract_prompt(prompt) when is_binary(prompt) and prompt != "",
    do: validate_utf8(prompt, {:invalid_input, :valid_utf8_prompt_required})

  def extract_prompt(_input), do: {:error, {:invalid_input, :prompt_required}}

  @spec required_string(keyword(), atom()) :: {:ok, String.t()} | {:error, term()}
  def required_string(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        validate_utf8(value, {:invalid_option, key, :valid_utf8_required})

      {:ok, _value} ->
        {:error, {:invalid_option, key, :non_empty_string_required}}

      :error ->
        {:error, {:missing_option, key}}
    end
  end

  @spec string_option(keyword(), atom(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def string_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_binary(value) and value != "" ->
        validate_utf8(value, {:invalid_option, key, :valid_utf8_required})

      _value ->
        {:error, {:invalid_option, key, :non_empty_string_required}}
    end
  end

  @spec positive_integer_option(keyword(), atom(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, term()}
  def positive_integer_option(opts, key, default) do
    value = Keyword.get(opts, key, default)

    case Map.fetch(@positive_integer_limits, key) do
      {:ok, maximum} when is_integer(value) and value > 0 and value <= maximum ->
        {:ok, value}

      {:ok, maximum} ->
        {:error, {:invalid_option, key, {:integer_range_required, 1, maximum}}}

      :error when is_integer(value) and value > 0 ->
        {:ok, value}

      :error ->
        {:error, {:invalid_option, key, :positive_integer_required}}
    end
  end

  @spec optional_positive_integer_option(keyword(), atom()) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  def optional_positive_integer_option(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> {:ok, nil}
      {:ok, value} -> positive_integer_option([{key, value}], key, value)
    end
  end

  @spec callback_option(keyword(), atom(), arity(), function()) ::
          {:ok, function()} | {:error, term()}
  def callback_option(opts, key, arity, default) do
    case Keyword.get(opts, key, default) do
      callback when is_function(callback, arity) -> {:ok, callback}
      _callback -> {:error, {:invalid_option, key, {:function_required, arity}}}
    end
  end

  @spec invoke(function(), [term()], atom()) :: term()
  def invoke(callback, args, error_tag) do
    apply(callback, args)
  rescue
    exception -> {:error, {error_tag, {:exception, Exception.message(exception)}}}
  catch
    :exit, reason -> {:error, {error_tag, {:exit, inspect(reason)}}}
    kind, reason -> {:error, {error_tag, {kind, inspect(reason)}}}
  end

  @spec truncate_utf8(String.t(), pos_integer()) :: String.t()
  def truncate_utf8(text, max_chars)
      when is_binary(text) and is_integer(max_chars) and max_chars > 0 do
    prefix = String.slice(text, 0, max_chars + 1)

    if String.length(prefix) <= max_chars do
      text
    else
      String.slice(prefix, 0, max_chars) <> "..."
    end
  end

  @spec load_index(String.t()) :: {:ok, [action()]} | {:error, term()}
  def load_index(path) when is_binary(path) and path != "" do
    with {:ok, body} <- read_index(path),
         {:ok, decoded} <- decode_index(path, body),
         {:ok, actions} <- normalize_index(path, decoded) do
      {:ok, actions}
    end
  end

  def load_index(_path),
    do: {:error, {:invalid_option, :index_path, :non_empty_string_required}}

  @spec embeddings_for_model([action()], String.t(), String.t()) ::
          {:ok, [{String.t(), [number()]}]} | {:error, term()}
  def embeddings_for_model(actions, model, index_path) do
    indexed =
      Enum.flat_map(actions, fn action ->
        case Map.get(action.embeddings, model) do
          vector when is_list(vector) -> [{action.module, vector}]
          nil -> []
        end
      end)

    case indexed do
      [] -> {:error, {:model_not_indexed, model, index_path}}
      _ -> {:ok, indexed}
    end
  end

  @spec validate_vector(term()) :: {:ok, [number()]} | {:error, term()}
  def validate_vector(vector) do
    case validate_vector_values(vector) do
      {:ok, _dimensions} -> {:ok, vector}
      {:error, reason} -> {:error, {:invalid_embedding_response, reason}}
    end
  end

  @spec validate_query_dimensions([{String.t(), [number()]}], [number()]) ::
          :ok | {:error, term()}
  def validate_query_dimensions([{_module, indexed_vector} | _], query_vector) do
    indexed_dimensions = length(indexed_vector)
    query_dimensions = length(query_vector)

    if indexed_dimensions == query_dimensions do
      :ok
    else
      {:error,
       {:invalid_embedding_response,
        {:vector_dimension_mismatch, indexed_dimensions, query_dimensions}}}
    end
  end

  def validate_query_dimensions([], _query_vector), do: :ok

  @spec parse_router_response(String.t(), MapSet.t(String.t()), pos_integer()) ::
          {:ok, [String.t()]} | {:error, term()}
  def parse_router_response(content, known_modules, top_k)
      when is_binary(content) and is_struct(known_modules, MapSet) do
    case Jason.decode(content) do
      {:ok, %{"selected" => list}} when is_list(list) ->
        normalize_router_modules(list, known_modules, top_k)

      {:ok, %{"actions" => list}} when is_list(list) ->
        normalize_router_modules(list, known_modules, top_k)

      {:ok, list} when is_list(list) ->
        normalize_router_modules(list, known_modules, top_k)

      {:ok, _other} ->
        {:error, {:invalid_router_response, :selected_list_required}}

      {:error, _decode_error} ->
        {:error, {:invalid_router_response, :malformed_json}}
    end
  end

  @spec rank([{String.t(), [number()]}], [number()], pos_integer()) :: [map()]
  def rank(indexed_actions, query_vector, top_k) do
    indexed_actions
    |> Enum.map(fn {module, action_vector} ->
      %{module: module, score: cosine_similarity(query_vector, action_vector)}
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(top_k)
  end

  @spec cosine_similarity([number()], [number()]) :: float()
  def cosine_similarity(a, b) when length(a) == length(b) do
    {dot, a_norm_squared, b_norm_squared} =
      a
      |> Enum.zip(b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {dot, a_norm, b_norm} ->
        {dot + x * y, a_norm + x * x, b_norm + y * y}
      end)

    denominator = :math.sqrt(a_norm_squared) * :math.sqrt(b_norm_squared)
    if denominator == 0.0, do: 0.0, else: dot / denominator
  end

  def cosine_similarity(_a, _b), do: 0.0

  defp validate_utf8(value, error) do
    if String.valid?(value), do: {:ok, value}, else: {:error, error}
  end

  defp normalize_router_modules(list, known_modules, top_k) do
    normalized =
      list
      |> Enum.filter(&is_binary/1)
      |> Enum.filter(&MapSet.member?(known_modules, &1))
      |> Enum.uniq()
      |> Enum.take(top_k)

    if list != [] and normalized == [] do
      {:error, {:invalid_router_response, :known_module_required}}
    else
      {:ok, normalized}
    end
  end

  defp read_index(path) do
    case File.open(path, [:read, :binary], fn io -> IO.binread(io, @max_index_bytes + 1) end) do
      {:ok, :eof} ->
        {:ok, ""}

      {:ok, body} when is_binary(body) and byte_size(body) <= @max_index_bytes ->
        {:ok, body}

      {:ok, body} when is_binary(body) ->
        {:error, {:index_size_exceeded, path, @max_index_bytes}}

      {:ok, {:error, reason}} ->
        {:error, {:index_read_failed, path, reason}}

      {:error, reason} ->
        {:error, {:index_read_failed, path, reason}}
    end
  rescue
    exception -> {:error, {:index_read_failed, path, Exception.message(exception)}}
  end

  defp decode_index(path, body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, {:index_decode_failed, path, Exception.message(error)}}
    end
  end

  defp normalize_index(path, %{"actions" => actions}) when is_list(actions) do
    action_count = length(actions)

    if action_count > @max_index_entries do
      {:error, {:invalid_index, path, {:entry_count_exceeded, @max_index_entries}}}
    else
      actions
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {action, index}, {:ok, acc} ->
        case normalize_action(action) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, reason} -> {:halt, {:error, {:invalid_index, path, index, reason}}}
        end
      end)
      |> case do
        {:ok, []} ->
          {:error, {:invalid_index, path, :actions_required}}

        {:ok, normalized} ->
          normalized = Enum.reverse(normalized)

          case validate_index_dimensions(normalized) do
            :ok -> {:ok, normalized}
            {:error, reason} -> {:error, {:invalid_index, path, reason}}
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp normalize_index(path, _index),
    do: {:error, {:invalid_index, path, :actions_required}}

  defp normalize_action(%{"module" => module} = action)
       when is_binary(module) and module != "" do
    description = Map.get(action, "description", "")
    embeddings = Map.get(action, "embeddings", %{})

    cond do
      not is_binary(description) ->
        {:error, :description_must_be_string}

      not is_map(embeddings) ->
        {:error, :embeddings_must_be_object}

      true ->
        case normalize_embeddings(embeddings) do
          {:ok, normalized} ->
            {:ok, %{module: module, description: description, embeddings: normalized}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp normalize_action(_action), do: {:error, :module_required}

  defp normalize_embeddings(embeddings) do
    Enum.reduce_while(embeddings, {:ok, %{}}, fn
      {model, vector}, {:ok, acc} when is_binary(model) ->
        case validate_vector_values(vector) do
          {:ok, _dimensions} -> {:cont, {:ok, Map.put(acc, model, vector)}}
          {:error, reason} -> {:halt, {:error, {:invalid_embedding, model, reason}}}
        end

      {model, _vector}, _acc ->
        {:halt, {:error, {:invalid_embedding, inspect(model), :numeric_vector_required}}}
    end)
  end

  defp validate_vector_values(vector) when is_list(vector) and vector != [] do
    Enum.reduce_while(vector, {:ok, 0}, fn value, {:ok, dimensions} ->
      cond do
        dimensions >= @max_vector_dimensions ->
          {:halt, {:error, {:vector_dimensions_exceeded, @max_vector_dimensions}}}

        not valid_vector_component?(value) ->
          {:halt, {:error, :numeric_vector_required}}

        true ->
          {:cont, {:ok, dimensions + 1}}
      end
    end)
  end

  defp validate_vector_values(_vector), do: {:error, :numeric_vector_required}

  defp valid_vector_component?(value) when is_number(value) do
    value >= -@max_vector_component_abs and value <= @max_vector_component_abs
  end

  defp valid_vector_component?(_value), do: false

  defp validate_index_dimensions(actions) do
    Enum.reduce_while(actions, {:ok, %{}}, fn action, {:ok, dimensions_by_model} ->
      case merge_embedding_dimensions(action.embeddings, dimensions_by_model) do
        {:ok, dimensions_by_model} -> {:cont, {:ok, dimensions_by_model}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _dimensions_by_model} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp merge_embedding_dimensions(embeddings, dimensions_by_model) do
    Enum.reduce_while(embeddings, {:ok, dimensions_by_model}, fn {model, vector}, {:ok, acc} ->
      dimensions = length(vector)

      case Map.fetch(acc, model) do
        :error ->
          {:cont, {:ok, Map.put(acc, model, dimensions)}}

        {:ok, ^dimensions} ->
          {:cont, {:ok, acc}}

        {:ok, expected} ->
          {:halt, {:error, {:inconsistent_embedding_dimensions, model, expected, dimensions}}}
      end
    end)
  end
end
