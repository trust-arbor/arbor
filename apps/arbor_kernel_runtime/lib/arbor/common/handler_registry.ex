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

  def validate_entry(_name, module, _metadata) do
    behaviours =
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    declared_handler_behaviour? =
      Enum.any?(behaviours, fn behaviour ->
        Code.ensure_loaded?(behaviour) and function_exported?(behaviour, :behaviour_info, 1) and
          {:execute, 4} in behaviour.behaviour_info(:callbacks)
      end)

    if declared_handler_behaviour? and function_exported?(module, :execute, 4) do
      :ok
    else
      {:error, {:missing_handler_behaviour, {:execute, 4}}}
    end
  rescue
    _ -> {:error, {:missing_handler_behaviour, {:execute, 4}}}
  catch
    _, _ -> {:error, {:missing_handler_behaviour, {:execute, 4}}}
  end
end
