defmodule Arbor.Orchestrator.AgentLoop.ProviderProfile do
  @moduledoc false

  alias Arbor.Orchestrator.AgentLoop.Session
  alias Arbor.Orchestrator.UnifiedLLM.{Request, Response}

  @callback provider() :: String.t()
  @callback system_prompt(keyword()) :: String.t()
  @callback default_tools(keyword()) :: [map()]
  @callback build_request(Session.t(), keyword()) :: Request.t()
  @callback decode_response(Response.t(), Session.t(), keyword()) :: map() | {:error, term()}
end
