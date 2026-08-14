defmodule Arbor.Commands.AppEnvInventory.Ast do
  @moduledoc """
  Pure AST walk for retired app-env call sites.

  Findings are emitted only when the app argument is attributable to a
  retired owner: a literal atom, a bounded module-attribute or local bind,
  or a dynamic expression that contains/resolves to a retired atom.
  Generic `Application.get_env(app, key)` helpers are not residue.
  """

  @legacy_owners MapSet.new([
                   :arbor_contracts,
                   :arbor_common,
                   :arbor_signals,
                   :arbor_monitor
                 ])

  @application_funs [
    :get_env,
    :fetch_env,
    :fetch_env!,
    :put_env,
    :delete_env,
    :compile_env,
    :compile_env!,
    :get_all_env
  ]

  @erlang_funs [
    :get_env,
    :fetch_env,
    :set_env,
    :unset_env,
    :get_all_env
  ]

  @function_forms [:def, :defp, :defmacro, :defmacrop]
  @unresolved_bind :__unresolved_bind__
  @max_nodes 200_000
  @max_depth 64
  @max_attr_depth 16

  @type finding :: map()

  @spec extract(String.t(), binary()) :: {:ok, [finding()]} | {:error, term()}
  def extract(path, bytes) when is_binary(path) and is_binary(bytes) do
    if byte_size(bytes) == 0 do
      {:ok, []}
    else
      case Code.string_to_quoted(bytes,
             file: path,
             columns: true,
             token_metadata: true,
             emit_warnings: false
           ) do
        {:ok, ast} ->
          case walk(ast, new_state(path), 0) do
            {:ok, state} -> {:ok, Enum.reverse(state.findings)}
            {:error, _} = err -> err
          end

        {:error, reason} ->
          {:error, {:parse_error, path, reason}}
      end
    end
  end

  def extract(_, _), do: {:error, :invalid_extract_args}

  defp new_state(path) do
    %{
      path: path,
      attrs: %{},
      attr_stack: [],
      scopes: [%{}],
      var_stack: [],
      aliases: %{},
      alias_stack: [],
      application_imported?: false,
      config_imported?: false,
      import_stack: [],
      findings: [],
      nodes: 0
    }
  end

  defp walk(_ast, %{nodes: n}, _depth) when n >= @max_nodes do
    {:error, :ast_node_limit}
  end

  defp walk(_ast, _state, depth) when depth > @max_depth do
    {:error, :ast_depth_limit}
  end

  defp walk(ast, state, depth) do
    state = %{state | nodes: state.nodes + 1}

    case ast do
      {:defmodule, _meta, [_name, body]} ->
        walk_defmodule(body, state, depth)

      {:alias, _meta, args} ->
        {:ok, record_alias(state, args)}

      {:import, _meta, args} ->
        {:ok, record_import(state, args)}

      {:use, _meta, args} ->
        {:ok, record_use(state, args)}

      {:@, _meta, [{name, _nmeta, [value]}]} when is_atom(name) ->
        walk(value, %{state | attrs: Map.put(state.attrs, name, value)}, depth + 1)

      {:=, _meta, [lhs, rhs]} ->
        with {:ok, after_rhs} <- walk(rhs, state, depth + 1) do
          walk(lhs, apply_assignment_bind(after_rhs, lhs, rhs, state), depth + 1)
        end

      {kind, _meta, args} when kind in @function_forms and is_list(args) ->
        walk_function(args, state, depth)

      {:if, _meta, args} when is_list(args) ->
        walk_conditional(args, state, depth)

      {:unless, _meta, args} when is_list(args) ->
        walk_conditional(args, state, depth)

      {:case, _meta, args} when is_list(args) ->
        walk_case(args, state, depth)

      {:cond, _meta, args} when is_list(args) ->
        walk_branch_rest(args, state, depth)

      {:fn, _meta, clauses} when is_list(clauses) ->
        walk_clause_list(clauses, state, depth)

      {:with, _meta, args} when is_list(args) ->
        walk_with(args, state, depth)

      {:for, _meta, args} when is_list(args) ->
        walk_for(args, state, depth)

      {:try, _meta, args} when is_list(args) ->
        walk_try(args, state, depth)

      {:receive, _meta, args} when is_list(args) ->
        walk_receive(args, state, depth)

      {:quote, _meta, args} when is_list(args) ->
        walk_in_scope(args, state, depth)

      {{:., meta, [receiver, fun]}, _call_meta, args} when is_atom(fun) and is_list(args) ->
        state = maybe_remote_finding(state, meta, receiver, fun, args)
        walk_list(args, state, depth)

      {fun, meta, args} when is_atom(fun) and is_list(args) ->
        state =
          if fun == :apply do
            maybe_apply_finding(state, meta, args)
          else
            maybe_local_finding(state, meta, fun, args)
          end

        walk_list(args, state, depth)

      {left, right} ->
        with {:ok, state} <- walk(left, state, depth + 1) do
          walk(right, state, depth + 1)
        end

      list when is_list(list) ->
        walk_list(list, state, depth)

      _other ->
        {:ok, state}
    end
  end

  defp walk_defmodule(body, state, depth) do
    inner = push_module(state)
    block = defmodule_body(body)

    case walk(block, inner, depth + 1) do
      {:ok, walked} -> {:ok, pop_module(walked)}
      err -> err
    end
  end

  defp defmodule_body([{:do, block} | _]), do: block
  defp defmodule_body(list) when is_list(list), do: Keyword.get(list, :do)
  defp defmodule_body(other), do: other

  defp push_module(state) do
    %{
      state
      | attr_stack: [state.attrs | state.attr_stack],
        attrs: %{},
        alias_stack: [state.aliases | state.alias_stack],
        aliases: %{},
        import_stack: [
          {state.application_imported?, state.config_imported?} | state.import_stack
        ],
        application_imported?: false,
        config_imported?: false,
        scopes: [%{} | state.scopes]
    }
  end

  defp pop_module(walked) do
    [{app_imp, cfg_imp} | import_rest] = walked.import_stack
    [aliases | alias_rest] = walked.alias_stack
    [attrs | attr_rest] = walked.attr_stack
    [_scope | scope_rest] = walked.scopes

    %{
      walked
      | attrs: attrs,
        attr_stack: attr_rest,
        aliases: aliases,
        alias_stack: alias_rest,
        application_imported?: app_imp,
        config_imported?: cfg_imp,
        import_stack: import_rest,
        scopes: scope_rest
    }
  end

  defp walk_list(list, state, depth) do
    Enum.reduce_while(list, {:ok, state}, fn item, {:ok, acc} ->
      case walk(item, acc, depth + 1) do
        {:ok, next} -> {:cont, {:ok, next}}
        err -> {:halt, err}
      end
    end)
  end

  defp walk_in_scope(ast, state, depth) do
    case walk(ast, push_scope(state), depth + 1) do
      {:ok, walked} -> {:ok, pop_scope(walked)}
      err -> err
    end
  end

  defp walk_conditional([condition | rest], state, depth) do
    with {:ok, state} <- walk(condition, state, depth + 1) do
      walk_branch_rest(rest, state, depth)
    end
  end

  defp walk_conditional(other, state, depth), do: walk_list(other, state, depth)

  defp walk_case([expr | rest], state, depth) do
    with {:ok, state} <- walk(expr, state, depth + 1) do
      walk_branch_rest(rest, state, depth)
    end
  end

  defp walk_case(other, state, depth), do: walk_list(other, state, depth)

  defp walk_branch_rest(list, state, depth) when is_list(list) do
    list = unwrap_hook_list(list)

    Enum.reduce_while(list, {:ok, state}, fn item, {:ok, acc} ->
      case item do
        {:do, block} ->
          continue_scope_block(block, acc, depth)

        {:else, block} ->
          continue_scope_block(block, acc, depth)

        {:->, _, _} = clause ->
          continue_scope_block(clause, acc, depth)

        other ->
          case walk(other, acc, depth + 1) do
            {:ok, next} -> {:cont, {:ok, next}}
            err -> {:halt, err}
          end
      end
    end)
  end

  defp walk_branch_rest(other, state, depth), do: walk(other, state, depth + 1)

  defp unwrap_hook_list([maybe_kw]) when is_list(maybe_kw) do
    if hook_keyword?(maybe_kw), do: maybe_kw, else: [maybe_kw]
  end

  defp unwrap_hook_list(list), do: list

  defp hook_keyword?([]), do: false

  defp hook_keyword?(list) do
    Enum.all?(list, fn
      {key, _} when is_atom(key) -> true
      _ -> false
    end)
  end

  defp continue_scope_block(block, state, depth) do
    case walk_scope_block(block, state, depth) do
      {:ok, next} -> {:cont, {:ok, next}}
      err -> {:halt, err}
    end
  end

  defp walk_scope_block(list, state, depth) when is_list(list) do
    if list != [] and Enum.all?(list, &match?({:->, _, _}, &1)) do
      walk_clause_list(list, state, depth)
    else
      walk_in_scope(list, state, depth)
    end
  end

  defp walk_scope_block(other, state, depth), do: walk_in_scope(other, state, depth)

  defp walk_clause_list(list, state, depth) do
    Enum.reduce_while(list, {:ok, state}, fn item, {:ok, acc} ->
      case walk_arrow(item, acc, depth) do
        {:ok, next} -> {:cont, {:ok, next}}
        err -> {:halt, err}
      end
    end)
  end

  defp walk_arrow({:->, _, [left, right]}, state, depth) do
    inner = bind_pattern(push_scope(state), left)

    with {:ok, inner} <- walk(left, inner, depth + 1),
         {:ok, walked} <- walk(right, inner, depth + 1) do
      {:ok, pop_scope(walked)}
    end
  end

  defp walk_arrow(other, state, depth), do: walk_in_scope(other, state, depth)

  defp walk_function(args, state, depth) do
    inner = bind_pattern(push_function(state), function_head(args))

    case walk_list(args, inner, depth) do
      {:ok, walked} -> {:ok, pop_function(walked)}
      err -> err
    end
  end

  defp function_head([head | _]), do: head
  defp function_head(_), do: nil

  defp walk_with(args, state, depth) do
    {gens, hooks} = split_trailing_hooks(args)
    inner = push_scope(state)

    with {:ok, inner} <- walk_generators(gens, inner, depth),
         {:ok, walked} <- walk_hook_block(hooks, :do, inner, depth) do
      walk_hook_clauses(hooks, :else, pop_scope(walked), depth)
    end
  end

  defp walk_for(args, state, depth) do
    {gens, hooks} = split_trailing_hooks(args)
    inner = push_scope(state)

    with {:ok, inner} <- walk_generators(gens, inner, depth),
         {:ok, walked} <- walk_for_hooks(hooks, inner, depth) do
      {:ok, pop_scope(walked)}
    end
  end

  defp walk_try(args, state, depth) do
    hooks = first_hook_list(args)

    Enum.reduce_while([:do, :rescue, :catch, :else, :after], {:ok, state}, fn key, {:ok, acc} ->
      case Keyword.get(hooks, key) do
        nil ->
          {:cont, {:ok, acc}}

        block when key in [:rescue, :catch] ->
          case walk_clause_list(try_clauses(block), acc, depth) do
            {:ok, next} -> {:cont, {:ok, next}}
            err -> {:halt, err}
          end

        block ->
          case walk_in_scope(block, acc, depth) do
            {:ok, next} -> {:cont, {:ok, next}}
            err -> {:halt, err}
          end
      end
    end)
  end

  defp walk_receive(args, state, depth) do
    hooks = first_hook_list(args)

    with {:ok, state} <- walk_receive_do(Keyword.get(hooks, :do), state, depth) do
      walk_receive_after(Keyword.get(hooks, :after), state, depth)
    end
  end

  defp walk_receive_do(nil, state, _depth), do: {:ok, state}

  defp walk_receive_do(clauses, state, depth) when is_list(clauses) do
    if clauses != [] and Enum.all?(clauses, &match?({:->, _, _}, &1)) do
      walk_clause_list(clauses, state, depth)
    else
      walk_in_scope(clauses, state, depth)
    end
  end

  defp walk_receive_do(other, state, depth), do: walk_in_scope(other, state, depth)

  defp walk_receive_after(nil, state, _depth), do: {:ok, state}

  defp walk_receive_after(clauses, state, depth) when is_list(clauses) do
    if clauses != [] and Enum.all?(clauses, &match?({:->, _, _}, &1)) do
      walk_clause_list(clauses, state, depth)
    else
      walk_in_scope(clauses, state, depth)
    end
  end

  defp walk_receive_after(other, state, depth), do: walk_in_scope(other, state, depth)

  defp walk_generators(gens, state, depth) do
    Enum.reduce_while(gens, {:ok, state}, fn gen, {:ok, acc} ->
      case walk_generator(gen, acc, depth) do
        {:ok, next} -> {:cont, {:ok, next}}
        err -> {:halt, err}
      end
    end)
  end

  defp walk_generator({:<-, _, [pat, expr]}, state, depth) do
    with {:ok, state} <- walk(expr, state, depth + 1) do
      {:ok, bind_pattern(state, pat)}
    end
  end

  defp walk_generator(other, state, depth), do: walk(other, state, depth + 1)

  defp walk_hook_block(hooks, key, state, depth) do
    case Keyword.get(hooks, key) do
      nil -> {:ok, state}
      block -> walk_scope_block(block, state, depth)
    end
  end

  defp walk_hook_clauses(hooks, key, state, depth) do
    case Keyword.get(hooks, key) do
      nil -> {:ok, state}
      clauses -> walk_scope_block(clauses, state, depth)
    end
  end

  defp walk_for_hooks(hooks, state, depth) do
    Enum.reduce_while(hooks, {:ok, state}, fn
      {:do, block}, {:ok, acc} ->
        case walk_scope_block(block, acc, depth) do
          {:ok, next} -> {:cont, {:ok, next}}
          err -> {:halt, err}
        end

      {_key, value}, {:ok, acc} ->
        case walk(value, acc, depth + 1) do
          {:ok, next} -> {:cont, {:ok, next}}
          err -> {:halt, err}
        end
    end)
  end

  defp split_trailing_hooks(args) when is_list(args) do
    case List.last(args) do
      hooks when is_list(hooks) ->
        if hook_keyword?(hooks) do
          {List.delete_at(args, -1), hooks}
        else
          {args, []}
        end

      _ ->
        {args, []}
    end
  end

  defp first_hook_list([hooks]) when is_list(hooks),
    do: if(hook_keyword?(hooks), do: hooks, else: [])

  defp first_hook_list(hooks) when is_list(hooks),
    do: if(hook_keyword?(hooks), do: hooks, else: [])

  defp first_hook_list(_), do: []

  defp try_clauses(list) when is_list(list) do
    if list != [] and Enum.all?(list, &match?({:->, _, _}, &1)) do
      list
    else
      [{:->, [], [[], list]}]
    end
  end

  defp try_clauses(other), do: [{:->, [], [[], other]}]

  defp push_function(state) do
    %{
      state
      | var_stack: [state.scopes | state.var_stack],
        scopes: [%{}],
        alias_stack: [state.aliases | state.alias_stack],
        import_stack: [
          {state.application_imported?, state.config_imported?} | state.import_stack
        ]
    }
  end

  defp pop_function(
         %{
           var_stack: [scopes | var_rest],
           alias_stack: [aliases | alias_rest],
           import_stack: [{app_imp, cfg_imp} | import_rest]
         } = state
       ) do
    %{
      state
      | scopes: scopes,
        var_stack: var_rest,
        aliases: aliases,
        alias_stack: alias_rest,
        application_imported?: app_imp,
        config_imported?: cfg_imp,
        import_stack: import_rest
    }
  end

  defp pop_function(state), do: state

  defp push_scope(state) do
    %{
      state
      | scopes: [%{} | state.scopes],
        alias_stack: [state.aliases | state.alias_stack],
        import_stack: [
          {state.application_imported?, state.config_imported?} | state.import_stack
        ]
    }
  end

  defp pop_scope(
         %{
           scopes: [_head | scope_rest],
           alias_stack: [aliases | alias_rest],
           import_stack: [{app_imp, cfg_imp} | import_rest]
         } = state
       ) do
    %{
      state
      | scopes: scope_rest,
        aliases: aliases,
        alias_stack: alias_rest,
        application_imported?: app_imp,
        config_imported?: cfg_imp,
        import_stack: import_rest
    }
  end

  defp pop_scope(state), do: state

  defp apply_assignment_bind(post_walk, lhs, rhs, pre_bind) do
    shadowed = bind_pattern(post_walk, lhs)

    case {simple_var(lhs), resolve_app_expr(rhs, pre_bind)} do
      {{:ok, name}, {:resolved, atom}} when is_atom(atom) ->
        put_bind(shadowed, name, atom)

      _ ->
        shadowed
    end
  end

  defp simple_var({name, _, ctx}) when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) do
    {:ok, name}
  end

  defp simple_var(_), do: :error

  defp bind_pattern(state, {:^, _, _}), do: state
  defp bind_pattern(state, {:when, _, [pat, _guard]}), do: bind_pattern(state, pat)
  defp bind_pattern(state, {:\\, _, [pat, _default]}), do: bind_pattern(state, pat)

  defp bind_pattern(state, {:=, _, [left, right]}) do
    state |> bind_pattern(left) |> bind_pattern(right)
  end

  defp bind_pattern(state, {:%{}, _, pairs}) when is_list(pairs) do
    Enum.reduce(pairs, state, fn
      {key, value}, acc -> acc |> bind_pattern(key) |> bind_pattern(value)
      other, acc -> bind_pattern(acc, other)
    end)
  end

  defp bind_pattern(state, {:%, _, [_struct, map]}), do: bind_pattern(state, map)

  defp bind_pattern(state, {:{}, _, elems}) when is_list(elems) do
    Enum.reduce(elems, state, &bind_pattern(&2, &1))
  end

  defp bind_pattern(state, {:|, _, [head, tail]}) do
    state |> bind_pattern(head) |> bind_pattern(tail)
  end

  defp bind_pattern(state, {left, right}) do
    state |> bind_pattern(left) |> bind_pattern(right)
  end

  defp bind_pattern(state, list) when is_list(list) do
    Enum.reduce(list, state, &bind_pattern(&2, &1))
  end

  defp bind_pattern(state, {name, _, ctx})
       when is_atom(name) and name != :_ and (is_atom(ctx) or is_nil(ctx)) do
    put_bind(state, name, @unresolved_bind)
  end

  defp bind_pattern(state, {name, _, args}) when is_atom(name) and is_list(args) do
    Enum.reduce(args, state, &bind_pattern(&2, &1))
  end

  defp bind_pattern(state, _), do: state

  defp put_bind(%{scopes: [scope | rest]} = state, name, value) do
    %{state | scopes: [Map.put(scope, name, value) | rest]}
  end

  defp put_bind(state, _name, _value), do: state

  defp record_alias(state, [target | rest]) do
    case alias_bindings(target, explicit_as(rest)) do
      {:ok, bindings} ->
        Enum.reduce(bindings, state, fn {as, from}, acc ->
          %{acc | aliases: Map.put(acc.aliases, as, from)}
        end)

      :error ->
        state
    end
  end

  defp record_alias(state, _), do: state

  defp explicit_as([opts | _]) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.fetch(opts, :as) do
        {:ok, as_mod} -> {:ok, as_mod}
        :error -> :none
      end
    else
      :none
    end
  end

  defp explicit_as(_), do: :none

  defp alias_bindings({:__aliases__, _, parts}, as_override) do
    with {:ok, as} <- resolve_as(as_override, parts),
         {:ok, from} <- alias_from(parts) do
      {:ok, [{as, from}]}
    end
  end

  defp alias_bindings({:__MODULE__, _, _} = mod, as_override) do
    alias_bindings({:__aliases__, [], [mod]}, as_override)
  end

  defp alias_bindings({{:., _, [base, :{}]}, _, items}, :none) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case alias_bindings(qualify_alias(base, item), :none) do
        {:ok, bindings} -> {:cont, {:ok, acc ++ bindings}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp alias_bindings({{:., _, [base, name]}, _, _}, as_override) when is_atom(name) do
    alias_bindings(qualify_alias(base, name), as_override)
  end

  defp alias_bindings(_, _), do: :error

  defp qualify_alias(base, {:__aliases__, _, parts}) do
    {:__aliases__, [], alias_base_parts(base) ++ parts}
  end

  defp qualify_alias(base, name) when is_atom(name) do
    {:__aliases__, [], alias_base_parts(base) ++ [name]}
  end

  defp qualify_alias(base, other) do
    {:__aliases__, [], alias_base_parts(base) ++ [other]}
  end

  defp alias_base_parts({:__aliases__, _, parts}) when is_list(parts), do: parts
  defp alias_base_parts({:__MODULE__, _, _} = mod), do: [mod]
  defp alias_base_parts(other), do: [other]

  defp alias_from(parts) when is_list(parts) and parts != [] do
    if Enum.all?(parts, &is_atom/1) do
      {:ok, Module.concat(parts)}
    else
      {:ok, {:unresolved_alias, parts}}
    end
  end

  defp alias_from(_), do: :error

  defp resolve_as({:ok, as_mod}, _parts), do: alias_as_module(as_mod)

  defp resolve_as(:none, parts) do
    case List.last(parts) do
      name when is_atom(name) -> {:ok, Module.concat([name])}
      _ -> :error
    end
  end

  defp alias_as_module({:__aliases__, _, parts}) when is_list(parts) and parts != [] do
    if Enum.all?(parts, &is_atom/1) do
      {:ok, Module.concat(parts)}
    else
      case List.last(parts) do
        name when is_atom(name) -> {:ok, Module.concat([name])}
        _ -> :error
      end
    end
  end

  defp alias_as_module(name) when is_atom(name), do: {:ok, name}
  defp alias_as_module(_), do: :error

  defp concat_alias_parts(parts) when is_list(parts) and parts != [] do
    if Enum.all?(parts, &is_atom/1) do
      {:ok, Module.concat(parts)}
    else
      :error
    end
  end

  defp concat_alias_parts(_), do: :error

  defp record_import(state, [mod | _rest]) do
    case expand_alias(mod, state) do
      Application -> %{state | application_imported?: true}
      Config -> %{state | config_imported?: true}
      Mix.Config -> %{state | config_imported?: true}
      _ -> state
    end
  end

  defp record_import(state, _), do: state

  defp record_use(state, [mod | _]) do
    case expand_alias(mod, state) do
      Mix.Config -> %{state | config_imported?: true}
      _ -> state
    end
  end

  defp record_use(state, _), do: state

  defp maybe_remote_finding(state, meta, receiver, fun, args) do
    case {expand_alias(receiver, state), fun} do
      {Arbor.Kernel.ConfigCompat, _} ->
        state

      {Application, fun} when fun in @application_funs ->
        maybe_app_finding(state, meta, form_name(fun), args)

      {:application, fun} when fun in @erlang_funs ->
        maybe_app_finding(state, meta, erlang_form_name(fun), args)

      {Config, :config} ->
        maybe_app_finding(state, meta, "config", args)

      {Mix.Config, :config} ->
        maybe_app_finding(state, meta, "config", args)

      _ ->
        maybe_dynamic_receiver(state, meta, fun, args)
    end
  end

  defp maybe_local_finding(state, meta, fun, args) do
    cond do
      state.application_imported? and fun in @application_funs ->
        maybe_app_finding(state, meta, form_name(fun), args)

      state.config_imported? and fun == :config ->
        maybe_app_finding(state, meta, "config", args)

      true ->
        state
    end
  end

  defp maybe_dynamic_receiver(state, meta, :apply, args) do
    maybe_apply_finding(state, meta, args)
  end

  defp maybe_dynamic_receiver(state, _meta, _fun, _args), do: state

  defp maybe_apply_finding(state, meta, [mod, fun, argv]) do
    target = expand_alias(mod, state)
    fun_atom = if is_atom(fun), do: fun

    cond do
      target == Arbor.Kernel.ConfigCompat ->
        state

      target in [Application, :application, Config, Mix.Config] and is_atom(fun_atom) ->
        form =
          if target == :application, do: erlang_form_name(fun_atom), else: form_name(fun_atom)

        maybe_app_finding(state, meta, form, apply_argv(argv))

      true ->
        state
    end
  end

  defp maybe_apply_finding(state, _meta, _), do: state

  defp apply_argv(argv) when is_list(argv), do: argv
  defp apply_argv(other), do: [other]

  defp maybe_app_finding(state, meta, form, args) do
    case args do
      [app_expr | _rest] ->
        case attribute_app(app_expr, state) do
          :skip ->
            state

          {trust, owner} ->
            add_finding(state, meta, form, trust, owner, length(args))
        end

      _ ->
        state
    end
  end

  defp attribute_app(expr, state) do
    case resolve_app_expr(expr, state) do
      {:resolved, owner} ->
        if MapSet.member?(@legacy_owners, owner) do
          {trust_for(expr), owner}
        else
          :skip
        end

      {:unresolved, []} ->
        :skip

      {:unresolved, [owner]} ->
        {"untrusted", owner}

      {:unresolved, _many} ->
        {"untrusted", nil}
    end
  end

  defp trust_for(atom) when is_atom(atom), do: "literal"
  defp trust_for(_), do: "resolved"

  defp resolve_app_expr(expr, state), do: resolve_app_expr(expr, state, 0, MapSet.new())

  defp resolve_app_expr(expr, _state, depth, _visited) when depth > @max_attr_depth do
    {:unresolved, collect_retired(expr)}
  end

  defp resolve_app_expr(atom, _state, _depth, _visited) when is_atom(atom), do: {:resolved, atom}

  defp resolve_app_expr({:__block__, _, [inner]}, state, depth, visited) do
    resolve_app_expr(inner, state, depth + 1, visited)
  end

  defp resolve_app_expr({:@, _, [{name, _, _}]}, state, depth, visited) when is_atom(name) do
    cond do
      MapSet.member?(visited, name) ->
        {:unresolved, []}

      true ->
        case Map.fetch(state.attrs, name) do
          {:ok, value} ->
            resolve_app_expr(value, state, depth + 1, MapSet.put(visited, name))

          :error ->
            {:unresolved, []}
        end
    end
  end

  defp resolve_app_expr({:unquote, _, [inner]}, state, depth, visited) do
    resolve_app_expr(inner, state, depth + 1, visited)
  end

  defp resolve_app_expr({name, _, ctx}, state, _depth, _visited)
       when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) do
    case fetch_bind(state.scopes, name) do
      {:ok, atom} when is_atom(atom) -> {:resolved, atom}
      _ -> {:unresolved, []}
    end
  end

  defp resolve_app_expr(other, _state, _depth, _visited) do
    {:unresolved, collect_retired(other)}
  end

  defp fetch_bind([], _name), do: :error

  defp fetch_bind([scope | rest], name) do
    case Map.fetch(scope, name) do
      {:ok, @unresolved_bind} -> :error
      {:ok, _} = ok -> ok
      :error -> fetch_bind(rest, name)
    end
  end

  defp collect_retired(ast) do
    {acc, _nodes} = collect_retired(ast, [], 0, 0)
    acc |> Enum.reverse() |> Enum.uniq()
  end

  defp collect_retired(_ast, acc, nodes, _depth) when nodes >= @max_nodes, do: {acc, nodes}
  defp collect_retired(_ast, acc, nodes, depth) when depth > @max_depth, do: {acc, nodes}

  defp collect_retired(atom, acc, nodes, _depth) when is_atom(atom) do
    acc = if MapSet.member?(@legacy_owners, atom), do: [atom | acc], else: acc
    {acc, nodes + 1}
  end

  defp collect_retired({left, right}, acc, nodes, depth) do
    {acc, nodes} = collect_retired(left, acc, nodes + 1, depth + 1)
    collect_retired(right, acc, nodes, depth + 1)
  end

  defp collect_retired(list, acc, nodes, depth) when is_list(list) do
    Enum.reduce(list, {acc, nodes + 1}, fn item, {acc, nodes} ->
      collect_retired(item, acc, nodes, depth + 1)
    end)
  end

  defp collect_retired({_form, _meta, args}, acc, nodes, depth)
       when is_list(args) or is_atom(args) do
    collect_retired(args, acc, nodes + 1, depth + 1)
  end

  defp collect_retired(_other, acc, nodes, _depth), do: {acc, nodes + 1}

  defp add_finding(state, meta, form, trust, owner, arity) do
    finding = %{
      "path" => state.path,
      "line" => Keyword.get(meta, :line, 0),
      "column" => Keyword.get(meta, :column, 0),
      "class" => classify(state.path, form),
      "trust" => trust,
      "form" => form,
      "legacy_app" => if(owner, do: Atom.to_string(owner), else: nil),
      "arity" => arity
    }

    %{state | findings: [finding | state.findings]}
  end

  defp classify(_path, "config"), do: "config_block"

  defp classify(path, _form) do
    parts = Path.split(path)

    cond do
      match?(["config" | _], parts) -> "config_block"
      match?(["apps", _app, "config" | _], parts) -> "config_block"
      "test" in parts or List.last(parts) == "test_helper.exs" -> "test_support"
      true -> "production"
    end
  end

  defp expand_alias({:__aliases__, _, parts}, state) do
    case concat_alias_parts(parts) do
      {:ok, mod} -> Map.get(state.aliases, mod, mod)
      :error -> nil
    end
  end

  defp expand_alias(atom, _state) when is_atom(atom), do: atom
  defp expand_alias(_, _), do: nil

  defp form_name(:set_env), do: "put_env"
  defp form_name(:unset_env), do: "delete_env"
  defp form_name(fun) when is_atom(fun), do: Atom.to_string(fun)

  defp erlang_form_name(:set_env), do: "put_env"
  defp erlang_form_name(:unset_env), do: "delete_env"
  defp erlang_form_name(fun), do: form_name(fun)
end
