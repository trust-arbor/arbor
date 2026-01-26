defmodule Arbor.Shell.Sandbox do
  @moduledoc """
  Sandbox configuration for shell command execution.

  Defines allowed/blocked commands and flags for each sandbox level.

  ## Sandbox Levels

  - `:none` - No restrictions, use with caution
  - `:basic` - Blocks dangerous commands (rm -rf, sudo, etc.)
  - `:strict` - Allowlist only, very limited commands
  - `:container` - Execute in isolated container (future)
  """

  @type level :: :none | :basic | :strict | :container

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

  # Commands allowed at :strict level
  @strict_allowlist ~w[
    ls cat head tail less more
    echo printf
    grep rg awk sed
    find fd
    wc sort uniq tr cut
    date cal
    pwd cd
    file stat
    diff comm
    git
    mix elixir erl
    node npm npx
    python python3 pip
  ]

  @doc """
  Check if a command is allowed under the given sandbox level.

  Returns `{:ok, :allowed}` or `{:error, reason}`.
  """
  @spec check(String.t(), level()) :: {:ok, :allowed} | {:error, term()}
  def check(_command, :none), do: {:ok, :allowed}

  def check(command, :basic) do
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

  def check(command, :strict) do
    {cmd, _args} = parse_command(command)

    if cmd in @strict_allowlist do
      {:ok, :allowed}
    else
      {:error, {:not_in_allowlist, cmd}}
    end
  end

  def check(_command, :container) do
    # Container mode would delegate to container execution
    # For now, treat as :basic until container support is added
    {:error, :container_not_implemented}
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

  defp parse_command(command) do
    parts = String.split(command, ~r/\s+/, parts: 2)

    case parts do
      [cmd] -> {cmd, []}
      [cmd, rest] -> {cmd, String.split(rest)}
    end
  end

  defp has_dangerous_flags?(args) do
    Enum.any?(args, &(&1 in @dangerous_flags))
  end

  defp find_dangerous_flags(args) do
    Enum.filter(args, &(&1 in @dangerous_flags))
  end
end
