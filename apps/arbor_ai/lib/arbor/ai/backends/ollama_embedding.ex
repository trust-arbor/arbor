defmodule Arbor.AI.Backends.OllamaEmbedding do
  @moduledoc """
  Compatibility facade for Ollama embeddings.

  Calls the OpenAI-compatible `/v1/embeddings` transport through `Arbor.LLM`,
  which requires authoritative indices for every multi-input response.
  """

  @behaviour Arbor.Contracts.API.Embedding

  @default_base_url "http://localhost:11434/v1"
  @default_model "nomic-embed-text"

  @impl true
  @spec embed(String.t(), keyword()) ::
          {:ok, Arbor.Contracts.API.Embedding.result()} | {:error, term()}
  def embed(text, opts \\ []) do
    with {:ok, result} <- embed_batch([text], opts),
         [embedding] <- result.embeddings do
      {:ok,
       %{
         embedding: embedding,
         model: result.model,
         provider: :ollama,
         usage: result.usage,
         dimensions: result.dimensions
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_single_embedding_result}
    end
  end

  @impl true
  @spec embed_batch([String.t()], keyword()) ::
          {:ok, Arbor.Contracts.API.Embedding.batch_result()} | {:error, term()}
  def embed_batch(texts, opts \\ [])

  def embed_batch(texts, opts) when is_list(texts) and is_list(opts) do
    model = Keyword.get(opts, :model, @default_model)
    base_url = Keyword.get(opts, :base_url, configured_base_url()) |> normalized_base_url()

    transport_opts =
      opts
      |> Keyword.delete(:provider)
      |> Keyword.put(:base_url, base_url)

    case Arbor.LLM.embed_batch("ollama", model, texts, transport_opts) do
      {:ok, result} -> {:ok, Map.put(result, :provider, :ollama)}
      {:error, reason} -> {:error, Arbor.LLM.sanitize_external_reason(reason)}
    end
  rescue
    exception -> {:error, {:embedding_failed, Arbor.LLM.external_exception_message(exception)}}
  catch
    kind, reason ->
      {:error, {:embedding_failure, kind, Arbor.LLM.sanitize_external_reason(reason)}}
  end

  def embed_batch(_texts, _opts), do: {:error, :invalid_embedding_request}

  defp configured_base_url do
    case Application.get_env(:arbor_ai, :ollama) do
      config when is_list(config) -> Keyword.get(config, :base_url, @default_base_url)
      _other -> @default_base_url
    end
  end

  defp normalized_base_url(value) when is_binary(value) do
    value = String.trim_trailing(value, "/")
    if String.ends_with?(value, "/v1"), do: value, else: value <> "/v1"
  end

  defp normalized_base_url(value), do: value
end
