defmodule Arbor.Sandbox.Code do
  @moduledoc """
  Code sandbox for AST-level validation.

  Validates Elixir code to ensure it doesn't use dangerous modules or functions
  based on sandbox level or trust tier. This is a compile-time safety check
  that runs before code is evaluated.

  ## Validation Levels

  | Level | Description |
  |-------|-------------|
  | `:pure` | Kernel + safe stdlib only |
  | `:limited` | + File, IO, Process, etc. |
  | `:full` | All except dangerous |
  | `:container` | No restrictions (isolated) |

  ## Trust Tier Integration

  Use `validate_for_tier/2` to validate against a trust tier directly.
  The tier is mapped to a sandbox level via `TrustBounds.sandbox_for_tier/1`.

  ## Dangerous Patterns

  Some patterns are blocked at all levels:

  - `Code.eval_string/1,2,3` — Dynamic code evaluation
  - `:erlang.halt/0,1` — VM termination
  - `File.rm_rf!/1` — Recursive delete (non-recoverable)
  - `System.halt/0,1` — VM termination

  Others are restricted by level:

  - `System.cmd/2,3` — Requires `:limited` or higher
  - `Port.open/2` — Requires `:limited` or higher
  - Network modules — Requires `:limited` or higher
  """

  alias Arbor.Contracts.Security.TrustBounds

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

  # Functions restricted by level (allowed at :limited+)
  @limited_functions [
    {System, :cmd},
    {System, :shell},
    {Port, :open},
    {Port, :command},
    {:os, :cmd}
  ]

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
  Validate code against a trust tier.

  Maps the trust tier to a sandbox level using TrustBounds, then validates.

  ## Examples

      iex> ast = quote do: File.read!("test.txt")
      iex> Arbor.Sandbox.Code.validate_for_tier(ast, :trusted)
      :ok

      iex> ast = quote do: Code.eval_string("1 + 1")
      iex> Arbor.Sandbox.Code.validate_for_tier(ast, :autonomous)
      {:error, {:code_violations, [%{type: :dangerous_call, ...}]}}
  """
  @spec validate_for_tier(Macro.t(), TrustBounds.trust_tier()) ::
          :ok | {:error, {:code_violations, [violation()]}}
  def validate_for_tier(ast, tier) do
    level = TrustBounds.sandbox_for_tier(tier)
    validate(ast, level)
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
  Check if a module is allowed for a trust tier.
  """
  @spec check_module_for_tier(module(), TrustBounds.trust_tier()) ::
          :ok | {:error, :module_not_allowed}
  def check_module_for_tier(module, tier) do
    level = TrustBounds.sandbox_for_tier(tier)
    check_module(module, level)
  end

  @doc """
  Get allowed modules for a sandbox level.
  """
  @spec allowed_modules(atom()) :: [module()]
  def allowed_modules(:pure), do: @always_allowed
  def allowed_modules(:limited), do: @always_allowed ++ @limited_allowed
  def allowed_modules(:full), do: @always_allowed ++ @limited_allowed
  def allowed_modules(:standard), do: @always_allowed ++ @limited_allowed
  def allowed_modules(:permissive), do: @always_allowed ++ @limited_allowed
  def allowed_modules(:strict), do: @always_allowed
  def allowed_modules(:none), do: :all
  def allowed_modules(_), do: @always_allowed

  @doc """
  Get restricted functions for a sandbox level.

  Returns the list of {module, function} tuples that are blocked at this level.
  """
  @spec restricted_functions(atom()) :: [{module(), atom()}]
  def restricted_functions(:pure), do: @never_allowed_functions ++ @limited_functions
  def restricted_functions(:strict), do: @never_allowed_functions ++ @limited_functions
  def restricted_functions(:limited), do: @never_allowed_functions
  def restricted_functions(:standard), do: @never_allowed_functions
  def restricted_functions(:full), do: @never_allowed_functions
  def restricted_functions(:permissive), do: @never_allowed_functions
  def restricted_functions(:none), do: @never_allowed_functions
  def restricted_functions(_), do: @never_allowed_functions ++ @limited_functions

  # ── Private Functions ──

  defp walk_ast(ast, level, violations) do
    {_, violations} =
      Macro.prewalk(ast, violations, fn
        # Remote function call: Module.function(args)
        {{:., meta, [{:__aliases__, _, module_parts}, function]}, _, _args} = node, acc ->
          module = Module.concat(module_parts)
          location = extract_location(meta)
          {node, check_remote_call(module, function, level, location, acc)}

        # Erlang module call: :module.function(args)
        {{:., meta, [module, function]}, _, _args} = node, acc when is_atom(module) ->
          location = extract_location(meta)
          {node, check_erlang_call(module, function, level, location, acc)}

        # Apply calls with literal module
        {:apply, meta, [module, function, _args]} = node, acc when is_atom(module) ->
          location = extract_location(meta)
          {node, check_apply_call(module, function, level, location, acc)}

        # H9: Apply calls with variable/dynamic module — can't verify target at compile time
        {:apply, meta, [_dynamic_module, _function, _args]} = node, acc ->
          location = extract_location(meta)
          {node, check_dynamic_dispatch(level, location, "apply/3", acc)}

        # H9: Kernel.apply/3 with variable module
        {{:., meta, [{:__aliases__, _, [:Kernel]}, :apply]}, _, [_dynamic_module, _function, _args]} =
            node,
        acc ->
          location = extract_location(meta)
          {node, check_dynamic_dispatch(level, location, "Kernel.apply/3", acc)}

        # spawn/spawn_link with MFA (literal module)
        {spawn_fn, meta, [module | _]} = node, acc
        when spawn_fn in [:spawn, :spawn_link, :spawn_monitor] and is_atom(module) ->
          location = extract_location(meta)
          {node, check_spawn_call(module, location, acc)}

        # H9: spawn/spawn_link with variable module
        {spawn_fn, meta, [_dynamic_module | _]} = node, acc
        when spawn_fn in [:spawn, :spawn_link, :spawn_monitor] ->
          location = extract_location(meta)
          {node, check_dynamic_dispatch(level, location, "#{spawn_fn} with dynamic module", acc)}

        node, acc ->
          {node, acc}
      end)

    violations
  end

  defp extract_location(meta) do
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)

    if line do
      {line, column || 0}
    else
      nil
    end
  end

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

      true ->
        acc
    end
  end

  defp check_apply_call(module, function, _level, location, acc) do
    cond do
      module in @never_allowed_modules ->
        [
          make_violation(
            :forbidden_module,
            location,
            "Apply to #{inspect(module)} is never allowed"
          )
          | acc
        ]

      {module, function} in @never_allowed_functions ->
        [
          make_violation(
            :dangerous_call,
            location,
            "Apply #{inspect(module)}.#{function} is never allowed"
          )
          | acc
        ]

      true ->
        acc
    end
  end

  # H9: Block dynamic dispatch (variable modules in apply/spawn) at restrictive levels.
  # At :pure/:strict/:limited we can't verify the target module, so block it.
  # At :full and above, allow it (the caller has high trust).
  defp check_dynamic_dispatch(level, location, call_form, acc)
       when level in [:pure, :strict, :limited] do
    [
      make_violation(
        :unsafe_pattern,
        location,
        "#{call_form} with dynamic module not allowed at #{level} level — " <>
          "target module cannot be verified at compile time"
      )
      | acc
    ]
  end

  defp check_dynamic_dispatch(_level, _location, _call_form, acc), do: acc

  defp check_spawn_call(module, location, acc) do
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
