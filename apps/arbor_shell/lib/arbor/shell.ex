defmodule Arbor.Shell do
  @moduledoc """
  Safe shell command execution for the Arbor platform.

  Arbor.Shell provides a secure interface for executing shell commands with
  sandbox support, timeout handling, and observability through signals.

  ## Quick Start

      {:ok, result} = Arbor.Shell.execute("ls -la", timeout: 5000)
      IO.puts(result.stdout)

  ## Sandbox Modes

  | Mode | Description |
  |------|-------------|
  | `:none` | No restrictions - use with caution |
  | `:basic` | Blocks dangerous commands (rm -rf, sudo, etc.) |
  | `:strict` | Allowlist only - very limited commands |
  | `:container` | Container isolation (future) |

  ## Examples

      # Basic execution
      {:ok, result} = Arbor.Shell.execute("echo hello")

      # With sandbox
      {:ok, result} = Arbor.Shell.execute("ls", sandbox: :strict)

      # With working directory
      {:ok, result} = Arbor.Shell.execute("git status", cwd: "/path/to/repo")

      # With absolute timeout (continuous output does not extend the deadline)
      {:ok, result} = Arbor.Shell.execute("sleep 10", timeout: 5000)
      result.timed_out  # => true

      # With retained-output ceiling (default 8 MiB; hard max 16 MiB)
      {:ok, result} = Arbor.Shell.execute(noisy_cmd, max_output_bytes: 256)
      result.output_limit_exceeded  # => true when the ceiling is hit

  ## Signals

  Shell emits signals for observability:

  - `{:shell, :command_started, %{command: ..., execution_id: ...}}`
  - `{:shell, :command_completed, %{execution_id: ..., exit_code: ..., timed_out: ..., killed: ..., output_limit_exceeded: ..., output_truncated: ...}}`
  - `{:shell, :command_failed, %{execution_id: ..., reason: ...}}`
  """

  @behaviour Arbor.Contracts.API.Shell

  alias Arbor.Shell.{CapShell, ExecutionRegistry, Executor, PortSession, Sandbox}
  alias Arbor.Signals

  @default_sandbox :basic

  # ===========================================================================
  # Public API — Output ceiling bounds (single source of truth for callers)
  # ===========================================================================

  @doc """
  Normalize a requested `:max_output_bytes` value.

  Positive integers are clamped to the system hard maximum
  (`max_output_bytes_limit/0`, 16 MiB). Invalid or non-positive values fall
  back to the executor default (8 MiB). This is the public facade over
  `Arbor.Shell.Executor` — other libraries must not import the Executor.
  """
  @spec normalize_max_output_bytes(term()) :: pos_integer()
  def normalize_max_output_bytes(n), do: Executor.normalize_max_output_bytes(n)

  @doc """
  Non-bypassable system hard maximum for retained merged-stdout bytes (16 MiB).
  """
  @spec max_output_bytes_limit() :: pos_integer()
  def max_output_bytes_limit, do: Executor.max_output_bytes_limit()

  # ===========================================================================
  # Public API — Compound shell (CapShell) feature gate
  # ===========================================================================

  @compound_shell_unavailable {:compound_shell_unavailable, :security_boundary_incomplete}

  @doc """
  Whether compound-shell routing is configured as enabled.

  Reads `Application.get_env(:arbor_shell, :compound_shell_enabled)`. **Defaults
  to `false` (fail-closed)** when the key is absent.

  **Intentional security API break:** even when an operator sets
  `config :arbor_shell, compound_shell_enabled: true`, CapShell does **not**
  execute compound commands. Configuration is informational only and **cannot**
  re-enable the retired prototype. Agent-authorized boundaries reject compounds
  unconditionally regardless of this flag (see `authorize/3`,
  `authorize_and_execute/3` and friends). See `Arbor.Shell.CapShell` for the
  missing upstream contracts.

  Other libraries (e.g. `Arbor.Actions.Shell`) must call this facade rather than
  re-reading Application env with their own default.
  """
  @spec compound_shell_enabled?() :: boolean()
  def compound_shell_enabled? do
    Application.get_env(:arbor_shell, :compound_shell_enabled, false) == true
  end

  @doc """
  Whether `command` contains shell metacharacters that mark it as compound
  (sequencing/background `;`/`&`/`&&`/`||`, grouping, pipes, substitution,
  or redirection).

  Public facade over `Arbor.Shell.Sandbox.compound?/1`. Other libraries
  (e.g. `Arbor.Actions.Shell`) must call this rather than importing Sandbox.
  """
  @spec compound_command?(String.t()) :: boolean()
  def compound_command?(command) when is_binary(command), do: Sandbox.compound?(command)

  @doc """
  Validate and bind a generic agent-authored command to the closed direct-argv
  policy.

  This check runs before authorization at every agent shell boundary. Only a
  fixed set of non-dispatching utilities is accepted; shell interpreters,
  language runtimes, command wrappers, generic Git/Mix execution, noncanonical
  executable paths, and non-empty child environments are rejected. The
  requested sandbox level cannot widen the policy.

  Compound syntax returns the same stable CapShell-unavailable error used by
  the retired compound entry points.
  """
  @spec prepare_agent_command(term(), term()) :: {:ok, map()} | {:error, term()}
  def prepare_agent_command(command, opts \\ []) do
    case Sandbox.prepare_agent_command(command, opts) do
      {:error, :compound_command} -> {:error, @compound_shell_unavailable}
      other -> other
    end
  end

  @doc """
  Execute a generic agent-authored command through the closed direct-argv path.

  This function enforces execution shape but does **not** grant authority. It is
  for adapters that have already performed their own principal-specific
  authorization (for example the Trust-backed action and DOT handlers). Callers
  that need both checks should use `authorize_and_execute/3`.

  `sandbox: :none` is accepted for compatibility but cannot widen this path;
  execution always uses the closed direct policy. Non-empty `:env` is rejected.
  Trusted system callers retain `execute/2` and `execute_direct/3` unchanged.
  """
  @spec execute_agent_command(term(), term()) :: {:ok, map()} | {:error, term()}
  def execute_agent_command(command, opts \\ []) do
    with {:ok, prepared} <- prepare_agent_command(command, opts) do
      execute_prepared_agent_command(command, prepared, opts)
    end
  end

  @doc """
  Fail-closed compound-shell entry (public facade over `Arbor.Shell.CapShell`).

  **Intentional security API break:** always returns
  `{:error, {:compound_shell_unavailable, :security_boundary_incomplete}}`
  without parsing, session creation, process launch, filesystem access, or
  adapter dispatch. Accepts any terms (including malformed arguments) and never
  raises. Does **not** fall back to an unchecked shell or the bounded
  single-command executor.

  Agent-authorized boundaries reject compound commands before auth/allowlist
  work; this entry remains for direct CapShell-shaped callers.
  """
  @spec execute_compound_with_capabilities(term(), term(), term()) ::
          {:error, {:compound_shell_unavailable, :security_boundary_incomplete}}
  def execute_compound_with_capabilities(agent_id \\ nil, command \\ nil, opts \\ [])

  def execute_compound_with_capabilities(agent_id, command, opts) do
    # Direct callers cannot bypass the fail-closed gate — CapShell.run/3 never
    # parses or launches, including for malformed terms. Project the stable
    # error without reshaping.
    CapShell.run(agent_id, command, opts)
  end

  # ===========================================================================
  # Public API — Authorized versions (for agent callers)
  # ===========================================================================

  @doc """
  Execute a shell command with authorization check.

  First binds the command to the closed direct-executable policy, then verifies
  the agent has the matching `arbor://shell/exec/{command_name}` capability.
  A broad capability does not admit an interpreter or dispatch wrapper.

  ## Parameters

  - `agent_id` - The agent's ID for capability lookup
  - `command` - The shell command to execute
  - `opts` - Direct execution options; non-empty `:env` is rejected and
    `sandbox: :none` cannot widen the agent policy

  ## Returns

  - `{:ok, result}` - Command executed successfully
  - `{:error, :unauthorized}` - Agent lacks the required capability
  - `{:ok, :pending_approval, proposal_id}` - Requires escalation approval
  - `{:error, reason}` - Other execution errors

  ## Examples

      {:ok, result} = Arbor.Shell.authorize_and_execute("agent_001", "ls -la")
      {:error, :unauthorized} = Arbor.Shell.authorize_and_execute("agent_002", "echo denied")
      {:error, {:agent_executable_not_allowed, "sh"}} =
        Arbor.Shell.authorize_and_execute("agent_001", "sh -c true")
  """
  @spec authorize_and_execute(String.t(), String.t(), keyword()) ::
          {:ok, map()}
          | {:ok, :pending_approval, String.t()}
          | {:error, :unauthorized | :timeout | term()}
          | {:error, {:compound_shell_unavailable, :security_boundary_incomplete}}
  # H6: Pass command context into authorize/4 opts so the reflex pipeline
  # can evaluate command-aware rules (e.g., blocking `rm -rf /`).
  def authorize_and_execute(agent_id, command, opts \\ []) do
    authorize_and_dispatch(agent_id, command, opts, fn prepared ->
      execute_prepared_agent_command(command, prepared, opts)
    end)
  end

  @doc """
  Execute an async shell command with authorization check.

  Same as `authorize_and_execute/3` but for async execution.
  """
  @spec authorize_and_execute_async(String.t(), String.t(), keyword()) ::
          {:ok, String.t()}
          | {:ok, :pending_approval, String.t()}
          | {:error, :unauthorized | term()}
          | {:error, {:compound_shell_unavailable, :security_boundary_incomplete}}
  # H6: Pass command context into authorize/4 opts for async execution too.
  def authorize_and_execute_async(agent_id, command, opts \\ []) do
    authorize_and_dispatch(agent_id, command, opts, fn prepared ->
      execute_prepared_agent_command_async(command, prepared, opts)
    end)
  end

  @doc """
  Authorize a shell command for an agent WITHOUT executing it.

  Runs the same capability + reflex policy check as `authorize_and_execute/3`
  but returns the decision instead of dispatching execution. This is for
  adapters that authorize separately before routing the same command through
  `execute_agent_command/2` — notably the DOT `shell` node handler.

  **Compound commands, interpreters/wrappers, noncanonical executable paths,
  and non-empty environments are rejected** before capability lookup or
  approval creation, regardless of `compound_shell_enabled` or sandbox level.
  Static per-command grants must not paper over expanded runtime semantics.

  ## Returns

  - `{:ok, :authorized}` - the principal may run this command
  - `{:ok, :pending_approval, proposal_id}` - escalated; not yet authorized
  - `{:error, :unauthorized}` - the principal lacks the capability
  - `{:error, {:compound_shell_unavailable, :security_boundary_incomplete}}` -
    command is compound / not agent-executable under CapShell retirement
  - `{:error, reason}` - closed direct-executable policy rejected the command

  ## Examples

      {:ok, :authorized} = Arbor.Shell.authorize("agent_001", "ls -la")
      {:error, :unauthorized} = Arbor.Shell.authorize("agent_002", "echo denied")
  """
  @spec authorize(String.t(), String.t(), keyword()) ::
          {:ok, :authorized}
          | {:ok, :pending_approval, String.t()}
          | {:error, term()}
  def authorize(agent_id, command, opts \\ []) do
    with {:ok, prepared} <- prepare_agent_command(command, opts) do
      authorize_prepared_agent_command(agent_id, command, prepared, opts)
    end
  end

  # ===========================================================================
  # Public API — short, human-friendly names (unchecked, for system callers)
  # ===========================================================================

  @doc """
  Execute a shell command synchronously.

  **Trusted system API only.** This entry does **not** authorize an agent
  principal and must not be exposed through agent action surfaces. Agent
  callers must use `authorize_and_execute/3` (or the Jido `Execute` action),
  which reject compound commands. Prefer those agent boundaries over this
  function for any principal-scoped work.

  ## Options

  - `:timeout` - Absolute timeout in milliseconds measured from command start
    (default: 30_000). Continuous stdout does not extend the deadline.
  - `:max_output_bytes` - Maximum retained bytes of the merged stdout stream
    (Executor uses `:stderr_to_stdout`; result `stderr` is `""`). Default:
    8_388_608 (8 MiB, headroom for Mix/compiler/test logs). Hard maximum:
    16_777_216 (16 MiB) — larger positive values are clamped down
    (non-bypassable). When a chunk would *exceed* the ceiling the process is
    killed immediately; the result has `output_limit_exceeded: true` and
    `output_truncated: true`. Exactly `max_output_bytes` is allowed;
    truncation keeps a valid UTF-8 prefix (may be slightly under the ceiling).
    Invalid or non-positive values fall back to the default.
  - `:cwd` - Working directory
  - `:env` - Environment variables map
  - `:sandbox` - Sandbox mode: `:none`, `:basic`, `:strict` (default: `:basic`)
  - `:stdin` - Input to send to the process

  ## Examples

      {:ok, result} = Arbor.Shell.execute("echo hello")
      result.exit_code  # => 0
      result.stdout     # => "hello\\n"
  """
  @spec execute(String.t(), keyword()) ::
          {:ok, map()} | {:error, :timeout | :unauthorized | term()}
  def execute(command, opts \\ []),
    do: execute_shell_command_with_options(command, opts)

  @doc """
  Execute a command with pre-parsed executable and arguments.

  Bypasses shell string parsing — use when you already have structured
  `{cmd, args}` and want to avoid the serialize-then-parse round-trip.
  Still performs sandbox checks on the command name and execution tracking.

  Options are the same as `execute/2` (`:timeout`, `:max_output_bytes`,
  `:cwd`, `:env`, `:sandbox`, `:stdin`).

  ## Examples

      {:ok, result} = Arbor.Shell.execute_direct("echo", ["hello", "world"])
      result.stdout  # => "hello world\\n"
  """
  @spec execute_direct(String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_direct(cmd, args, opts \\ []) do
    sandbox = Keyword.get(opts, :sandbox, @default_sandbox)
    # Absolute executable paths (e.g. worktree `…/bin/mix`) must not be
    # shell-split for policy checks — use basename + argv for sandbox, and
    # pass the path through to the port as a single executable.
    check_command = sandbox_check_command(cmd, args)

    with {:ok, :allowed} <- Sandbox.check(check_command, sandbox, opts),
         {:ok, execution_id} <- register_execution(check_command, opts) do
      emit_started(check_command, execution_id, opts)

      case Executor.run_direct(cmd, args, opts) do
        {:ok, result} ->
          complete_execution(execution_id, result)
          emit_completed(execution_id, result)
          {:ok, result}

        {:error, reason} ->
          fail_execution(execution_id, reason)
          emit_failed(execution_id, reason)
          {:error, reason}
      end
    else
      {:error, reason} ->
        emit_blocked(check_command, reason)
        {:error, reason}
    end
  end

  # Build a space-joined string for Sandbox.check only. Absolute paths are
  # reduced to their basename so spaces in the path never become extra args.
  defp sandbox_check_command(cmd, args) when is_binary(cmd) and is_list(args) do
    name =
      if absolute_path?(cmd) do
        Path.basename(cmd)
      else
        cmd
      end

    Enum.join([name | Enum.map(args, &to_string/1)], " ")
  end

  defp absolute_path?(cmd) when is_binary(cmd) do
    Path.type(cmd) == :absolute or String.starts_with?(cmd, "/")
  end

  @doc """
  Execute a shell command asynchronously.

  **Trusted system API only.** Unchecked by agent capability gates — do not
  expose through agent action surfaces. Agent callers must use
  `authorize_and_execute_async/3`.

  Returns an execution ID that can be used to check status and get results.

  ## Examples

      {:ok, exec_id} = Arbor.Shell.execute_async("long-running-command")
      {:ok, result} = Arbor.Shell.get_result(exec_id)
  """
  @spec execute_async(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :unauthorized | term()}
  def execute_async(command, opts \\ []),
    do: execute_shell_command_async_with_options(command, opts)

  @doc "Get the status of an async execution."
  @spec get_status(String.t()) :: {:ok, atom()} | {:error, :not_found}
  def get_status(execution_id), do: get_execution_status_by_id(execution_id)

  @doc "Get the result of an async execution."
  @spec get_result(String.t(), keyword()) ::
          {:ok, map()} | {:pending, map()} | {:error, :not_found | :timeout}
  def get_result(execution_id, opts \\ []), do: get_execution_result_by_id(execution_id, opts)

  @doc "Kill a running async execution."
  @spec kill(String.t(), keyword()) :: :ok | {:error, :not_found | :not_running}
  def kill(execution_id, opts \\ []), do: kill_running_execution_by_id(execution_id, opts)

  @doc "List all executions."
  @spec list_executions(keyword()) :: {:ok, [map()]}
  def list_executions(opts \\ []), do: list_active_executions_with_filters(opts)

  # ===========================================================================
  # Public API — Streaming (PortSession-backed)
  # ===========================================================================

  @doc """
  Execute a command as a streaming session.

  **Trusted system API only.** Unchecked by agent capability gates — do not
  expose through agent action surfaces. Agent callers must use
  `authorize_and_execute_streaming/3`.

  Starts a supervised PortSession and returns the session ID.
  Output is streamed to the caller specified via `stream_to:` in opts.

  ## Options

  Same as `execute/2`, plus:
  - `:stream_to` - PID or list of PIDs to receive output messages (required)

  ## Subscriber Messages

  - `{:port_data, session_id, chunk}` — output chunk
  - `{:port_exit, session_id, exit_code, full_output}` — process exited

  ## Examples

      {:ok, session_id} = Arbor.Shell.execute_streaming("long-command", stream_to: self())

      receive do
        {:port_data, ^session_id, chunk} -> IO.write(chunk)
        {:port_exit, ^session_id, 0, output} -> IO.puts("Done")
      end
  """
  @spec execute_streaming(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def execute_streaming(command, opts \\ []) do
    execute_streaming_shell_command(command, opts)
  end

  @doc """
  Stop a streaming session by session ID.
  """
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(session_id) do
    stop_streaming_session(session_id)
  end

  @doc """
  Execute a streaming command with authorization check.

  Same as `authorize_and_execute/3` but for streaming sessions.
  """
  @spec authorize_and_execute_streaming(String.t(), String.t(), keyword()) ::
          {:ok, String.t()}
          | {:ok, :pending_approval, String.t()}
          | {:error, :unauthorized | term()}
          | {:error, {:compound_shell_unavailable, :security_boundary_incomplete}}
  # H6: Pass command context into authorize/4 opts for streaming execution too.
  def authorize_and_execute_streaming(agent_id, command, opts \\ []) do
    authorize_and_dispatch(agent_id, command, opts, fn prepared ->
      execute_prepared_agent_command_streaming(command, prepared, opts)
    end)
  end

  # ===========================================================================
  # Contract implementations — verbose, AI-readable names
  # ===========================================================================

  @impl true
  def execute_shell_command_with_options(command, opts) do
    sandbox = Keyword.get(opts, :sandbox, @default_sandbox)

    with {:ok, :allowed} <- Sandbox.check(command, sandbox, opts),
         {:ok, execution_id} <- register_execution(command, opts) do
      emit_started(command, execution_id, opts)

      case Executor.run(command, opts) do
        {:ok, result} ->
          complete_execution(execution_id, result)
          emit_completed(execution_id, result)
          {:ok, result}

        {:error, reason} ->
          fail_execution(execution_id, reason)
          emit_failed(execution_id, reason)
          {:error, reason}
      end
    else
      {:error, reason} ->
        emit_blocked(command, reason)
        {:error, reason}
    end
  end

  @impl true
  def execute_shell_command_async_with_options(command, opts) do
    sandbox = Keyword.get(opts, :sandbox, @default_sandbox)

    with {:ok, :allowed} <- Sandbox.check(command, sandbox, opts),
         {:ok, execution_id} <- register_execution(command, opts) do
      emit_started(command, execution_id, opts)

      Task.start(fn ->
        case Executor.run(command, opts) do
          {:ok, result} ->
            complete_execution(execution_id, result)
            emit_completed(execution_id, result)

          {:error, reason} ->
            fail_execution(execution_id, reason)
            emit_failed(execution_id, reason)
        end
      end)

      {:ok, execution_id}
    end
  end

  @impl true
  def get_execution_status_by_id(execution_id) do
    case ExecutionRegistry.get(execution_id) do
      {:ok, execution} -> {:ok, execution.status}
      error -> error
    end
  end

  @impl true
  def get_execution_result_by_id(execution_id, opts) do
    wait = Keyword.get(opts, :wait, false)
    timeout = Keyword.get(opts, :timeout, 5000)

    if wait do
      wait_for_result(execution_id, timeout)
    else
      case ExecutionRegistry.get(execution_id) do
        {:ok, %{status: status, result: result}}
        when status in [:completed, :failed, :timed_out, :killed] ->
          {:ok, result}

        {:ok, execution} ->
          {:pending, %{status: execution.status}}

        error ->
          error
      end
    end
  end

  @impl true
  def kill_running_execution_by_id(execution_id, _opts) do
    case ExecutionRegistry.get(execution_id) do
      {:ok, %{status: :running, port: port}} when not is_nil(port) ->
        Executor.kill_port(port)
        ExecutionRegistry.update_status(execution_id, :killed)
        :ok

      {:ok, %{status: status}} when status != :running ->
        {:error, :not_running}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @impl true
  def list_active_executions_with_filters(opts) do
    ExecutionRegistry.list(opts)
  end

  # Streaming contract implementations

  @impl true
  def execute_streaming_shell_command(command, opts) do
    sandbox = Keyword.get(opts, :sandbox, @default_sandbox)

    case Sandbox.check(command, sandbox, opts) do
      {:ok, :allowed} ->
        session_opts =
          opts
          |> Keyword.take([:timeout, :cwd, :env, :stream_to])
          |> Keyword.put_new(:timeout, 30_000)

        case PortSession.start_supervised(command, session_opts) do
          {:ok, pid} ->
            session_id = PortSession.get_id(pid)

            # Register in the ExecutionRegistry for tracking
            {:ok, exec_id} = register_execution(command, opts)
            ExecutionRegistry.update_status(exec_id, :running, %{port_session_pid: pid})

            emit_started(command, session_id, opts)
            {:ok, session_id}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        emit_blocked(command, reason)
        {:error, reason}
    end
  end

  @impl true
  def stop_streaming_session(session_id) do
    case find_port_session(session_id) do
      {:ok, pid} ->
        PortSession.stop(pid)
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  defp find_port_session(session_id) do
    # Search DynamicSupervisor children for the matching session
    children = DynamicSupervisor.which_children(Arbor.Shell.PortSessionSupervisor)

    Enum.find_value(children, :error, fn {_, pid, _, _} ->
      if is_pid(pid) and Process.alive?(pid) do
        try do
          if PortSession.get_id(pid) == session_id, do: {:ok, pid}
        catch
          :exit, _ -> nil
        end
      end
    end)
  end

  # System API

  @doc """
  Start the shell system.

  Normally started automatically by the application supervisor.
  """
  @impl true
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Arbor.Shell.Application.start(:normal, opts)
  end

  @doc """
  Check if the shell system is healthy.
  """
  @impl true
  @spec healthy?() :: boolean()
  def healthy? do
    Process.whereis(ExecutionRegistry) != nil
  end

  @doc """
  Get sandbox configuration for a level.
  """
  @spec sandbox_config(atom()) :: map()
  def sandbox_config(level) do
    Sandbox.config(level)
  end

  # Private functions

  # Generic agent commands are already bound to a fixed executable + argv by
  # Sandbox.prepare_agent_command/2. Force the legacy sandbox marker to :basic
  # and drop all child-environment/capability-projection options so sandbox:none
  # and env can never widen execution after authorization.
  defp agent_execution_opts(opts) do
    opts
    |> Keyword.drop([:env, :allowlist, :gate_command])
    |> Keyword.put(:sandbox, :basic)
  end

  defp execute_prepared_agent_command(
         command,
         %{executable: executable, args: args},
         opts
       ) do
    execution_opts = agent_execution_opts(opts)

    if Process.whereis(ExecutionRegistry) do
      with {:ok, execution_id} <- register_execution(command, execution_opts) do
        emit_started(command, execution_id, execution_opts)

        case Executor.run_direct(executable, args, execution_opts) do
          {:ok, result} ->
            complete_execution(execution_id, result)
            emit_completed(execution_id, result)
            {:ok, result}

          {:error, reason} ->
            fail_execution(execution_id, reason)
            emit_failed(execution_id, reason)
            {:error, reason}
        end
      else
        {:error, reason} ->
          emit_blocked(command, reason)
          {:error, reason}
      end
    else
      # The orchestrator can be exercised without the arbor_shell application
      # supervisor. Preserve that standalone mode with the same already-bound
      # Executor argv; never fall back to a shell string or unchecked Port.
      Executor.run_direct(executable, args, execution_opts)
    end
  end

  defp execute_prepared_agent_command_async(
         command,
         %{executable: executable, args: args},
         opts
       ) do
    execution_opts = agent_execution_opts(opts)

    with {:ok, execution_id} <- register_execution(command, execution_opts) do
      emit_started(command, execution_id, execution_opts)

      Task.start(fn ->
        case Executor.run_direct(executable, args, execution_opts) do
          {:ok, result} ->
            complete_execution(execution_id, result)
            emit_completed(execution_id, result)

          {:error, reason} ->
            fail_execution(execution_id, reason)
            emit_failed(execution_id, reason)
        end
      end)

      {:ok, execution_id}
    else
      {:error, reason} ->
        emit_blocked(command, reason)
        {:error, reason}
    end
  end

  defp execute_prepared_agent_command_streaming(
         command,
         %{executable: executable, args: args},
         opts
       ) do
    execution_opts = agent_execution_opts(opts)

    session_opts =
      execution_opts
      |> Keyword.take([:timeout, :cwd, :stream_to])
      |> Keyword.put_new(:timeout, 30_000)

    with {:ok, exec_id} <- register_execution(command, execution_opts) do
      case PortSession.start_supervised_direct(executable, args, command, session_opts) do
        {:ok, pid} ->
          session_id = PortSession.get_id(pid)
          ExecutionRegistry.update_status(exec_id, :running, %{port_session_pid: pid})
          emit_started(command, session_id, execution_opts)
          {:ok, session_id}

        {:error, reason} ->
          fail_execution(exec_id, reason)
          {:error, reason}
      end
    end
  end

  defp authorize_prepared_agent_command(agent_id, command, prepared, opts) do
    resource = "arbor://shell/exec/#{prepared.command_name}"

    # Skip identity verification — facade auth is a policy check only; the
    # caller (or the action layer above it) owns request-signature checks.
    auth_opts = [command: command, path: Keyword.get(opts, :cwd), verify_identity: false]

    case Arbor.Security.authorize(agent_id, resource, :execute, auth_opts) do
      {:ok, :authorized} -> {:ok, :authorized}
      {:ok, :pending_approval, proposal_id} -> {:ok, :pending_approval, proposal_id}
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  defp register_execution(command, opts) do
    ExecutionRegistry.register(command,
      sandbox: Keyword.get(opts, :sandbox, @default_sandbox),
      cwd: Keyword.get(opts, :cwd)
    )
  end

  defp complete_execution(execution_id, result) do
    # Output-limit termination is killed (not timed_out and not a successful
    # completed run). Registry + get_result treat :killed as terminal.
    status =
      cond do
        Map.get(result, :timed_out) == true -> :timed_out
        Map.get(result, :killed) == true -> :killed
        true -> :completed
      end

    ExecutionRegistry.update_status(execution_id, status, %{result: result})
  end

  defp fail_execution(execution_id, reason) do
    ExecutionRegistry.update_status(execution_id, :failed, %{
      result: %{error: reason}
    })
  end

  defp wait_for_result(execution_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_result(execution_id, deadline)
  end

  @terminal_statuses [:completed, :failed, :timed_out, :killed]

  defp do_wait_for_result(execution_id, deadline) do
    case ExecutionRegistry.get(execution_id) do
      {:ok, %{status: status, result: result}} when status in @terminal_statuses ->
        {:ok, result}

      {:ok, _} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          do_wait_for_result(execution_id, deadline)
        else
          {:error, :timeout}
        end

      error ->
        error
    end
  end

  # Signal emission

  defp emit_started(command, execution_id, opts) do
    durable_shell_emit(:command_started, %{
      command: truncate_command(command),
      execution_id: execution_id,
      sandbox: Keyword.get(opts, :sandbox, @default_sandbox),
      cwd: Keyword.get(opts, :cwd)
    })
  end

  defp emit_completed(execution_id, result) do
    # Keep established event name `:command_completed`; add killed / output-limit
    # metadata so observers can distinguish ceiling kills from success/timeout.
    durable_shell_emit(:command_completed, %{
      execution_id: execution_id,
      exit_code: result.exit_code,
      duration_ms: result.duration_ms,
      timed_out: Map.get(result, :timed_out, false),
      killed: Map.get(result, :killed, false),
      output_limit_exceeded: Map.get(result, :output_limit_exceeded, false),
      output_truncated: Map.get(result, :output_truncated, false)
    })
  end

  defp emit_failed(execution_id, reason) do
    durable_shell_emit(:command_failed, %{
      execution_id: execution_id,
      reason: inspect(reason)
    })
  end

  defp emit_blocked(command, reason) do
    durable_shell_emit(:command_blocked, %{
      command: truncate_command(command),
      reason: inspect(reason)
    })
  end

  defp durable_shell_emit(type, data) do
    if function_exported?(Signals, :durable_emit, 4) do
      Signals.durable_emit(:shell, type, data, stream_id: "shell:execution")
    else
      Signals.emit(:shell, type, data)
    end
  end

  defp truncate_command(command) do
    if String.length(command) > 200 do
      String.slice(command, 0, 197) <> "..."
    else
      command
    end
  end

  # Shared authorization dispatch — validate and bind the executable before
  # Security/approval work, then execute the exact prepared argv only after an
  # authorized decision. All sync/async/streaming variants use this path.
  defp authorize_and_dispatch(agent_id, command, opts, execute_fn) do
    with {:ok, prepared} <- prepare_agent_command(command, opts) do
      case authorize_prepared_agent_command(agent_id, command, prepared, opts) do
        {:ok, :authorized} -> execute_fn.(prepared)
        {:ok, :pending_approval, proposal_id} -> {:ok, :pending_approval, proposal_id}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
