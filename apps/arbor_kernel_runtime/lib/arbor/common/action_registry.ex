defmodule Arbor.Common.ActionRegistry do
  @moduledoc """
  Registry for Arbor action modules.

  Replaces the hardcoded `Arbor.Actions.list_actions()` map with a dynamic
  registry supporting runtime registration for plugin-provided actions.

  ## Dual-Name Indexing

  Each action is registered under both its canonical dot-separated name
  (e.g., "file.read") and its Jido underscore name (e.g., "file_read").
  Both resolve to the same module.

  ## Core Entries (locked at boot)

  All actions from `Arbor.Actions.list_actions()` are registered as core
  entries during application boot.

  ## Plugin Registration

      ActionRegistry.register("my_plugin.custom_action", MyPlugin.CustomAction, %{category: :plugin})
  """

  use Arbor.Common.RegistryBase,
    table_name: :action_registry,
    allow_overwrite: false

  @doc """
  Register an action module under both its canonical and Jido names.

  The canonical name is dot-separated (e.g., "file.read").
  The Jido name replaces dots with underscores (e.g., "file_read").
  """
  @spec register_action(module(), map()) :: :ok | {:error, term()}
  def register_action(action_module, metadata \\ %{}) do
    canonical = action_module_to_name(action_module)
    jido_name = String.replace(canonical, ".", "_")

    with :ok <- register(canonical, action_module, metadata) do
      # Register Jido name only if different from canonical
      if jido_name != canonical do
        case register(jido_name, action_module, metadata) do
          :ok -> :ok
          # If Jido name already registered (e.g., from another module), that's fine
          {:error, :already_registered} -> :ok
          error -> error
        end
      else
        :ok
      end
    end
  end

  @doc """
  Resolve an action name to its module, supporting both dot and underscore formats.

  Normalizes underscore names to dot format before lookup.
  """
  @spec resolve_by_name(String.t()) :: {:ok, module()} | {:error, :not_found}
  def resolve_by_name(name) when is_binary(name) do
    # Try direct lookup first
    case resolve(name) do
      {:ok, _module} = ok ->
        ok

      {:error, :not_found} ->
        # Normalize: if no dots, replace underscores with dots
        normalized =
          if String.contains?(name, ".") do
            name
          else
            String.replace(name, "_", ".")
          end

        if normalized != name do
          resolve(normalized)
        else
          {:error, :not_found}
        end
    end
  end

  @doc """
  List all registered actions grouped by category.

  Returns a map of `%{category_atom => [module()]}`.
  """
  @spec list_by_category() :: %{atom() => [module()]}
  def list_by_category do
    list_all()
    |> Enum.reject(fn {_name, _module, metadata} ->
      Map.get(metadata, :is_jido_alias, false)
    end)
    |> Enum.reduce(%{}, &group_action_by_category/2)
  end

  defp group_action_by_category({_name, module, metadata}, acc) do
    category = Map.get(metadata, :category, :uncategorized)

    Map.update(acc, category, [module], fn modules ->
      if module in modules, do: modules, else: modules ++ [module]
    end)
  end

  # Convert an action module to its canonical dot-separated name.
  defp action_module_to_name(module) do
    module
    |> Module.split()
    |> Enum.drop_while(&(&1 != "Actions"))
    |> Enum.drop(1)
    |> Enum.join(".")
    |> Macro.underscore()
    |> String.replace("/", ".")
  end
end
