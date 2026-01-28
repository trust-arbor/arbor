defmodule Arbor.AI.ShellAdapter do
  @moduledoc """
  Adapts Arbor.Shell to the System.cmd-style interface expected by CLI backends.

  The old arbor codebase used `Arbor.ShellAdapter.cmd/3` which returns
  `{output, exit_code}` like `System.cmd/3`. This module provides that
  interface on top of `Arbor.Shell.execute/2`.

  ## Usage

      {output, exit_code} = ShellAdapter.cmd("which", ["claude"])
      #=> {"/usr/local/bin/claude\\n", 0}

      {output, exit_code} = ShellAdapter.cmd("ls", ["-la"], cd: "/tmp")
      #=> {"total 0\\n...", 0}
  """

  alias Arbor.Shell

  @doc """
  Execute a command with arguments, returning `{output, exit_code}`.

  This mirrors the `System.cmd/3` interface for compatibility with
  code that expects that format.

  ## Options

  - `:stderr_to_stdout` - Merge stderr into stdout (default: false)
  - `:cd` - Working directory (mapped to Arbor.Shell's `:cwd`)
  - `:env` - Environment variables as keyword list or map
  - `:timeout` - Timeout in milliseconds (default: 30_000)
  - `:sandbox` - Sandbox level for Arbor.Shell (default: :none for CLI agents)

  ## Returns

  `{output, exit_code}` where:
  - `output` is a string (stdout, or stdout+stderr if `:stderr_to_stdout`)
  - `exit_code` is an integer (0 = success, non-zero = failure)
  """
  @spec cmd(String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def cmd(command, args, opts \\ []) do
    full_command = build_command(command, args)
    shell_opts = translate_opts(opts)

    case Shell.execute(full_command, shell_opts) do
      {:ok, result} ->
        output = build_output(result, opts)
        {output, result.exit_code}

      {:error, :timeout} ->
        {"", 124}

      {:error, :unauthorized} ->
        {"Command blocked by sandbox", 126}

      {:error, reason} ->
        {"Error: #{inspect(reason)}", 1}
    end
  end

  # Build the full command string from command and arguments
  defp build_command(command, []) do
    command
  end

  defp build_command(command, args) do
    escaped_args = Enum.map(args, &shell_escape/1)
    "#{command} #{Enum.join(escaped_args, " ")}"
  end

  # Escape argument for shell execution
  defp shell_escape(arg) do
    if needs_escaping?(arg) do
      "'" <> String.replace(arg, "'", "'\\''") <> "'"
    else
      arg
    end
  end

  defp needs_escaping?(arg) do
    String.contains?(arg, [" ", "'", "\"", "\\", "$", "`", "\n", "\t", ";", "&", "|", "<", ">"])
  end

  # Translate System.cmd options to Arbor.Shell options
  defp translate_opts(opts) do
    base = [
      # CLI agents need unrestricted shell access
      sandbox: Keyword.get(opts, :sandbox, :none),
      timeout: Keyword.get(opts, :timeout, 30_000)
    ]

    base
    |> maybe_add_cwd(opts)
    |> maybe_add_env(opts)
  end

  defp maybe_add_cwd(shell_opts, opts) do
    case Keyword.get(opts, :cd) do
      nil -> shell_opts
      cwd -> Keyword.put(shell_opts, :cwd, cwd)
    end
  end

  defp maybe_add_env(shell_opts, opts) do
    case Keyword.get(opts, :env) do
      nil ->
        shell_opts

      env when is_list(env) ->
        # Convert keyword list to map of strings
        env_map = Map.new(env, fn {k, v} -> {to_string(k), to_string(v)} end)
        Keyword.put(shell_opts, :env, env_map)

      env when is_map(env) ->
        Keyword.put(shell_opts, :env, env)
    end
  end

  # Build output string from result
  defp build_output(result, opts) do
    if Keyword.get(opts, :stderr_to_stdout, false) do
      # Combine stdout and stderr
      stdout = result.stdout || ""
      stderr = Map.get(result, :stderr, "")

      if stderr != "" do
        stdout <> stderr
      else
        stdout
      end
    else
      result.stdout || ""
    end
  end
end
