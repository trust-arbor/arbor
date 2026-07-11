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

  @impl true
  def grade(actual, expected, opts \\ []) do
    with :ok <- RetrievalSupport.validate_opts(opts),
         {:ok, url} <- RetrievalSupport.string_option(opts, :embed_url, @default_url),
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
             {:ok, vector_b} <- RetrievalSupport.validate_vector(vector_b) do
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

  defp normalize_text(value) when is_binary(value), do: {:ok, value}
  defp normalize_text(value) when is_atom(value) or is_number(value), do: {:ok, to_string(value)}
  defp normalize_text(_value), do: {:error, {:invalid_input, :text_required}}

  defp unavailable(reason) do
    %{
      score: 0.0,
      passed: false,
      detail: "embedding unavailable: #{inspect(reason)}"
    }
  end

  defp default_embed(texts, url, model, timeout) do
    case Req.post(url,
           json: %{"model" => model, "input" => texts},
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
        embeddings = Enum.map(data, &Map.get(&1, "embedding"))
        {:ok, embeddings}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, %{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
