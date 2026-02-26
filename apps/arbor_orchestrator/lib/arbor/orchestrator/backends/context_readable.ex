defmodule Arbor.Orchestrator.Backends.ContextReadable do
  @moduledoc """
  Readable implementation for pipeline context reads.

  Reads values from the pipeline execution context. This is an identity
  operation — it retrieves a previously-stored context value by key.

  ## ScopedContext Keys

    - `"source_key"` — the context key to read (default: "last_response")
  """

  @behaviour Arbor.Contracts.Handler.Readable

  alias Arbor.Contracts.Handler.ScopedContext

  @impl true
  def read(%ScopedContext{} = ctx, _opts) do
    source_key = ScopedContext.get(ctx, "source_key", "last_response")
    value = ScopedContext.get(ctx, source_key)
    {:ok, value}
  end

  @impl true
  def list(%ScopedContext{} = _ctx, _opts) do
    {:ok, []}
  end

  @impl true
  def capability_required(_operation, _ctx) do
    "arbor://handler/read/context"
  end
end
