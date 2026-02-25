defmodule Arbor.Orchestrator.UnifiedLLM.ProviderAdapter do
  @moduledoc false

  alias Arbor.Orchestrator.UnifiedLLM.{Request, Response}

  @callback provider() :: String.t()
  @callback complete(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  @callback stream(Request.t(), keyword()) :: Enumerable.t() | {:error, term()}
  @callback runtime_contract() :: Arbor.Contracts.AI.RuntimeContract.t()
  @optional_callbacks [stream: 2, runtime_contract: 0]
end
