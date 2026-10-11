defmodule Arbor.Sandbox.Code do
  @moduledoc """
  Code sandbox for AST-level validation.

  Validates Elixir code to ensure it doesn't use dangerous modules or functions
  based on sandbox level. This is a compile-time safety check that runs before
  code is evaluated.

  ## Validation Levels

  | Level | Description |
  |-------|-------------|
  | `:pure` / `:strict` | Kernel + safe stdlib only |
  | `:hot_load` | `:limited` minus OS exec, dynamic code loading, cluster escape |
  | `:limited` | + File, IO, Process, etc. |
  | `:full` / `:standard` / `:permissive` | All except dangerous |
  | `:none` / `:container` | No restrictions (isolated) |

  `:pure`, `:strict`, `:limited` and `:hot_load` are the **restrictive** levels.
  At a restrictive level the validator is an allowlist barrier:

  - Elixir modules must be in the level's allowlist.
  - Erlang modules must be in `erlang_allowed_modules/0` (a conservative set of
    pure data/stdlib modules); `:erlang` itself is allowed subject to a
    per-function denylist; `:crypto` and `:timer` only for a few pure
    functions. Everything else (`:file`, `:code`, `:rpc`, `:erpc`, `:init`,
    `:ets`, `:persistent_term`, `:net_kernel`, ...) is a `:forbidden_module`.
  - Dynamic dispatch is rejected: a remote call whose receiver is not a literal
    module (`m = System; m.cmd(...)`, `@mod.f(...)`, `state.mod.f()`),
    `apply/2`, `Kernel.apply/2`, `Function.capture/3`, `:erlang.make_fun/3`,
    `&dynamic.f/arity`, and `spawn*` with an anonymous function.
    `apply/3` / `Kernel.apply/3` / `spawn/3` with a literal module are checked
    exactly like the equivalent direct call.
  - `import` / `alias` of a module that carries per-function restrictions
    (`System`, `File`, `Code`, `Module`, `Function`, `:erlang`, ...) is
    rejected, because an imported bare call or a shadowing alias
    (`alias System, as: Enum`) cannot be attributed to its real target.
    `require` / `use` / `alias` / `import` of a module that is not allowed at
    the level is a `:forbidden_module`.
  - Dynamic code loading is rejected: `Code.string_to_quoted`,
    `Code.compile_file`, `Code.require_file`, `Code.ensure_loaded(?)`,
    `Code.ensure_compiled(?)`, `Module.create`, `Module.eval_quoted`.

  At `:full` / `:standard` / `:permissive` the historical behaviour is kept:
  only `@never_allowed_modules` / `@never_allowed_functions` are rejected.

  ## `:hot_load`

  Used by `Arbor.Actions.Code.HotLoad` for model-supplied source that is
  compiled into the running VM. It is `:limited` (so `GenServer`, `Logger`,
  `Enum`, `Map`, `Process`, `Task`, `File` ... still work) **minus** anything
  that starts an OS process, loads code, or escapes the node: `System.cmd`,
  `System.shell`, `System.halt`/`stop`/`restart`, `System.at_exit`,
  `System.trap_signal`, `Port.*`, `Node.*`, `Code.*`, `Module.create`, and
  (via the Erlang allowlist) `:os`, `:rpc`, `:erpc`, `:code`, `:init`,
  `:file`. It is a validator-internal level, not an
  `Arbor.Contracts.Security.SandboxLevel` canonical level.

  ## Known residual gap

  A no-parens zero-arity call on a variable receiver (`m = System; m.halt`)
  is syntactically identical to map field access (`state.count`) and still
  executes on Elixir 1.19 (with a deprecation warning). Field access cannot be
  rejected without making the sandbox useless, so this shape is only rejected
  when the field name is in `@dangerous_zero_arity` (`halt`, `stop`, ...).
  Everything that takes arguments or uses parentheses is rejected.

  ## Dangerous Patterns

  Some patterns are blocked at all levels:

  - `Code.eval_string/1,2,3` — Dynamic code evaluation
  - `:erlang.halt/0,1` — VM termination
  - `File.rm_rf!/1` — Recursive delete (non-recoverable)
  - `System.halt/0,1` — VM termination

  Others are restricted by level:

  - `System.cmd/2,3` — Requires `:limited` or higher (denied at `:hot_load`)
  - `Port.open/2` — Requires `:limited` or higher (denied at `:hot_load`)
  - Network modules — Requires `:limited` or higher
  """

  # Modules always allowed (safe pure functions)
  # M7: Agent/Task moved to @limited_allowed — they can spawn processes
  @always_allowed [
    Kernel,
    Enum,
    List,
    Map,
    String,
    Integer,
    Float,
    Tuple,
    MapSet,
    Keyword,
    Access,
    Stream,
    Range,
    Date,
    Time,
    DateTime,
    NaiveDateTime,
    Calendar,
    Regex,
    URI,
    Base,
    Bitwise,
    Inspect,
    Protocol,
    Behaviour,
    Function,
    Exception
  ]

  # Modules only allowed at :limited and above
  # M7: Agent/Task moved here from @always_allowed — they can spawn processes
  @limited_allowed [
    File,
    Path,
    IO,
    System,
    Process,
    GenServer,
    Supervisor,
    DynamicSupervisor,
    Application,
    Code,
    Module,
    Macro,
    ETS,
    Logger,
    Port,
    Node,
    Registry,
    OptionParser,
    StringIO,
    Agent,
    Task
  ]

  # F-007: Elixir modules that :hot_load removes from the :limited allowlist.
  # OS processes, dynamic code loading and cluster escape have no place in a
  # hot-loaded module.
  @hot_load_denied_modules [Port, Node, Code]

  # F-007: Erlang modules allowed at the restrictive levels. Conservative:
  # pure data / string / math / container modules only. :erlang is handled
  # separately (allowed with a per-function denylist); :crypto and :timer are
  # allowed only for the functions in @erlang_function_allowlists.
  @erlang_allowed [
    :lists,
    :maps,
    :binary,
    :string,
    :math,
    :unicode,
    :proplists,
    :orddict,
    :ordsets,
    :sets,
    :gb_trees,
    :gb_sets,
    :queue,
    :array,
    :calendar,
    :re,
    :base64,
    :uri_string,
    :json,
    :io_lib,
    :filename
  ]

  # Erlang modules allowed at restrictive levels only for the listed functions.
  @erlang_function_allowlists %{
    crypto: [:hash, :hash_init, :hash_update, :hash_final, :mac, :strong_rand_bytes, :supports],
    timer: [:sleep, :tc, :seconds, :minutes, :hours, :hms, :now_diff]
  }

  # F-007: :erlang functions denied at restrictive levels on top of
  # @never_allowed_functions (process/port/NIF/timer/cluster/trace escapes).
  @erlang_restricted_functions [
    :spawn_opt,
    :spawn_request,
    :system_flag,
    :send_after,
    :start_timer,
    :load_nif,
    :apply,
    :make_fun,
    :hibernate,
    :set_cookie,
    :get_cookie,
    :disconnect_node,
    :monitor_node,
    :trace,
    :trace_pattern,
    :trace_delivered,
    :suspend_process,
    :resume_process,
    :group_leader
  ]

  # :erlang function-name prefixes denied at restrictive levels.
  @erlang_restricted_prefixes ["port_", "nif_"]

  # Network modules — require :limited or higher
  @network_modules [
    :gen_tcp,
    :gen_udp,
    :ssl,
    :httpc,
    :inet,
    :socket
  ]

  # Dangerous modules NEVER allowed (even at :full)
  @never_allowed_modules [
    :os
  ]

  # Dangerous functions NEVER allowed regardless of level
  @never_allowed_functions [
    # Code evaluation — arbitrary code execution
    {Code, :eval_string},
    {Code, :eval_quoted},
    {Code, :eval_file},
    {Code, :compile_string},
    {Code, :compile_quoted},
    # VM termination
    {:erlang, :halt},
    {System, :halt},
    {System, :stop},
    # Dangerous file operations
    {File, :rm_rf!},
    # Process manipulation that could escape sandbox
    {Process, :exit},
    {:erlang, :exit},
    {:erlang, :process_flag},
    # Application control
    {Application, :stop},
    {Application, :unload},
    # Node operations (cluster escape)
    {Node, :spawn},
    {Node, :spawn_link},
    {:rpc, :call},
    {:rpc, :cast},
    # M6: Additional dangerous :erlang functions
    {:erlang, :open_port},
    {:erlang, :send},
    {:erlang, :spawn},
    {:erlang, :spawn_link},
    {:erlang, :spawn_monitor},
    {:erlang, :binary_to_term},
    {:erlang, :apply},
    {:erlang, :load_module},
    {:erlang, :delete_module},
    {:erlang, :purge_module}
  ]

  # Functions restricted by level (allowed at :limited+, denied at :hot_load)
  @limited_functions [
    {System, :cmd},
    {System, :shell},
    {Port, :open},
    {Port, :command},
    {:os, :cmd}
  ]

  # F-007: dynamic code loading / dynamic dispatch helpers denied below :full.
  @restricted_dynamic_functions [
    {Code, :string_to_quoted},
    {Code, :string_to_quoted!},
    {Code, :string_to_quoted_with_comments},
    {Code, :compile_file},
    {Code, :require_file},
    {Code, :ensure_loaded},
    {Code, :ensure_loaded?},
    {Code, :ensure_loaded!},
    {Code, :ensure_compiled},
    {Code, :ensure_compiled?},
    {Code, :ensure_compiled!},
    {Code, :ensure_all_loaded},
    {Code, :ensure_all_loaded!},
    {Module, :create},
    {Module, :eval_quoted},
    {Function, :capture},
    {:erlang, :make_fun}
  ]

  # F-007: extra functions denied at :hot_load (on top of :limited).
  @hot_load_denied_functions [
    {System, :cmd},
    {System, :shell},
    {System, :halt},
    {System, :stop},
    {System, :restart},
    {System, :at_exit},
    {System, :trap_signal},
    {System, :untrap_signal},
    {Module, :create},
    {Module, :eval_quoted}
  ]

  # Modules that carry per-function restrictions somewhere in this validator.
  # `import`ing or `alias`ing one of these at a restrictive level would let a
  # bare call (`cmd("id", [])`) or a shadowing alias (`alias System, as: Enum`)
  # evade the per-function checks, so those directives are rejected for them.
  # Kernel is exempt: its dangerous bare forms (apply/spawn) are matched by
  # the walker regardless of import.
  @function_restricted_modules (@never_allowed_functions ++
                                  @limited_functions ++
                                  @restricted_dynamic_functions ++
                                  @hot_load_denied_functions)
                               |> Enum.map(&elem(&1, 0))
                               |> Kernel.++([:erlang, :crypto, :timer])
                               |> Enum.uniq()
                               |> Enum.reject(&(&1 == Kernel))

  # No-parens zero-arity access on a variable receiver (`m.halt`) is
  # indistinguishable from field access (`state.count`); only these names are
  # rejected (see "Known residual gap" in the moduledoc).
  @dangerous_zero_arity [:halt, :stop, :reboot, :restart, :get_cookie, :get_env]

  @restrictive_levels [:pure, :strict, :limited, :hot_load]
  @spawn_functions [:spawn, :spawn_link, :spawn_monitor]
  @directives [:import, :require, :use, :alias]

  @type violation :: %{
          type: :dangerous_call | :forbidden_module | :unsafe_pattern | :level_restricted,
          location: {line :: integer(), column :: integer()} | nil,
          description: String.t()
        }

  # ── Public API ──

  @doc """
  Validate an AST at the given sandbox level.

  Returns `:ok` if the code is safe, or `{:error, {:code_violations, violations}}`
  with a list of detected violations.
  """
  @spec validate(Macro.t(), atom()) :: :ok | {:error, {:code_violations, [violation()]}}
  def validate(ast, level) do
    case walk_ast(ast, level, []) do
      [] -> :ok
      violations -> {:error, {:code_violations, Enum.reverse(violations)}}
    end
  end

  @doc """
  Check if a module is allowed at the given level.
  """
  @spec check_module(module(), atom()) :: :ok | {:error, :module_not_allowed}
  def check_module(module, level) do
    if module_allowed?(module, level) do
      :ok
    else
      {:error, :module_not_allowed}
    end
  end

  @doc """
  Get allowed modules for a sandbox level.
  """
  @spec allowed_modules(atom()) :: [module()]
  def allowed_modules(:pure), do: @always_allowed
  def allowed_modules(:limited), do: @always_allowed ++ @limited_allowed

  def allowed_modules(:hot_load),
    do: (@always_allowed ++ @limited_allowed) -- @hot_load_denied_modules

  def allowed_modules(:full), do: @always_allowed ++ @limited_allowed
  def allowed_modules(:standard), do: @always_allowed ++ @limited_allowed
  def allowed_modules(:permissive), do: @always_allowed ++ @limited_allowed
  def allowed_modules(:strict), do: @always_allowed
  def allowed_modules(:none), do: :all
  def allowed_modules(_), do: @always_allowed

  @doc """
  Erlang (atom) modules allowed at the restrictive levels
  (`:pure`, `:strict`, `:limited`, `:hot_load`).

  `:erlang` is additionally allowed subject to a per-function denylist, and
  `:crypto` / `:timer` only for a few pure functions.
  """
  @spec erlang_allowed_modules() :: [atom()]
  def erlang_allowed_modules, do: @erlang_allowed

  @doc """
  Whether `level` is a restrictive (allowlist-barrier) level.
  """
  @spec restrictive_level?(atom()) :: boolean()
  def restrictive_level?(level), do: level in @restrictive_levels

  @doc """
  Get restricted functions for a sandbox level.

  Returns the list of {module, function} tuples that are blocked at this level.
  """
  @spec restricted_functions(atom()) :: [{module(), atom()}]
  def restricted_functions(:pure),
    do: @never_allowed_functions ++ @limited_functions ++ @restricted_dynamic_functions

  def restricted_functions(:strict),
    do: @never_allowed_functions ++ @limited_functions ++ @restricted_dynamic_functions

  def restricted_functions(:limited),
    do: @never_allowed_functions ++ @restricted_dynamic_functions

  def restricted_functions(:hot_load),
    do: @never_allowed_functions ++ @restricted_dynamic_functions ++ @hot_load_denied_functions

  def restricted_functions(:standard), do: @never_allowed_functions
  def restricted_functions(:full), do: @never_allowed_functions
  def restricted_functions(:permissive), do: @never_allowed_functions
  def restricted_functions(:none), do: @never_allowed_functions

  def restricted_functions(_),
    do: @never_allowed_functions ++ @limited_functions ++ @restricted_dynamic_functions

  # ── AST walk ──

  defp walk_ast(ast, level, violations) do
    {_, violations} =
      Macro.prewalk(ast, violations, fn node, acc -> {node, check_node(node, level, acc)} end)

    violations
  end

  # Remote call / field access: receiver.function(args)
  defp check_node({{:., meta, [receiver, function]}, call_meta, args}, level, acc)
       when is_atom(function) and is_list(args) do
    location = extract_location(meta)

    case resolve_module(receiver) do
      {:module, module} ->
        check_module_call(module, function, args, level, location, acc)

      :self ->
        # __MODULE__.function(...) — calls into the module being validated
        acc

      :dynamic ->
        if args == [] and Keyword.get(call_meta, :no_parens, false) do
          check_field_access(function, level, location, acc)
        else
          check_dynamic_dispatch(
            level,
            location,
            "remote call #{describe_receiver(receiver)}.#{function}/#{length(args)}",
            acc
          )
        end
    end
  end

  # Capture of a remote function: &receiver.function/arity. Literal receivers
  # are checked when the walker descends into the inner dot node; a dynamic
  # receiver would otherwise look like field access, so catch it here.
  defp check_node(
         {:&, meta, [{:/, _, [{{:., _, [receiver, function]}, _, []}, _arity]}]},
         level,
         acc
       )
       when is_atom(function) do
    case resolve_module(receiver) do
      :dynamic ->
        check_dynamic_dispatch(
          level,
          extract_location(meta),
          "capture &#{describe_receiver(receiver)}.#{function}/arity",
          acc
        )

      _ ->
        acc
    end
  end

  # apply/3
  defp check_node({:apply, meta, [module_arg, function_arg, args]}, level, acc) do
    check_apply(module_arg, function_arg, args, level, extract_location(meta), acc)
  end

  # apply/2 — applies an opaque fun value
  defp check_node({:apply, meta, [_fun, _args]}, level, acc) do
    check_dynamic_dispatch(level, extract_location(meta), "apply/2", acc)
  end

  # spawn/spawn_link/spawn_monitor
  defp check_node({spawn_fn, meta, args}, level, acc)
       when spawn_fn in @spawn_functions and is_list(args) do
    check_spawn(spawn_fn, args, level, extract_location(meta), acc)
  end

  # import / require / use / alias
  defp check_node({directive, meta, [target | _opts]}, level, acc)
       when directive in @directives do
    check_directive(directive, target, level, extract_location(meta), acc)
  end

  defp check_node(_node, _level, acc), do: acc

  # ── Receiver resolution ──

  # Resolve a call receiver / module argument to a literal module when possible.
  defp resolve_module({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      {:module, Module.concat(parts)}
    else
      # e.g. __MODULE__.Sub — cannot be resolved statically
      :dynamic
    end
  end

  defp resolve_module({:__MODULE__, _, ctx}) when is_atom(ctx), do: :self
  defp resolve_module(module) when is_atom(module) and not is_nil(module), do: {:module, module}
  defp resolve_module(_other), do: :dynamic

  defp describe_receiver({name, _, ctx}) when is_atom(name) and is_atom(ctx),
    do: Atom.to_string(name)

  defp describe_receiver({:@, _, [{name, _, _}]}), do: "@#{name}"
  defp describe_receiver(_), do: "<expression>"

  defp elixir_module?(module), do: String.starts_with?(Atom.to_string(module), "Elixir.")

  # ── Call checks ──

  # Kernel.apply/3 — checked exactly like apply/3 (fixes the dead H9 clause:
  # the generic remote-call path used to match first and Kernel is allowed).
  defp check_module_call(Kernel, :apply, [module_arg, function_arg, args], level, location, acc) do
    check_apply(module_arg, function_arg, args, level, location, acc)
  end

  defp check_module_call(Kernel, :apply, [_fun, _args], level, location, acc) do
    check_dynamic_dispatch(level, location, "Kernel.apply/2", acc)
  end

  defp check_module_call(Kernel, :apply, _args, level, location, acc) do
    check_dynamic_dispatch(level, location, "Kernel.apply with non-literal arguments", acc)
  end

  defp check_module_call(Kernel, spawn_fn, args, level, location, acc)
       when spawn_fn in @spawn_functions do
    check_spawn(spawn_fn, args, level, location, acc)
  end

  defp check_module_call(module, function, _args, level, location, acc) do
    if elixir_module?(module) do
      check_remote_call(module, function, level, location, acc)
    else
      check_erlang_call(module, function, level, location, acc)
    end
  end

  # apply/3 is dynamic dispatch by construction. Below :full it is rejected
  # outright (a direct call expresses the same thing and can be verified);
  # `apply(__MODULE__, f, a)` is exempt because the target is the module
  # being validated. At :full and above a literal target is checked exactly
  # like the equivalent direct call, so `apply(:os, :cmd, ...)` and
  # `Kernel.apply(Code, :eval_string, ...)` can no longer slip past.
  defp check_apply(module_arg, function_arg, args, level, location, acc) do
    case resolve_module(module_arg) do
      :self ->
        acc

      _ when level in @restrictive_levels ->
        check_dynamic_dispatch(level, location, "apply/3", acc)

      {:module, Kernel} ->
        # apply(Kernel, :apply, [...]) / apply(Kernel, :spawn, [...]) — the
        # real target is nested inside a runtime list and cannot be verified.
        acc

      {:module, module} when is_atom(function_arg) ->
        check_module_call(module, function_arg, list_args(args), level, location, acc)

      {:module, module} ->
        check_module_call(module, :__dynamic__, [], level, location, acc)

      :dynamic ->
        acc
    end
  end

  defp list_args(args) when is_list(args), do: args
  defp list_args(_), do: []

  # spawn/3 is process creation plus dynamic dispatch; below :full it is
  # rejected (H9). At :full and above a literal target is checked like the
  # equivalent direct call.
  defp check_spawn(spawn_fn, [module_arg, function_arg, args], level, location, acc) do
    case resolve_module(module_arg) do
      :self ->
        acc

      _ when level in @restrictive_levels ->
        check_dynamic_dispatch(level, location, "#{spawn_fn}/3", acc)

      {:module, module} when is_atom(function_arg) ->
        acc = check_spawn_target(module, location, acc)
        check_module_call(module, function_arg, list_args(args), level, location, acc)

      {:module, module} ->
        check_spawn_target(module, location, acc)

      :dynamic ->
        acc
    end
  end

  defp check_spawn(spawn_fn, [_fun | _], level, location, acc) do
    # spawn(fn -> ... end) / spawn(&f/0): the spawned code is in-sandbox, but
    # at a restrictive level process creation itself is not permitted (H9).
    check_dynamic_dispatch(level, location, "#{spawn_fn} with anonymous function", acc)
  end

  defp check_spawn(_spawn_fn, _args, _level, _location, acc), do: acc

  defp check_spawn_target(module, location, acc) do
    if module in @never_allowed_modules do
      [
        make_violation(
          :forbidden_module,
          location,
          "Spawning with #{inspect(module)} is never allowed"
        )
        | acc
      ]
    else
      acc
    end
  end

  # ── Directives ──

  defp check_directive(directive, target, level, location, acc) do
    for module <- directive_targets(target), reduce: acc do
      acc -> check_directive_module(directive, module, level, location, acc)
    end
  end

  # alias Foo.{Bar, Baz}
  defp directive_targets({{:., _, [base, :{}]}, _, subs}) when is_list(subs) do
    case resolve_module(base) do
      {:module, base_module} ->
        Enum.map(subs, fn sub ->
          case resolve_module(sub) do
            {:module, sub_module} -> Module.concat([base_module, sub_module])
            _ -> :__dynamic__
          end
        end)

      _ ->
        [:__dynamic__]
    end
  end

  defp directive_targets(target) do
    case resolve_module(target) do
      {:module, module} -> [module]
      :self -> []
      :dynamic -> [:__dynamic__]
    end
  end

  defp check_directive_module(directive, :__dynamic__, level, location, acc) do
    check_dynamic_dispatch(level, location, "#{directive} with dynamic target", acc)
  end

  defp check_directive_module(directive, module, level, location, acc) do
    cond do
      module in @never_allowed_modules ->
        [
          make_violation(
            :forbidden_module,
            location,
            "#{directive} of #{inspect(module)} is never allowed"
          )
          | acc
        ]

      not restrictive_level?(level) ->
        acc

      not directive_module_allowed?(module, level) ->
        [
          make_violation(
            :forbidden_module,
            location,
            "#{directive} of #{inspect(module)} not allowed at #{level} level"
          )
          | acc
        ]

      directive in [:import, :alias] and module in @function_restricted_modules ->
        [
          make_violation(
            :forbidden_module,
            location,
            "#{directive} of #{inspect(module)} not allowed at #{level} level — " <>
              "its calls could no longer be attributed to #{inspect(module)}"
          )
          | acc
        ]

      true ->
        acc
    end
  end

  defp directive_module_allowed?(module, level) do
    if elixir_module?(module) do
      module_allowed?(module, level)
    else
      erlang_module_allowed?(module)
    end
  end

  # ── Elixir module calls ──

  defp check_remote_call(module, function, level, location, acc) do
    cond do
      module in @never_allowed_modules ->
        [
          make_violation(
            :forbidden_module,
            location,
            "Module #{inspect(module)} is never allowed"
          )
          | acc
        ]

      {module, function} in @never_allowed_functions ->
        [
          make_violation(
            :dangerous_call,
            location,
            "#{inspect(module)}.#{function} is never allowed"
          )
          | acc
        ]

      level == :hot_load and
          (module in @hot_load_denied_modules or {module, function} in @hot_load_denied_functions) ->
        [
          make_violation(
            :level_restricted,
            location,
            "#{inspect(module)}.#{function} not allowed at :hot_load level — " <>
              "no OS processes, code loading or cluster access in hot-loaded code"
          )
          | acc
        ]

      restrictive_level?(level) and {module, function} in @restricted_dynamic_functions ->
        [
          make_violation(
            :level_restricted,
            location,
            "#{inspect(module)}.#{function} requires :full level or higher"
          )
          | acc
        ]

      {module, function} in @limited_functions and level in [:pure, :strict] ->
        [
          make_violation(
            :level_restricted,
            location,
            "#{inspect(module)}.#{function} requires :limited level or higher"
          )
          | acc
        ]

      module in @network_modules and level in [:pure, :strict] ->
        [
          make_violation(
            :level_restricted,
            location,
            "Network module #{inspect(module)} requires :limited level or higher"
          )
          | acc
        ]

      not module_allowed?(module, level) ->
        [
          make_violation(
            :forbidden_module,
            location,
            "Module #{inspect(module)} not allowed at #{level} level"
          )
          | acc
        ]

      true ->
        acc
    end
  end

  # ── Erlang module calls ──

  defp check_erlang_call(module, function, level, location, acc) do
    cond do
      module in @never_allowed_modules ->
        [
          make_violation(
            :forbidden_module,
            location,
            "Erlang module #{inspect(module)} is never allowed"
          )
          | acc
        ]

      {module, function} in @never_allowed_functions ->
        [
          make_violation(
            :dangerous_call,
            location,
            "#{inspect(module)}.#{function} is never allowed"
          )
          | acc
        ]

      restrictive_level?(level) and module == :erlang and erlang_function_restricted?(function) ->
        [
          make_violation(
            :dangerous_call,
            location,
            ":erlang.#{function} not allowed at #{level} level"
          )
          | acc
        ]

      {module, function} in @limited_functions and level in [:pure, :strict] ->
        [
          make_violation(
            :level_restricted,
            location,
            "#{inspect(module)}.#{function} requires :limited level or higher"
          )
          | acc
        ]

      module in @network_modules and level in [:pure, :strict] ->
        [
          make_violation(
            :level_restricted,
            location,
            "Network module #{inspect(module)} requires :limited level or higher"
          )
          | acc
        ]

      restrictive_level?(level) and not erlang_module_allowed?(module) ->
        [
          make_violation(
            :forbidden_module,
            location,
            "Erlang module #{inspect(module)} not allowed at #{level} level"
          )
          | acc
        ]

      restrictive_level?(level) and not erlang_function_allowed?(module, function) ->
        [
          make_violation(
            :level_restricted,
            location,
            "#{inspect(module)}.#{function} not allowed at #{level} level"
          )
          | acc
        ]

      true ->
        acc
    end
  end

  defp erlang_module_allowed?(:erlang), do: true

  defp erlang_module_allowed?(module),
    do: module in @erlang_allowed or allowlisted_erlang_module?(module)

  defp allowlisted_erlang_module?(module), do: Map.has_key?(@erlang_function_allowlists, module)

  defp erlang_function_allowed?(module, function) do
    case Map.fetch(@erlang_function_allowlists, module) do
      {:ok, functions} -> function in functions
      :error -> true
    end
  end

  defp erlang_function_restricted?(function) do
    function in @erlang_restricted_functions or
      Enum.any?(@erlang_restricted_prefixes, &String.starts_with?(Atom.to_string(function), &1))
  end

  # ── Dynamic dispatch / field access ──

  # H9 / F-007: Block dynamic dispatch (non-literal receivers, apply/2, dynamic
  # apply/spawn targets) at restrictive levels — the target cannot be verified
  # at compile time. At :full and above, allow it (the caller has high trust).
  defp check_dynamic_dispatch(level, location, call_form, acc) do
    if restrictive_level?(level) do
      [
        make_violation(
          :unsafe_pattern,
          location,
          "#{call_form} not allowed at #{level} level — " <>
            "target cannot be verified at compile time"
        )
        | acc
      ]
    else
      acc
    end
  end

  defp check_field_access(name, level, location, acc) do
    if restrictive_level?(level) and name in @dangerous_zero_arity do
      [
        make_violation(
          :unsafe_pattern,
          location,
          "no-parens access .#{name} on a dynamic receiver not allowed at #{level} level — " <>
            "it would invoke #{name}/0 if the receiver is a module"
        )
        | acc
      ]
    else
      acc
    end
  end

  # ── Helpers ──

  defp extract_location(meta) do
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)

    if line do
      {line, column || 0}
    else
      nil
    end
  end

  defp make_violation(type, location, description) do
    %{
      type: type,
      location: location,
      description: description
    }
  end

  defp module_allowed?(module, :pure) do
    module in @always_allowed
  end

  defp module_allowed?(module, :strict) do
    module in @always_allowed
  end

  defp module_allowed?(module, :limited) do
    module in @always_allowed or module in @limited_allowed
  end

  defp module_allowed?(module, :hot_load) do
    (module in @always_allowed or module in @limited_allowed) and
      module not in @hot_load_denied_modules
  end

  defp module_allowed?(module, :standard) do
    module in @always_allowed or module in @limited_allowed
  end

  defp module_allowed?(module, :full) do
    module not in @never_allowed_modules
  end

  defp module_allowed?(module, :permissive) do
    module not in @never_allowed_modules
  end

  defp module_allowed?(_module, :none) do
    # :none means no sandbox — allow everything
    true
  end

  defp module_allowed?(_module, :container) do
    # In container mode, code runs isolated
    true
  end

  defp module_allowed?(_module, _level) do
    false
  end
end
