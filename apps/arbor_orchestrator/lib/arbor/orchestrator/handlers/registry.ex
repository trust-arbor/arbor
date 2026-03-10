defmodule Arbor.Orchestrator.Handlers.Registry do
  @moduledoc """
  Handler registry mapping node type strings to handler modules.

  Organized into two layers:
    - **Core handlers** — 15 canonical primitives stored in `HandlerRegistry` (RegistryBase)
    - **Custom handlers** — runtime-registered overrides in persistent_term

  All legacy type names (codergen, tool, memory.recall, etc.) are resolved via
  the alias layer (`Stdlib.Aliases`) which maps them to canonical core types
  with injected attributes.

  Resolution order: custom (persistent_term) > alias-resolved core (HandlerRegistry) > default (LlmHandler).
  """

  alias Arbor.Common.HandlerRegistry
  alias Arbor.Orchestrator.Graph.Node

  alias Arbor.Orchestrator.Handlers.{
    AdaptHandler,
    BranchHandler,
    ComposeHandler,
    ComputeHandler,
    ExecHandler,
    ExitHandler,
    FanInHandler,
    GateHandler,
    LlmHandler,
    MapHandler,
    ParallelHandler,
    ReadHandler,
    StartHandler,
    TransformHandler,
    WaitHandler,
    WriteHandler
  }

  @shape_to_type %{
    "Mdiamond" => "start",
    "Msquare" => "exit",
    "diamond" => "conditional",
    "parallelogram" => "tool",
    "hexagon" => "wait.human",
    "component" => "parallel",
    "tripleoctagon" => "parallel.fan_in",
    "house" => "stack.manager_loop",
    "octagon" => "graph.adapt"
  }

  # 15 canonical core handlers — registered into HandlerRegistry at boot
  @core_handlers %{
    "start" => StartHandler,
    "exit" => ExitHandler,
    "branch" => BranchHandler,
    "parallel" => ParallelHandler,
    "fan_in" => FanInHandler,
    "compute" => ComputeHandler,
    "transform" => TransformHandler,
    "exec" => ExecHandler,
    "read" => ReadHandler,
    "write" => WriteHandler,
    "compose" => ComposeHandler,
    "map" => MapHandler,
    "adapt" => AdaptHandler,
    "wait" => WaitHandler,
    "gate" => GateHandler
  }

  @custom_handlers_key {__MODULE__, :custom_handlers}

  @doc "Returns the canonical core type for any type string."
  @spec canonical_type(String.t()) :: String.t()
  defdelegate canonical_type(type), to: Arbor.Orchestrator.Stdlib.Aliases

  @doc "Returns the 15 core handler type → module map."
  @spec core_handlers() :: map()
  def core_handlers, do: @core_handlers

  @spec node_type(Node.t()) :: String.t()
  def node_type(%Node{} = node) do
    Map.get(node.attrs, "type") ||
      Map.get(@shape_to_type, Map.get(node.attrs, "shape", "box"), "codergen")
  end

  @spec resolve(Node.t()) :: module()
  def resolve(%Node{} = node) do
    {handler, _resolved_node} = resolve_with_attrs(node)
    handler
  end

  @doc """
  Resolves a node to its handler module AND applies alias attribute injection.

  Returns `{handler_module, prepared_node}` where `prepared_node` has any
  alias-injected attributes merged into its attrs. The original type is
  preserved (e.g. "consensus.propose" stays as `type` attr) so delegated
  handlers can dispatch on it.

  Resolution order:
  1. Custom handlers (highest priority, by raw type)
  2. Alias resolution → core handler lookup (primary path)
  3. Canonical type mapping (for aliases without attr injection)
  4. Default to LlmHandler
  """
  @spec resolve_with_attrs(Node.t()) :: {module(), Node.t()}
  def resolve_with_attrs(%Node{} = node) do
    raw_type = node_type(node)

    # Custom handlers always take priority
    case Map.get(custom_handlers(), raw_type) do
      nil ->
        resolve_via_aliases(raw_type, node)

      handler ->
        {handler, node}
    end
  end

  defp resolve_via_aliases(raw_type, node) do
    alias_mod = Arbor.Orchestrator.Stdlib.Aliases

    case alias_mod.resolve(raw_type) do
      {canonical_type, injected_attrs} ->
        # Merge injected attrs into node (don't overwrite existing attrs)
        merged_attrs = Map.merge(injected_attrs, node.attrs)
        prepared_node = %{node | attrs: merged_attrs}
        handler = lookup_core_handler(canonical_type)
        {handler, prepared_node}

      :passthrough ->
        # Check alias_map for types that map without attr injection
        # (e.g. "conditional" → "branch", "parallel.fan_in" → "fan_in")
        canonical = alias_mod.canonical_type(raw_type)

        if canonical != raw_type do
          handler = lookup_core_handler(canonical)
          {handler, node}
        else
          handler = lookup_core_handler(raw_type)
          {handler, node}
        end
    end
  end

  @spec register(String.t(), module()) :: :ok
  def register(type, module) when is_binary(type) and is_atom(module) do
    put_custom_handlers(Map.put(custom_handlers(), type, module))
  end

  @spec unregister(String.t()) :: :ok
  def unregister(type) when is_binary(type) do
    put_custom_handlers(Map.delete(custom_handlers(), type))
  end

  @spec reset_custom_handlers() :: :ok
  def reset_custom_handlers, do: put_custom_handlers(%{})

  @doc """
  Returns the current custom handlers map.
  Use with `restore_custom_handlers/1` for test save/restore.
  """
  @spec snapshot_custom_handlers() :: map()
  def snapshot_custom_handlers, do: custom_handlers()

  @doc """
  Restores custom handlers from a previous snapshot.
  """
  @spec restore_custom_handlers(map()) :: :ok
  def restore_custom_handlers(handlers) when is_map(handlers) do
    put_custom_handlers(handlers)
  end

  @doc "Returns the custom handler for a type, or nil if none registered."
  @spec custom_handler_for(String.t()) :: module() | nil
  def custom_handler_for(type) when is_binary(type) do
    Map.get(custom_handlers(), type)
  end

  @doc """
  Register the 15 core handlers into the HandlerRegistry.
  Called by the Registrar during application boot.
  """
  @spec register_core_handlers() :: :ok
  def register_core_handlers do
    if Process.whereis(HandlerRegistry) do
      for {type, module} <- @core_handlers do
        case HandlerRegistry.register(type, module) do
          :ok -> :ok
          {:error, :already_registered} -> :ok
          {:error, :core_locked} -> :ok
          _ -> :ok
        end
      end

      HandlerRegistry.lock_core()
    end

    :ok
  end

  # --- Private ---

  # Look up a core handler from HandlerRegistry, falling back to compile-time map
  defp lookup_core_handler(type) do
    if Process.whereis(HandlerRegistry) do
      case HandlerRegistry.resolve(type) do
        {:ok, module} -> module
        _ -> Map.get(@core_handlers, type, LlmHandler)
      end
    else
      Map.get(@core_handlers, type, LlmHandler)
    end
  end

  defp custom_handlers do
    :persistent_term.get(@custom_handlers_key, %{})
  end

  defp put_custom_handlers(handlers) do
    :persistent_term.put(@custom_handlers_key, handlers)
    :ok
  end
end
