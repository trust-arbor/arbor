defmodule Arbor.Contracts.Handler.Readable do
  @moduledoc """
  Behaviour for handler backends that read data from sources.

  Implementations are registered in ReadableRegistry by source name
  (e.g., "file", "context", "database"). The ReadHandler dispatches
  to the appropriate implementation based on the node's `source` attribute.

  ## Example

      defmodule MyFileReadable do
        @behaviour Arbor.Contracts.Handler.Readable

        @impl true
        def read(%ScopedContext{} = ctx, opts) do
          path = ScopedContext.get(ctx, "path")
          {:ok, File.read!(path)}
        end

        @impl true
        def list(%ScopedContext{} = ctx, opts) do
          dir = ScopedContext.get(ctx, "directory", ".")
          {:ok, File.ls!(dir)}
        end

        @impl true
        def capability_required(operation, _ctx) do
          "arbor://handler/read/file/\#{operation}"
        end
      end
  """

  alias Arbor.Contracts.Handler.ScopedContext

  @doc """
  Read data from this source.

  Returns `{:ok, data}` or `{:error, reason}`.
  """
  @callback read(ScopedContext.t(), keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  List available items from this source.

  Returns `{:ok, items}` or `{:error, reason}`.
  """
  @callback list(ScopedContext.t(), keyword()) ::
              {:ok, [term()]} | {:error, term()}

  @doc """
  Return the capability URI required for the given operation and context.

  The operation is `:read` or `:list`. Implementations can make
  capability requirements context-dependent (e.g., different capabilities
  for different file paths).
  """
  @callback capability_required(operation :: :read | :list, ScopedContext.t()) :: String.t()

  @optional_callbacks [list: 2]
end
