defmodule Arbor.Shell.Sandbox do
  @moduledoc """
  Sandbox configuration for shell command execution.

  Defines allowed/blocked commands and flags for each sandbox level.

  ## Sandbox Levels

  - `:none` - No restrictions, use with caution
  - `:basic` - Blocks dangerous commands (rm -rf, sudo, etc.)
  - `:strict` - Allowlist only, very limited commands
  - `:container` - Execute in isolated container (future)

  ## Shell Metacharacter Protection

  At `:basic` and `:strict` levels, commands containing shell metacharacters
  are rejected to prevent command injection via chaining (`;`, `&&`, `||`),
  subshells (`$()`, backticks), pipes (`|`), or redirections (`>`, `<`).
  """

  # The recognized sandbox levels. An UNrecognized level (e.g. the trust-tier
  # vocabulary's :standard/:permissive, which this module doesn't define) is
  # tolerated by check/2 + config/1 — it degrades to the most restrictive level
  # (:strict) rather than raising. See the finish-retiring-trust-tiers roadmap item.
  @type level :: :none | :basic | :strict | :container

  require Logger

  # Shell metacharacters that enable command injection
  @shell_metacharacters [";", "&&", "||", "|", "`", "$(", ">", "<", "\n", "\r"]

  # Commands blocked at :basic level
  @dangerous_commands ~w[
    sudo su chmod chown rm rmdir mkfs fdisk dd
    shutdown reboot halt poweroff init systemctl
    iptables ufw firewall-cmd
    kill killall pkill
    passwd useradd userdel usermod groupadd groupdel
    mount umount
    nc netcat ncat curl wget
  ]

  # Interpreters / exec-wrappers blocked at :basic level.
  # SECURITY (codex sandbox.shell-basic-nested-command-bypass): the :basic
  # denylist only inspects the TOP-LEVEL command. These programs run an
  # ARBITRARY nested command supplied as an argument — `sh -c "rm -rf /"`,
  # `xargs rm`, `env rm`, `python -c "..."`, `perl -e "..."` — which trivially
  # defeats the top-level check (the dangerous command rides as an opaque arg).
  # Block the wrappers themselves at :basic; trusted arbitrary execution must
  # use the :none level (the documented escape hatch).
  @interpreter_commands ~w[
    sh bash zsh ksh dash csh tcsh fish ash
    env eval exec command nohup nice timeout watch stdbuf setsid xargs
    python python2 python3 perl ruby node nodejs php lua tclsh
    awk gawk
  ]

  # Dangerous flags blocked at :basic level
  @dangerous_flags ~w[
    -rf --recursive --force
    --no-preserve-root
    -f
    -exec -execdir
  ]

  # Commands allowed at :strict level — read-only utilities only
  # M8: Removed language runtimes (mix, elixir, erl, node, npm, npx, python, pip)
  # and write-capable tools (sed -i, awk system(), git push/fetch)
  @strict_allowlist ~w[
    ls cat head tail less more
    echo printf
    grep rg
    find fd
    wc sort uniq tr cut
    date cal
    pwd
    file stat
    diff comm
  ]

  @doc """
  Check if a command is allowed under the given sandbox level.

  Returns `{:ok, :allowed}` or `{:error, reason}`.

  ## Options

  - `:allowlist` — a capability-derived command allowlist
    (`Arbor.Shell.CapPolicy.allowlist/0`: `:all | {:commands, MapSet}`). When
    present (the agent path), the COMMAND check uses this allowlist instead of
    the level's hardcoded list, so the sandbox agrees with the capability grant
    rather than conflicting with it. The safety floor (metacharacters +
    dangerous-command/interpreter/flag blocking) is ALWAYS applied on top — a
    capability grant lets an agent run a command, but never escape it via
    metacharacters or use the dangerous-command/interpreter floor. `:none` still
    bypasses entirely (the capability gate already authorized the command).
    When absent (system callers), the level-based behavior is unchanged.
  """
  @spec check(String.t(), level(), keyword()) :: {:ok, :allowed} | {:error, term()}
  def check(command, level, opts \\ [])

  def check(_command, :none, _opts), do: {:ok, :allowed}

  def check(command, level, opts) do
    case Keyword.get(opts, :allowlist) do
      nil -> check_by_level(command, level)
      allowlist -> check_with_allowlist(command, allowlist)
    end
  end

  # Capability-derived path: the command must be in the agent's cap-derived
  # allowlist AND clear the always-on safety floor. The allowlist replaces the
  # hardcoded @strict_allowlist; the floor (@dangerous_commands /
  # @interpreter_commands / @dangerous_flags + metacharacters) is the absolute
  # safety boundary a capability grant does NOT override.
  defp check_with_allowlist(command, allowlist) do
    with :ok <- check_metacharacters(command) do
      {cmd, args} = parse_command(command)

      cond do
        not Arbor.Shell.CapPolicy.allows?(allowlist, cmd) ->
          {:error, {:not_in_allowlist, cmd}}

        cmd in @dangerous_commands ->
          {:error, {:blocked_command, cmd}}

        Path.basename(cmd) in @interpreter_commands ->
          {:error, {:blocked_interpreter, cmd}}

        has_dangerous_flags?(args) ->
          {:error, {:dangerous_flags, find_dangerous_flags(args)}}

        true ->
          {:ok, :allowed}
      end
    end
  end

  defp check_by_level(command, :basic) do
    with :ok <- check_metacharacters(command) do
      {cmd, args} = parse_command(command)

      cond do
        cmd in @dangerous_commands ->
          {:error, {:blocked_command, cmd}}

        Path.basename(cmd) in @interpreter_commands ->
          # Match on basename so /bin/sh, /usr/bin/env, etc. are caught too.
          {:error, {:blocked_interpreter, cmd}}

        has_dangerous_flags?(args) ->
          {:error, {:dangerous_flags, find_dangerous_flags(args)}}

        true ->
          {:ok, :allowed}
      end
    end
  end

  defp check_by_level(command, :strict) do
    with :ok <- check_metacharacters(command) do
      {cmd, _args} = parse_command(command)

      if cmd in @strict_allowlist do
        {:ok, :allowed}
      else
        {:error, {:not_in_allowlist, cmd}}
      end
    end
  end

  defp check_by_level(_command, :container) do
    # Container mode would delegate to container execution
    # For now, treat as :basic until container support is added
    {:error, :container_not_implemented}
  end

  # Fail-safe: an unrecognized level degrades to the most restrictive recognized
  # one (:strict) instead of raising. Callers may feed sandbox levels in a
  # vocabulary this module doesn't share (:standard/:permissive), which would
  # otherwise crash shell execution with a FunctionClauseError. Degrade DOWN
  # only — never widen.
  defp check_by_level(command, level) do
    Logger.warning(
      "[Shell.Sandbox] unrecognized sandbox level #{inspect(level)} — degrading to :strict"
    )

    check_by_level(command, :strict)
  end

  @doc """
  Parse a command string into executable and arguments list.

  Used by the executor to split commands for `{:spawn_executable, path}`.
  Respects single and double quoting so that e.g. `sh -c 'echo hello'`
  produces `{"sh", ["-c", "echo hello"]}`.

  Returns `{executable, [arg1, arg2, ...]}`.
  """
  @spec parse_command(String.t()) :: {String.t(), [String.t()]}
  def parse_command(command) do
    args = shell_split(String.trim(command))

    case args do
      [] -> {"", []}
      [cmd] -> {cmd, []}
      [cmd | rest] -> {cmd, rest}
    end
  end

  # Simple shell-style argument splitting that respects single and double quotes.
  defp shell_split(str), do: shell_split(str, [], [])

  defp shell_split(<<>>, current, acc) do
    case current do
      [] -> Enum.reverse(acc)
      _ -> Enum.reverse([IO.iodata_to_binary(Enum.reverse(current)) | acc])
    end
  end

  defp shell_split(<<"'", rest::binary>>, current, acc) do
    {content, remaining} = consume_until(rest, ?')
    shell_split(remaining, [content | current], acc)
  end

  defp shell_split(<<"\"", rest::binary>>, current, acc) do
    {content, remaining} = consume_until(rest, ?")
    shell_split(remaining, [content | current], acc)
  end

  defp shell_split(<<c, rest::binary>>, current, acc) when c in ~c[ \t] do
    case current do
      [] -> shell_split(rest, [], acc)
      _ -> shell_split(rest, [], [IO.iodata_to_binary(Enum.reverse(current)) | acc])
    end
  end

  defp shell_split(<<c, rest::binary>>, current, acc) do
    shell_split(rest, [<<c>> | current], acc)
  end

  defp consume_until(str, quote_char), do: consume_until(str, quote_char, [])

  defp consume_until(<<>>, _quote_char, acc),
    do: {IO.iodata_to_binary(Enum.reverse(acc)), <<>>}

  defp consume_until(<<c, rest::binary>>, quote_char, acc) when c == quote_char,
    do: {IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp consume_until(<<c, rest::binary>>, quote_char, acc),
    do: consume_until(rest, quote_char, [<<c>> | acc])

  @doc """
  Resolve a command name to its full executable path.

  Uses `System.find_executable/1` to locate the binary.
  Returns `{:ok, path}` or `{:error, :executable_not_found}`.
  """
  @spec resolve_executable(String.t()) :: {:ok, String.t()} | {:error, :executable_not_found}
  def resolve_executable(cmd) do
    case System.find_executable(cmd) do
      nil -> {:error, :executable_not_found}
      path -> {:ok, path}
    end
  end

  @doc """
  Get the configuration for a sandbox level.
  """
  @spec config(level()) :: map()
  def config(:none) do
    %{
      level: :none,
      restrictions: :none,
      blocked_commands: [],
      blocked_flags: [],
      allowlist: nil
    }
  end

  def config(:basic) do
    %{
      level: :basic,
      restrictions: :blocklist,
      blocked_commands: @dangerous_commands,
      blocked_flags: @dangerous_flags,
      allowlist: nil
    }
  end

  def config(:strict) do
    %{
      level: :strict,
      restrictions: :allowlist,
      blocked_commands: [],
      blocked_flags: [],
      allowlist: @strict_allowlist
    }
  end

  def config(:container) do
    %{
      level: :container,
      restrictions: :container,
      blocked_commands: [],
      blocked_flags: [],
      allowlist: nil
    }
  end

  # Fail-safe: an unrecognized level uses the most restrictive recognized config
  # (:strict) instead of raising. (Mirrors check/2 — see its comment.)
  def config(level) do
    Logger.warning(
      "[Shell.Sandbox] unrecognized sandbox level #{inspect(level)} — using :strict config"
    )

    config(:strict)
  end

  # Private functions

  defp check_metacharacters(command) do
    found =
      Enum.filter(@shell_metacharacters, fn meta ->
        String.contains?(command, meta)
      end)

    case found do
      [] -> :ok
      chars -> {:error, {:shell_metacharacters, chars}}
    end
  end

  defp has_dangerous_flags?(args) do
    Enum.any?(args, &(&1 in @dangerous_flags))
  end

  defp find_dangerous_flags(args) do
    Enum.filter(args, &(&1 in @dangerous_flags))
  end
end
