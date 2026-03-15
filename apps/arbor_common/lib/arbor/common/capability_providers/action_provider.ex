defmodule Arbor.Common.CapabilityProviders.ActionProvider do
  @moduledoc """
  CapabilityProvider adapter for the ActionRegistry.

  Converts registered Jido action modules into `CapabilityDescriptor`s
  for the unified capability index. Deduplicates by excluding Jido alias
  entries (underscore variants).
  """

  @behaviour Arbor.Contracts.CapabilityProvider

  alias Arbor.Common.ActionRegistry
  alias Arbor.Contracts.CapabilityDescriptor

  @impl true
  def list_capabilities(_opts \\ []) do
    ActionRegistry.list_all()
    |> deduplicate_actions()
    |> Enum.map(fn {name, module, metadata} ->
      module_to_descriptor(name, module, metadata)
    end)
  end

  @impl true
  def describe(id) do
    case parse_action_id(id) do
      {:ok, name} ->
        case ActionRegistry.resolve_by_name(name) do
          {:ok, module} ->
            metadata = get_metadata(name)
            {:ok, module_to_descriptor(name, module, metadata)}

          {:error, _} = err ->
            err
        end

      :error ->
        {:error, :not_found}
    end
  end

  @impl true
  def execute(id, input, opts) do
    case parse_action_id(id) do
      {:ok, name} ->
        case ActionRegistry.resolve_by_name(name) do
          {:ok, module} ->
            context = Keyword.get(opts, :context, %{})
            module.run(input, context)

          {:error, _} = err ->
            err
        end

      :error ->
        {:error, :not_found}
    end
  end

  @actions_mod Arbor.Actions

  @doc false
  def module_to_descriptor(canonical_name, module, metadata) do
    {description, tags} = extract_module_info(module)

    # Include the canonical capability URI from the actions facade.
    # This enables intent-based delegation: resolver results carry their
    # authorization URI, so trust profile intersection can work directly.
    metadata =
      metadata
      |> Map.put(:module, module)
      |> Map.put(:capability_uri, resolve_capability_uri(module))

    %CapabilityDescriptor{
      id: "action:#{canonical_name}",
      name: humanize_name(canonical_name),
      kind: :action,
      description: description,
      tags: tags,
      trust_required: :new,
      provider: __MODULE__,
      source_ref: canonical_name,
      metadata: metadata
    }
  end

  # Runtime bridge to Arbor.Actions.canonical_uri_for/2 (Level 2).
  defp resolve_capability_uri(module) do
    if Code.ensure_loaded?(@actions_mod) and
         function_exported?(@actions_mod, :canonical_uri_for, 2) do
      apply(@actions_mod, :canonical_uri_for, [module, %{}])
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp parse_action_id("action:" <> name), do: {:ok, name}
  defp parse_action_id(_), do: :error

  # Deduplicate entries where the same module is registered under both
  # canonical (dot) and Jido (underscore) names. Prefers the dot name.
  defp deduplicate_actions(entries) do
    entries
    |> Enum.group_by(fn {_name, module, _metadata} -> module end)
    |> Enum.map(fn {_module, group} ->
      # Prefer the dot-separated name (canonical)
      Enum.find(group, hd(group), fn {name, _m, _meta} ->
        String.contains?(name, ".")
      end)
    end)
  end

  defp extract_module_info(module) do
    description =
      if function_exported?(module, :description, 0) do
        module.description()
      else
        ""
      end

    tags =
      if function_exported?(module, :tags, 0) do
        module.tags()
      else
        []
      end

    {description, tags}
  end

  defp humanize_name(name) do
    name
    |> String.split(".")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp get_metadata(name) do
    ActionRegistry.list_all()
    |> Enum.find(fn {n, _m, _meta} -> n == name end)
    |> case do
      {_name, _module, metadata} -> metadata
      nil -> %{}
    end
  end
end
