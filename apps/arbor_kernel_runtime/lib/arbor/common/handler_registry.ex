defmodule Arbor.Common.HandlerRegistry do
  @moduledoc """
  Registry for DOT pipeline handler modules.

  Maps node type strings (e.g., "compute", "branch", "exec") to handler
  modules. Core handlers are registered at boot and locked; custom handlers
  can be registered at runtime for plugin-provided node types.

  ## Usage

      # Resolve a handler by type string
      {:ok, ComputeHandler} = HandlerRegistry.resolve("compute")

      # Register a custom handler
      :ok = HandlerRegistry.register("my_plugin.custom", MyPlugin.Handler)

  This registry backs `Arbor.Orchestrator.Handlers.Registry`, which adds
  domain-specific resolution (alias expansion, attribute injection, shape
  mapping) on top of the raw type→module lookup.
  """

  use Arbor.Common.RegistryBase,
    table_name: :handler_registry,
    require_behaviour: nil,
    allow_overwrite: false
end
