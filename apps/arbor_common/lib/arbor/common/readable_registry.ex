defmodule Arbor.Common.ReadableRegistry do
  @moduledoc """
  Registry for read-source backends.

  Maps source names (e.g., "file", "context") to modules implementing
  `Arbor.Contracts.Handler.Readable`. Used by `ReadHandler` to dispatch
  read operations to the appropriate backend.

  ## Core Entries (locked at boot)

      "file"    → FileReadable    (reads from filesystem)
      "context" → ContextReadable (reads from pipeline context)

  ## Plugin Registration

  Plugins can register additional sources:

      ReadableRegistry.register("s3", MyPlugin.S3Readable, %{bucket: "default"})
  """

  use Arbor.Common.RegistryBase,
    table_name: :readable_registry,
    require_behaviour: Arbor.Contracts.Handler.Readable
end
