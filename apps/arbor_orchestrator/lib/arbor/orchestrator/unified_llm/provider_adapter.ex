defmodule Arbor.Orchestrator.UnifiedLLM.ProviderAdapter do
  @moduledoc false

  alias Arbor.Orchestrator.UnifiedLLM.{Request, Response}

  @type embed_result :: %{
          embedding: [float()],
          model: String.t(),
          provider: String.t(),
          usage: map(),
          dimensions: pos_integer()
        }

  @type embed_batch_result :: %{
          embeddings: [[float()]],
          model: String.t(),
          provider: String.t(),
          usage: map(),
          dimensions: pos_integer()
        }

  @callback provider() :: String.t()
  @callback complete(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  @callback stream(Request.t(), keyword()) :: Enumerable.t() | {:error, term()}
  @callback embed(texts :: [String.t()], model :: String.t(), opts :: keyword()) ::
              {:ok, embed_batch_result()} | {:error, term()}
  @callback runtime_contract() :: Arbor.Contracts.AI.RuntimeContract.t()
  @optional_callbacks [stream: 2, embed: 3, runtime_contract: 0]
end
