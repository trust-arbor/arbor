defmodule Arbor.Orchestrator.Eval.Graders.EmbeddingSimilarity do
  @moduledoc """
  Grader using embedding cosine similarity between actual and expected text.

  Calls an embedding provider (default: Ollama at localhost:11434) to
  generate vector embeddings, then computes cosine similarity.

  Options:
    - `:embed_url` — embedding API endpoint (default: "http://localhost:11434/v1/embeddings")
    - `:embed_model` — model name (default: "nomic-embed-text:latest")
    - `:threshold` — pass threshold (default: 0.7)
    - `:timeout` — HTTP timeout in ms (default: 30_000)
  """

  @behaviour Arbor.Orchestrator.Eval.Grader

  @default_url "http://localhost:11434/v1/embeddings"
  @default_model "nomic-embed-text:latest"

  @impl true
  def grade(actual, expected, opts \\ []) do
    url = Keyword.get(opts, :embed_url, @default_url)
    model = Keyword.get(opts, :embed_model, @default_model)
    threshold = Keyword.get(opts, :threshold, 0.7)
    timeout = Keyword.get(opts, :timeout, 30_000)

    actual_str = to_string(actual)
    expected_str = to_string(expected)

    case embed_texts([actual_str, expected_str], url, model, timeout) do
      {:ok, [vec_a, vec_b]} ->
        similarity = cosine_similarity(vec_a, vec_b)

        %{
          score: similarity,
          passed: similarity >= threshold,
          detail: "cosine_similarity=#{Float.round(similarity, 4)}"
        }

      {:error, reason} ->
        %{
          score: 0.0,
          passed: false,
          detail: "embedding unavailable: #{inspect(reason)}"
        }
    end
  end

  @doc "Compute cosine similarity between two vectors."
  def cosine_similarity(a, b) when is_list(a) and is_list(b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    mag_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    mag_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

    if mag_a == 0.0 or mag_b == 0.0, do: 0.0, else: dot / (mag_a * mag_b)
  end

  defp embed_texts(texts, url, model, timeout) do
    case Req.post(url,
           json: %{"model" => model, "input" => texts},
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        {:ok, Enum.map(data, & &1["embedding"])}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, %{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
