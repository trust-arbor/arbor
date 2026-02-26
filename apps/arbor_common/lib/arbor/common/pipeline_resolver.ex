defmodule Arbor.Common.PipelineResolver do
  @moduledoc """
  Registry for pipeline composition backends.

  Maps composition mode names (e.g., "invoke", "pipeline", "session") to
  handler modules. Used by `ComposeHandler` to dispatch.

  ## Core Entries (locked at boot)

      "invoke"       → SubgraphHandler
      "compose"      → SubgraphHandler
      "pipeline"     → PipelineRunHandler
      "manager_loop" → ManagerLoopHandler
      "session"      → SessionHandler

  Phase 2 will wrap these in proper `Composable` behaviour implementations.
  """

  use Arbor.Common.RegistryBase,
    table_name: :pipeline_resolver
end
