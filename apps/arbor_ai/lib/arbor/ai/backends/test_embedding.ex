defmodule Arbor.AI.Backends.TestEmbedding do
  @moduledoc """
  Hash-based test embedding provider.

  Generates deterministic pseudo-embeddings from text using hashing.
  No external dependencies required. Used in tests and as fallback
  when no real embedding providers are available.

  The embeddings are NOT semantically meaningful — identical text always
  produces the same vector, but similar text does not produce similar vectors.
  This is sufficient for testing the pipeline without requiring a running model.

  ## Configuration

      config :arbor_ai, :test_embedding,
        dimensions: 768   # default, matches nomic-embed-text
  """

  @behaviour Arbor.Contracts.API.Embedding

  @default_dimensions 768

  @impl true
  @spec embed(String.t(), keyword()) ::
          {:ok, Arbor.Contracts.API.Embedding.result()} | {:error, term()}
  def embed(text, opts \\ []) do
    dimensions = get_dimensions(opts)
    embedding = hash_embedding(text, dimensions)

    {:ok,
     %{
       embedding: embedding,
       model: "test-hash-#{dimensions}d",
       provider: :test,
       usage: %{prompt_tokens: 0, total_tokens: 0},
       dimensions: dimensions
     }}
  end

  @impl true
  @spec embed_batch([String.t()], keyword()) ::
          {:ok, Arbor.Contracts.API.Embedding.batch_result()} | {:error, term()}
  def embed_batch(texts, opts \\ []) when is_list(texts) do
    dimensions = get_dimensions(opts)
    embeddings = Enum.map(texts, &hash_embedding(&1, dimensions))

    {:ok,
     %{
       embeddings: embeddings,
       model: "test-hash-#{dimensions}d",
       provider: :test,
       usage: %{prompt_tokens: 0, total_tokens: 0},
       dimensions: dimensions
     }}
  end

  @doc """
  Generate a hash-based embedding directly.

  Exposed for callers that need the raw vector without the result wrapper.
  """
  @spec hash_embedding(String.t(), pos_integer()) :: [float()]
  def hash_embedding(text, dimensions \\ @default_dimensions) do
    hash = :erlang.phash2(text, 1_000_000)

    for i <- 0..(dimensions - 1) do
      :math.sin((hash + i) / 1000) * 0.5 + 0.5
    end
  end

  defp get_dimensions(opts) do
    Keyword.get(opts, :dimensions, configured_dimensions())
  end

  defp configured_dimensions do
    case Application.get_env(:arbor_ai, :test_embedding) do
      nil -> @default_dimensions
      config -> Keyword.get(config, :dimensions, @default_dimensions)
    end
  end
end
