defmodule Arbor.Contracts.API.Embedding do
  @moduledoc """
  Contract for embedding provider implementations.

  Defines the interface for generating vector embeddings from text.
  Implementations wrap an underlying embedding model (Ollama, OpenAI, etc.)
  and provide a consistent interface with structured responses.

  ## Implementation

      defmodule MyApp.Embeddings do
        @behaviour Arbor.Contracts.API.Embedding

        @impl true
        def embed(text, opts) do
          # Call your embedding provider
          {:ok, %{embedding: [...], model: "nomic-embed-text", ...}}
        end

        @impl true
        def embed_batch(texts, opts) do
          # Call your embedding provider with multiple texts
          {:ok, %{embeddings: [[...], [...]], model: "nomic-embed-text", ...}}
        end
      end
  """

  @typedoc "Token usage information from embedding response"
  @type usage :: %{
          prompt_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  @typedoc "Structured response from single embedding"
  @type result :: %{
          embedding: [float()],
          model: String.t(),
          provider: atom(),
          usage: usage(),
          dimensions: pos_integer()
        }

  @typedoc "Structured response from batch embedding"
  @type batch_result :: %{
          embeddings: [[float()]],
          model: String.t(),
          provider: atom(),
          usage: usage(),
          dimensions: pos_integer()
        }

  @typedoc "Options for embedding generation"
  @type opts :: [
          provider: atom(),
          model: String.t(),
          dimensions: pos_integer(),
          timeout: pos_integer()
        ]

  @doc """
  Generate an embedding for a single text.

  ## Parameters

    * `text` - The text to embed
    * `opts` - Options for embedding generation

  ## Options

    * `:provider` - Embedding provider (e.g., `:ollama`, `:openai`). Default: configured default
    * `:model` - Model identifier. Default: implementation-specific
    * `:dimensions` - Requested embedding dimensions (if provider supports it)
    * `:timeout` - Request timeout in ms. Default: 30_000

  ## Returns

    * `{:ok, result}` - Successful embedding with vector and metadata
    * `{:error, term()}` - Embedding failed
  """
  @callback embed(text :: String.t(), opts :: opts()) ::
              {:ok, result()} | {:error, term()}

  @doc """
  Generate embeddings for multiple texts in a single request.

  ## Parameters

    * `texts` - List of texts to embed
    * `opts` - Options for embedding generation (same as `embed/2`)

  ## Returns

    * `{:ok, batch_result}` - Successful batch embedding with vectors and metadata
    * `{:error, term()}` - Embedding failed
  """
  @callback embed_batch(texts :: [String.t()], opts :: opts()) ::
              {:ok, batch_result()} | {:error, term()}
end
