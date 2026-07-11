defmodule Arbor.AI.Eval.RetrievalSupport do
  @moduledoc false

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
    do: {:ok, prompt}

  def extract_prompt(prompt) when is_binary(prompt) and prompt != "", do: {:ok, prompt}
  def extract_prompt(_input), do: {:error, {:invalid_input, :prompt_required}}

  @spec required_string(keyword(), atom()) :: {:ok, String.t()} | {:error, term()}
  def required_string(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key, :non_empty_string_required}}
      :error -> {:error, {:missing_option, key}}
    end
  end

  @spec string_option(keyword(), atom(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def string_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:invalid_option, key, :non_empty_string_required}}
    end
  end

  @spec positive_integer_option(keyword(), atom(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, term()}
  def positive_integer_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _value -> {:error, {:invalid_option, key, :positive_integer_required}}
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
  def validate_vector(vector) when is_list(vector) and vector != [] do
    if Enum.all?(vector, &is_number/1) do
      {:ok, vector}
    else
      {:error, {:invalid_embedding_response, :numeric_vector_required}}
    end
  end

  def validate_vector(_vector),
    do: {:error, {:invalid_embedding_response, :numeric_vector_required}}

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

  defp read_index(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:index_read_failed, path, reason}}
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
    actions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {action, index}, {:ok, acc} ->
      case normalize_action(action) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_index, path, index, reason}}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, {:invalid_index, path, :actions_required}}
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
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
      {model, vector}, {:ok, acc} when is_binary(model) and is_list(vector) ->
        if vector != [] and Enum.all?(vector, &is_number/1) do
          {:cont, {:ok, Map.put(acc, model, vector)}}
        else
          {:halt, {:error, {:invalid_embedding, model}}}
        end

      {model, _vector}, _acc ->
        {:halt, {:error, {:invalid_embedding, to_string(model)}}}
    end)
  end
end
