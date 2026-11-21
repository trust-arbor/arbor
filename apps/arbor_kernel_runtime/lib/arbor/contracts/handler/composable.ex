defmodule Arbor.Contracts.Handler.Composable do
  @moduledoc """
  Behaviour for handler backends that resolve and compose pipelines.

  Implementations are registered in PipelineResolver by source name
  (e.g., "core", "plugin", "remote"). The ComposeHandler dispatches
  to the appropriate implementation based on the node's `source` attribute.

  ## Example

      defmodule MyCorePipelineResolver do
        @behaviour Arbor.Contracts.Handler.Composable

        @impl true
        def resolve(%ScopedContext{} = ctx, opts) do
          name = ScopedContext.get(ctx, "pipeline")
          {:ok, GraphRegistry.resolve(name)}
        end

        @impl true
        def list(opts) do
          {:ok, GraphRegistry.list_all()}
        end

        @impl true
        def capability_required(_ctx) do
          "arbor://handler/compose/core"
        end
      end
  """

  alias Arbor.Contracts.Handler.ScopedContext

  @doc """
  Resolve a pipeline by name or description.

  Returns `{:ok, pipeline_source}` or `{:error, reason}`.
  """
  @callback resolve(ScopedContext.t(), keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  List available pipelines from this source.

  Returns `{:ok, pipelines}` or `{:error, reason}`.
  """
  @callback list(keyword()) ::
              {:ok, [term()]} | {:error, term()}

  @doc """
  Return the capability URI required for resolving pipelines from this source.
  """
  @callback capability_required(ScopedContext.t()) :: String.t()

  @optional_callbacks [list: 1]
end
