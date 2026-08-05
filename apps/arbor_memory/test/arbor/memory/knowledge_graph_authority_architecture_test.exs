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
    bindings = resource_bindings(ast, resource)

    {_ast, operations} =
      Macro.prewalk(ast, MapSet.new(), fn
        {{:., _, [module, operation]}, _, [first_arg | _]} = node, operations
        when is_atom(operation) ->
          if module_matcher.(module) and resource_reference?(first_arg, resource, bindings) do
            {node, MapSet.put(operations, operation)}
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

  defp resource_bindings(ast, resource) do
    definitions = function_definitions(ast)

    converge_bindings(
      ast,
      resource,
      definitions,
      %{attributes: MapSet.new(), variables: MapSet.new()},
      0
    )
  end

  defp converge_bindings(_ast, _resource, _definitions, bindings, 16), do: bindings

  defp converge_bindings(ast, resource, definitions, bindings, attempt) do
    {_ast, next} =
      Macro.prewalk(ast, bindings, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) ->
          if resource_reference?(value, resource, acc),
            do: {node, put_in(acc.attributes, MapSet.put(acc.attributes, name))},
            else: {node, acc}

        {operator, _, [left, right]} = node, acc when operator in [:=, :<-] ->
          if resource_reference?(right, resource, acc),
            do: {node, bind_variables(acc, left)},
            else: {node, acc}

        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          updated =
            definitions
            |> Map.get({name, length(args)}, [])
            |> Enum.reduce(acc, fn parameters, bindings_acc ->
              Enum.zip(parameters, args)
              |> Enum.reduce(bindings_acc, fn {parameter, argument}, call_acc ->
                if resource_reference?(argument, resource, call_acc),
                  do: bind_variables(call_acc, parameter),
                  else: call_acc
              end)
            end)

          {node, updated}

        node, acc ->
          {node, acc}
      end)

    if next == bindings,
      do: bindings,
      else: converge_bindings(ast, resource, definitions, next, attempt + 1)
  end

  defp function_definitions(ast) do
    {_ast, definitions} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [signature | _]} = node, definitions when kind in [:def, :defp] ->
          case unwrap_signature(signature) do
            {name, _, args} when is_atom(name) and is_list(args) ->
              key = {name, length(args)}
              {node, Map.update(definitions, key, [args], &[args | &1])}

            _ ->
              {node, definitions}
          end

        node, definitions ->
          {node, definitions}
      end)

    definitions
  end

  defp unwrap_signature({:when, _, [signature | _guards]}), do: signature
  defp unwrap_signature(signature), do: signature

  defp bind_variables(bindings, pattern) do
    variables =
      pattern
      |> variable_names()
      |> Enum.reduce(bindings.variables, &MapSet.put(&2, &1))

    %{bindings | variables: variables}
  end

  defp variable_names({name, _, context})
       when is_atom(name) and name != :_ and (is_atom(context) or is_nil(context)),
       do: [name]

  defp variable_names(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.flat_map(&variable_names/1)

  defp variable_names(term) when is_list(term), do: Enum.flat_map(term, &variable_names/1)
  defp variable_names(_term), do: []

  defp resource_reference?(term, resource, _bindings) when term === resource, do: true

  defp resource_reference?({:@, _, [{name, _, _}]}, _resource, bindings),
    do: MapSet.member?(bindings.attributes, name)

  defp resource_reference?({name, _, context}, _resource, bindings)
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: MapSet.member?(bindings.variables, name)

  defp resource_reference?(term, resource, bindings) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&resource_reference?(&1, resource, bindings))

  defp resource_reference?(term, resource, bindings) when is_list(term),
    do: Enum.any?(term, &resource_reference?(&1, resource, bindings))

  defp resource_reference?(_term, _resource, _bindings), do: false

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
