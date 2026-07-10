defmodule Arbor.Orchestrator.CodingPlan.ExecutionManifest do
  @moduledoc """
  Deterministic compile-to-run bindings for reviewed coding graphs.

  The manifest identifies the exact loaded action and handler code referenced
  by a compiled graph, including wrapper handlers and every dynamically selected
  delegate module. It also binds the complete compiled graph structure, not only
  the source bytes from which that graph was parsed. Capability and egress
  projections are derived from those bindings for audit; neither projection
  grants execution authority.
  """

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Handlers.Registry
  alias Arbor.Orchestrator.CodingPlan.LoadedModuleIdentity
  alias Arbor.Contracts.Security.Classification

  @version 2
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/

  @runtime_action_keys ~w(
    beam_sha256
    effect_class
    egress_declared
    egress_destination_resolver
    egress_tier_resolver
    module
    name
    resource_uri
  )

  @action_keys Enum.sort(@runtime_action_keys ++ ~w(description parameters_schema))
  @handler_keys ~w(beam_sha256 handler_type module)
  @stack_entry_keys ~w(beam_sha256 module slot)
  @node_binding_keys ~w(handler_type node_id stack)

  @manifest_keys ~w(
    actions
    capability_uris
    compiled_graph_hash
    egress
    graph_hash
    handlers
    nodes
    version
  )

  @effect_classes Classification.effect_classes()
                  |> Enum.map(&Atom.to_string/1)
                  |> Enum.sort()

  @type json_value ::
          nil | boolean() | number() | String.t() | [json_value()] | %{String.t() => json_value()}
  @type manifest :: %{String.t() => json_value()}
  @type action_index :: %{String.t() => %{String.t() => json_value()}}
  @type node_binding_index :: %{String.t() => %{String.t() => json_value()}}

  @doc "Build the referenced action/handler binding manifest for a compiled graph."
  @spec build(Graph.t(), map(), String.t()) ::
          {:ok, {manifest(), String.t()}} | {:error, term()}
  def build(%Graph{compiled: true} = graph, action_catalog, graph_hash)
      when is_map(action_catalog) and is_binary(graph_hash) do
    with :ok <- validate_sha256(graph_hash, :graph_hash),
         {:ok, compiled_graph_hash} <- compiled_graph_hash(graph),
         {:ok, actions} <- referenced_actions(graph, action_catalog),
         {:ok, handlers} <- referenced_handlers(graph),
         {:ok, nodes} <- referenced_nodes(graph) do
      manifest = %{
        "version" => @version,
        "graph_hash" => graph_hash,
        "compiled_graph_hash" => compiled_graph_hash,
        "actions" => actions,
        "handlers" => handlers,
        "nodes" => nodes,
        "capability_uris" => capability_uris(actions),
        "egress" => egress_manifest(actions)
      }

      with {:ok, digest} <- digest(manifest),
           :ok <- validate(manifest, digest, graph_hash) do
        {:ok, {manifest, digest}}
      end
    end
  end

  def build(_graph, _action_catalog, _graph_hash), do: {:error, :invalid_execution_manifest_input}

  @doc "Validate a JSON-clean execution manifest and its deterministic digest."
  @spec validate(manifest(), String.t(), String.t()) :: :ok | {:error, term()}
  def validate(manifest, expected_digest, expected_graph_hash)
      when is_map(manifest) and is_binary(expected_digest) and is_binary(expected_graph_hash) do
    with :ok <- require_exact_keys(manifest, @manifest_keys, :manifest),
         :ok <- require_equal(manifest["version"], @version, :version),
         :ok <- require_equal(manifest["graph_hash"], expected_graph_hash, :graph_hash),
         :ok <- validate_sha256(expected_graph_hash, :graph_hash),
         :ok <- validate_sha256(manifest["compiled_graph_hash"], :compiled_graph_hash),
         :ok <- validate_actions(manifest["actions"]),
         :ok <- validate_handlers(manifest["handlers"]),
         :ok <- validate_nodes(manifest["nodes"]),
         :ok <- validate_handler_node_consistency(manifest["handlers"], manifest["nodes"]),
         :ok <- validate_string_list(manifest["capability_uris"], :capability_uris),
         :ok <- validate_egress(manifest["egress"]),
         :ok <-
           require_equal(
             manifest["capability_uris"],
             capability_uris(manifest["actions"]),
             :capability_uris
           ),
         :ok <- require_equal(manifest["egress"], egress_manifest(manifest["actions"]), :egress),
         {:ok, actual_digest} <- digest(manifest),
         :ok <- require_equal(actual_digest, expected_digest, :digest) do
      :ok
    end
  end

  def validate(_manifest, _expected_digest, _expected_graph_hash),
    do: {:error, :invalid_execution_manifest}

  @doc "Compare a freshly derived live manifest with the compiler-pinned manifest."
  @spec verify(manifest(), String.t(), Graph.t(), map(), String.t()) ::
          {:ok, action_index()} | {:error, term()}
  def verify(expected, expected_digest, %Graph{} = graph, live_catalog, graph_hash) do
    with :ok <- validate(expected, expected_digest, graph_hash),
         :ok <- verify_compiled_graph(expected, graph),
         {:ok, {actual, actual_digest}} <- build(graph, live_catalog, graph_hash),
         :ok <- compare(expected, expected_digest, actual, actual_digest),
         {:ok, index} <- action_binding_index(expected) do
      {:ok, index}
    end
  end

  @doc "Index manifest action bindings by their exact Jido action name."
  @spec action_binding_index(manifest()) :: {:ok, action_index()} | {:error, term()}
  def action_binding_index(%{"actions" => actions}) when is_list(actions) do
    with :ok <- validate_actions(actions) do
      {:ok, Map.new(actions, &{Map.fetch!(&1, "name"), &1})}
    end
  end

  def action_binding_index(_manifest), do: {:error, :invalid_action_bindings}

  @doc "Index manifest handler bindings by exact graph handler type."
  @spec handler_binding_index(manifest()) :: {:ok, map()} | {:error, term()}
  def handler_binding_index(%{"handlers" => handlers}) when is_list(handlers) do
    with :ok <- validate_handlers(handlers) do
      {:ok, Map.new(handlers, &{Map.fetch!(&1, "handler_type"), &1})}
    end
  end

  def handler_binding_index(_manifest), do: {:error, :invalid_handler_bindings}

  @doc "Index exact per-node wrapper/delegate execution stacks by node ID."
  @spec node_binding_index(manifest()) :: {:ok, node_binding_index()} | {:error, term()}
  def node_binding_index(%{"nodes" => nodes}) when is_list(nodes) do
    with :ok <- validate_nodes(nodes) do
      {:ok, Map.new(nodes, &{Map.fetch!(&1, "node_id"), &1})}
    end
  end

  def node_binding_index(_manifest), do: {:error, :invalid_node_bindings}

  @doc "Verify that a manifest's compiled graph hash matches the actual compiled graph."
  @spec verify_compiled_graph(manifest(), Graph.t()) :: :ok | {:error, term()}
  def verify_compiled_graph(%{"compiled_graph_hash" => expected}, %Graph{} = graph) do
    with {:ok, actual} <- compiled_graph_hash(graph),
         :ok <- require_equal(actual, expected, :compiled_graph_hash) do
      :ok
    end
  end

  def verify_compiled_graph(_manifest, _graph), do: {:error, :invalid_compiled_graph_binding}

  @doc "Compute a deterministic hash over the complete compiled Graph structure."
  @spec compiled_graph_hash(Graph.t()) :: {:ok, String.t()} | {:error, term()}
  def compiled_graph_hash(%Graph{compiled: true} = graph) do
    projection = compiled_term(graph)

    with {:ok, encoded} <- projection |> canonicalize() |> Jason.encode() do
      {:ok, encoded |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)}
    else
      {:error, reason} -> {:error, {:compiled_graph_hash_failed, reason}}
    end
  rescue
    _exception -> {:error, :compiled_graph_hash_failed}
  catch
    _kind, _reason -> {:error, :compiled_graph_hash_failed}
  end

  def compiled_graph_hash(%Graph{}), do: {:error, :graph_not_ir_compiled}
  def compiled_graph_hash(_graph), do: {:error, :invalid_compiled_graph}

  @doc "Verify an already-resolved module against a pinned action binding index."
  @spec verify_action_module(String.t(), module(), action_index() | nil) ::
          {:ok, map() | nil} | {:error, term()}
  def verify_action_module(_action_name, _action_module, nil), do: {:ok, nil}

  def verify_action_module(action_name, action_module, bindings)
      when is_binary(action_name) and is_atom(action_module) and is_map(bindings) do
    with {:ok, expected} <- fetch_binding(bindings, action_name),
         {:ok, actual} <- Arbor.Actions.runtime_descriptor(action_module),
         :ok <- compare_action_runtime_binding(action_name, expected, actual) do
      {:ok, expected}
    end
  end

  def verify_action_module(_action_name, _action_module, _bindings),
    do: {:error, :invalid_action_bindings}

  @doc "Verify an already-resolved handler module against a pinned handler index."
  @spec verify_handler_module(String.t(), module(), map() | nil) ::
          {:ok, map() | nil} | {:error, term()}
  def verify_handler_module(_handler_type, _handler_module, nil), do: {:ok, nil}

  def verify_handler_module(handler_type, handler_module, bindings)
      when is_binary(handler_type) and is_atom(handler_module) and is_map(bindings) do
    with {:ok, expected} <- fetch_handler_binding(bindings, handler_type),
         {:ok, actual} <- handler_binding(handler_type, handler_module),
         :ok <- compare_handler_runtime_binding(handler_type, expected, actual) do
      {:ok, expected}
    end
  end

  def verify_handler_module(_handler_type, _handler_module, _bindings),
    do: {:error, :invalid_handler_bindings}

  @doc "Verify an already-selected per-node execution module immediately before invocation."
  @spec verify_node_module(
          String.t(),
          String.t(),
          module() | nil,
          node_binding_index() | nil
        ) :: {:ok, map() | nil} | {:error, term()}
  def verify_node_module(_node_id, _slot, _module, nil), do: {:ok, nil}

  def verify_node_module(node_id, slot, module, bindings)
      when is_binary(node_id) and is_binary(slot) and
             (is_atom(module) or is_nil(module)) and is_map(bindings) do
    with {:ok, node_binding} <- fetch_node_binding(bindings, node_id),
         {:ok, stack_index} <- stack_binding_index(node_binding["stack"]) do
      verify_selected_stack_module(node_id, slot, module, stack_index)
    end
  end

  def verify_node_module(_node_id, _slot, _module, _bindings),
    do: {:error, :invalid_node_bindings}

  @doc "Require a child manifest to be an exact authority/code subset of its parent."
  @spec require_subset(manifest(), manifest()) :: :ok | {:error, term()}
  def require_subset(child, parent) when is_map(child) and is_map(parent) do
    with {:ok, child_actions} <- action_binding_index(child),
         {:ok, parent_actions} <- action_binding_index(parent),
         :ok <- require_index_subset(child_actions, parent_actions, :action),
         {:ok, child_handlers} <- handler_binding_index(child),
         {:ok, parent_handlers} <- handler_binding_index(parent),
         :ok <- require_index_subset(child_handlers, parent_handlers, :handler),
         :ok <- require_execution_stack_subset(child["nodes"], parent["nodes"]),
         :ok <-
           require_list_subset(
             child["capability_uris"],
             parent["capability_uris"],
             :capability_uri
           ),
         :ok <- require_egress_subset(child["egress"], parent["egress"]) do
      :ok
    end
  end

  def require_subset(_child, _parent), do: {:error, :invalid_execution_manifest_subset}

  @doc "Compute the canonical SHA-256 digest of a JSON-clean manifest."
  @spec digest(manifest()) :: {:ok, String.t()} | {:error, term()}
  def digest(manifest) when is_map(manifest) do
    with true <- json_clean?(manifest),
         {:ok, encoded} <- manifest |> canonicalize() |> Jason.encode() do
      {:ok, encoded |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)}
    else
      false -> {:error, :execution_manifest_not_json_clean}
      {:error, reason} -> {:error, {:execution_manifest_digest_failed, reason}}
    end
  rescue
    _exception -> {:error, :execution_manifest_digest_failed}
  catch
    _kind, _reason -> {:error, :execution_manifest_digest_failed}
  end

  def digest(_manifest), do: {:error, :invalid_execution_manifest}

  defp referenced_actions(graph, catalog) do
    graph
    |> action_names()
    |> Enum.reduce_while({:ok, []}, fn action_name, {:ok, bindings} ->
      case fetch_catalog_action(catalog, action_name) do
        {:ok, binding} -> {:cont, {:ok, [binding | bindings]}}
        :error -> {:halt, {:error, {:referenced_action_missing, action_name}}}
      end
    end)
    |> case do
      {:ok, bindings} -> {:ok, Enum.sort_by(bindings, & &1["name"])}
      {:error, _reason} = error -> error
    end
  end

  defp action_names(%Graph{} = graph) do
    graph.nodes
    |> Map.values()
    |> Enum.flat_map(fn node ->
      if Registry.node_type(node) == "exec" and Map.get(node.attrs, "target") == "action" do
        case Map.get(node.attrs, "action") do
          name when is_binary(name) and name != "" -> [name]
          _other -> []
        end
      else
        []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp fetch_catalog_action(%{"actions" => actions}, action_name) when is_list(actions) do
    case Enum.find(actions, &(&1["name"] == action_name)) do
      binding when is_map(binding) -> {:ok, binding}
      _other -> :error
    end
  end

  defp fetch_catalog_action(_catalog, _action_name), do: :error

  defp referenced_handlers(%Graph{} = graph) do
    graph.nodes
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {_node_id, node}, {:ok, bindings} ->
      handler_type = Registry.node_type(node)

      with module when is_atom(module) <- node.handler_module,
           {:ok, binding} <- handler_binding(handler_type, module) do
        case Map.fetch(bindings, handler_type) do
          :error -> {:cont, {:ok, Map.put(bindings, handler_type, binding)}}
          {:ok, ^binding} -> {:cont, {:ok, bindings}}
          {:ok, _other} -> {:halt, {:error, {:conflicting_handler_binding, handler_type}}}
        end
      else
        nil -> {:halt, {:error, {:handler_binding_missing, handler_type}}}
        {:error, _reason} = error -> {:halt, error}
        _other -> {:halt, {:error, {:invalid_handler_module, handler_type}}}
      end
    end)
    |> case do
      {:ok, bindings} -> {:ok, bindings |> Map.values() |> Enum.sort_by(& &1["handler_type"])}
      {:error, _reason} = error -> error
    end
  end

  defp referenced_nodes(%Graph{} = graph) do
    graph.nodes
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {node_id, node}, {:ok, bindings} ->
      handler_type = Registry.node_type(node)

      with module when is_atom(module) <- node.handler_module,
           {:ok, stack} <- execution_stack(node, module) do
        binding = %{
          "node_id" => node_id,
          "handler_type" => handler_type,
          "stack" => stack
        }

        {:cont, {:ok, [binding | bindings]}}
      else
        nil -> {:halt, {:error, {:handler_binding_missing, handler_type}}}
        {:error, _reason} = error -> {:halt, error}
        _other -> {:halt, {:error, {:invalid_handler_module, handler_type}}}
      end
    end)
    |> case do
      {:ok, bindings} -> {:ok, Enum.sort_by(bindings, & &1["node_id"])}
      {:error, _reason} = error -> error
    end
  end

  defp execution_stack(node, handler_module) do
    with {:ok, wrapper} <- stack_binding("handler", handler_module),
         {:ok, delegates} <- execution_delegates(node, handler_module),
         {:ok, delegate_bindings} <- bind_execution_delegates(delegates) do
      stack = [wrapper | delegate_bindings]

      case stack_binding_index(stack) do
        {:ok, _index} -> {:ok, stack}
        {:error, _reason} = error -> error
      end
    end
  end

  defp execution_delegates(node, handler_module) do
    if function_exported?(handler_module, :execution_delegates, 1) do
      case handler_module.execution_delegates(node) do
        {:ok, delegates} when is_list(delegates) -> {:ok, delegates}
        {:error, _reason} = error -> error
        _other -> {:error, {:invalid_execution_delegates, node.id}}
      end
    else
      {:ok, []}
    end
  end

  defp bind_execution_delegates(delegates) do
    Enum.reduce_while(delegates, {:ok, []}, fn
      {slot, nil}, {:ok, bindings} when is_binary(slot) and slot != "" ->
        {:cont, {:ok, bindings}}

      {slot, module}, {:ok, bindings}
      when is_binary(slot) and slot != "" and is_atom(module) ->
        case stack_binding(slot, module) do
          {:ok, binding} -> {:cont, {:ok, bindings ++ [binding]}}
          {:error, _reason} = error -> {:halt, error}
        end

      _delegate, _acc ->
        {:halt, {:error, :invalid_execution_delegate}}
    end)
  end

  defp handler_binding(handler_type, module) do
    with {:ok, identity} <- module_identity(module, {:handler, handler_type}) do
      {:ok, Map.put(identity, "handler_type", handler_type)}
    end
  end

  defp stack_binding(slot, module) do
    with {:ok, identity} <- module_identity(module, {:execution_slot, slot}) do
      {:ok, Map.put(identity, "slot", slot)}
    end
  end

  defp module_identity(module, error_context) when is_atom(module) do
    case LoadedModuleIdentity.sha256(module) do
      {:ok, beam_sha256} ->
        {:ok, %{"module" => Atom.to_string(module), "beam_sha256" => beam_sha256}}

      {:error, :loaded_object_code_mismatch} ->
        {:error, {:execution_module_loaded_code_mismatch, error_context}}

      {:error, _reason} ->
        {:error, {:execution_module_beam_unavailable, error_context}}
    end
  end

  defp capability_uris(actions) do
    actions
    |> Enum.map(& &1["resource_uri"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp egress_manifest(actions) do
    actions
    |> Enum.map(fn action ->
      %{
        "action" => action["name"],
        "effect_class" => action["effect_class"],
        "egress_declared" => action["egress_declared"],
        "egress_tier_resolver" => action["egress_tier_resolver"],
        "egress_destination_resolver" => action["egress_destination_resolver"]
      }
    end)
    |> Enum.sort_by(& &1["action"])
  end

  defp compare(expected, expected_digest, actual, actual_digest) do
    if expected == actual and expected_digest == actual_digest do
      :ok
    else
      sections =
        @manifest_keys
        |> Enum.reject(&(Map.get(expected, &1) == Map.get(actual, &1)))
        |> Enum.sort()

      {:error, {:execution_manifest_mismatch, sections}}
    end
  end

  defp fetch_binding(bindings, action_name) do
    case Map.fetch(bindings, action_name) do
      {:ok, binding} when is_map(binding) -> {:ok, binding}
      _other -> {:error, {:missing_action_binding, action_name}}
    end
  end

  defp fetch_handler_binding(bindings, handler_type) do
    case Map.fetch(bindings, handler_type) do
      {:ok, binding} when is_map(binding) -> {:ok, binding}
      _other -> {:error, {:missing_handler_binding, handler_type}}
    end
  end

  defp fetch_node_binding(bindings, node_id) do
    case Map.fetch(bindings, node_id) do
      {:ok, binding} when is_map(binding) -> {:ok, binding}
      _other -> {:error, {:missing_node_binding, node_id}}
    end
  end

  defp stack_binding_index(stack) when is_list(stack) do
    Enum.reduce_while(stack, {:ok, %{}}, fn
      %{"slot" => slot} = binding, {:ok, index} when is_binary(slot) and slot != "" ->
        if Map.has_key?(index, slot) do
          {:halt, {:error, {:duplicate_execution_slot, slot}}}
        else
          {:cont, {:ok, Map.put(index, slot, binding)}}
        end

      _binding, _acc ->
        {:halt, {:error, :invalid_execution_stack}}
    end)
  end

  defp stack_binding_index(_stack), do: {:error, :invalid_execution_stack}

  defp verify_selected_stack_module(node_id, slot, nil, stack_index) do
    case Map.fetch(stack_index, slot) do
      :error -> {:ok, nil}
      {:ok, _binding} -> {:error, {:execution_delegate_missing, node_id, slot}}
    end
  end

  defp verify_selected_stack_module(node_id, slot, module, stack_index) when is_atom(module) do
    with {:ok, expected} <- fetch_stack_binding(stack_index, node_id, slot),
         {:ok, actual} <- stack_binding(slot, module),
         :ok <- compare_stack_runtime_binding(node_id, slot, expected, actual) do
      {:ok, expected}
    end
  end

  defp fetch_stack_binding(stack_index, node_id, slot) do
    case Map.fetch(stack_index, slot) do
      {:ok, binding} -> {:ok, binding}
      :error -> {:error, {:missing_execution_delegate_binding, node_id, slot}}
    end
  end

  defp compare_action_runtime_binding(action_name, expected, actual) do
    expected_runtime = Map.take(expected, @runtime_action_keys)

    if expected_runtime == actual do
      :ok
    else
      fields =
        @runtime_action_keys
        |> Enum.reject(&(Map.get(expected_runtime, &1) == Map.get(actual, &1)))
        |> Enum.sort()

      {:error, {:action_binding_mismatch, action_name, fields}}
    end
  end

  defp compare_handler_runtime_binding(handler_type, expected, actual) do
    if expected == actual do
      :ok
    else
      fields =
        @handler_keys
        |> Enum.reject(&(Map.get(expected, &1) == Map.get(actual, &1)))
        |> Enum.sort()

      {:error, {:handler_binding_mismatch, handler_type, fields}}
    end
  end

  defp compare_stack_runtime_binding(node_id, slot, expected, actual) do
    if expected == actual do
      :ok
    else
      fields =
        @stack_entry_keys
        |> Enum.reject(&(Map.get(expected, &1) == Map.get(actual, &1)))
        |> Enum.sort()

      {:error, {:execution_delegate_binding_mismatch, node_id, slot, fields}}
    end
  end

  defp require_index_subset(child, parent, kind) do
    case Enum.find(child, fn {name, binding} -> Map.get(parent, name) != binding end) do
      nil -> :ok
      {name, _binding} -> {:error, {:child_binding_not_pinned_by_parent, kind, name}}
    end
  end

  defp require_execution_stack_subset(child_nodes, parent_nodes)
       when is_list(child_nodes) and is_list(parent_nodes) do
    parent_entries =
      parent_nodes
      |> Enum.flat_map(&Map.get(&1, "stack", []))
      |> MapSet.new()

    child_nodes
    |> Enum.flat_map(&Map.get(&1, "stack", []))
    |> Enum.find(&(not MapSet.member?(parent_entries, &1)))
    |> case do
      nil -> :ok
      entry -> {:error, {:child_binding_not_pinned_by_parent, :execution_module, entry["slot"]}}
    end
  end

  defp require_execution_stack_subset(_child_nodes, _parent_nodes),
    do: {:error, {:invalid_execution_manifest_subset, :execution_modules}}

  defp require_list_subset(child, parent, kind) when is_list(child) and is_list(parent) do
    parent = MapSet.new(parent)

    case Enum.find(child, &(not MapSet.member?(parent, &1))) do
      nil -> :ok
      value -> {:error, {:child_binding_not_pinned_by_parent, kind, value}}
    end
  end

  defp require_list_subset(_child, _parent, kind),
    do: {:error, {:invalid_execution_manifest_subset, kind}}

  defp require_egress_subset(child, parent) when is_list(child) and is_list(parent) do
    parent = MapSet.new(parent)

    case Enum.find(child, &(not MapSet.member?(parent, &1))) do
      nil -> :ok
      entry -> {:error, {:child_binding_not_pinned_by_parent, :egress, entry["action"]}}
    end
  end

  defp require_egress_subset(_child, _parent),
    do: {:error, {:invalid_execution_manifest_subset, :egress}}

  defp validate_actions(actions) when is_list(actions) do
    with :ok <- validate_entries(actions, &validate_action/1, :actions),
         :ok <- validate_sorted_unique(actions, "name", :actions) do
      :ok
    end
  end

  defp validate_actions(_actions), do: {:error, {:invalid_execution_manifest_field, :actions}}

  defp validate_action(action) when is_map(action) do
    with :ok <- require_exact_keys(action, @action_keys, :action),
         :ok <- validate_nonblank(action["name"], :action_name),
         :ok <- validate_nonblank(action["module"], :action_module),
         :ok <- validate_sha256(action["beam_sha256"], :action_beam_sha256),
         :ok <- validate_nonblank(action["description"], :action_description, allow_empty: true),
         true <- is_map(action["parameters_schema"]),
         :ok <- validate_nonblank(action["resource_uri"], :action_resource_uri),
         true <- action["effect_class"] in @effect_classes,
         true <- is_boolean(action["egress_declared"]),
         true <- is_boolean(action["egress_tier_resolver"]),
         true <- is_boolean(action["egress_destination_resolver"]),
         true <- json_clean?(action) do
      :ok
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_action_binding}
    end
  end

  defp validate_action(_action), do: {:error, :invalid_action_binding}

  defp validate_handlers(handlers) when is_list(handlers) do
    with :ok <- validate_entries(handlers, &validate_handler/1, :handlers),
         :ok <- validate_sorted_unique(handlers, "handler_type", :handlers) do
      :ok
    end
  end

  defp validate_handlers(_handlers),
    do: {:error, {:invalid_execution_manifest_field, :handlers}}

  defp validate_handler(handler) when is_map(handler) do
    with :ok <- require_exact_keys(handler, @handler_keys, :handler),
         :ok <- validate_nonblank(handler["handler_type"], :handler_type),
         :ok <- validate_nonblank(handler["module"], :handler_module),
         :ok <- validate_sha256(handler["beam_sha256"], :handler_beam_sha256) do
      :ok
    end
  end

  defp validate_handler(_handler), do: {:error, :invalid_handler_binding}

  defp validate_nodes(nodes) when is_list(nodes) do
    with :ok <- validate_entries(nodes, &validate_node_binding/1, :nodes),
         :ok <- validate_sorted_unique(nodes, "node_id", :nodes) do
      :ok
    end
  end

  defp validate_nodes(_nodes), do: {:error, {:invalid_execution_manifest_field, :nodes}}

  defp validate_node_binding(node) when is_map(node) do
    with :ok <- require_exact_keys(node, @node_binding_keys, :node_binding),
         :ok <- validate_nonblank(node["node_id"], :node_id),
         :ok <- validate_nonblank(node["handler_type"], :node_handler_type),
         :ok <- validate_execution_stack(node["stack"]),
         [%{"slot" => "handler"} | _rest] <- node["stack"] do
      :ok
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_node_binding}
    end
  end

  defp validate_node_binding(_node), do: {:error, :invalid_node_binding}

  defp validate_execution_stack(stack) when is_list(stack) and stack != [] do
    with :ok <- validate_entries(stack, &validate_stack_entry/1, :execution_stack),
         {:ok, _index} <- stack_binding_index(stack) do
      :ok
    end
  end

  defp validate_execution_stack(_stack), do: {:error, :invalid_execution_stack}

  defp validate_stack_entry(binding) when is_map(binding) do
    with :ok <- require_exact_keys(binding, @stack_entry_keys, :execution_stack_entry),
         :ok <- validate_nonblank(binding["slot"], :execution_slot),
         :ok <- validate_nonblank(binding["module"], :execution_module),
         :ok <- validate_sha256(binding["beam_sha256"], :execution_module_beam_sha256) do
      :ok
    end
  end

  defp validate_stack_entry(_binding), do: {:error, :invalid_execution_stack_entry}

  defp validate_handler_node_consistency(handlers, nodes) do
    with {:ok, derived} <- handlers_from_nodes(nodes) do
      require_equal(handlers, derived, :handlers)
    end
  end

  defp handlers_from_nodes(nodes) do
    Enum.reduce_while(nodes, {:ok, %{}}, fn node, {:ok, bindings} ->
      [wrapper | _rest] = node["stack"]
      handler_type = node["handler_type"]

      binding = %{
        "handler_type" => handler_type,
        "module" => wrapper["module"],
        "beam_sha256" => wrapper["beam_sha256"]
      }

      case Map.fetch(bindings, handler_type) do
        :error -> {:cont, {:ok, Map.put(bindings, handler_type, binding)}}
        {:ok, ^binding} -> {:cont, {:ok, bindings}}
        {:ok, _other} -> {:halt, {:error, {:conflicting_handler_binding, handler_type}}}
      end
    end)
    |> case do
      {:ok, bindings} -> {:ok, bindings |> Map.values() |> Enum.sort_by(& &1["handler_type"])}
      {:error, _reason} = error -> error
    end
  end

  defp validate_egress(egress) when is_list(egress) do
    valid? =
      Enum.all?(egress, fn entry ->
        is_map(entry) and
          Map.keys(entry) |> Enum.sort() ==
            ~w(action effect_class egress_declared egress_destination_resolver egress_tier_resolver) and
          is_binary(entry["action"]) and entry["effect_class"] in @effect_classes and
          is_boolean(entry["egress_declared"]) and
          is_boolean(entry["egress_tier_resolver"]) and
          is_boolean(entry["egress_destination_resolver"])
      end)

    if valid?, do: :ok, else: {:error, {:invalid_execution_manifest_field, :egress}}
  end

  defp validate_egress(_egress),
    do: {:error, {:invalid_execution_manifest_field, :egress}}

  defp validate_entries(entries, validator, field) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {entry, index}, :ok ->
      case validator.(entry) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:invalid_execution_manifest_entry, field, index, reason}}}
      end
    end)
  end

  defp validate_sorted_unique(entries, key, field) do
    values = Enum.map(entries, &Map.get(&1, key))

    if values == Enum.sort(values) and length(values) == length(Enum.uniq(values)),
      do: :ok,
      else: {:error, {:execution_manifest_not_sorted_or_unique, field}}
  end

  defp validate_string_list(values, field) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and String.valid?(&1) and String.trim(&1) != "")) and
         values == Enum.sort(values) and length(values) == length(Enum.uniq(values)) do
      :ok
    else
      {:error, {:invalid_execution_manifest_field, field}}
    end
  end

  defp validate_string_list(_values, field),
    do: {:error, {:invalid_execution_manifest_field, field}}

  defp require_exact_keys(map, expected, field) do
    if Map.keys(map) |> Enum.sort() == Enum.sort(expected),
      do: :ok,
      else: {:error, {:unexpected_execution_manifest_keys, field}}
  end

  defp require_equal(value, value, _field), do: :ok

  defp require_equal(_actual, _expected, field),
    do: {:error, {:execution_manifest_field_mismatch, field}}

  defp validate_sha256(value, _field) when is_binary(value) do
    if Regex.match?(@sha256_pattern, value),
      do: :ok,
      else: {:error, :invalid_sha256}
  end

  defp validate_sha256(_value, _field), do: {:error, :invalid_sha256}

  defp validate_nonblank(value, field, opts \\ [])

  defp validate_nonblank(value, field, opts) when is_binary(value) do
    allow_empty? = Keyword.get(opts, :allow_empty, false)

    if String.valid?(value) and not String.contains?(value, <<0>>) and
         (allow_empty? or String.trim(value) != ""),
       do: :ok,
       else: {:error, {:invalid_execution_manifest_field, field}}
  end

  defp validate_nonblank(_value, field, _opts),
    do: {:error, {:invalid_execution_manifest_field, field}}

  # Preserve type distinctions while producing a JSON-clean, order-stable view
  # of the complete compiled Graph. In particular, adjacency maps and parsed IR
  # tuples are included because the Engine consumes them directly at runtime.
  defp compiled_term(%MapSet{} = set) do
    values =
      set |> MapSet.to_list() |> Enum.map(&compiled_term/1) |> Enum.sort_by(&term_sort_key/1)

    %{"$map_set" => values}
  end

  defp compiled_term(%module{} = struct) do
    %{
      "$struct" => Atom.to_string(module),
      "fields" => struct |> Map.from_struct() |> compiled_term()
    }
  end

  defp compiled_term(map) when is_map(map) do
    entries =
      map
      |> Enum.map(fn {key, value} ->
        %{"key" => compiled_term(key), "value" => compiled_term(value)}
      end)
      |> Enum.sort_by(fn %{"key" => key} -> term_sort_key(key) end)

    %{"$map" => entries}
  end

  defp compiled_term(tuple) when is_tuple(tuple) do
    %{"$tuple" => tuple |> Tuple.to_list() |> Enum.map(&compiled_term/1)}
  end

  defp compiled_term(list) when is_list(list), do: Enum.map(list, &compiled_term/1)
  defp compiled_term(atom) when is_atom(atom), do: %{"$atom" => Atom.to_string(atom)}

  defp compiled_term(binary) when is_binary(binary) do
    if String.valid?(binary), do: binary, else: raise(ArgumentError, "invalid graph UTF-8")
  end

  defp compiled_term(value)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: value

  defp compiled_term(_value), do: raise(ArgumentError, "unsupported compiled graph term")

  defp term_sort_key(value) do
    value
    |> canonicalize()
    |> Jason.encode!()
  end

  defp canonicalize(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, canonicalize(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value

  defp json_clean?(value) when is_binary(value), do: String.valid?(value)

  defp json_clean?(value)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_clean?(value) when is_list(value), do: Enum.all?(value, &json_clean?/1)

  defp json_clean?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, nested} ->
      is_binary(key) and String.valid?(key) and json_clean?(nested)
    end)
  end

  defp json_clean?(_value), do: false
end
