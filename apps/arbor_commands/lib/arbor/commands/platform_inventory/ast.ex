defmodule Arbor.Commands.PlatformInventory.Ast do
  @moduledoc """
  Pure per-file syntactic fact projector for platform inventory.

  Parses exact supplied Elixir bytes via `Code.string_to_quoted/2` only. It
  never compiles, evaluates, loads, or executes source. Facts are bounded,
  deterministic booleans/lists reflecting syntactic presence of a small set
  of watched calls/forms, not a semantic proof of behavior.
  """

  @max_path_bytes 4_096
  @max_source_bytes 1_048_576
  @max_nodes 200_000
  @max_depth 256
  @max_modules 64
  @max_aliases 64
  @max_roles 16
  @max_name_bytes 256

  @otp_use_roles %{
    "GenServer" => "genserver",
    "Supervisor" => "supervisor",
    "DynamicSupervisor" => "dynamic_supervisor",
    "Application" => "application",
    "Agent" => "agent",
    "Task" => "task",
    "GenStateMachine" => "gen_statem",
    "gen_statem" => "gen_statem",
    "gen_server" => "genserver",
    "supervisor" => "supervisor"
  }

  @app_env_funs MapSet.new([
                  :get_env,
                  :fetch_env,
                  :fetch_env!,
                  :put_env,
                  :delete_env,
                  :compile_env,
                  :compile_env!,
                  :get_all_env
                ])

  @erlang_app_env_funs MapSet.new([:get_env, :fetch_env, :set_env, :unset_env, :get_all_env])
  @ets_funs MapSet.new([:new])
  @port_funs MapSet.new([:open, :command, :control, :connect])
  @fs_scan_funs MapSet.new([:ls, :ls!, :stream!])
  @code_eval_funs MapSet.new([:eval_string, :eval_quoted, :compile_string, :compile_quoted])
  @telemetry_funs MapSet.new([:attach, :attach_many, :detach])
  @logger_backend_funs MapSet.new([:add_backend, :remove_backend, :configure_backend])

  @network_modules MapSet.new([
                     "gen_tcp",
                     "gen_udp",
                     "ssl",
                     "inet",
                     "httpc",
                     "Finch",
                     "Req",
                     "Mint.HTTP"
                   ])

  @type facts :: map()

  @spec facts(String.t(), binary()) :: {:ok, facts()} | {:error, term()}
  def facts(path, bytes) when is_binary(path) and is_binary(bytes) do
    with :ok <- validate_input(path, bytes),
         {:ok, ast} <- parse(path, bytes),
         {:ok, {state, _count, _env}} <- walk(ast, new_state(), new_env(), 0, 0) do
      {:ok, to_facts(state)}
    end
  end

  def facts(_, _), do: {:error, :invalid_facts_args}

  defp validate_input(path, source) do
    cond do
      path == "" -> {:error, :path_empty}
      not String.valid?(path) -> {:error, :path_invalid_utf8}
      String.contains?(path, <<0>>) -> {:error, :path_nul_byte}
      byte_size(path) > @max_path_bytes -> {:error, :path_too_long}
      not String.valid?(source) -> {:error, :source_invalid_utf8}
      byte_size(source) > @max_source_bytes -> {:error, :source_too_large}
      true -> :ok
    end
  end

  defp parse(path, bytes) do
    case Code.string_to_quoted(bytes,
           file: path,
           columns: false,
           token_metadata: false,
           emit_warnings: false
         ) do
      {:ok, ast} -> {:ok, ast}
      {:error, reason} -> {:error, {:parse_error, path, reason}}
    end
  end

  defp new_state do
    %{
      modules: [],
      module_set: MapSet.new(),
      module_count: 0,
      otp_roles: MapSet.new(),
      role_count: 0,
      alias_count: 0,
      configuration: false,
      ownership: false,
      registry: false,
      process: false,
      native: false,
      network: false,
      filesystem_scan: false,
      dynamic_code: false,
      telemetry: false
    }
  end

  defp new_env, do: %{module_stack: [], aliases: %{}}

  defp to_facts(state) do
    %{
      "modules" => Enum.reverse(state.modules),
      "otp_roles" => state.otp_roles |> MapSet.to_list() |> Enum.sort(),
      "configuration" => state.configuration,
      "ownership" => state.ownership,
      "registry" => state.registry,
      "process" => state.process,
      "native" => state.native,
      "network" => state.network,
      "filesystem_scan" => state.filesystem_scan,
      "dynamic_code" => state.dynamic_code,
      "telemetry" => state.telemetry
    }
  end

  defp walk(_node, _state, _env, _depth, count) when count >= @max_nodes do
    {:error, :ast_node_limit}
  end

  defp walk(_node, _state, _env, depth, _count) when depth > @max_depth do
    {:error, :ast_depth_limit}
  end

  defp walk(node, state, env, depth, count) do
    count = count + 1

    case node do
      {:defmodule, _meta, [name_ast, body]} ->
        walk_defmodule(name_ast, body, state, env, depth, count)

      {:alias, _meta, args} when is_list(args) ->
        with {:ok, state, env} <- register_alias(args, state, env),
             {:ok, {state, count, _child_env}} <-
               walk_children(args, state, env, depth + 1, count) do
          {:ok, {state, count, env}}
        end

      {:use, _meta, [target | _rest] = args} ->
        with {:ok, state} <- record_use(state, target, env),
             {:ok, {state, count, _child_env}} <-
               walk_children(args, state, env, depth + 1, count) do
          {:ok, {state, count, env}}
        end

      {:__block__, _meta, expressions} when is_list(expressions) ->
        walk_sequence(expressions, state, env, depth + 1, count)

      {{:., _dot_meta, [receiver, fun]}, _call_meta, args}
      when is_atom(fun) and is_list(args) ->
        with {:ok, state} <- record_remote_call(state, receiver, fun, length(args), env),
             {:ok, {state, count, _child_env}} <-
               walk_children([receiver, args], state, env, depth + 1, count) do
          {:ok, {state, count, env}}
        end

      {:@, _meta, [{:behaviour, _bmeta, [target]} | _rest] = args} ->
        with {:ok, state} <- record_behaviour(state, target, env),
             {:ok, {state, count, _child_env}} <-
               walk_children(args, state, env, depth + 1, count) do
          {:ok, {state, count, env}}
        end

      {:@, _meta, [{callback, _cmeta, _} | _rest] = args}
      when callback in [:callback, :macrocallback] ->
        walk_children(args, %{state | registry: true}, env, depth + 1, count)

      {:@, _meta, [{:impl, _imeta, _} | _rest] = args} ->
        walk_children(args, %{state | registry: true}, env, depth + 1, count)

      {:@, _meta, [{:on_load, _ometa, _} | _rest] = args} ->
        walk_children(args, %{state | native: true}, env, depth + 1, count)

      {fun, _meta, args} when is_atom(fun) and is_list(args) ->
        state = record_local_call(state, fun, length(args))
        walk_children(args, state, env, depth + 1, count)

      {left, right} ->
        walk_children([left, right], state, env, depth + 1, count)

      list when is_list(list) ->
        walk_children(list, state, env, depth + 1, count)

      _leaf ->
        {:ok, {state, count, env}}
    end
  end

  defp walk_defmodule(name_ast, body, state, env, depth, count) do
    with {:ok, module_name} <- qualify_module(name_ast, env),
         {:ok, state} <- add_module(state, module_name),
         {:ok, {state, count, _child_env}} <-
           walk_children([name_ast], state, env, depth + 1, count) do
      nested_env = %{env | module_stack: [module_name | env.module_stack]}

      with {:ok, {state, count, _nested_env}} <-
             walk(body, state, nested_env, depth + 1, count) do
        {:ok, {state, count, env}}
      end
    else
      :unknown -> walk_children([name_ast, body], state, env, depth + 1, count)
      {:error, _} = error -> error
    end
  end

  defp walk_children(children, state, env, depth, count) do
    result =
      Enum.reduce_while(children, {:ok, {state, count}}, fn child, {:ok, {state, count}} ->
        case walk(child, state, env, depth, count) do
          {:ok, {state, count, _child_env}} -> {:cont, {:ok, {state, count}}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, {state, count}} -> {:ok, {state, count, env}}
      {:error, _} = error -> error
    end
  end

  defp walk_sequence(expressions, state, env, depth, count) do
    Enum.reduce_while(expressions, {:ok, {state, count, env}}, fn expression,
                                                                  {:ok, {state, count, env}} ->
      case walk(expression, state, env, depth, count) do
        {:ok, result} -> {:cont, {:ok, result}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp qualify_module(name_ast, env) do
    case resolve_name(name_ast, env) do
      {:ok, raw_name, absolute?} ->
        qualified =
          if absolute? or env.module_stack == [] do
            {:ok, raw_name}
          else
            join_names([hd(env.module_stack), raw_name])
          end

        case qualified do
          {:ok, name} -> bounded_name(name, :module_name)
          {:error, :name_too_long} -> {:error, {:module_name, :too_long}}
        end

      {:error, :name_too_long} ->
        {:error, {:module_name, :too_long}}

      :unknown ->
        :unknown

      {:error, _} = error ->
        error
    end
  end

  defp add_module(state, module_name) do
    if state.module_count >= @max_modules do
      {:error, :ast_module_limit}
    else
      state = %{state | module_count: state.module_count + 1}

      if MapSet.member?(state.module_set, module_name) do
        {:ok, state}
      else
        {:ok,
         %{
           state
           | modules: [module_name | state.modules],
             module_set: MapSet.put(state.module_set, module_name)
         }}
      end
    end
  end

  defp register_alias(args, state, env) do
    with {:ok, state} <- consume_alias(state),
         {:ok, target, local} <- parse_alias(args, env),
         {:ok, target} <- bounded_name(target, :alias_name),
         {:ok, local} <- bounded_name(local, :alias_name) do
      {:ok, state, %{env | aliases: Map.put(env.aliases, local, target)}}
    else
      {:error, _} = error -> error
      :unknown -> {:ok, state, env}
    end
  end

  defp consume_alias(%{alias_count: count}) when count >= @max_aliases do
    {:error, :ast_alias_limit}
  end

  defp consume_alias(state), do: {:ok, %{state | alias_count: state.alias_count + 1}}

  defp parse_alias([target], env) do
    with {:ok, target} <- resolve_receiver(target, env),
         {:ok, local} <- last_name_part(target) do
      {:ok, target, local}
    end
  end

  defp parse_alias([target, options], env) when is_list(options) do
    case List.keyfind(options, :as, 0) do
      {:as, as_ast} ->
        with {:ok, target} <- resolve_receiver(target, env),
             {:ok, local} <- local_alias_name(as_ast) do
          {:ok, target, local}
        end

      nil ->
        :unknown

      _other ->
        :unknown
    end
  end

  defp parse_alias(_, _env), do: :unknown

  defp local_alias_name({:__aliases__, _meta, [part]}) when is_atom(part) do
    name = Atom.to_string(part)
    if name == "Elixir", do: :unknown, else: {:ok, name}
  end

  defp local_alias_name(_), do: :unknown

  defp last_name_part(name) do
    case List.last(String.split(name, ".")) do
      nil -> :unknown
      part -> {:ok, part}
    end
  end

  defp add_role(state, role_name) do
    case Map.fetch(@otp_use_roles, role_name) do
      {:ok, role} when state.role_count < @max_roles ->
        {:ok,
         %{state | otp_roles: MapSet.put(state.otp_roles, role), role_count: state.role_count + 1}}

      {:ok, _role} ->
        {:error, :ast_role_limit}

      :error ->
        {:ok, state}
    end
  end

  defp record_local_call(state, :apply, 3), do: %{state | dynamic_code: true}
  defp record_local_call(state, _fun, _arity), do: state

  defp record_remote_call(state, receiver, fun, arity, env) do
    case resolve_receiver(receiver, env) do
      {:ok, receiver_name} -> {:ok, record_remote_call_for(receiver_name, state, fun, arity)}
      :unknown -> {:ok, state}
      {:error, _} = error -> error
    end
  end

  defp record_remote_call_for("Application", state, fun, _arity),
    do: mark(state, :configuration, MapSet.member?(@app_env_funs, fun))

  defp record_remote_call_for("application", state, fun, _arity),
    do: mark(state, :configuration, MapSet.member?(@erlang_app_env_funs, fun))

  defp record_remote_call_for("Config", state, fun, _arity),
    do: mark(state, :configuration, fun == :config)

  defp record_remote_call_for("Process", state, fun, _arity),
    do: mark(state, :process, fun in [:register, :unregister])

  defp record_remote_call_for("global", state, fun, _arity),
    do: mark(state, :process, fun in [:register_name, :unregister_name])

  defp record_remote_call_for("erlang", state, fun, arity),
    do: record_erlang_call(state, fun, arity)

  defp record_remote_call_for("ets", state, fun, _arity),
    do: mark(state, :ownership, MapSet.member?(@ets_funs, fun))

  defp record_remote_call_for("Registry", state, _fun, _arity), do: %{state | registry: true}

  defp record_remote_call_for("Port", state, fun, _arity),
    do: mark(state, :native, MapSet.member?(@port_funs, fun))

  defp record_remote_call_for("System", state, fun, _arity), do: mark(state, :native, fun == :cmd)
  defp record_remote_call_for("os", state, fun, _arity), do: mark(state, :native, fun == :cmd)

  defp record_remote_call_for(receiver, state, _fun, _arity)
       when receiver in ["Finch", "Req", "Mint.HTTP"],
       do: %{state | network: true}

  defp record_remote_call_for(receiver, state, fun, _arity),
    do: record_network_or_fs_or_code_call(state, receiver, fun)

  defp record_network_or_fs_or_code_call(state, receiver, fun) do
    cond do
      MapSet.member?(@network_modules, receiver) ->
        %{state | network: true}

      receiver == "filelib" and fun == :wildcard ->
        %{state | filesystem_scan: true}

      receiver == "File" and fun in @fs_scan_funs ->
        %{state | filesystem_scan: true}

      receiver == "Path" and fun == :wildcard ->
        %{state | filesystem_scan: true}

      receiver == "Kernel" and fun == :apply ->
        %{state | dynamic_code: true}

      receiver == "Code" and MapSet.member?(@code_eval_funs, fun) ->
        %{state | dynamic_code: true}

      receiver == "Module" and fun == :concat ->
        %{state | dynamic_code: true}

      receiver == "telemetry" and MapSet.member?(@telemetry_funs, fun) ->
        %{state | telemetry: true}

      receiver == "Logger" and MapSet.member?(@logger_backend_funs, fun) ->
        %{state | telemetry: true}

      true ->
        state
    end
  end

  defp record_erlang_call(state, :register, 2), do: %{state | process: true}
  defp record_erlang_call(state, :unregister, 1), do: %{state | process: true}
  defp record_erlang_call(state, :load_nif, 2), do: %{state | native: true}
  defp record_erlang_call(state, :open_port, 2), do: %{state | native: true}
  defp record_erlang_call(state, _fun, _arity), do: state

  defp mark(state, key, true), do: Map.put(state, key, true)
  defp mark(state, _key, false), do: state

  defp resolve_receiver(ast, env) do
    case resolve_name(ast, env) do
      {:ok, name, _absolute?} ->
        bounded_name(name, :receiver_name)

      {:error, :name_too_long} ->
        {:error, {:receiver_name, :too_long}}

      :unknown ->
        :unknown

      {:error, _} = error ->
        error
    end
  end

  defp resolve_name({:__aliases__, _meta, parts}, env) when is_list(parts) do
    with {:ok, names} <- alias_parts(parts, env),
         {:ok, name} <- join_alias_parts(names),
         {:ok, {name, absolute?}} <-
           qualify_alias_receiver(name, env, absolute_alias_parts?(parts)) do
      {:ok, name, absolute?}
    end
  end

  defp resolve_name({:__MODULE__, _meta, nil}, %{module_stack: [module | _]}),
    do: {:ok, module, true}

  defp resolve_name({{:., _meta, [left, right]}, _call_meta, args}, env)
       when is_atom(right) and args in [[], nil] do
    with {:ok, left_name, _absolute?} <- resolve_name(left, env),
         {:ok, name} <- join_names([left_name, Atom.to_string(right)]) do
      {:ok, name, true}
    end
  end

  defp resolve_name(atom, _env) when is_atom(atom), do: {:ok, Atom.to_string(atom), true}
  defp resolve_name(_, _env), do: :unknown

  defp alias_parts(parts, env) do
    Enum.reduce_while(parts, {:ok, []}, fn
      {:__MODULE__, _meta, nil}, {:ok, acc} ->
        case env.module_stack do
          [module | _] -> {:cont, {:ok, acc ++ [module]}}
          [] -> {:halt, :unknown}
        end

      part, {:ok, acc} when is_atom(part) ->
        {:cont, {:ok, acc ++ [Atom.to_string(part)]}}

      _part, _acc ->
        {:halt, :unknown}
    end)
  end

  defp join_alias_parts([]), do: :unknown

  defp join_alias_parts(parts) do
    parts = if hd(parts) == "Elixir", do: tl(parts), else: parts

    case parts do
      [] -> :unknown
      _ -> join_names(parts)
    end
  end

  defp qualify_alias_receiver(name, _env, true), do: {:ok, {name, true}}

  defp qualify_alias_receiver(name, env, false) do
    case String.split(name, ".") do
      [first | rest] ->
        case Map.fetch(env.aliases, first) do
          {:ok, target} ->
            with {:ok, expanded} <- join_names([target | rest]) do
              {:ok, {expanded, true}}
            end

          :error ->
            {:ok, {name, false}}
        end

      [] ->
        {:ok, {name, false}}
    end
  end

  defp absolute_alias_parts?([:"Elixir" | _]), do: true

  defp absolute_alias_parts?([{:__MODULE__, _meta, nil} | _]), do: true
  defp absolute_alias_parts?(_parts), do: false

  defp bounded_name(name, _kind) when not is_binary(name), do: :unknown

  defp bounded_name(name, kind) do
    cond do
      name == "" -> :unknown
      not String.valid?(name) -> {:error, {kind, :invalid_utf8}}
      String.contains?(name, <<0>>) -> {:error, {kind, :nul_byte}}
      byte_size(name) > @max_name_bytes -> {:error, {kind, :too_long}}
      true -> {:ok, name}
    end
  end

  defp join_names(names) do
    name = Enum.join(names, ".")
    if byte_size(name) <= @max_name_bytes, do: {:ok, name}, else: {:error, :name_too_long}
  end

  defp record_use(state, target, env) do
    case resolve_receiver(target, env) do
      {:ok, "Registry"} -> {:ok, %{state | registry: true}}
      {:ok, role_name} -> add_role(state, role_name)
      :unknown -> {:ok, state}
      {:error, _} = error -> error
    end
  end

  defp record_behaviour(state, target, env) do
    case resolve_receiver(target, env) do
      {:ok, _name} -> {:ok, %{state | registry: true}}
      :unknown -> {:ok, state}
      {:error, _} = error -> error
    end
  end
end
