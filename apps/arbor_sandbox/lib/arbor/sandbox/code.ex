defmodule Arbor.Sandbox.Code do
  @moduledoc """
  Code sandbox for AST-level validation.

  Validates Elixir code to ensure it doesn't use
  dangerous modules or functions based on sandbox level.
  """

  # Modules always allowed
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
    Agent,
    Task
  ]

  # Modules only allowed at :limited and above
  @limited_allowed [
    File,
    Path,
    IO,
    System,
    Process,
    GenServer,
    Supervisor,
    Application,
    Code,
    Module,
    Macro,
    ETS,
    Logger
  ]

  # Dangerous modules/functions never allowed
  @never_allowed_modules [
    :os,
    :erlang
  ]

  @never_allowed_functions [
    {System, :cmd},
    {System, :shell},
    {:os, :cmd},
    {Code, :eval_string},
    {Code, :eval_quoted},
    {Code, :eval_file},
    {Kernel, :send},
    {Process, :exit},
    {Application, :stop},
    {Application, :unload}
  ]

  @doc """
  Validate an AST at the given sandbox level.
  """
  @spec validate(Macro.t(), atom()) :: :ok | {:error, term()}
  def validate(ast, level) do
    case walk_ast(ast, level, []) do
      [] -> :ok
      violations -> {:error, {:code_violations, violations}}
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
  def allowed_modules(:full), do: @always_allowed ++ @limited_allowed
  def allowed_modules(_), do: @always_allowed

  # Private functions

  defp walk_ast(ast, level, violations) do
    {_, violations} =
      Macro.prewalk(ast, violations, fn
        # Remote function call: Module.function(args)
        {{:., _, [{:__aliases__, _, module_parts}, function]}, _, _args} = node, acc ->
          module = Module.concat(module_parts)
          {node, check_remote_call(module, function, level, acc)}

        # Erlang module call: :module.function(args)
        {{:., _, [module, function]}, _, _args} = node, acc when is_atom(module) ->
          {node, check_erlang_call(module, function, acc)}

        # Apply calls
        {:apply, _, [module, _function, _args]} = node, acc when is_atom(module) ->
          {node, check_apply_call(module, acc)}

        # spawn/spawn_link with MFA
        {spawn_fn, _, [module | _]} = node, acc
        when spawn_fn in [:spawn, :spawn_link, :spawn_monitor] and is_atom(module) ->
          {node, check_spawn_call(module, acc)}

        node, acc ->
          {node, acc}
      end)

    violations
  end

  defp check_remote_call(module, function, level, acc) do
    cond do
      module in @never_allowed_modules ->
        [{:forbidden_module, module} | acc]

      {module, function} in @never_allowed_functions ->
        [{:forbidden_function, {module, function}} | acc]

      not module_allowed?(module, level) ->
        [{:module_not_allowed, module, level} | acc]

      true ->
        acc
    end
  end

  defp check_erlang_call(module, function, acc) do
    cond do
      module in @never_allowed_modules ->
        [{:forbidden_module, module} | acc]

      {module, function} in @never_allowed_functions ->
        [{:forbidden_function, {module, function}} | acc]

      true ->
        acc
    end
  end

  defp check_apply_call(module, acc) do
    if module in @never_allowed_modules do
      [{:forbidden_module, module} | acc]
    else
      acc
    end
  end

  defp check_spawn_call(module, acc) do
    if module in @never_allowed_modules do
      [{:forbidden_spawn, module} | acc]
    else
      acc
    end
  end

  defp module_allowed?(module, :pure) do
    module in @always_allowed
  end

  defp module_allowed?(module, :limited) do
    module in @always_allowed or module in @limited_allowed
  end

  defp module_allowed?(module, :full) do
    module not in @never_allowed_modules
  end

  defp module_allowed?(_module, :container) do
    # In container mode, code runs isolated
    true
  end

  defp module_allowed?(_module, _level) do
    false
  end
end
