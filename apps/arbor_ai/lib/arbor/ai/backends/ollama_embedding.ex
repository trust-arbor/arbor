defmodule Arbor.AI.Backends.OllamaEmbedding do
  @moduledoc """
  Ollama embedding provider.

  Generates embeddings via a local Ollama instance using the `/api/embed` endpoint.
  Default model: `nomic-embed-text` (768 dimensions).

  ## Configuration

      config :arbor_ai, :ollama,
        base_url: "http://localhost:11434"   # default

  ## Requirements

  Ollama must be running locally with the embedding model pulled:

      ollama pull nomic-embed-text
  """

  @behaviour Arbor.Contracts.API.Embedding

  require Logger

  @default_base_url "http://localhost:11434"
  @default_model "nomic-embed-text"
  @default_timeout 30_000

  @impl true
  @spec embed(String.t(), keyword()) ::
          {:ok, Arbor.Contracts.API.Embedding.result()} | {:error, term()}
  def embed(text, opts \\ []) do
    case do_embed([text], opts) do
      {:ok, %{embeddings: [embedding | _]} = result} ->
        {:ok,
         %{
           embedding: embedding,
           model: result.model,
           provider: :ollama,
           usage: result.usage,
           dimensions: length(embedding)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec embed_batch([String.t()], keyword()) ::
          {:ok, Arbor.Contracts.API.Embedding.batch_result()} | {:error, term()}
  def embed_batch(texts, opts \\ []) when is_list(texts) do
    do_embed(texts, opts)
  end

  # ── Private ──

  defp do_embed(texts, opts) do
    model = Keyword.get(opts, :model, @default_model)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    base_url = ollama_base_url()

    url = "#{base_url}/api/embed"

    body = Jason.encode!(%{model: model, input: texts})

    Logger.debug("Ollama embed request: model=#{model}, texts=#{length(texts)}")

    case Req.post(url,
           body: body,
           headers: [{"content-type", "application/json"}],
           receive_timeout: timeout
         ) do
      {:ok, %{status: 200, body: body}} ->
        parse_ollama_response(body, model)

      {:ok, %{status: status, body: body}} ->
        error_msg = extract_error(body)
        Logger.warning("Ollama embed failed: status=#{status}, error=#{error_msg}")
        {:error, {:ollama_error, status, error_msg}}

      {:error, reason} ->
        Logger.warning("Ollama embed request failed: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  defp parse_ollama_response(%{"embeddings" => embeddings, "model" => model_name}, _model)
       when is_list(embeddings) do
    dimensions =
      case embeddings do
        [first | _] when is_list(first) -> length(first)
        _ -> 0
      end

    {:ok,
     %{
       embeddings: embeddings,
       model: model_name,
       provider: :ollama,
       usage: %{prompt_tokens: 0, total_tokens: 0},
       dimensions: dimensions
     }}
  end

  defp parse_ollama_response(body, _model) do
    {:error, {:unexpected_response, body}}
  end

  defp extract_error(%{"error" => msg}) when is_binary(msg), do: msg
  defp extract_error(body) when is_binary(body), do: body
  defp extract_error(body), do: inspect(body)

  defp ollama_base_url do
    case Application.get_env(:arbor_ai, :ollama) do
      nil -> @default_base_url
      config -> Keyword.get(config, :base_url, @default_base_url)
    end
  end
end
