defmodule Arbor.LLM.ProviderAdapter do
  @moduledoc false

  alias Arbor.LLM.Request

  alias Arbor.LLM.Response

  @type embedding :: [number()]
  @type indexed_embedding :: %{index: non_neg_integer(), embedding: embedding()}

  @typedoc """
  Authoritative batch result. `indexed_embeddings` must contain exactly one
  entry per submitted input in input order, with indices `0..n-1`.

  The positional `embeddings` projection is retained for consumers, but it is
  never used to reconstruct associations at an untrusted transport boundary.
  """
  @type indexed_embed_batch_result :: %{
          required(:association_version) => 1,
          required(:indexed_embeddings) => [indexed_embedding()],
          required(:embeddings) => [embedding()],
          optional(:model) => String.t(),
          optional(:provider) => String.t(),
          optional(:usage) => map(),
          optional(:dimensions) => pos_integer()
        }

  @typedoc """
  Compatibility shape for a single submitted input only. Positional results
  are rejected for multi-input calls because association is ambiguous once an
  adapter has discarded provider indices.
  """
  @type legacy_single_embed_result :: %{
          required(:embeddings) => [embedding()],
          optional(:model) => String.t(),
          optional(:provider) => String.t(),
          optional(:usage) => map(),
          optional(:dimensions) => pos_integer()
        }

  @type embed_batch_result :: indexed_embed_batch_result() | legacy_single_embed_result()

  @callback provider() :: String.t()
  @callback complete(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  @callback stream(Request.t(), keyword()) :: Enumerable.t() | {:error, term()}
  @callback embed(texts :: [String.t()], model :: String.t(), opts :: keyword()) ::
              {:ok, embed_batch_result()} | {:error, term()}
  @callback runtime_contract() :: Arbor.Contracts.AI.RuntimeContract.t()
  @optional_callbacks [stream: 2, embed: 3, runtime_contract: 0]
end
