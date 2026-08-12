defmodule Arbor.Commands.SourceCoupling.AstExtract do
  @moduledoc """
  Pure AST extraction for source-coupling census.

  Walks `Code.string_to_quoted` forms with lexical alias scopes. Only `alias`
  creates bindings; import/require emit references. Tracks static module and
  non-module attributes (including map field values) used later as module
  expressions, and resolves nested `__MODULE__` paths.
  """

  alias Arbor.Commands.SourceCoupling.Encode

  @max_nodes 200_000
  @max_depth 64
  @max_module_bytes 512
  @max_evidence_bytes 240
  @max_expr_bytes 2_000

  @typespec_attrs MapSet.new([
                    :spec,
                    :type,
                    :typep,
                    :opaque,
                    :callback,
                    :macrocallback
                  ])

  @type extract_result :: %{
          module_defs: [map()],
          references: [map()],
          unresolved: [map()],
          errors: [map()]
        }

  @doc "Extract module defs, references, and unresolved sites from source bytes."
  @spec extract(String.t(), binary(), keyword()) :: {:ok, extract_result()} | {:error, term()}
  def extract(path, bytes, opts \\ [])

  def extract(path, bytes, opts)
      when is_binary(path) and is_binary(bytes) and is_list(opts) do
    max_nodes = Keyword.get(opts, :max_nodes, @max_nodes)
    max_depth = Keyword.get(opts, :max_depth, @max_depth)

    if byte_size(bytes) == 0 do
      {:ok, empty_result()}
    else
      case Code.string_to_quoted(bytes,
             file: path,
             columns: true,
             token_metadata: true,
             emit_warnings: false
           ) do
        {:ok, ast} ->
          state = %{
            path: path,
            module_stack: [],
            scopes: [%{}],
            # Module-attribute environment stack: push empty map on nested
            # defmodule/defprotocol entry; pop on exit so outer attrs survive.
            attrs: %{},
            attr_stack: [],
            typespec?: false,
            nodes: 0,
            max_nodes: max_nodes,
            max_depth: max_depth,
            module_defs: [],
            references: [],
            unresolved: [],
            errors: []
          }

          case walk(ast, state, 0) do
            {:ok, final} ->
              {:ok,
               %{
                 module_defs: Enum.reverse(final.module_defs),
                 references: Enum.reverse(final.references),
                 unresolved: Enum.reverse(final.unresolved),
                 errors: Enum.reverse(final.errors)
               }}

            {:error, _} = err ->
              err
          end

        {:error, reason} ->
          {:error, {:parse_error, path, reason}}
      end
    end
  end

  def extract(_, _, _), do: {:error, :invalid_extract_args}

  defp empty_result do
    %{module_defs: [], references: [], unresolved: [], errors: []}
  end

  defp walk(_ast, %{nodes: n, max_nodes: max}, _depth) when n >= max do
    {:error, :ast_node_limit}
  end

  defp walk(_ast, %{max_depth: max_depth}, depth)
       when is_integer(max_depth) and depth > max_depth do
    {:error, :ast_depth_limit}
  end

  defp walk(ast, state, depth) do
    state = %{state | nodes: state.nodes + 1}

    case ast do
      {:defmodule, meta, [name_ast, [do: body]]} ->
        handle_defmodule(meta, name_ast, body, state, depth)

      {:defmodule, meta, [name_ast, block]} when is_list(block) ->
        body = Keyword.get(block, :do)
        handle_defmodule(meta, name_ast, body, state, depth)

      # Remote call: Alias.fun(...) or Module.concat(...)
      {{:., meta, [mod, fun]}, _call_meta, call_args} ->
        state = ref_module_expr(meta, mod, state, "remote")

        state =
          if fun == :concat do
            case mod do
              {:__aliases__, _, parts} ->
                if parts_to_string(parts) == "Module" do
                  resolve_module_concat(
                    line_of(meta),
                    List.wrap(call_args),
                    state,
                    "module_concat"
                  )
                else
                  state
                end

              _ ->
                state
            end
          else
            state
          end

        walk_list(List.wrap(call_args), state, depth)

      # Struct: %Alias{}
      {:%, meta, [mod, map_ast]} ->
        state = ref_module_expr(meta, mod, state, "struct")
        walk(map_ast, state, depth + 1)

      {:%{}, _meta, args} when is_list(args) ->
        walk_list(args, state, depth)

      {form, meta, args} when is_atom(form) and is_list(args) ->
        handle_form(form, meta, args, state, depth)

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

  defp walk_list(list, state, depth) do
    Enum.reduce_while(list, {:ok, state}, fn item, {:ok, st} ->
      case walk(item, st, depth + 1) do
        {:ok, st2} -> {:cont, {:ok, st2}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp handle_defmodule(meta, name_ast, body, state, depth) do
    enter_named_module(meta, name_ast, body, state, depth, "defmodule")
  end

  defp handle_defprotocol(meta, name_ast, body, state, depth) do
    enter_named_module(meta, name_ast, body, state, depth, "defprotocol")
  end

  # Shared ownership entry for defmodule / defprotocol.
  # Nested `defmodule Inner` under Outer owns Outer.Inner (Elixir nesting rules).
  # Attribute maps are pushed/popped so outer @attr bindings survive nested modules.
  defp enter_named_module(meta, name_ast, body, state, depth, kind) do
    case resolve_defined_module_name(name_ast, state) do
      {:ok, module} ->
        line = line_of(meta)

        state = %{
          state
          | module_stack: [module | state.module_stack],
            module_defs: [
              %{
                module: module,
                file: state.path,
                line: line,
                kind: kind
              }
              | state.module_defs
            ],
            attr_stack: [state.attrs | state.attr_stack],
            attrs: %{}
        }

        state = push_scope(state)

        result =
          case body do
            nil -> {:ok, state}
            b -> walk(b, state, depth + 1)
          end

        case result do
          {:ok, st} ->
            st = pop_scope(st)
            [prev_attrs | rest_attrs] = st.attr_stack

            {:ok,
             %{
               st
               | module_stack: tl(st.module_stack),
                 attrs: prev_attrs,
                 attr_stack: rest_attrs
             }}

          err ->
            err
        end

      {:unresolved, expr} ->
        state = add_unresolved(state, line_of(meta), "dynamic_#{kind}", kind, expr)
        walk(body, state, depth + 1)

      :error ->
        walk(body, state, depth + 1)
    end
  end

  # Module definition names nest under the enclosing module (Elixir semantics).
  # Does not use alias expansion for the defined name — raw segments only.
  defp resolve_defined_module_name({:__aliases__, _, parts}, state) when is_list(parts) do
    case relative_module_segments(parts) do
      {:ok, relative} ->
        case current_module(state) do
          nil ->
            if byte_size(relative) <= @max_module_bytes, do: {:ok, relative}, else: :error

          parent ->
            full = parent <> "." <> relative
            if byte_size(full) <= @max_module_bytes, do: {:ok, full}, else: :error
        end

      :error ->
        :error
    end
  end

  defp resolve_defined_module_name({:__MODULE__, _, _}, state) do
    case current_module(state) do
      nil -> :error
      mod -> {:ok, mod}
    end
  end

  # __MODULE__.Child
  defp resolve_defined_module_name({{:., _, [{:__MODULE__, _, _}, child]}, _, _}, state)
       when is_atom(child) do
    case current_module(state) do
      nil ->
        :error

      parent ->
        full = parent <> "." <> Atom.to_string(child)
        if byte_size(full) <= @max_module_bytes, do: {:ok, full}, else: :error
    end
  end

  defp resolve_defined_module_name(other, state) do
    # Fall back to expression resolution then nest if parent present and result is relative.
    case resolve_module_name(other, state) do
      {:ok, mod} ->
        case current_module(state) do
          nil ->
            {:ok, mod}

          parent ->
            if String.starts_with?(mod, parent <> ".") or mod == parent do
              {:ok, mod}
            else
              full = parent <> "." <> mod
              if byte_size(full) <= @max_module_bytes, do: {:ok, full}, else: :error
            end
        end

      other_result ->
        other_result
    end
  end

  defp relative_module_segments(parts) do
    # defmodule names may quote nested __MODULE__.Child as aliases parts.
    # Caller prepends current_module, so __MODULE__ head contributes only the
    # trailing segments (Outer + Child => Outer.Child), never a double Outer.
    case parts do
      [{:__MODULE__, _, _} | rest] ->
        case alias_rest_segments(rest) do
          {:ok, [_ | _] = segs} -> {:ok, Enum.join(segs, ".")}
          {:ok, []} -> :error
          :error -> :error
        end

      _ ->
        segs =
          Enum.map(parts, fn
            a when is_atom(a) -> Atom.to_string(a)
            s when is_binary(s) -> s
            _ -> nil
          end)

        if Enum.any?(segs, &is_nil/1) do
          :error
        else
          {:ok, Enum.join(segs, ".")}
        end
    end
  end

  defp handle_form(:alias, meta, args, state, depth) do
    state = process_alias(meta, args, state, bind?: true, kind: "alias")
    walk_args_rest(args, state, depth)
  end

  defp handle_form(:import, meta, args, state, depth) do
    state = process_alias(meta, args, state, bind?: false, kind: "import")
    walk_args_rest(args, state, depth)
  end

  defp handle_form(:require, meta, args, state, depth) do
    state = process_alias(meta, args, state, bind?: false, kind: "require")
    walk_args_rest(args, state, depth)
  end

  defp handle_form(:use, meta, args, state, depth) do
    state = ref_first_module_arg(meta, args, state, "use")
    walk_args_rest(args, state, depth)
  end

  defp handle_form(:defprotocol, meta, args, state, depth) do
    case args do
      [name_ast, [do: body]] ->
        handle_defprotocol(meta, name_ast, body, state, depth)

      [name_ast, block] when is_list(block) ->
        handle_defprotocol(meta, name_ast, Keyword.get(block, :do), state, depth)

      _ ->
        walk_list(args, state, depth)
    end
  end

  defp handle_form(:defimpl, meta, args, state, depth) do
    state = process_defimpl(meta, args, state)
    state = push_scope(state)

    result =
      case args do
        [_, [do: body]] -> walk(body, state, depth + 1)
        [_, _, [do: body]] -> walk(body, state, depth + 1)
        [_, opts] when is_list(opts) -> walk(Keyword.get(opts, :do), state, depth + 1)
        _ -> walk_list(args, state, depth)
      end

    case result do
      {:ok, st} -> {:ok, pop_scope(st)}
      err -> err
    end
  end

  defp handle_form(form, meta, args, state, depth)
       when form in [:def, :defp, :defmacro, :defmacrop] do
    state = maybe_default_refs(meta, args, state)
    scoped_walk(form, meta, args, state, depth)
  end

  defp handle_form(form, meta, args, state, depth) when form in [:fn, :quote] do
    scoped_walk(form, meta, args, state, depth)
  end

  defp handle_form(form, meta, args, state, depth)
       when form in [:if, :unless, :case, :cond, :with, :for, :try, :receive] do
    scoped_walk(form, meta, args, state, depth)
  end

  defp handle_form(:@, meta, args, state, depth) do
    case process_attribute(meta, args, state, depth) do
      {:done, state} ->
        # Attribute handler already walked typespec/module value.
        {:ok, state}

      {:error, _} = err ->
        # Fail closed on AST depth/node limit exhaustion during typespec walk.
        err

      state when is_map(state) ->
        walk_list(args, state, depth)
    end
  end

  defp handle_form(_form, meta, args, state, depth) do
    _ = meta
    walk_list(args, state, depth)
  end

  defp scoped_walk(_form, _meta, args, state, depth) do
    state = push_scope(state)

    result =
      case args do
        list when is_list(list) ->
          # Walk each do-block branch in its own scope for multi-clause forms
          walk_scoped_args(list, state, depth)

        other ->
          walk(other, state, depth + 1)
      end

    case result do
      {:ok, st} -> {:ok, pop_scope(st)}
      err -> err
    end
  end

  defp walk_scoped_args(args, state, depth) do
    Enum.reduce_while(args, {:ok, state}, fn
      {:do, body}, {:ok, st} ->
        st = push_scope(st)

        case walk(body, st, depth + 1) do
          {:ok, st2} -> {:cont, {:ok, pop_scope(st2)}}
          err -> {:halt, err}
        end

      {:else, body}, {:ok, st} ->
        st = push_scope(st)

        case walk(body, st, depth + 1) do
          {:ok, st2} -> {:cont, {:ok, pop_scope(st2)}}
          err -> {:halt, err}
        end

      {:catch, body}, {:ok, st} ->
        st = push_scope(st)

        case walk(body, st, depth + 1) do
          {:ok, st2} -> {:cont, {:ok, pop_scope(st2)}}
          err -> {:halt, err}
        end

      {:rescue, body}, {:ok, st} ->
        st = push_scope(st)

        case walk(body, st, depth + 1) do
          {:ok, st2} -> {:cont, {:ok, pop_scope(st2)}}
          err -> {:halt, err}
        end

      {:after, body}, {:ok, st} ->
        st = push_scope(st)

        case walk(body, st, depth + 1) do
          {:ok, st2} -> {:cont, {:ok, pop_scope(st2)}}
          err -> {:halt, err}
        end

      # case/cond clauses: [ {:->, _, [left, right]} ]
      {:->, _meta, [left, right]}, {:ok, st} ->
        st = push_scope(st)

        with {:ok, st} <- walk(left, st, depth + 1),
             {:ok, st} <- walk(right, st, depth + 1) do
          {:cont, {:ok, pop_scope(st)}}
        else
          err -> {:halt, err}
        end

      other, {:ok, st} ->
        case walk(other, st, depth + 1) do
          {:ok, st2} -> {:cont, {:ok, st2}}
          err -> {:halt, err}
        end
    end)
  end

  defp walk_args_rest(args, state, depth) do
    # First arg is the alias target already processed; still walk opts for nested ASTs
    walk_list(List.wrap(args), state, depth)
  end

  defp process_alias(meta, args, state, bind?: bind?, kind: kind) do
    line = line_of(meta)

    case args do
      [{:__aliases__, _, parts} | rest] when is_list(parts) ->
        case parts_to_module(parts, state) do
          {:ok, module} ->
            state = add_ref(state, line, module, kind)
            if bind?, do: bind_alias(state, module, rest), else: state

          {:unresolved, expr} ->
            add_unresolved(state, line, "dynamic_alias_target", kind, expr)

          :error ->
            state
        end

      [{{:., _, [base, :{}]}, _, group_args} | _rest] ->
        process_grouped_alias(line, base, group_args, state, bind?: bind?, kind: kind)

      [{:__MODULE__, _, _} | rest] ->
        case current_module(state) do
          nil ->
            state

          mod ->
            state = add_ref(state, line, mod, kind)
            if bind?, do: bind_alias(state, mod, rest), else: state
        end

      # Nested forms such as `alias __MODULE__.Child` and other static paths.
      [other | rest] ->
        case resolve_module_name(other, state) do
          {:ok, module} ->
            state = add_ref(state, line, module, kind)
            if bind?, do: bind_alias(state, module, rest), else: state

          {:unresolved, expr} ->
            add_unresolved(state, line, "dynamic_alias_target", kind, expr)

          :error ->
            state
        end
    end
  end

  defp process_grouped_alias(line, base, group_args, state, bind?: bind?, kind: kind) do
    case resolve_module_name(base, state) do
      {:ok, base_mod} ->
        Enum.reduce(group_args, state, fn
          {:__aliases__, _, parts}, st when is_list(parts) ->
            case join_parts(base_mod, parts) do
              {:ok, mod} ->
                st = add_ref(st, line, mod, kind)
                if bind?, do: bind_short(st, List.last(parts), mod), else: st

              _ ->
                st
            end

          atom, st when is_atom(atom) ->
            case join_parts(base_mod, [atom]) do
              {:ok, mod} ->
                st = add_ref(st, line, mod, kind)
                if bind?, do: bind_short(st, atom, mod), else: st

              _ ->
                st
            end

          _, st ->
            st
        end)

      {:unresolved, expr} ->
        add_unresolved(state, line, "dynamic_grouped_alias", kind, expr)

      :error ->
        state
    end
  end

  defp bind_alias(state, module, rest) do
    as_name =
      case rest do
        [[as: {:__aliases__, _, parts}]] when is_list(parts) -> List.last(parts)
        [[as: atom]] when is_atom(atom) -> atom
        _ -> module |> String.split(".") |> List.last()
      end

    bind_short(state, as_name, module)
  end

  defp bind_short(state, short, module) when is_atom(short) do
    short_s = Atom.to_string(short)
    [current | outer] = state.scopes
    %{state | scopes: [Map.put(current, short_s, module) | outer]}
  end

  defp bind_short(state, short, module) when is_binary(short) do
    [current | outer] = state.scopes
    %{state | scopes: [Map.put(current, short, module) | outer]}
  end

  defp bind_short(state, _, _), do: state

  defp process_defimpl(meta, args, state) do
    line = line_of(meta)

    state =
      case args do
        [proto | _] -> ref_module_expr(meta, proto, state, "defimpl")
        _ -> state
      end

    for_targets =
      case args do
        [_, opts] when is_list(opts) -> Keyword.get_values(opts, :for)
        [_, _, opts] when is_list(opts) -> Keyword.get_values(opts, :for)
        _ -> []
      end

    Enum.reduce(List.flatten(for_targets), state, fn target, st ->
      ref_module_expr(meta, target, st, "defimpl")
    end)
    |> then(fn st ->
      _ = line
      st
    end)
  end

  defp process_attribute(meta, args, state, depth) do
    line = line_of(meta)

    case args do
      [{attr, _, nil}] when is_atom(attr) ->
        state

      [{attr, _, value_args}] when is_atom(attr) and is_list(value_args) ->
        value = List.first(value_args)

        cond do
          MapSet.member?(@typespec_attrs, attr) ->
            prev = state.typespec?
            state = %{state | typespec?: true}

            # Propagate depth/node limit errors — never swallow fail-closed limits.
            case walk(value, state, depth + 1) do
              {:ok, st} -> {:done, %{st | typespec?: prev}}
              {:error, _} = err -> err
            end

          attr in [:behaviour, :behavior] ->
            {:done, ref_module_expr(meta, value, state, "behaviour")}

          true ->
            case classify_attr_value(value, state) do
              {:module, mod} ->
                state = add_ref(state, line, mod, "attribute")
                %{state | attrs: Map.put(state.attrs, attr, {:module, mod})}

              {:map, fields} ->
                state =
                  Enum.reduce(fields, state, fn
                    {_key, {:module, mod}}, st -> add_ref(st, line, mod, "attribute")
                    _, st -> st
                  end)

                %{state | attrs: Map.put(state.attrs, attr, {:map, fields})}

              :non_module ->
                %{state | attrs: Map.put(state.attrs, attr, :non_module)}

              :unknown ->
                state
            end
        end

      _ ->
        state
    end
  end

  # Classify static attribute values for later module-vs-non-module resolution.
  # Tags are internal only and never appear in the census report.
  # Literals (including ordinary atoms like :oauth) and maps are classified
  # before module resolution so they never become fake module targets.
  defp classify_attr_value(v, _state)
       when is_binary(v) or is_integer(v) or is_float(v) or is_boolean(v) or is_nil(v) do
    :non_module
  end

  # Bare atoms in attr maps/lists are literals, not module aliases.
  # True module references quote as {:__aliases__, _, _} even for one segment.
  defp classify_attr_value(v, _state) when is_atom(v), do: :non_module

  defp classify_attr_value({:%{}, _, pairs}, state) when is_list(pairs) do
    classify_map_fields(pairs, state, %{})
  end

  defp classify_attr_value(pairs, state) when is_list(pairs) do
    if keyword_attr_pairs?(pairs) do
      classify_map_fields(pairs, state, %{})
    else
      classify_list_attr_value(pairs, state)
    end
  end

  defp classify_attr_value(value, state) do
    case resolve_module_name(value, state) do
      {:ok, mod} -> {:module, mod}
      {:unresolved, _} -> :unknown
      :error -> :unknown
    end
  end

  defp keyword_attr_pairs?(pairs) do
    pairs != [] and
      Enum.all?(pairs, fn
        {k, _v} when is_atom(k) -> true
        _ -> false
      end)
  end

  defp classify_map_fields(pairs, state, acc) do
    Enum.reduce_while(pairs, {:map, acc}, fn
      {key, val}, {:map, fields} when is_atom(key) ->
        case classify_attr_value(val, state) do
          :unknown ->
            {:halt, :unknown}

          classified ->
            {:cont, {:map, Map.put(fields, key, classified)}}
        end

      _other, _acc ->
        {:halt, :unknown}
    end)
  end

  defp classify_list_attr_value(list, state) do
    Enum.reduce_while(list, :non_module, fn item, :non_module ->
      case classify_attr_value(item, state) do
        :non_module -> {:cont, :non_module}
        {:map, _} -> {:cont, :non_module}
        {:module, _} -> {:halt, :unknown}
        :unknown -> {:halt, :unknown}
      end
    end)
  end

  defp maybe_default_refs(meta, args, state) do
    # def f(x \\ Alias) 
    case args do
      [{_name, _, params} | _] when is_list(params) ->
        Enum.reduce(params, state, fn
          {:\\, _, [_pat, default]}, st ->
            case resolve_module_name(default, st) do
              {:ok, mod} -> add_ref(st, line_of(meta), mod, "default")
              _ -> st
            end

          _, st ->
            st
        end)

      _ ->
        state
    end
  end

  defp ref_first_module_arg(meta, args, state, kind) do
    case args do
      [mod | _] -> ref_module_expr(meta, mod, state, kind)
      _ -> state
    end
  end

  defp ref_module_expr(meta, expr, state, kind) do
    line = line_of(meta)

    case resolve_module_name(expr, state) do
      {:ok, mod} ->
        add_ref(state, line, mod, kind)

      {:unresolved, norm} ->
        add_unresolved(state, line, "dynamic_module_expr", kind, norm)

      :error ->
        # Module.concat special-case
        case expr do
          {{:., _, [{:__aliases__, _, [:Module]}, :concat]}, _, concat_args} ->
            resolve_module_concat(line, concat_args, state, kind)

          {{:., _, [{:__aliases__, _, parts}, :concat]}, _, concat_args} ->
            if parts_to_string(parts) == "Module" do
              resolve_module_concat(line, concat_args, state, kind)
            else
              state
            end

          _ ->
            state
        end
    end
  end

  defp resolve_module_concat(line, args, state, kind) do
    case args do
      [list] when is_list(list) ->
        case static_concat_list(list, state) do
          {:ok, mod} -> add_ref(state, line, mod, "module_concat")
          {:unresolved, expr} -> add_unresolved(state, line, "dynamic_module_concat", kind, expr)
        end

      [a, b] ->
        case {resolve_module_name(a, state), resolve_module_name(b, state)} do
          {{:ok, ma}, {:ok, mb}} ->
            case join_module_strings(ma, mb) do
              {:ok, mod} ->
                add_ref(state, line, mod, "module_concat")

              _ ->
                add_unresolved(state, line, "dynamic_module_concat", kind, normalize_expr({a, b}))
            end

          _ ->
            add_unresolved(
              state,
              line,
              "dynamic_module_concat",
              kind,
              normalize_expr({:concat, a, b})
            )
        end

      other ->
        add_unresolved(state, line, "dynamic_module_concat", kind, normalize_expr(other))
    end
  end

  defp static_concat_list(list, state) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case item do
        s when is_binary(s) ->
          {:cont, {:ok, [s | acc]}}

        a when is_atom(a) ->
          {:cont, {:ok, [Atom.to_string(a) | acc]}}

        {:__aliases__, _, parts} when is_list(parts) ->
          case parts_to_module(parts, state) do
            {:ok, mod} -> {:cont, {:ok, [mod | acc]}}
            _ -> {:halt, {:unresolved, normalize_expr(list)}}
          end

        other ->
          case resolve_module_name(other, state) do
            {:ok, mod} -> {:cont, {:ok, [mod | acc]}}
            _ -> {:halt, {:unresolved, normalize_expr(list)}}
          end
      end
    end)
    |> case do
      {:ok, parts} ->
        # Module.concat([Arbor, Contracts, M]) joins segments; when items are already
        # full aliases, join with "." only between distinct pieces.
        mod = parts |> Enum.reverse() |> Enum.join(".")

        if byte_size(mod) <= @max_module_bytes, do: {:ok, mod}, else: {:unresolved, mod}

      other ->
        other
    end
  end

  defp resolve_module_name({:__aliases__, _, parts}, state) when is_list(parts) do
    parts_to_module(parts, state)
  end

  defp resolve_module_name({:__MODULE__, _, _}, state) do
    case current_module(state) do
      nil -> :error
      mod -> {:ok, mod}
    end
  end

  defp resolve_module_name({:@, _, [{attr, _, _}]}, state) when is_atom(attr) do
    case Map.fetch(state.attrs, attr) do
      {:ok, {:module, mod}} -> {:ok, mod}
      # Static non-module attrs are not module expressions (not unresolved).
      {:ok, {:map, _}} -> :error
      {:ok, :non_module} -> :error
      # Legacy untagged string (should not occur after bind rewrite).
      {:ok, mod} when is_binary(mod) -> {:ok, mod}
      :error -> {:unresolved, normalize_expr({:attr, attr})}
    end
  end

  # @attr.field used as a module expression (map field access / zero-arity call shape).
  defp resolve_module_name({{:., _, [{:@, _, [{attr, _, _}]}, field]}, _, []}, state)
       when is_atom(attr) and is_atom(field) do
    case Map.fetch(state.attrs, attr) do
      {:ok, {:map, fields}} ->
        case Map.fetch(fields, field) do
          {:ok, {:module, mod}} -> {:ok, mod}
          {:ok, {:map, _}} -> :error
          {:ok, :non_module} -> :error
          :error -> :error
        end

      # Module-valued attr + field is a call shape, not a nested module under the attr.
      {:ok, {:module, _mod}} ->
        :error

      {:ok, :non_module} ->
        :error

      {:ok, mod} when is_binary(mod) ->
        :error

      :error ->
        {:unresolved, normalize_expr({:attr_field, attr, field})}
    end
  end

  # Module.concat(...) as a module expression — must precede the general dotted catch-all.
  defp resolve_module_name({{:., _, [{:__aliases__, _, [:Module]}, :concat]}, _, args}, state) do
    resolve_module_concat_expr(args, state)
  end

  defp resolve_module_name({{:., _, [{:__aliases__, _, parts}, :concat]}, _, args}, state)
       when is_list(parts) do
    if parts_to_string(parts) == "Module" do
      resolve_module_concat_expr(args, state)
    else
      :error
    end
  end

  # Nested static module path: __MODULE__.Child, Alias.Child, multi-segment chains.
  defp resolve_module_name({{:., _, [base, child]}, _, []}, state) when is_atom(child) do
    case resolve_module_name(base, state) do
      {:ok, parent} -> join_module_strings(parent, Atom.to_string(child))
      {:unresolved, _} = u -> u
      :error -> :error
    end
  end

  defp resolve_module_name({{:., _, [_mod, _]}, _, _}, state) do
    # True call / dynamic dotted form — not a static module name alone.
    _ = state
    :error
  end

  defp resolve_module_name(atom, state) when is_atom(atom) do
    # Bare alias expansion
    short = Atom.to_string(atom)

    case lookup_alias(state, short) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:ok, short}
    end
  end

  defp resolve_module_name(bin, _state) when is_binary(bin) do
    if byte_size(bin) <= @max_module_bytes, do: {:ok, bin}, else: :error
  end

  defp resolve_module_name(_other, _state), do: :error

  defp resolve_module_concat_expr(args, state) do
    case args do
      [list] when is_list(list) ->
        static_concat_list(list, state)

      [a, b] ->
        with {:ok, ma} <- resolve_module_name(a, state),
             {:ok, mb} <- resolve_module_name(b, state) do
          join_module_strings(ma, mb)
        else
          _ -> {:unresolved, normalize_expr({:Module, :concat, args})}
        end

      _ ->
        {:unresolved, normalize_expr({:Module, :concat, args})}
    end
  end

  # Expand alias segment lists to a module binary.
  # Quoted nested `__MODULE__.Child` is `{:__aliases__, _, [{:__MODULE__, _, _}, :Child]}`
  # — not a dotted call — so the leading segment may be a `__MODULE__` tuple.
  defp parts_to_module(parts, state) when is_list(parts) do
    case expand_alias_head(parts, state) do
      {:ok, base, rest} ->
        case alias_rest_segments(rest) do
          {:ok, rest_s} ->
            mod = Enum.join([base | rest_s], ".")

            if byte_size(mod) <= @max_module_bytes do
              {:ok, mod}
            else
              :error
            end

          :error ->
            {:unresolved, normalize_expr(parts)}
        end

      :error ->
        {:unresolved, normalize_expr(parts)}
    end
  end

  defp parts_to_module(_parts, _state), do: :error

  # Shared leading-segment resolution for ordinary aliases and nested __MODULE__.
  # Quoted `__MODULE__.Child` is `{:__aliases__, _, [{:__MODULE__, _, nil}, :Child]}`.
  # Resolve the leading tuple via the same bare-__MODULE__ path (not atom-only).
  defp expand_alias_head([{:__MODULE__, _, _} = head | rest], state) do
    case resolve_module_name(head, state) do
      {:ok, parent} when is_binary(parent) -> {:ok, parent, rest}
      _ -> :error
    end
  end

  defp expand_alias_head([first | rest], state) when is_atom(first) do
    first_s = Atom.to_string(first)

    base =
      case lookup_alias(state, first_s) do
        {:ok, mod} -> mod
        :error -> first_s
      end

    {:ok, base, rest}
  end

  defp expand_alias_head(_parts, _state), do: :error

  defp alias_rest_segments(rest) when is_list(rest) do
    segs =
      Enum.map(rest, fn
        a when is_atom(a) -> Atom.to_string(a)
        s when is_binary(s) -> s
        _ -> nil
      end)

    if Enum.any?(segs, &is_nil/1), do: :error, else: {:ok, segs}
  end

  defp parts_to_string(parts) do
    parts
    |> Enum.map(fn
      a when is_atom(a) -> Atom.to_string(a)
      s when is_binary(s) -> s
      _ -> "?"
    end)
    |> Enum.join(".")
  end

  defp join_parts(base_mod, parts) do
    rest =
      Enum.map(parts, fn
        a when is_atom(a) -> Atom.to_string(a)
        s when is_binary(s) -> s
        _ -> nil
      end)

    if Enum.any?(rest, &is_nil/1) do
      :error
    else
      mod = Enum.join([base_mod | rest], ".")
      if byte_size(mod) <= @max_module_bytes, do: {:ok, mod}, else: :error
    end
  end

  defp join_module_strings(a, b) when is_binary(a) and is_binary(b) do
    mod = a <> "." <> b
    if byte_size(mod) <= @max_module_bytes, do: {:ok, mod}, else: :error
  end

  defp lookup_alias(state, short) when is_binary(short) do
    Enum.find_value(state.scopes, :error, fn scope ->
      case Map.fetch(scope, short) do
        {:ok, mod} -> {:ok, mod}
        :error -> nil
      end
    end)
    |> case do
      {:ok, _} = ok -> ok
      nil -> :error
      :error -> :error
    end
  end

  defp current_module(%{module_stack: [m | _]}), do: m
  defp current_module(_), do: nil

  defp push_scope(state), do: %{state | scopes: [%{} | state.scopes]}

  defp pop_scope(%{scopes: [_ | outer]} = state), do: %{state | scopes: outer}
  defp pop_scope(state), do: state

  defp add_ref(state, line, module, kind) when is_binary(module) do
    class = if state.typespec?, do: "typespec_only", else: "code"
    # typespec kind override
    kind = if state.typespec? and kind not in ["typespec"], do: "typespec", else: kind

    from_module = current_module(state) || ""

    ref = %{
      file: state.path,
      line: line,
      from_module: from_module,
      target: module,
      kind: kind,
      class: class
    }

    %{state | references: [ref | state.references]}
  end

  defp add_ref(state, _, _, _), do: state

  defp add_unresolved(state, line, reason, kind, expr) do
    # Identity digests the full bounded normalized form (not a display truncation)
    # so long common-prefix expressions cannot collide after evidence clipping.
    full_bounded =
      expr
      |> normalize_expr()
      |> bound_bytes(@max_expr_bytes)

    digest = Encode.expression_digest(full_bounded)
    from_module = current_module(state) || ""

    item = %{
      file: state.path,
      line: line,
      from_module: from_module,
      reason: reason,
      kind: kind,
      # Full bounded form — baseline identity / digest recompute source.
      normalized_expression: full_bounded,
      # UTF-8-safe display evidence only (not used for digest identity).
      evidence: utf8_safe_truncate(full_bounded, @max_evidence_bytes),
      expression_digest: digest
    }

    %{state | unresolved: [item | state.unresolved]}
  end

  defp normalize_expr(expr) when is_binary(expr), do: expr

  defp normalize_expr(expr) do
    expr
    |> Macro.to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  rescue
    _ -> inspect(expr, limit: 50, printable_limit: 100)
  end

  # Identity-bound form must remain valid UTF-8 so Jason report/baseline JSON
  # never fails on mid-codepoint splits. Never use binary_part/3 at an arbitrary
  # byte boundary for identity or display strings.
  defp bound_bytes(s, max) when is_binary(s) and is_integer(max) and max > 0 do
    utf8_safe_truncate(s, max)
  end

  defp bound_bytes(_, _), do: ""

  # Truncate to at most `max` bytes on UTF-8 codepoint boundaries only.
  defp utf8_safe_truncate(s, max) when is_binary(s) and is_integer(max) and max >= 0 do
    if byte_size(s) <= max do
      s
    else
      take_codepoints(s, max, [])
    end
  end

  defp utf8_safe_truncate(_, _), do: ""

  defp take_codepoints(_rest, remaining, acc) when remaining <= 0 do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp take_codepoints(<<>>, _remaining, acc) do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp take_codepoints(rest, remaining, acc) do
    case String.next_codepoint(rest) do
      {cp, more} ->
        size = byte_size(cp)

        if size > remaining do
          acc |> Enum.reverse() |> IO.iodata_to_binary()
        else
          take_codepoints(more, remaining - size, [cp | acc])
        end

      nil ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp line_of(meta) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp line_of(_), do: 0
end
