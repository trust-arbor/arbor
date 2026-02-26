defmodule Arbor.Common.WriteableRegistry do
  @moduledoc """
  Registry for write-destination backends.

  Maps destination names (e.g., "file", "accumulator") to handler modules
  that perform write operations. Used by `WriteHandler` to dispatch.

  ## Core Entries (locked at boot)

      "file"        → FileWriteHandler
      "accumulator" → AccumulatorHandler

  Phase 2 will wrap these in proper `Writeable` behaviour implementations.
  """

  use Arbor.Common.RegistryBase,
    table_name: :writeable_registry
end
