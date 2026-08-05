defmodule Arbor.Memory.KnowledgeGraphAuthorityArchitectureTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  @root Path.expand("../../../../..", __DIR__)
  @projection_table :arbor_memory_graphs
  @authority_namespace "knowledge_graph"

  # C3H-H2 still owns proposal transfer. The AI reader cannot depend upward on
  # arbor_memory, and the dashboard reader is discovery-only; both are explicit
  # E2 follow-ups rather than hidden exceptions.
  @projection_allowlist %{
    "apps/arbor_ai/lib/arbor/ai/system_prompt_builder.ex" => [:lookup, :whereis],
    "apps/arbor_dashboard/lib/arbor_dashboard/live/memory_live.ex" => [
      :tab2list,
      :whereis
    ],
    "apps/arbor_memory/lib/arbor/memory.ex" => [:delete],
    "apps/arbor_memory/lib/arbor/memory/application.ex" => [:new, :whereis],
    "apps/arbor_memory/lib/arbor/memory/knowledge_graph_store.ex" => [
      :delete,
      :insert,
      :whereis
    ],
    "apps/arbor_memory/lib/arbor/memory/proposal.ex" => [:insert, :lookup]
  }

  @raw_authority_allowlist %{
    "apps/arbor_memory/lib/arbor/memory/knowledge_graph_store.ex" => [
      :compare_and_swap_tainted,
      :delete_tainted_authoritative,
      :load_tainted_authoritative_with_status
    ]
  }

  test "GraphOps cannot regain ETS or raw MemoryStore authority" do
    source = source!("apps/arbor_memory/lib/arbor/memory/graph_ops.ex")

    assert projection_operations(source) == []
    assert raw_authority_operations(source) == []

    store_calls = remote_call_operations(source, :KnowledgeGraphStore)

    assert MapSet.subset?(
             MapSet.new([
               :get_graph,
               :add_node,
               :add_edge,
               :reinforce,
               :approve_pending,
               :reject_pending,
               :cascade_recall,
               :import_legacy_graph
             ]),
             MapSet.new(store_calls)
           )
  end

  test "raw knowledge_graph MemoryStore authority is confined repository-wide" do
    assert repository_accesses(&raw_authority_operations/1) == @raw_authority_allowlist
  end

  test "projection access is confined repository-wide to explicit operations" do
    assert repository_accesses(&projection_operations/1) == @projection_allowlist
  end

  test "AST projection detector catches indirection and alternate ETS operations" do
    variable_source = """
    table = :arbor_memory_graphs
    :ets.update_element(table, "agent", {2, :forged})
    """

    attribute_source = """
    defmodule AttributeBypass do
      @table :arbor_memory_graphs
      def write(value), do: :ets.insert_new(@table, value)
    end
    """

    function_source = """
    defmodule FunctionBypass do
      @table :arbor_memory_graphs
      def write(value), do: replace(@table, value)
      defp replace(table, value), do: :ets.select_replace(table, value)
    end
    """

    unrelated_source = """
    defmodule UnrelatedTable do
      @moduledoc "Mentions :arbor_memory_graphs only as documentation."
      @table :another_table
      def write(value), do: :ets.insert(@table, value)
    end
    """

    assert projection_operations(variable_source) == [:update_element]
    assert projection_operations(attribute_source) == [:insert_new]
    assert projection_operations(function_source) == [:select_replace]
    assert projection_operations(unrelated_source) == []
  end

  test "AST projection detector catches module and helper indirection" do
    alias_source = """
    alias :ets, as: TableStore
    table = :arbor_memory_graphs
    TableStore.insert(table, {:agent, :value})
    """

    apply_source = """
    write_op = :insert
    apply(:ets, write_op, [:arbor_memory_graphs, {:agent, :value}])
    """

    module_variable_source = """
    backend = :ets
    backend.insert(:arbor_memory_graphs, {:agent, :value})
    """

    helper_source = """
    defp graph_table, do: :arbor_memory_graphs
    :ets.insert(graph_table(), {:agent, :value})
    """

    assert projection_operations(alias_source) == [:insert]
    assert projection_operations(apply_source) == [:apply]
    assert projection_operations(module_variable_source) == [:insert]
    assert projection_operations(helper_source) == [:insert]
  end

  test "AST raw authority detector resolves indirect MemoryStore aliases" do
    source = """
    alias Arbor.Memory.MemoryStore, as: Store
    Store.put("knowledge_graph", "agent", :forged)
    """

    assert raw_authority_operations(source) == [:put]
  end

  test "create-only compatibility save remains confined to C3B initialization" do
    callers =
      app_sources()
      |> Enum.filter(fn path ->
        path
        |> File.read!()
        |> remote_call_operations(:GraphOps)
        |> Enum.member?(:save_graph)
      end)
      |> Enum.map(&relative_path/1)

    assert callers == ["apps/arbor_memory/lib/arbor/memory.ex"]
  end

  defp repository_accesses(detector) do
    app_sources()
    |> Enum.reduce(%{}, fn path, accesses ->
      operations = path |> File.read!() |> detector.()

      if operations == [],
        do: accesses,
        else: Map.put(accesses, relative_path(path), operations)
    end)
  end

  defp projection_operations(source) do
    resource_operations(source, @projection_table, &(&1 == :ets))
  end

  defp raw_authority_operations(source) do
    resource_operations(source, @authority_namespace, &module_named?(&1, :MemoryStore))
  end

  defp resource_operations(source, resource, module_matcher) do
    ast = Code.string_to_quoted!(source)
    bindings = resource_bindings(ast, resource, module_matcher)

    {_ast, operations} =
      Macro.prewalk(ast, MapSet.new(), fn
        {{:., _, [module, operation]}, _, [first_arg | _]} = node, operations
        when is_atom(operation) ->
          if module_reference?(module, module_matcher, bindings) and
               resource_reference?(first_arg, resource, bindings) do
            {node, MapSet.put(operations, operation)}
          else
            {node, operations}
          end

        {:apply, _, [module, _operation | args]} = node, operations ->
          if module_reference?(module, module_matcher, bindings) and
               resource_reference?(args, resource, bindings) do
            {node, MapSet.put(operations, :apply)}
          else
            {node, operations}
          end

        node, operations ->
          {node, operations}
      end)

    operations |> MapSet.to_list() |> Enum.sort()
  end

  defp remote_call_operations(source, module_name) do
    ast = Code.string_to_quoted!(source)

    {_ast, operations} =
      Macro.prewalk(ast, MapSet.new(), fn
        {{:., _, [module, operation]}, _, args} = node, operations
        when is_atom(operation) and is_list(args) ->
          if module_named?(module, module_name),
            do: {node, MapSet.put(operations, operation)},
            else: {node, operations}

        node, operations ->
          {node, operations}
      end)

    operations |> MapSet.to_list() |> Enum.sort()
  end

  defp resource_bindings(ast, resource, module_matcher) do
    definitions = function_definitions(ast)
    aliases = module_aliases(ast)

    converge_bindings(
      ast,
      resource,
      module_matcher,
      definitions,
      %{
        attributes: MapSet.new(),
        variables: MapSet.new(),
        module_attributes: MapSet.new(),
        modules: MapSet.new(),
        aliases: aliases,
        functions: MapSet.new()
      },
      0
    )
  end

  defp converge_bindings(_ast, _resource, _module_matcher, _definitions, bindings, 16),
    do: bindings

  defp converge_bindings(ast, resource, module_matcher, definitions, bindings, attempt) do
    {_ast, next} =
      Macro.prewalk(ast, bindings, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) ->
          acc =
            cond do
              resource_reference?(value, resource, acc) ->
                put_in(acc.attributes, MapSet.put(acc.attributes, name))

              module_reference?(value, module_matcher, acc) ->
                put_in(acc.module_attributes, MapSet.put(acc.module_attributes, name))

              true ->
                acc
            end

          {node, acc}

        {operator, _, [left, right]} = node, acc when operator in [:=, :<-] ->
          acc =
            cond do
              resource_reference?(right, resource, acc) ->
                bind_variables(acc, left, :resource)

              module_reference?(right, module_matcher, acc) ->
                bind_variables(acc, left, :module)

              true ->
                acc
            end

          {node, acc}

        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          updated =
            definitions
            |> Map.get({name, length(args)}, [])
            |> Enum.reduce(acc, fn definition, bindings_acc ->
              Enum.zip(definition.parameters, args)
              |> Enum.reduce(bindings_acc, fn {parameter, argument}, call_acc ->
                cond do
                  resource_reference?(argument, resource, call_acc) ->
                    bind_variables(call_acc, parameter, :resource)

                  module_reference?(argument, module_matcher, call_acc) ->
                    bind_variables(call_acc, parameter, :module)

                  true ->
                    call_acc
                end
              end)
            end)

          {node, updated}

        node, acc ->
          {node, acc}
      end)

    next = mark_returning_functions(next, resource, definitions)

    if next == bindings,
      do: bindings,
      else: converge_bindings(ast, resource, module_matcher, definitions, next, attempt + 1)
  end

  defp function_definitions(ast) do
    {_ast, definitions} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [signature | _]} = node, definitions when kind in [:def, :defp] ->
          case unwrap_signature(signature) do
            {name, _, args} when is_atom(name) and is_list(args) ->
              key = {name, length(args)}

              body =
                case node do
                  {_kind, _, [_signature, body]} when is_list(body) -> Keyword.get(body, :do)
                  _ -> nil
                end

              definition = %{parameters: args, body: body}
              {node, Map.update(definitions, key, [definition], &[definition | &1])}

            _ ->
              {node, definitions}
          end

        node, definitions ->
          {node, definitions}
      end)

    definitions
  end

  defp unwrap_signature({:when, _, [signature | _guards]}), do: signature
  defp unwrap_signature({name, metadata, nil}), do: {name, metadata, []}
  defp unwrap_signature(signature), do: signature

  defp bind_variables(bindings, pattern, :resource) do
    variables =
      pattern
      |> variable_names()
      |> Enum.reduce(bindings.variables, &MapSet.put(&2, &1))

    %{bindings | variables: variables}
  end

  defp bind_variables(bindings, pattern, :module) do
    modules =
      pattern
      |> variable_names()
      |> Enum.reduce(bindings.modules, &MapSet.put(&2, &1))

    %{bindings | modules: modules}
  end

  defp variable_names({name, _, context})
       when is_atom(name) and name != :_ and (is_atom(context) or is_nil(context)),
       do: [name]

  defp variable_names(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.flat_map(&variable_names/1)

  defp variable_names(term) when is_list(term), do: Enum.flat_map(term, &variable_names/1)
  defp variable_names(_term), do: []

  defp mark_returning_functions(bindings, resource, definitions) do
    functions =
      Enum.reduce(definitions, bindings.functions, fn {key, definitions}, functions ->
        if Enum.any?(definitions, &resource_return_expression?(&1.body, resource, bindings)),
          do: MapSet.put(functions, key),
          else: functions
      end)

    %{bindings | functions: functions}
  end

  defp resource_return_expression?(nil, _resource, _bindings), do: false

  defp resource_return_expression?(expression, resource, bindings),
    do: resource_reference?(expression, resource, bindings)

  defp resource_reference?(term, resource, _bindings) when term === resource, do: true

  defp resource_reference?({:@, _, [{name, _, _}]}, _resource, bindings),
    do: MapSet.member?(bindings.attributes, name)

  defp resource_reference?({name, _, args}, resource, bindings)
       when is_atom(name) and is_list(args),
       do:
         MapSet.member?(bindings.functions, {name, length(args)}) or
           Enum.any?(args, &resource_reference?(&1, resource, bindings))

  defp resource_reference?({name, _, context}, _resource, bindings)
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: MapSet.member?(bindings.variables, name)

  defp resource_reference?(term, resource, bindings) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&resource_reference?(&1, resource, bindings))

  defp resource_reference?(term, resource, bindings) when is_list(term),
    do: Enum.any?(term, &resource_reference?(&1, resource, bindings))

  defp resource_reference?(_term, _resource, _bindings), do: false

  defp module_reference?(term, module_matcher, _bindings) when is_atom(term),
    do: module_matcher.(term)

  defp module_reference?({:__aliases__, _, [name]}, module_matcher, bindings) do
    case Map.get(bindings.aliases, name) do
      nil -> false
      target -> module_matcher.(target)
    end
  end

  defp module_reference?({:__aliases__, _, _parts} = term, module_matcher, _bindings),
    do: module_matcher.(term)

  defp module_reference?({:@, _, [{name, _, _}]}, module_matcher, bindings),
    do:
      MapSet.member?(bindings.module_attributes, name) or
        module_alias_reference?(name, module_matcher, bindings)

  defp module_reference?({name, _, context}, _module_matcher, bindings)
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: MapSet.member?(bindings.modules, name)

  defp module_reference?(_term, _module_matcher, _bindings), do: false

  defp module_alias_reference?(name, module_matcher, bindings) do
    case Map.get(bindings.aliases, name) do
      nil -> false
      target -> module_matcher.(target)
    end
  end

  defp module_aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{{:., _, [prefix, :{}]}, _, modules}]} = node, aliases ->
          aliases =
            Enum.reduce(modules, aliases, fn module, aliases ->
              name = alias_name(module, module)
              target = append_module_alias(prefix, module)
              Map.put(aliases, name, target)
            end)

          {node, aliases}

        {:alias, _, [module, opts]} = node, aliases when is_list(opts) ->
          {node, Map.put(aliases, alias_name(Keyword.get(opts, :as), module), module)}

        {:alias, _, [module]} = node, aliases ->
          {node, Map.put(aliases, alias_name(nil, module), module)}

        node, aliases ->
          {node, aliases}
      end)

    aliases
  end

  defp append_module_alias(prefix, module) do
    {:__aliases__, [], module_parts(prefix) ++ module_parts(module)}
  end

  defp module_parts({:__aliases__, _, parts}), do: parts
  defp module_parts(_module), do: []

  defp alias_name({:__aliases__, _, parts}, _module), do: List.last(parts)
  defp alias_name(nil, {:__aliases__, _, parts}), do: List.last(parts)
  defp alias_name(nil, module) when is_atom(module), do: module
  defp alias_name(as, _module) when is_atom(as), do: as

  defp module_named?(:ets, :ets), do: true

  defp module_named?({:__aliases__, _, parts}, expected) when is_list(parts),
    do: List.last(parts) == expected

  defp module_named?(_module, _expected), do: false

  defp app_sources do
    case System.cmd("git", ["ls-files", "--", "apps"], cd: @root) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&Regex.match?(~r{\Aapps/[^/]+/lib/.+\.ex\z}, &1))
        |> Enum.map(&Path.join(@root, &1))
        |> Enum.sort()

      {_output, _status} ->
        raise "unable to enumerate tracked application sources"
    end
  end

  defp relative_path(path), do: Path.relative_to(path, @root)
  defp source!(path), do: @root |> Path.join(path) |> File.read!()
end
