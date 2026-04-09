defmodule Arbor.Common.CommandRouter do
  @moduledoc """
  Parses and routes slash commands from agent chat input.

  Commands are discovered at startup from modules implementing
  `Arbor.Common.Command`. The router caches the lookup table in
  a persistent_term for fast dispatch.

  ## Parse Rules

  - Input starting with `/` followed by a word character is a command
  - `/` alone or `/ text` (space after slash) passes through as a prompt
  - Arguments are everything after the command name, trimmed
  - Unknown commands return an error with suggestions

  ## Usage

  Most callers should use `Arbor.Common.CommandIntake.handle/3` instead of
  calling `parse/1` and `execute/3` directly. The intake helper centralizes
  the parse → dispatch → fallback flow that every entry point needs.

      case CommandRouter.parse(input) do
        {:command, name, args} ->
          CommandRouter.execute(name, args, context)

        {:prompt, text} ->
          # send to LLM as normal
      end

  ## Context and Result

  As of the 2026-04-09 CRC refactor, `execute/3` takes a typed
  `Arbor.Contracts.Commands.Context` struct and returns
  `{:ok, %Arbor.Contracts.Commands.Result{}}`. Commands are pure — they
  never perform side effects. If a command needs the caller to do
  something, the Result carries an `:action` field describing it; the
  caller dispatches the action.
  """

  alias Arbor.Contracts.Commands.{Context, Result}

  @behaviour_mod Arbor.Common.Command

  # Built-in command modules — always included in discovery.
  # Additional modules found via :code.all_loaded() scan.
  @builtin_commands [
    Arbor.Common.Commands.Help,
    Arbor.Common.Commands.Status,
    Arbor.Common.Commands.Model,
    Arbor.Common.Commands.Compact,
    Arbor.Common.Commands.Clear,
    Arbor.Common.Commands.Tools,
    Arbor.Common.Commands.Session,
    Arbor.Common.Commands.Trust,
    Arbor.Common.Commands.Memory
  ]

  @doc """
  Parse user input into a command or prompt.

  Returns `{:command, name, args}` or `{:prompt, text}`.
  """
  @spec parse(String.t()) :: {:command, String.t(), String.t()} | {:prompt, String.t()}
  def parse("/" <> rest) do
    # Slash must be immediately followed by a word character (no space)
    if rest == "" or String.starts_with?(rest, " ") do
      {:prompt, "/" <> rest}
    else
      case String.split(rest, ~r/\s+/, parts: 2) do
        [name] ->
          if Regex.match?(~r/^\w/, name) do
            {:command, String.downcase(name), ""}
          else
            {:prompt, "/" <> rest}
          end

        [name, args] ->
          if Regex.match?(~r/^\w/, name) do
            {:command, String.downcase(name), String.trim(args)}
          else
            {:prompt, "/" <> rest}
          end
      end
    end
  end

  def parse(input), do: {:prompt, input}

  @doc """
  Execute a named command with arguments and a typed Context.

  Returns `{:ok, %Result{}}` for both display-only and action commands
  (action commands carry their action description in `result.action`).
  Returns `{:error, term}` for unknown commands, unavailable commands, or
  infrastructure failures during command execution.
  """
  @spec execute(String.t(), String.t(), Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  def execute(name, args, %Context{} = context) do
    commands = command_map()

    case Map.get(commands, name) do
      nil ->
        suggestion = suggest_command(name, Map.keys(commands))
        msg = "Unknown command: /#{name}" <> if(suggestion, do: ". Did you mean /#{suggestion}?", else: "")
        {:error, {:unknown_command, msg}}

      module ->
        if module.available?(context) do
          module.execute(args, context)
        else
          {:error, {:unavailable, "Command /#{name} is not available in this context."}}
        end
    end
  rescue
    e ->
      {:error, {:command_error, Exception.message(e)}}
  end

  @doc """
  List all registered commands, filtered by availability against the given Context.

  Returns a list of `{name, description, usage}` tuples sorted by name.
  """
  @spec list_commands(Context.t()) :: [{String.t(), String.t(), String.t()}]
  def list_commands(%Context{} = context) do
    command_modules()
    |> Enum.filter(& &1.available?(context))
    |> Enum.map(&{&1.name(), &1.description(), &1.usage()})
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  Return the set of registered command modules.
  """
  @spec command_modules() :: [module()]
  def command_modules do
    case :persistent_term.get({__MODULE__, :modules}, :not_loaded) do
      :not_loaded ->
        modules = discover_commands()
        :persistent_term.put({__MODULE__, :modules}, modules)
        modules

      modules ->
        modules
    end
  end

  @doc """
  Force re-discovery of command modules. Call after loading new commands.
  """
  @spec refresh() :: :ok
  def refresh do
    modules = discover_commands()
    :persistent_term.put({__MODULE__, :modules}, modules)
    :persistent_term.put({__MODULE__, :map}, build_map(modules))
    :ok
  end

  @doc """
  Return the name → module lookup map. Used by Help command.
  """
  @spec command_map_public() :: %{String.t() => module()}
  def command_map_public, do: command_map()

  # -- Private --

  defp command_map do
    case :persistent_term.get({__MODULE__, :map}, :not_loaded) do
      :not_loaded ->
        modules = command_modules()
        map = build_map(modules)
        :persistent_term.put({__MODULE__, :map}, map)
        map

      map ->
        map
    end
  end

  defp build_map(modules) do
    Enum.reduce(modules, %{}, fn mod, acc ->
      # Primary name
      acc = Map.put(acc, mod.name(), mod)

      # Aliases
      aliases =
        if function_exported?(mod, :aliases, 0) do
          mod.aliases()
        else
          []
        end

      Enum.reduce(aliases, acc, fn a, inner -> Map.put(inner, a, mod) end)
    end)
  end

  defp discover_commands do
    # Start with built-in commands, then scan loaded modules for extras
    dynamic =
      :code.all_loaded()
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&implements_command?/1)

    (@builtin_commands ++ dynamic)
    |> Enum.uniq()
    |> Enum.filter(&Code.ensure_loaded?/1)
  end

  defp implements_command?(module) do
    behaviours =
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    @behaviour_mod in behaviours
  rescue
    _ -> false
  end

  defp suggest_command(input, known) do
    known
    |> Enum.map(&{&1, String.jaro_distance(input, &1)})
    |> Enum.filter(fn {_, score} -> score > 0.7 end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> case do
      [{name, _} | _] -> name
      [] -> nil
    end
  end
end
