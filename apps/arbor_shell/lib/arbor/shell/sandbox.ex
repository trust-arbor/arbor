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
  are rejected to prevent command injection via lists/control operators
  (`;`, `&`, `&&`, `||`, `(`, `)`), subshells (`$()`, backticks), pipes
  (`|`, `|&`), or redirections (`>`, `<`).
  """

  # The recognized sandbox levels. An UNrecognized level (e.g. the trust-tier
  # vocabulary's :standard/:permissive, which this module doesn't define) is
  # tolerated by check/2 + config/1 — it degrades to the most restrictive level
  # (:strict) rather than raising. See the finish-retiring-trust-tiers roadmap item.
  @type level :: :none | :basic | :strict | :container

  require Logger

  alias Arbor.Shell.ExecutablePolicy

  # Every POSIX-style list/control operator contains at least one of these
  # characters. Matching the single-character roots is intentional: it catches
  # standalone background `&` as well as `&&`, `;&`, `;;&`, `|&`, grouping, and
  # every redirection variant. Quoted operators remain compound because the
  # agent path cannot rely on shell quoting semantics while CapShell is absent.
  @shell_metacharacters [";", "&", "|", "(", ")", "`", "$(", ">", "<", "\n", "\r"]

  # Positive policy for generic agent-authored command strings. Executable-name
  # admission is not sufficient: otherwise a utility such as `sort` can dispatch
  # an arbitrary helper through `--compress-program`. Every name in this list
  # has a closed argv grammar in validate_agent_argv/2. Unknown flags fail
  # closed before authorization or process work.
  #
  # Keep this deliberately small. Git/Mix, interpreters, env/exec wrappers,
  # find/xargs, pagers/editors, and programmable tools belong behind
  # schema-specific direct-argv actions, not this generic string boundary.
  @agent_direct_commands ~w[
    cat echo false grep head ls printenv printf pwd sleep sort tail touch true wc
  ]

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
    present, the COMMAND check uses this allowlist instead of
    the level's hardcoded list, so the sandbox agrees with the capability grant
    rather than conflicting with it. The safety floor (metacharacters +
    dangerous-command/interpreter/flag blocking) is ALWAYS applied on top — a
    capability grant lets a caller run a command, but never escape it via
    metacharacters or use the dangerous-command/interpreter floor. `:none` still
    bypasses this legacy sandbox check for trusted system callers. Generic
    agent-facing paths use `prepare_agent_command/2` instead: a capability
    allowlist (especially `:all`) is not proof that an executable cannot dispatch
    a nested runtime command. When absent, the level-based behavior is unchanged.
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

  @doc """
  Parse and bind a generic agent-authored command to the closed direct-argv
  executable policy.

  This gate is independent of the requested sandbox level. In particular,
  `sandbox: :none` cannot widen it. Non-empty child environments are rejected:
  loader variables and interpreter-specific options can turn an otherwise
  direct spawn into runtime code execution. Absolute paths are accepted only
  when they name the same executable selected from the trusted host `PATH` for
  the allowed basename; relative executable paths are rejected.

  Returns a prepared map containing the resolved executable, argv, and canonical
  command name. It never launches a process.
  """
  @spec prepare_agent_command(term(), term()) ::
          {:ok,
           %{
             required(:executable) => String.t(),
             required(:executable_identity) => ExecutablePolicy.Executable.t(),
             required(:args) => [String.t()],
             required(:command_name) => String.t()
           }}
          | {:error, term()}
  def prepare_agent_command(command, opts \\ [])

  def prepare_agent_command(command, opts) when is_binary(command) and is_list(opts) do
    with true <- Keyword.keyword?(opts),
         :ok <- validate_agent_command_text(command),
         {:ok, [raw_command | args]} <- split_agent_command(command),
         command_name <- Path.basename(raw_command),
         :ok <- validate_agent_command_name(command_name),
         :ok <- validate_agent_argv(command_name, args),
         :ok <- validate_gate_command(opts, command_name),
         :ok <- validate_agent_environment(opts),
         {:ok, executable} <- resolve_agent_executable(raw_command, command_name) do
      {:ok,
       %{
         executable: executable.path,
         executable_identity: executable,
         args: args,
         command_name: command_name
       }}
    else
      false -> {:error, {:invalid_agent_command, :invalid_options}}
      {:ok, []} -> {:error, {:invalid_agent_command, :empty}}
      {:error, _reason} = error -> error
    end
  end

  def prepare_agent_command(_command, _opts),
    do: {:error, {:invalid_agent_command, :invalid_input}}

  @doc """
  Returns `true` if the command contains shell metacharacters — i.e. it is a
  *compound* command (sequencing/background `;`/`&`/`&&`/`||`, grouping
  `()`, pipes `|`/`|&`, substitution `$(…)`/backticks, or redirection
  `>`/`<`) that the single-command path rejects.

  Used by agent-authorized shell boundaries (`Arbor.Shell.authorize/3`,
  `authorize_and_execute/3` and friends, `Arbor.Actions.Shell`) to reject
  compounds **unconditionally** with the CapShell unavailable error — before
  auth, approval, allowlist, registry, session, process, or fs work. Config
  (`compound_shell_enabled`) and sandbox level (including `:none`) cannot
  re-enable compound execution on those paths.

  System-only `Arbor.Shell.execute/2` still uses metacharacter rejection on the
  bounded Executor path at `:basic`/`:strict`. (A quoted metacharacter —
  `grep "a|b"` — also matches here as compound.)
  """
  @spec compound?(String.t()) :: boolean()
  def compound?(command) when is_binary(command) do
    Enum.any?(@shell_metacharacters, &String.contains?(command, &1)) or
      Regex.match?(~r/(?:^|[ \t])!(?:[ \t]|$)/, command)
  end

  @doc """
  Check an already-structured executable and argv without re-serializing data
  arguments through shell-string metacharacter rules.

  This is the sandbox gate for trusted system and schema-specific direct-argv
  APIs such as Git and Mix. Shell control characters inside an argv element are
  inert data to `Port.open({:spawn_executable, ...})`; command/interpreter and
  dangerous-flag floors still apply at `:basic`, and `:strict` remains an
  executable allowlist.
  """
  @spec check_argv(String.t(), [String.t()], level(), keyword()) ::
          {:ok, :allowed} | {:error, term()}
  def check_argv(command, args, level, opts \\ [])

  def check_argv(command, args, :none, _opts)
      when is_binary(command) and is_list(args),
      do: {:ok, :allowed}

  def check_argv(command, args, level, opts)
      when is_binary(command) and is_list(args) and is_list(opts) do
    if Enum.all?(args, &is_binary/1) do
      command_name = Path.basename(command)
      allowlist = Keyword.get(opts, :allowlist)
      check_argv_by_level(command_name, args, level, allowlist)
    else
      {:error, {:invalid_argv, :non_binary_argument}}
    end
  end

  def check_argv(_command, _args, _level, _opts),
    do: {:error, {:invalid_argv, :invalid_input}}

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

  defp check_argv_by_level(command, args, _level, allowlist) when not is_nil(allowlist) do
    cond do
      not Arbor.Shell.CapPolicy.allows?(allowlist, command) ->
        {:error, {:not_in_allowlist, command}}

      command in @dangerous_commands ->
        {:error, {:blocked_command, command}}

      command in @interpreter_commands ->
        {:error, {:blocked_interpreter, command}}

      has_dangerous_flags?(args) ->
        {:error, {:dangerous_flags, find_dangerous_flags(args)}}

      true ->
        {:ok, :allowed}
    end
  end

  defp check_argv_by_level(command, args, :basic, nil) do
    cond do
      command in @dangerous_commands ->
        {:error, {:blocked_command, command}}

      command in @interpreter_commands ->
        {:error, {:blocked_interpreter, command}}

      has_dangerous_flags?(args) ->
        {:error, {:dangerous_flags, find_dangerous_flags(args)}}

      true ->
        {:ok, :allowed}
    end
  end

  defp check_argv_by_level(command, _args, :strict, nil) do
    if command in @strict_allowlist do
      {:ok, :allowed}
    else
      {:error, {:not_in_allowlist, command}}
    end
  end

  defp check_argv_by_level(_command, _args, :container, nil),
    do: {:error, :container_not_implemented}

  defp check_argv_by_level(command, args, level, nil) do
    Logger.warning(
      "[Shell.Sandbox] unrecognized sandbox level #{inspect(level)} - degrading to :strict"
    )

    check_argv_by_level(command, args, :strict, nil)
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

  Uses the startup-frozen executable policy to locate and identify the binary.
  Returns `{:ok, path}` or `{:error, :executable_not_found}`.
  """
  @spec resolve_executable(String.t()) :: {:ok, String.t()} | {:error, :executable_not_found}
  def resolve_executable(cmd) when is_binary(cmd) do
    case ExecutablePolicy.resolve(cmd) do
      {:ok, executable} -> {:ok, executable.path}
      {:error, _reason} -> {:error, :executable_not_found}
    end
  end

  def resolve_executable(_cmd), do: {:error, :executable_not_found}

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

  defp validate_agent_environment(opts) do
    case Keyword.get(opts, :env) do
      nil -> :ok
      %{} = env when map_size(env) == 0 -> :ok
      [] -> :ok
      _ -> {:error, {:agent_shell_option_not_allowed, :env}}
    end
  end

  defp validate_agent_command_text(command) do
    cond do
      command == "" or String.trim(command) == "" ->
        {:error, {:invalid_agent_command, :empty}}

      not String.valid?(command) ->
        {:error, {:invalid_agent_command, :invalid_utf8}}

      compound?(command) ->
        {:error, :compound_command}

      Regex.match?(~r/[\x00-\x1F\x7F]/u, command) ->
        {:error, {:invalid_agent_command, :control_character}}

      true ->
        :ok
    end
  end

  defp split_agent_command(command) do
    {:ok, OptionParser.split(command)}
  rescue
    RuntimeError -> {:error, {:invalid_agent_command, :malformed_argv}}
  end

  defp validate_agent_command_name(command_name) do
    if command_name in @agent_direct_commands do
      :ok
    else
      {:error, {:agent_executable_not_allowed, command_name}}
    end
  end

  # Closed argv grammars for every generic executable. A new executable is not
  # admitted until it has an explicit clause here and its runtime-dispatch
  # surface has been audited. In particular, unknown options are never treated
  # as harmless merely because the executable name is allowlisted.
  defp validate_agent_argv("cat", args), do: validate_operands("cat", args, 0)
  defp validate_agent_argv("grep", args), do: validate_operands("grep", args, 1)
  defp validate_agent_argv("printenv", args), do: validate_env_names(args)
  defp validate_agent_argv("touch", args), do: validate_operands("touch", args, 1)

  defp validate_agent_argv(command, args) when command in ["false", "true"] do
    validate_exact_arity(command, args, 0)
  end

  defp validate_agent_argv("pwd", args) do
    validate_enumerated_flags("pwd", args, MapSet.new(["-L", "-P"]), 0)
  end

  defp validate_agent_argv("echo", args) do
    validate_enumerated_flags("echo", args, MapSet.new(["-n", "-e", "-E"]), 0)
  end

  defp validate_agent_argv("printf", ["--" | args]),
    do: validate_exact_arity("printf", args, 1, :at_least)

  defp validate_agent_argv("printf", [format | _rest] = args)
       when not (is_binary(format) and byte_size(format) > 0 and
                   binary_part(format, 0, 1) == "-") do
    validate_exact_arity("printf", args, 1, :at_least)
  end

  defp validate_agent_argv("printf", args),
    do: agent_argv_error("printf", {:unsupported_option, List.first(args)})

  defp validate_agent_argv("sleep", [duration]) do
    if Regex.match?(~r/^(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)[smhd]?$/, duration) do
      :ok
    else
      agent_argv_error("sleep", {:invalid_duration, duration})
    end
  end

  defp validate_agent_argv("sleep", args),
    do: agent_argv_error("sleep", {:invalid_arity, length(args)})

  defp validate_agent_argv("ls", args),
    do: validate_short_flags("ls", args, MapSet.new(~w[a l d 1]))

  # Only in-process sort modes are accepted. `-S`, `-T`, `-o`,
  # `--compress-program`, `--random-source`, and every unknown option reject.
  # This prevents sort from becoming a helper-program execution boundary.
  defp validate_agent_argv("sort", args),
    do: validate_short_flags("sort", args, MapSet.new(~w[f n r u]))

  defp validate_agent_argv("wc", args),
    do: validate_short_flags("wc", args, MapSet.new(~w[c l m w]))

  defp validate_agent_argv(command, [flag, count | operands])
       when command in ["head", "tail"] and flag in ["-c", "-n"] do
    if Regex.match?(~r/^[0-9]+$/, count) do
      validate_operands(command, operands, 0)
    else
      agent_argv_error(command, {:invalid_count, count})
    end
  end

  defp validate_agent_argv(command, args) when command in ["head", "tail"],
    do: validate_operands(command, args, 0)

  defp validate_agent_argv(command, _args),
    do: agent_argv_error(command, :missing_policy)

  defp validate_env_names(args) do
    invalid = Enum.find(args, &(not Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, &1)))

    if invalid do
      agent_argv_error("printenv", {:invalid_variable_name, invalid})
    else
      :ok
    end
  end

  defp validate_operands(command, ["--" | operands], minimum),
    do: validate_exact_arity(command, operands, minimum, :at_least)

  defp validate_operands(command, args, minimum) do
    case Enum.find(args, &option_token?/1) do
      nil -> validate_exact_arity(command, args, minimum, :at_least)
      option -> agent_argv_error(command, {:unsupported_option, option})
    end
  end

  defp validate_enumerated_flags(command, args, allowed, minimum) do
    {flags, operands} = Enum.split_while(args, &option_token?/1)

    case Enum.find(flags, &(not MapSet.member?(allowed, &1))) do
      nil -> validate_exact_arity(command, operands, minimum, :at_least)
      option -> agent_argv_error(command, {:unsupported_option, option})
    end
  end

  defp validate_short_flags(command, args, allowed_chars) do
    {flags, operands} = take_short_flags(args, [])

    with :ok <- validate_short_flag_tokens(command, flags, allowed_chars) do
      validate_operands(command, operands, 0)
    end
  end

  defp take_short_flags(["--" | operands], flags), do: {Enum.reverse(flags), operands}

  defp take_short_flags([flag | rest], flags)
       when is_binary(flag) and byte_size(flag) > 1 and binary_part(flag, 0, 1) == "-" do
    take_short_flags(rest, [flag | flags])
  end

  defp take_short_flags(operands, flags), do: {Enum.reverse(flags), operands}

  defp validate_short_flag_tokens(command, flags, allowed_chars) do
    invalid =
      Enum.find(flags, fn "-" <> chars ->
        chars == "" or
          String.starts_with?(chars, "-") or
          Enum.any?(String.graphemes(chars), &(not MapSet.member?(allowed_chars, &1)))
      end)

    if invalid do
      agent_argv_error(command, {:unsupported_option, invalid})
    else
      :ok
    end
  end

  defp validate_exact_arity(command, args, expected),
    do: validate_exact_arity(command, args, expected, :exact)

  defp validate_exact_arity(_command, args, expected, :exact)
       when length(args) == expected,
       do: :ok

  defp validate_exact_arity(_command, args, minimum, :at_least)
       when length(args) >= minimum,
       do: :ok

  defp validate_exact_arity(command, args, expected, mode),
    do: agent_argv_error(command, {:invalid_arity, mode, expected, length(args)})

  defp option_token?("-"), do: false
  defp option_token?("-" <> _rest), do: true
  defp option_token?(_arg), do: false

  defp agent_argv_error(command, reason),
    do: {:error, {:agent_argv_not_allowed, command, reason}}

  defp validate_gate_command(opts, command_name) do
    case Keyword.get(opts, :gate_command) do
      nil ->
        :ok

      gate when is_binary(gate) ->
        normalized = Path.basename(gate)

        if normalized == command_name do
          :ok
        else
          {:error, {:agent_shell_gate_mismatch, normalized, command_name}}
        end

      _ ->
        {:error, {:agent_shell_option_not_allowed, :gate_command}}
    end
  end

  defp resolve_agent_executable(raw_command, command_name) do
    case ExecutablePolicy.resolve_agent(raw_command, command_name) do
      {:ok, executable} -> {:ok, executable}
      {:error, reason} -> {:error, reason}
    end
  end

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
