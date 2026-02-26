defmodule Arbor.Common.ComputeRegistry do
  @moduledoc """
  Registry for computation backends.

  Maps backend names (e.g., "llm", "routing") to handler modules
  that perform computation. Used by `ComputeHandler` to dispatch.

  ## Core Entries (locked at boot)

      "llm"     → CodergenHandler
      "routing"  → RoutingHandler

  Phase 2 will wrap these in proper `Computable` behaviour implementations
  and add `select_best/1` for policy-based backend selection.
  """

  use Arbor.Common.RegistryBase,
    table_name: :compute_registry
end
