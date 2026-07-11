defmodule Arbor.AI.Eval.Graders.EmbeddingSimilarity do
  @moduledoc """
  Grades text similarity using embedding cosine similarity.

  The `:embed_fn` option accepts an injectable
  `(texts, url, model, timeout -> result)` callback. The default callback uses
  the configured OpenAI-compatible embedding endpoint directly.
  """

  @behaviour Arbor.Eval.Grader

  alias Arbor.AI.Eval.RetrievalSupport

  @default_url "http://localhost:11434/v1/embeddings"
  @default_model "nomic-embed-text:latest"
  @default_timeout 30_000
  @max_detail_bytes 1_024
  @max_text_bytes 2_000_000
  @max_embedding_response_bytes 16_777_216
  @max_options 16
  @allowed_options [:embed_url, :embed_model, :timeout, :threshold, :embed_fn]

  @impl true
  def grade(actual, expected, opts \\ []) do
    with :ok <- validate_embedding_opts(opts),
         {:ok, url} <-
           RetrievalSupport.endpoint_option(opts, :embed_url, @default_url, :embedding),
         {:ok, model} <- RetrievalSupport.string_option(opts, :embed_model, @default_model),
         {:ok, timeout} <-
           RetrievalSupport.positive_integer_option(opts, :timeout, @default_timeout),
         {:ok, threshold} <- threshold(opts),
         {:ok, embed_fn} <-
           RetrievalSupport.callback_option(opts, :embed_fn, 4, &default_embed/4),
         {:ok, actual_text} <- normalize_text(actual),
         {:ok, expected_text} <- normalize_text(expected) do
      do_grade(actual_text, expected_text, url, model, timeout, threshold, embed_fn)
    else
      {:error, reason} -> unavailable(reason)
    end
  end

  @doc "Compute cosine similarity between two vectors."
  @spec cosine_similarity([number()], [number()]) :: float()
  def cosine_similarity(a, b) when is_list(a) and is_list(b) do
    RetrievalSupport.cosine_similarity(a, b)
  end

  defp do_grade(actual, expected, url, model, timeout, threshold, embed_fn) do
    case RetrievalSupport.invoke(
           embed_fn,
           [[actual, expected], url, model, timeout],
           :embedding_callback_failed
         ) do
      {:ok, [vector_a, vector_b]} ->
        with {:ok, vector_a} <- RetrievalSupport.validate_vector(vector_a),
             {:ok, vector_b} <- RetrievalSupport.validate_vector(vector_b),
             :ok <- matching_dimensions(vector_a, vector_b) do
          similarity = cosine_similarity(vector_a, vector_b)

          %{
            score: similarity,
            passed: similarity >= threshold,
            detail: "cosine_similarity=#{Float.round(similarity, 4)}"
          }
        else
          {:error, reason} -> unavailable(reason)
        end

      {:ok, _embeddings} ->
        unavailable({:invalid_embedding_response, :two_vectors_required})

      {:error, reason} ->
        unavailable(reason)

      _response ->
        unavailable({:invalid_embedding_response, :ok_tuple_required})
    end
  end

  defp threshold(opts) do
    case Keyword.get(opts, :threshold, 0.7) do
      value when is_number(value) and value >= -1.0 and value <= 1.0 ->
        {:ok, value * 1.0}

      _value ->
        {:error, {:invalid_option, :threshold, :similarity_range_required}}
    end
  end

  defp validate_embedding_opts(opts) when is_list(opts) do
    with :ok <- bounded_option_keys(opts, 0),
         :ok <- RetrievalSupport.validate_opts(opts) do
      :ok
    end
  end

  defp validate_embedding_opts(_opts), do: {:error, {:invalid_options, :keyword_required}}

  defp bounded_option_keys([], _count), do: :ok

  defp bounded_option_keys(_opts, count) when count >= @max_options,
    do: {:error, {:invalid_options, {:option_count_exceeded, @max_options}}}

  defp bounded_option_keys([{key, _value} | rest], count) when key in @allowed_options,
    do: bounded_option_keys(rest, count + 1)

  defp bounded_option_keys([{key, _value} | _rest], _count) when is_atom(key),
    do: {:error, {:invalid_option, key, :unsupported}}

  defp bounded_option_keys(_opts, _count), do: {:error, {:invalid_options, :keyword_required}}

  defp normalize_text(value) when is_binary(value) do
    cond do
      byte_size(value) > @max_text_bytes ->
        {:error, {:invalid_input, {:text_bytes_exceeded, @max_text_bytes}}}

      not String.valid?(value) ->
        {:error, {:invalid_input, :valid_utf8_text_required}}

      true ->
        {:ok, value}
    end
  end

  defp normalize_text(_value), do: {:error, {:invalid_input, :text_required}}

  defp unavailable(reason) do
    %{
      score: 0.0,
      passed: false,
      detail:
        reason
        |> RetrievalSupport.bounded_external_reason()
        |> then(&"embedding unavailable: #{inspect(&1, limit: 20, printable_limit: 400)}")
        |> String.replace_invalid("")
        |> RetrievalSupport.truncate_utf8(@max_detail_bytes)
    }
  end

  defp matching_dimensions(vector_a, vector_b) do
    dimensions_a = length(vector_a)
    dimensions_b = length(vector_b)

    if dimensions_a == dimensions_b do
      :ok
    else
      {:error,
       {:invalid_embedding_response, {:vector_dimension_mismatch, dimensions_a, dimensions_b}}}
    end
  end

  defp default_embed(texts, url, model, timeout) do
    case RetrievalSupport.post_json(
           url,
           %{"model" => model, "input" => texts},
           timeout,
           @max_embedding_response_bytes
         ) do
      {:ok, 200, %{"data" => [first, second]}} when is_map(first) and is_map(second) ->
        {:ok, [Map.get(first, "embedding"), Map.get(second, "embedding")]}

      {:ok, 200, _body} ->
        {:error, {:invalid_embedding_response, :two_vectors_required}}

      {:ok, status, body} ->
        RetrievalSupport.http_error(:http_error, status, body)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
