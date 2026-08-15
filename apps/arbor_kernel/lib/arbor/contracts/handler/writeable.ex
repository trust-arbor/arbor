defmodule Arbor.Contracts.Handler.Writeable do
  @moduledoc """
  Behaviour for handler backends that write data to destinations.

  Implementations are registered in WriteableRegistry by destination name
  (e.g., "file", "accumulator", "database"). The WriteHandler dispatches
  to the appropriate implementation based on the node's `target` attribute.

  ## Example

      defmodule MyFileWriteable do
        @behaviour Arbor.Contracts.Handler.Writeable

        @impl true
        def write(%ScopedContext{} = ctx, data, opts) do
          path = ScopedContext.get(ctx, "path")
          File.write(path, data)
        end

        @impl true
        def delete(%ScopedContext{} = ctx, opts) do
          path = ScopedContext.get(ctx, "path")
          File.rm(path)
        end

        @impl true
        def capability_required(operation, _ctx) do
          "arbor://handler/write/file/\#{operation}"
        end
      end
  """

  alias Arbor.Contracts.Handler.ScopedContext

  @doc """
  Write data to this destination.

  Returns `:ok` or `{:ok, result}` or `{:error, reason}`.
  """
  @callback write(ScopedContext.t(), data :: term(), keyword()) ::
              :ok | {:ok, term()} | {:error, term()}

  @doc """
  Delete data at this destination.

  Returns `:ok` or `{:error, reason}`.
  """
  @callback delete(ScopedContext.t(), keyword()) ::
              :ok | {:error, term()}

  @doc """
  Return the capability URI required for the given operation and context.

  The operation is `:write` or `:delete`.
  """
  @callback capability_required(operation :: :write | :delete, ScopedContext.t()) :: String.t()

  @optional_callbacks [delete: 2]
end
