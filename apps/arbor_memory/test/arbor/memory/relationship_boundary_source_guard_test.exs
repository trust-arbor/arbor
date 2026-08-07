defmodule Arbor.Memory.RelationshipBoundarySourceGuardTest do
  @moduledoc """
  AST source guard: production arbor_memory must not reach Repo, Ecto.Query,
  or Persistence relationship schemas (VP-05D2C3I0A).

  Detector is AST-only (no source substring scans). Clause order matters:
  Kernel.apply / :erlang.apply must match before the generic remote-call form.
  """

  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0A"

  @root Path.expand("../../../../..", __DIR__)
  @memory_lib Path.join(@root, "apps/arbor_memory/lib")

  @forbidden_modules MapSet.new([
                       Arbor.Persistence.Repo,
                       Arbor.Persistence.Schemas.Relationship,
                       Ecto.Query
                     ])

  test "production arbor_memory has no forbidden relationship boundary reach-through" do
    hits =
      @memory_lib
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.flat_map(fn path ->
        forms =
          path
          |> File.read!()
          |> Code.string_to_quoted!()
          |> detect_forbidden()

        for form <- forms, do: {Path.relative_to(path, @root), form}
      end)

    assert hits == [], "forbidden boundary forms found: #{inspect(hits)}"
  end

  test "red fixtures: direct alias and remote call through expanded alias" do
    source = """
    defmodule RedAlias do
      alias Arbor.Persistence.Repo
      def go, do: Repo.all(:q)
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:alias, Arbor.Persistence.Repo} in hits
    assert {:remote, Arbor.Persistence.Repo} in hits
  end

  test "red fixtures: grouped alias expands each member" do
    source = """
    defmodule RedGroupedAlias do
      alias Arbor.Persistence.{Repo, Schemas}
      def go, do: Repo.one(:q)
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:alias, Arbor.Persistence.Repo} in hits
    assert {:remote, Arbor.Persistence.Repo} in hits
  end

  test "red fixtures: import Ecto.Query" do
    source = """
    defmodule RedImport do
      import Ecto.Query
      def go, do: from(r in "t")
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:import, Ecto.Query} in hits
  end

  test "red fixtures: grouped import" do
    source = """
    defmodule RedGroupedImport do
      import Ecto.{Query}
      def go, do: from(r in "t")
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:import, Ecto.Query} in hits
  end

  test "red fixtures: fully-qualified remote call" do
    source = """
    defmodule RedRemote do
      def go, do: Arbor.Persistence.Schemas.Relationship.changeset(%{}, %{})
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:remote, Arbor.Persistence.Schemas.Relationship} in hits
  end

  test "red fixtures: function capture" do
    source = """
    defmodule RedCapture do
      def go, do: &Arbor.Persistence.Repo.delete_all/2
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:capture, Arbor.Persistence.Repo} in hits
  end

  test "red fixtures: bare apply/3" do
    source = """
    defmodule RedApply do
      def go, do: apply(Arbor.Persistence.Repo, :all, [[]])
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:apply, Arbor.Persistence.Repo} in hits
  end

  test "red fixtures: Kernel.apply before generic remote match" do
    source = """
    defmodule RedKernelApply do
      def go, do: Kernel.apply(Arbor.Persistence.Repo, :all, [[]])
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:kernel_apply, Arbor.Persistence.Repo} in hits
    # Must not be misclassified only as a remote call on Kernel
    refute Enum.any?(hits, &match?({:remote, Kernel}, &1))
  end

  test "red fixtures: :erlang.apply" do
    source = """
    defmodule RedErlangApply do
      def go, do: :erlang.apply(Arbor.Persistence.Repo, :all, [[]])
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:erlang_apply, Arbor.Persistence.Repo} in hits
  end

  test "red fixtures: helper-returned forbidden module via apply" do
    source = """
    defmodule RedHelperApply do
      def go, do: apply(repo(), :all, [[]])
      defp repo, do: Arbor.Persistence.Repo
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))

    assert {:apply, Arbor.Persistence.Repo} in hits or
             {:module_return, Arbor.Persistence.Repo} in hits
  end

  test "red fixtures: helper-returned forbidden module via remote call" do
    source = """
    defmodule RedHelperRemote do
      def go, do: repo().all(:q)
      defp repo, do: Arbor.Persistence.Repo
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))

    assert Enum.any?(hits, fn
             {:remote, Arbor.Persistence.Repo} -> true
             {:module_return, Arbor.Persistence.Repo} -> true
             {:module_call, Arbor.Persistence.Repo} -> true
             _ -> false
           end),
           "expected helper-returned module hit, got: #{inspect(hits)}"
  end

  test "red fixtures: variable binding to forbidden module" do
    source = """
    defmodule RedVar do
      def go do
        mod = Arbor.Persistence.Repo
        mod.all(:q)
      end
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))

    assert Enum.any?(hits, fn
             {:remote, Arbor.Persistence.Repo} -> true
             {:module_binding, Arbor.Persistence.Repo} -> true
             _ -> false
           end),
           "expected variable-bound module hit, got: #{inspect(hits)}"
  end

  test "clean public Persistence facade is admitted" do
    source = """
    defmodule Clean do
      alias Arbor.Persistence
      def go(agent), do: Persistence.put_relationship(agent, %{})
      def go2(agent), do: Arbor.Persistence.delete_all_relationships(agent)
    end
    """

    assert detect_forbidden(Code.string_to_quoted!(source)) == []
  end

  # ---------------------------------------------------------------------------
  # Detector (AST only)
  # ---------------------------------------------------------------------------

  defp detect_forbidden(ast) do
    aliases = collect_aliases(ast)
    module_returns = collect_module_returning_functions(ast, aliases)
    module_vars = collect_module_variables(ast, aliases)

    {_ast, hits} =
      Macro.prewalk(ast, MapSet.new(), fn node, hits ->
        {node, MapSet.union(hits, hits_for_node(node, aliases, module_returns, module_vars))}
      end)

    hits =
      module_returns
      |> Enum.reduce(hits, fn {_name, mod}, acc ->
        MapSet.put(acc, {:module_return, mod})
      end)

    hits |> MapSet.to_list() |> Enum.sort()
  end

  # Clause order is load-bearing: Kernel.apply / :erlang.apply / bare apply /
  # captures / aliases / imports must be matched before the generic remote form
  # `Module.fun(...)`, which would otherwise swallow `Kernel.apply(...)`.
  defp hits_for_node(node, aliases, module_returns, module_vars)

  defp hits_for_node({:alias, _, args}, _aliases, _module_returns, _module_vars) do
    alias_hits(args)
  end

  defp hits_for_node({:import, _, args}, _aliases, _module_returns, _module_vars) do
    import_hits(args)
  end

  # Kernel.apply/3 — must precede generic remote
  defp hits_for_node(
         {{:., _, [kernel, :apply]}, _, [module, _fun, _args]},
         aliases,
         module_returns,
         module_vars
       )
       when kernel == Kernel or
              (is_tuple(kernel) and elem(kernel, 0) == :__aliases__ and
                 elem(kernel, 2) == [:Kernel]) do
    case resolve_module(module, aliases, module_returns, module_vars) do
      {:ok, mod} -> MapSet.new([{:kernel_apply, mod}])
      :error -> MapSet.new()
    end
  end

  # :erlang.apply/3 — must precede generic remote
  defp hits_for_node(
         {{:., _, [:erlang, :apply]}, _, [module, _fun, _args]},
         aliases,
         module_returns,
         module_vars
       ) do
    case resolve_module(module, aliases, module_returns, module_vars) do
      {:ok, mod} -> MapSet.new([{:erlang_apply, mod}])
      :error -> MapSet.new()
    end
  end

  # bare apply/3
  defp hits_for_node(
         {:apply, _, [module, _fun, _args]},
         aliases,
         module_returns,
         module_vars
       ) do
    case resolve_module(module, aliases, module_returns, module_vars) do
      {:ok, mod} -> MapSet.new([{:apply, mod}])
      :error -> MapSet.new()
    end
  end

  # capture &Mod.fun/arity
  defp hits_for_node(
         {:&, _, [{:/, _, [{{:., _, [module, _fun]}, _, []}, _arity]}]},
         aliases,
         module_returns,
         module_vars
       ) do
    case resolve_module(module, aliases, module_returns, module_vars) do
      {:ok, mod} -> MapSet.new([{:capture, mod}])
      :error -> MapSet.new()
    end
  end

  # helper-returned module call: repo().all(...)
  defp hits_for_node(
         {{:., _, [{helper, _, helper_args}, _fun]}, _, _args},
         aliases,
         module_returns,
         module_vars
       )
       when is_atom(helper) and (is_list(helper_args) or is_nil(helper_args)) do
    arity = if is_list(helper_args), do: length(helper_args), else: 0

    cond do
      Map.has_key?(module_returns, {helper, arity}) ->
        MapSet.new([{:module_call, Map.fetch!(module_returns, {helper, arity})}])

      Map.has_key?(module_vars, helper) ->
        MapSet.new([{:remote, Map.fetch!(module_vars, helper)}])

      true ->
        MapSet.new()
    end
  end

  # generic remote Mod.fun(...) — after apply forms
  defp hits_for_node(
         {{:., _, [module, _fun]}, _, _args},
         aliases,
         module_returns,
         module_vars
       ) do
    case resolve_module(module, aliases, module_returns, module_vars) do
      {:ok, mod} -> MapSet.new([{:remote, mod}])
      :error -> MapSet.new()
    end
  end

  defp hits_for_node(_node, _aliases, _module_returns, _module_vars), do: MapSet.new()

  # ---------------------------------------------------------------------------
  # Alias / import collection
  # ---------------------------------------------------------------------------

  defp collect_aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, parts} | rest]} = node, acc ->
          as_name =
            case rest do
              [[as: {:__aliases__, _, [name]}]] -> name
              _ -> List.last(parts)
            end

          {node, Map.put(acc, as_name, Module.concat(parts))}

        {:alias, _, [{{:., _, [base, :{}]}, _, names} | _]} = node, acc ->
          base_mod = expand_alias_node(base, %{})

          acc =
            Enum.reduce(names, acc, fn
              {:__aliases__, _, tail}, a ->
                Map.put(a, List.last(tail), Module.concat([base_mod | tail]))

              {name, _, _}, a when is_atom(name) ->
                Map.put(a, name, Module.concat([base_mod, name]))

              name, a when is_atom(name) ->
                Map.put(a, name, Module.concat([base_mod, name]))

              _, a ->
                a
            end)

          {node, acc}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  defp alias_hits([{:__aliases__, _, parts} | _]) do
    mod = Module.concat(parts)
    if forbidden_module_name?(mod), do: MapSet.new([{:alias, mod}]), else: MapSet.new()
  end

  defp alias_hits([{{:., _, [base, :{}]}, _, names} | _]) do
    base_mod = expand_alias_node(base, %{})

    Enum.reduce(names, MapSet.new(), fn
      {:__aliases__, _, tail}, acc ->
        mod = Module.concat([base_mod | tail])
        if forbidden_module_name?(mod), do: MapSet.put(acc, {:alias, mod}), else: acc

      {name, _, _}, acc when is_atom(name) ->
        mod = Module.concat([base_mod, name])
        if forbidden_module_name?(mod), do: MapSet.put(acc, {:alias, mod}), else: acc

      name, acc when is_atom(name) ->
        mod = Module.concat([base_mod, name])
        if forbidden_module_name?(mod), do: MapSet.put(acc, {:alias, mod}), else: acc

      _, acc ->
        acc
    end)
  end

  defp alias_hits(_), do: MapSet.new()

  defp import_hits([{:__aliases__, _, parts} | _]) do
    mod = Module.concat(parts)
    if forbidden_module_name?(mod), do: MapSet.new([{:import, mod}]), else: MapSet.new()
  end

  defp import_hits([{{:., _, [base, :{}]}, _, names} | _]) do
    base_mod = expand_alias_node(base, %{})

    Enum.reduce(names, MapSet.new(), fn
      {:__aliases__, _, tail}, acc ->
        mod = Module.concat([base_mod | tail])
        if forbidden_module_name?(mod), do: MapSet.put(acc, {:import, mod}), else: acc

      {name, _, _}, acc when is_atom(name) ->
        mod = Module.concat([base_mod, name])
        if forbidden_module_name?(mod), do: MapSet.put(acc, {:import, mod}), else: acc

      name, acc when is_atom(name) ->
        mod = Module.concat([base_mod, name])
        if forbidden_module_name?(mod), do: MapSet.put(acc, {:import, mod}), else: acc

      _, acc ->
        acc
    end)
  end

  defp import_hits(_), do: MapSet.new()

  # ---------------------------------------------------------------------------
  # Module-returning helpers and variable bindings
  # ---------------------------------------------------------------------------

  defp collect_module_returning_functions(ast, aliases) do
    {_ast, returns} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [signature | rest]} = node, acc when kind in [:def, :defp] ->
          case unwrap_signature(signature) do
            {name, _, args} when is_atom(name) and is_list(args) ->
              body =
                case rest do
                  [opts] when is_list(opts) -> Keyword.get(opts, :do)
                  _ -> nil
                end

              case body_module(body, aliases) do
                {:ok, mod} ->
                  {node, Map.put(acc, {name, length(args)}, mod)}

                :error ->
                  {node, acc}
              end

            _ ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    returns
  end

  defp collect_module_variables(ast, aliases) do
    {_ast, vars} =
      Macro.prewalk(ast, %{}, fn
        {:=, _, [{var, _, ctx}, right]} = node, acc
        when is_atom(var) and (is_atom(ctx) or is_nil(ctx)) ->
          case resolve_module(right, aliases, %{}, acc) do
            {:ok, mod} -> {node, Map.put(acc, var, mod)}
            :error -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    vars
  end

  defp body_module({:__block__, _, exprs}, aliases) when is_list(exprs) do
    body_module(List.last(exprs), aliases)
  end

  defp body_module(expr, aliases) do
    resolve_module(expr, aliases, %{}, %{})
  end

  defp unwrap_signature({:when, _, [signature | _]}), do: signature
  defp unwrap_signature({name, meta, nil}), do: {name, meta, []}
  defp unwrap_signature(other), do: other

  # ---------------------------------------------------------------------------
  # Module resolution
  # ---------------------------------------------------------------------------

  defp resolve_module(module, aliases, module_returns, module_vars)

  defp resolve_module({:__aliases__, _, parts}, aliases, _module_returns, _module_vars) do
    mod =
      case parts do
        [head | tail] when is_atom(head) ->
          case Map.fetch(aliases, head) do
            {:ok, base} when tail == [] -> base
            {:ok, base} -> Module.concat([base | tail])
            :error -> Module.concat(parts)
          end

        _ ->
          Module.concat(parts)
      end

    if forbidden_module_name?(mod), do: {:ok, mod}, else: :error
  end

  defp resolve_module(mod, _aliases, _module_returns, _module_vars)
       when is_atom(mod) do
    if forbidden_module_name?(mod), do: {:ok, mod}, else: :error
  end

  defp resolve_module({name, _, args}, _aliases, module_returns, module_vars)
       when is_atom(name) and (is_list(args) or is_nil(args)) do
    arity = if is_list(args), do: length(args), else: 0

    cond do
      Map.has_key?(module_returns, {name, arity}) ->
        {:ok, Map.fetch!(module_returns, {name, arity})}

      Map.has_key?(module_vars, name) ->
        {:ok, Map.fetch!(module_vars, name)}

      true ->
        :error
    end
  end

  defp resolve_module(_other, _aliases, _module_returns, _module_vars), do: :error

  defp expand_alias_node({:__aliases__, _, parts}, _aliases), do: Module.concat(parts)
  defp expand_alias_node(mod, _aliases) when is_atom(mod), do: mod
  defp expand_alias_node(_, _), do: :"Elixir.Unknown"

  defp forbidden_module_name?(mod) when is_atom(mod) do
    mod in @forbidden_modules or forbidden_by_suffix?(mod)
  end

  defp forbidden_module_name?(_), do: false

  defp forbidden_by_suffix?(mod) do
    case Module.split(mod) do
      ["Arbor", "Persistence", "Repo"] -> true
      ["Arbor", "Persistence", "Schemas", "Relationship"] -> true
      ["Ecto", "Query"] -> true
      _ -> false
    end
  end
end
