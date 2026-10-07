defmodule Arbor.Orchestrator.Handlers.Registry do
  @moduledoc """
  Handler registry mapping node type strings to handler modules.

  Core handlers and admitted plugin handlers are stored in the owner-protected
  `HandlerRegistry`. Core registration is performed by a supervised custody
  owner during application boot.

  All legacy type names (codergen, tool, memory.recall, etc.) are resolved via
  the alias layer (`Stdlib.Aliases`) which maps them to canonical core types
  with injected attributes.

  Resolution order: alias-resolved registry entry > direct registry entry >
  strict unknown-handler policy.
  """

  alias Arbor.Orchestrator.Graph.Node

  alias Arbor.Orchestrator.Handlers.{
    AdaptHandler,
    BranchHandler,
    ComposeHandler,
    ComputeHandler,
    ExecHandler,
    ExitHandler,
    ExtractHandler,
    FanInHandler,
    GateHandler,
    LlmHandler,
    MapHandler,
    ParallelHandler,
    ReadHandler,
    SanitizeHandler,
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

  # Canonical core handlers — registered into HandlerRegistry at boot
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
    "gate" => GateHandler,
    # Phase 4 (taint-tracking-rebuild): runs vetted sanitizers and records the
    # resulting sanitization bits on output provenance.
    "sanitize" => SanitizeHandler,
    # Phase 4: quarantined extraction via schema validation — passing a strict
    # schema earns an :untrusted/:hostile -> :derived reduction.
    "extract" => ExtractHandler
  }

  @test_fixtures Application.compile_env(
                   :arbor_kernel_runtime,
                   :expose_test_fixtures,
                   false
                 )

  if @test_fixtures do
    @test_fixture_key {__MODULE__, :test_handler_fixtures_v1}
  end

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

  Resolution applies aliases first and then resolves the resulting type through
  the owner-protected registry.
  """
  @spec resolve_with_attrs(Node.t()) :: {module(), Node.t()}
  def resolve_with_attrs(%Node{} = node) do
    raw_type = node_type(node)

    case fixture_handler_for(raw_type) do
      nil -> resolve_via_aliases(raw_type, node)
      handler -> {handler, node}
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

  @spec register(String.t(), module()) :: {:error, :unauthorized}
  def register(type, module) when is_binary(type) and is_atom(module),
    do: {:error, :unauthorized}

  @spec unregister(String.t()) :: {:error, :unauthorized}
  def unregister(type) when is_binary(type), do: {:error, :unauthorized}

  @spec reset_custom_handlers() :: {:error, :unauthorized}
  def reset_custom_handlers, do: {:error, :unauthorized}

  @spec snapshot_custom_handlers() :: {:error, :unauthorized}
  def snapshot_custom_handlers, do: {:error, :unauthorized}

  @spec restore_custom_handlers(map()) :: {:error, :unauthorized}
  def restore_custom_handlers(handlers) when is_map(handlers), do: {:error, :unauthorized}

  @doc "Returns the custom handler for a type, or nil if none registered."
  @spec custom_handler_for(String.t()) :: module() | nil
  def custom_handler_for(type) when is_binary(type) do
    case fixture_handler_for(type) do
      nil -> registered_custom_handler_for(type)
      module -> module
    end
  end

  if @test_fixtures do
    @doc false
    @spec register_fixture(String.t(), module()) :: :ok | {:error, term()}
    def register_fixture(type, module) when is_binary(type) and is_atom(module) do
      if valid_handler_module?(module) do
        :persistent_term.put(@test_fixture_key, Map.put(test_fixtures(), type, module))
        :ok
      else
        {:error, {:missing_handler_behaviour, {:execute, 4}}}
      end
    end

    @doc false
    @spec unregister_fixture(String.t()) :: :ok | {:error, term()}
    def unregister_fixture(type) when is_binary(type) do
      :persistent_term.put(@test_fixture_key, Map.delete(test_fixtures(), type))
      :ok
    end

    @doc false
    @spec snapshot_fixtures() :: %{optional(String.t()) => module()}
    def snapshot_fixtures, do: test_fixtures()

    @doc false
    @spec reset_fixtures() :: :ok
    def reset_fixtures do
      :persistent_term.put(@test_fixture_key, %{})
      :ok
    end

    @doc false
    @spec restore_fixtures(map()) :: :ok | {:error, :invalid_fixture_snapshot}
    def restore_fixtures(fixtures) when is_map(fixtures) do
      if Enum.all?(fixtures, fn {type, module} ->
           is_binary(type) and is_atom(module) and valid_handler_module?(module)
         end) do
        :persistent_term.put(@test_fixture_key, fixtures)
        :ok
      else
        {:error, :invalid_fixture_snapshot}
      end
    end
  end

  @doc """
  Register the 15 core handlers into the HandlerRegistry.
  Called by the Registrar during application boot.
  """
  @spec register_core_handlers() :: :ok | {:error, term()}
  def register_core_handlers do
    case Process.whereis(Arbor.Orchestrator.Handlers.RegistryAuthority) do
      pid when is_pid(pid) -> Arbor.Orchestrator.Handlers.RegistryAuthority.ensure_registered()
      _other -> {:error, :handler_registry_authority_unavailable}
    end
  end

  @doc false
  @spec register_core_handlers_with_custody(binary()) :: :ok | {:error, term()}
  def register_core_handlers_with_custody(custody) when is_binary(custody) do
    if Arbor.Common.core_handlers_locked?() do
      verify_core_handlers()
    else
      with :ok <- register_each_core_handler(custody),
           :ok <- Arbor.Common.lock_core_handlers(custody, 60_000) do
        :ok
      end
    end
  end

  # --- Private ---

  # Look up a core handler from HandlerRegistry, falling back to compile-time map.
  #
  # M3: in strict mode, unknown handler types raise instead of silently
  # dispatching to LlmHandler. The pre-fix fallback turned every misspelled
  # node type, every typo in a custom handler name, and every malicious
  # unrecognized type into an LLM call with whatever context the graph
  # happened to be carrying. Custom handlers must register via
  # HandlerRegistry through the authenticated plugin-admission path.
  defp lookup_core_handler(type) do
    resolved =
      if Arbor.Common.handler_registry_pid() do
        case Arbor.Common.resolve_handler(type) do
          {:ok, module} -> module
          _ -> Map.get(@core_handlers, type)
        end
      else
        Map.get(@core_handlers, type)
      end

    case resolved do
      nil ->
        if strict_unknown_handlers?() do
          raise ArgumentError,
                "Unknown handler type #{inspect(type)} — refusing to fall back to " <>
                  "LlmHandler in strict mode (M3). Register the handler via " <>
                  "the Arbor.Common facade or as a custom handler."
        else
          LlmHandler
        end

      module ->
        module
    end
  end

  @doc false
  def strict_unknown_handlers? do
    Application.get_env(:arbor_orchestrator, :strict_unknown_handlers, Mix.env() == :prod)
  end

  if @test_fixtures do
    defp fixture_handler_for(type), do: Map.get(test_fixtures(), type)
    defp test_fixtures, do: :persistent_term.get(@test_fixture_key, %{})

    defp valid_handler_module?(module) do
      Code.ensure_loaded?(module) and function_exported?(module, :execute, 4)
    rescue
      _exception -> false
    catch
      _kind, _reason -> false
    end
  else
    defp fixture_handler_for(_type), do: nil
  end

  defp registered_custom_handler_for(type) do
    if Map.has_key?(@core_handlers, type) do
      nil
    else
      case Arbor.Common.resolve_handler(type) do
        {:ok, module} -> module
        _other -> nil
      end
    end
  end

  defp verify_core_handlers do
    Enum.reduce_while(@core_handlers, :ok, fn {type, expected_module}, :ok ->
      case Arbor.Common.resolve_handler(type) do
        {:ok, ^expected_module} ->
          {:cont, :ok}

        {:ok, actual_module} ->
          {:halt, {:error, {:core_handler_mismatch, type, expected_module, actual_module}}}

        {:error, reason} ->
          {:halt, {:error, {:core_handler_unavailable, type, reason}}}
      end
    end)
  end

  defp register_each_core_handler(custody) do
    Enum.reduce_while(@core_handlers, :ok, fn {type, module}, :ok ->
      result = Arbor.Common.register_core_handler(type, module, %{}, custody)

      case result do
        :ok ->
          {:cont, :ok}

        {:error, reason} when reason in [:already_registered, :core_locked] ->
          case Arbor.Common.resolve_handler(type) do
            {:ok, ^module} -> {:cont, :ok}
            {:ok, other} -> {:halt, {:error, {:core_handler_mismatch, type, module, other}}}
            {:error, resolve_reason} -> {:halt, {:error, {type, resolve_reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {type, reason}}}
      end
    end)
  end
end
