defmodule Arbor.Orchestrator.Handlers.CodergenHandler do
  @moduledoc """
  Backward-compatible alias for `Arbor.Orchestrator.Handlers.LlmHandler`.

  All functionality has been moved to LlmHandler. This module delegates
  all calls for backward compatibility with existing code that references
  CodergenHandler directly.
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Handlers.LlmHandler

  @impl true
  defdelegate execute(node, context, graph, opts), to: LlmHandler

  @impl true
  defdelegate idempotency(), to: LlmHandler
end
