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

  @type level :: :none | :basic | :strict | :container

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

  # Dangerous flags blocked at :basic level
  @dangerous_flags ~w[
    -rf --recursive --force
    --no-preserve-root
    -f
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
  """
  @spec check(String.t(), level()) :: {:ok, :allowed} | {:error, term()}
  def check(_command, :none), do: {:ok, :allowed}

  def check(command, :basic) do
    with :ok <- check_metacharacters(command) do
      {cmd, args} = parse_command(command)

      cond do
        cmd in @dangerous_commands ->
          {:error, {:blocked_command, cmd}}

        has_dangerous_flags?(args) ->
          {:error, {:dangerous_flags, find_dangerous_flags(args)}}

        true ->
          {:ok, :allowed}
      end
    end
  end

  def check(command, :strict) do
    with :ok <- check_metacharacters(command) do
      {cmd, _args} = parse_command(command)

      if cmd in @strict_allowlist do
        {:ok, :allowed}
      else
        {:error, {:not_in_allowlist, cmd}}
      end
    end
  end

  def check(_command, :container) do
    # Container mode would delegate to container execution
    # For now, treat as :basic until container support is added
    {:error, :container_not_implemented}
  end

  @doc """
  Parse a command string into executable and arguments list.

  Used by the executor to split commands for `{:spawn_executable, path}`.
  Returns `{executable, [arg1, arg2, ...]}`.
  """
  @spec parse_command(String.t()) :: {String.t(), [String.t()]}
  def parse_command(command) do
    parts = String.split(command, ~r/\s+/, parts: 2)

    case parts do
      [cmd] -> {cmd, []}
      [cmd, rest] -> {cmd, String.split(rest)}
    end
  end

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
