defmodule Arbor.Orchestrator.UnifiedLLM.ProviderAdapter do
  @moduledoc false

  alias Arbor.Orchestrator.UnifiedLLM.{Request, Response}

  @callback provider() :: String.t()
  @callback complete(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  @callback stream(Request.t(), keyword()) :: Enumerable.t() | {:error, term()}
  @optional_callbacks [stream: 2]
end
