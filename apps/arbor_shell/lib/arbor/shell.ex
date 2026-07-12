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

  alias Arbor.Shell.{
    CapShell,
    ExecutionRegistry,
    ExecutionWorker,
    Executor,
    PortSession,
    Sandbox
  }

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
  Legacy agent execution entry retained as an explicit fail-closed boundary.

  Shape validation alone is not authority, so this function never launches a
  process. Agent-facing adapters must authorize at a higher Trust-aware layer
  and then use the trusted-system direct API internally, or configure the
  injected authorizer used by `authorize_and_execute/3`.
  """
  @spec execute_agent_command(term(), term()) :: {:error, :agent_authority_required}
  def execute_agent_command(_command, _opts \\ []), do: {:error, :agent_authority_required}

  @doc false
  @spec execute_bound_agent_command(term(), term(), term()) ::
          {:error, :agent_authority_required}
  def execute_bound_agent_command(_command, _prepared, _opts),
    do: {:error, :agent_authority_required}

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

  First binds the command to the closed direct-executable policy, then delegates
  the exact principal, command, and prepared identity to the operator-configured
  `:arbor_shell, :agent_authorizer`. There is no low-level capability-only
  default because that would bypass higher Trust policy. Missing or invalid
  authorizer configuration fails closed.

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

  Runs the same injected authority check as `authorize_and_execute/3` but
  returns the decision instead of dispatching execution. Trust-aware higher
  layers may instead authorize through their own facade and route the already
  prepared command through the trusted-system direct API.

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

  **Trusted system API only.** This function performs no principal or Trust
  authorization. Agent-facing higher layers may call it only after binding and
  authorizing the same executable and argv.

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
    display_command = direct_command_for_display(cmd, args)

    # Structured argv is already the security boundary. Do not serialize data
    # arguments back through shell metacharacter scanning: a Git commit message
    # such as "Fix A & B (safe)" is inert argv, not a shell compound.
    with {:ok, :allowed} <- Sandbox.check_argv(cmd, args, sandbox, opts),
         {:ok, execution_id} <- register_execution(display_command, opts),
         :ok <- mark_execution_running(execution_id) do
      emit_started(display_command, execution_id, opts)

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
        emit_blocked(display_command, reason)
        {:error, reason}
    end
  end

  # Observability only. `inspect/1` makes argv boundaries unambiguous; this
  # string is never parsed or passed to a process.
  defp direct_command_for_display(cmd, args) when is_binary(cmd) and is_list(args) do
    Enum.map_join([cmd | args], " ", &inspect/1)
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

  `:max_output_bytes` is a hard ceiling for both retained and delivered bytes.
  Crossing it kills the process and reports explicit output-limit metadata.

  ## Subscriber Messages

  - `{:port_data, session_id, chunk}` — output chunk
  - `{:port_output_limit, session_id, metadata}` — output ceiling killed the process
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
  @spec stop_session(String.t()) ::
          :ok | {:error, :not_found | :not_running | :not_owner | :cancellation_timeout}
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
         {:ok, execution_id} <- register_execution(command, opts),
         :ok <- mark_execution_running(execution_id) do
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

    with {:ok, :allowed} <- Sandbox.check(command, sandbox, opts) do
      start_async_execution(command, opts, fn run_opts ->
        Executor.run(command, run_opts)
      end)
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
    case ExecutionRegistry.request_cancel(execution_id) do
      :ok -> wait_for_cancellation(execution_id)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_active_executions_with_filters(opts) do
    ExecutionRegistry.list(opts)
  end

  # Streaming contract implementations

  @impl true
  def execute_streaming_shell_command(command, opts) do
    start_time = System.monotonic_time(:millisecond)
    sandbox = Keyword.get(opts, :sandbox, @default_sandbox)

    with {:ok, :allowed} <- Sandbox.check(command, sandbox, opts),
         {:ok, timeout} <- PortSession.validate_timeout(Keyword.get(opts, :timeout, 30_000)),
         {executable, args} <- Sandbox.parse_command(command) do
      start_tracked_stream(
        command,
        executable,
        args,
        opts |> Keyword.put(:timeout, timeout) |> Keyword.put(:started_at, start_time)
      )
    else
      {:error, reason} ->
        emit_blocked(command, reason)
        {:error, reason}
    end
  end

  @impl true
  def stop_streaming_session(session_id) do
    case ExecutionRegistry.request_cancel(session_id) do
      :ok -> wait_for_cancellation(session_id)
      {:error, reason} -> {:error, reason}
    end
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
         %{executable_identity: executable, args: args},
         opts
       ) do
    execution_opts = agent_execution_opts(opts)

    if Process.whereis(ExecutionRegistry) do
      with {:ok, execution_id} <- register_execution(command, execution_opts),
           :ok <- mark_execution_running(execution_id) do
        emit_started(command, execution_id, execution_opts)

        case Executor.run_bound(executable, args, execution_opts) do
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
      Executor.run_bound(executable, args, execution_opts)
    end
  end

  defp execute_prepared_agent_command_async(
         command,
         %{executable_identity: executable, args: args},
         opts
       ) do
    execution_opts = agent_execution_opts(opts)

    start_async_execution(command, execution_opts, fn run_opts ->
      Executor.run_bound(executable, args, run_opts)
    end)
  end

  defp execute_prepared_agent_command_streaming(
         command,
         %{executable_identity: executable, args: args},
         opts
       ) do
    execution_opts = agent_execution_opts(opts)

    start_time = System.monotonic_time(:millisecond)

    with {:ok, timeout} <-
           PortSession.validate_timeout(Keyword.get(execution_opts, :timeout, 30_000)) do
      session_opts =
        execution_opts
        |> Keyword.take([:max_output_bytes, :cwd, :stream_to])
        |> Keyword.put(:timeout, timeout)
        |> Keyword.put(:started_at, start_time)

      start_tracked_stream(command, executable, args, session_opts)
    end
  end

  defp authorize_prepared_agent_command(agent_id, command, prepared, opts) do
    with true <- valid_agent_principal?(agent_id),
         {:ok, authorizer} <- configured_agent_authorizer() do
      auth_opts =
        opts
        |> Keyword.drop([:agent_authorizer])
        |> Keyword.put(:prepared_command, prepared)

      case authorizer.(agent_id, command, auth_opts) do
        {:ok, :authorized} -> {:ok, :authorized}
        {:ok, :pending_approval, proposal_id} -> {:ok, :pending_approval, proposal_id}
        {:error, reason} -> {:error, reason}
        _other -> {:error, :unauthorized}
      end
    else
      false -> {:error, :invalid_agent_principal}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :agent_authorizer_unavailable}
  catch
    _kind, _reason -> {:error, :agent_authorizer_unavailable}
  end

  defp valid_agent_principal?(agent_id) when is_binary(agent_id),
    do: String.trim(agent_id) != ""

  defp valid_agent_principal?(_agent_id), do: false

  defp configured_agent_authorizer do
    case Application.get_env(:arbor_shell, :agent_authorizer) do
      fun when is_function(fun, 3) ->
        {:ok, fun}

      module when is_atom(module) ->
        if function_exported?(module, :authorize_command, 3),
          do: {:ok, &module.authorize_command/3},
          else: {:error, :agent_authorizer_unavailable}

      {module, function} when is_atom(module) and is_atom(function) ->
        if function_exported?(module, function, 3) do
          {:ok,
           fn agent_id, command, opts ->
             apply(module, function, [agent_id, command, opts])
           end}
        else
          {:error, :agent_authorizer_unavailable}
        end

      _other ->
        {:error, :agent_authorizer_unavailable}
    end
  end

  defp register_execution(command, opts) do
    ExecutionRegistry.register(command,
      sandbox: Keyword.get(opts, :sandbox, @default_sandbox),
      cwd: Keyword.get(opts, :cwd),
      id_prefix: Keyword.get(opts, :execution_id_prefix, "exec_")
    )
  end

  defp mark_execution_running(execution_id), do: ExecutionRegistry.mark_running(execution_id)

  # The registry derives the controller from this caller, then the controller
  # atomically adopts the supervised worker before releasing its start message.
  # No PID/Port or copyable mutation credential enters a public projection.
  defp start_async_execution(command, opts, runner) when is_function(runner, 1) do
    case register_execution(command, opts) do
      {:ok, execution_id} ->
        start_registered_async_execution(execution_id, command, opts, runner)

      {:error, reason} ->
        emit_blocked(command, reason)
        {:error, reason}
    end
  end

  defp start_registered_async_execution(execution_id, command, opts, runner) do
    case start_waiting_execution_owner(execution_id, opts, runner) do
      {:ok, owner_pid, start_ref} ->
        case ExecutionRegistry.adopt(execution_id, owner_pid) do
          :ok ->
            emit_started(command, execution_id, opts)
            send(owner_pid, {:start_shell_execution, start_ref})
            {:ok, execution_id}

          {:error, reason} ->
            GenServer.stop(owner_pid, :normal)
            fail_execution(execution_id, reason)
            emit_failed(execution_id, reason)
            {:error, reason}
        end

      {:error, reason} ->
        fail_execution(execution_id, reason)
        emit_failed(execution_id, reason)
        {:error, reason}
    end
  end

  defp start_waiting_execution_owner(execution_id, opts, runner) do
    start_ref = make_ref()

    case DynamicSupervisor.start_child(
           Arbor.Shell.PortSessionSupervisor,
           {ExecutionWorker, {execution_id, opts, runner, start_ref, self()}}
         ) do
      {:ok, owner_pid} -> {:ok, owner_pid, start_ref}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_tracked_stream(command, executable, args, opts) do
    case register_execution(command, Keyword.put(opts, :execution_id_prefix, "port_")) do
      {:ok, execution_id} ->
        do_start_tracked_stream(execution_id, command, executable, args, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_start_tracked_stream(execution_id, command, executable, args, opts) do
    start_ref = make_ref()

    case PortSession.start_supervised_direct(
           executable,
           args,
           command,
           Keyword.put(opts, :deferred, {execution_id, start_ref})
         ) do
      {:ok, owner_pid} ->
        adopt_and_begin_stream(execution_id, owner_pid, start_ref, command, opts)

      {:error, reason} ->
        _ = fail_execution(execution_id, reason)
        {:error, reason}
    end
  end

  defp adopt_and_begin_stream(execution_id, owner_pid, start_ref, command, opts) do
    case ExecutionRegistry.adopt(execution_id, owner_pid) do
      :ok ->
        remaining =
          Keyword.fetch!(opts, :started_at) + Keyword.fetch!(opts, :timeout) -
            System.monotonic_time(:millisecond)

        result =
          if remaining > 0,
            do: PortSession.begin(owner_pid, start_ref, remaining + 2_000),
            else: {:error, :stream_setup_timeout}

        case result do
          :ok ->
            emit_started(command, execution_id, opts)
            {:ok, execution_id}

          {:error, reason} ->
            _ = ExecutionRegistry.request_cancel(execution_id)
            {:error, reason}
        end

      {:error, reason} ->
        GenServer.stop(owner_pid, :normal)
        _ = fail_execution(execution_id, reason)
        {:error, reason}
    end
  end

  defp complete_execution(execution_id, result) do
    ExecutionRegistry.finish(execution_id, result)
  end

  defp fail_execution(execution_id, reason) do
    ExecutionRegistry.fail(execution_id, reason)
  end

  defp wait_for_result(execution_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_result(execution_id, deadline)
  end

  @terminal_statuses [:completed, :failed, :timed_out, :killed]

  defp wait_for_cancellation(execution_id) do
    deadline = System.monotonic_time(:millisecond) + 3_000

    case do_wait_for_result(execution_id, deadline) do
      {:ok, _result} -> :ok
      {:error, :timeout} -> {:error, :cancellation_timeout}
      {:error, reason} -> {:error, reason}
    end
  end

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
