defmodule Arbor.Actions.Shell do
  @moduledoc """
  Shell command execution actions.

  This module provides Jido-compatible actions for executing shell commands
  with sandbox support and observability through Arbor.Signals.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Execute` | Execute a single non-compound shell command |
  | `ExecuteScript` | Fail-closed unavailable (compound/script boundary incomplete) |

  Compound commands (metacharacters) and multi-line scripts are **not**
  agent-executable: CapShell is retired and static line admission is not a
  security proof of expanded runtime argv. Agent boundaries reject them with
  a stable unavailable error before auth/temp-file/process work.

  ## Sandbox Support

  Single-command `Execute` supports sandboxing through Arbor.Shell:

  - `:none` - No restrictions (still rejects compound commands for agents)
  - `:basic` - Blocks dangerous commands (rm -rf, sudo, etc.)
  - `:strict` - Allowlist only

  ## Examples

      # Simple command
      {:ok, result} = Arbor.Actions.Shell.Execute.run(%{command: "echo hello"}, %{})
      result.stdout  # => "hello\\n"

      # With sandbox
      {:ok, result} = Arbor.Actions.Shell.Execute.run(
        %{command: "ls", sandbox: :strict},
        %{}
      )
  """

  alias Arbor.Shell

  @compound_shell_unavailable {:compound_shell_unavailable, :security_boundary_incomplete}

  @doc false
  @spec authorize_command(String.t(), String.t(), keyword()) ::
          {:ok, :authorized}
          | {:ok, :pending_approval, String.t()}
          | {:error, :unauthorized | term()}
          | {:error, {:compound_shell_unavailable, :security_boundary_incomplete}}
  def authorize_command(agent_id, command, opts \\ [])
      when is_binary(agent_id) and is_binary(command) do
    # Unconditional compound rejection before Trust/Security, approval creation,
    # or any execution. Used by the DOT shell handler — sandbox:none /bin/sh -c
    # must never obtain authorization for metacharacter-bearing commands.
    if Shell.compound_command?(command) do
      {:error, @compound_shell_unavailable}
    else
      command_name = Keyword.get(opts, :gate_command) || extract_command_name(command)
      resource = "arbor://shell/exec/#{command_name}"

      auth_opts =
        [
          command: command,
          path: Keyword.get(opts, :cwd) || Keyword.get(opts, :path),
          verify_identity: false
        ]
        |> maybe_add_opt(:approved_invocation, Keyword.get(opts, :approved_invocation))
        |> maybe_add_opt(:approval_context, Keyword.get(opts, :approval_context))
        |> maybe_add_opt(:task_id, Keyword.get(opts, :task_id))
        |> maybe_add_opt(:session_id, Keyword.get(opts, :session_id))
        |> maybe_add_opt(:params, Keyword.get(opts, :params) || %{command: command})

      case Arbor.Trust.authorize(agent_id, resource, :execute, auth_opts) do
        {:ok, :authorized} -> {:ok, :authorized}
        {:ok, :pending_approval, proposal_id} -> {:ok, :pending_approval, proposal_id}
        {:error, _reason} -> {:error, :unauthorized}
      end
    end
  end

  defp extract_command_name(command) do
    command
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> Path.basename()
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defmodule Execute do
    @moduledoc """
    Execute a shell command.

    Wraps Arbor.Shell.execute/2 as a Jido action for consistent execution
    and LLM tool schema generation.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `command` | string | yes | The shell command to execute |
    | `timeout` | integer | no | Absolute timeout in ms from command start (default: 30000) |
    | `max_output_bytes` | integer | no | Max retained merged-stdout bytes (default 8 MiB; hard max 16 MiB) |
    | `cwd` | string | no | Working directory |
    | `env` | map | no | Environment variables |
    | `sandbox` | atom | no | Sandbox mode: :none, :basic, :strict (default: :basic) |

    ## Returns

    - `exit_code` - The command exit code
    - `stdout` - Merged stdout stream (may be truncated at max_output_bytes)
    - `stderr` - Standard error (empty when Shell merges via stderr_to_stdout)
    - `duration_ms` - Execution duration in milliseconds
    - `timed_out` - Whether the absolute timeout fired
    - `killed` - Whether the OS process was killed
    - `output_limit_exceeded` - Whether retained-output ceiling terminated the run
    - `output_truncated` - Whether stdout was truncated to the ceiling
    """

    use Jido.Action,
      name: "shell_execute",
      description: "Execute a shell command with sandboxing support",
      category: "shell",
      tags: ["shell", "command", "execution"],
      schema: [
        command: [
          type: :string,
          required: true,
          doc: "The shell command to execute"
        ],
        timeout: [
          type: :non_neg_integer,
          default: 30_000,
          doc: "Absolute timeout in milliseconds from command start"
        ],
        max_output_bytes: [
          type: :pos_integer,
          doc:
            "Maximum retained merged-stdout bytes (default 8 MiB via Arbor.Shell; hard max 16 MiB)"
        ],
        cwd: [
          type: :string,
          doc: "Working directory for command execution"
        ],
        env: [
          type: {:map, :string, :string},
          doc: "Environment variables to set"
        ],
        sandbox: [
          type: {:in, [:none, :basic, :strict]},
          default: :basic,
          doc: "Sandbox mode for command validation"
        ]
      ]

    alias Arbor.Actions

    @doc """
    Declares taint roles for Shell.Execute parameters.

    Control parameters that affect execution flow:
    - `command` - The shell command to execute
    - `cwd` - Working directory affects where command runs
    - `sandbox` - Sandbox level affects execution restrictions
    - `max_output_bytes` - Output ceiling governs resource use / process termination

    Data parameters that are just processed:
    - `env` - Environment variables are passed through
    - `timeout` - Numeric timeout doesn't affect security
    """
    @spec taint_roles() :: %{atom() => Arbor.Actions.Taint.role()}
    def taint_roles do
      %{
        command: {:control, requires: [:command_injection]},
        cwd: {:control, requires: [:path_traversal]},
        sandbox: :control,
        env: :data,
        timeout: :data,
        max_output_bytes: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      opts =
        [
          # Do not use `|| 30_000` — timeout: 0 is truthy and becomes an immediate
          # Port kill (exit 137) in Shell.Executor.
          timeout: effective_timeout(params[:timeout], 30_000),
          sandbox: params[:sandbox] || :basic
        ]
        |> maybe_add_opt(:cwd, params[:cwd])
        |> maybe_add_opt(:env, params[:env])
        |> maybe_add_opt(
          :max_output_bytes,
          normalize_forwarded_max_output_bytes(params[:max_output_bytes])
        )
        |> maybe_add_context_opts(context)

      case call_shell(params.command, opts, context) do
        {:ok, result} when is_map(result) ->
          Actions.emit_completed(__MODULE__, result)

          {:ok,
           %{
             exit_code: result.exit_code,
             stdout: result.stdout,
             stderr: result.stderr,
             duration_ms: result.duration_ms,
             timed_out: Map.get(result, :timed_out, false),
             killed: Map.get(result, :killed, false),
             output_limit_exceeded: Map.get(result, :output_limit_exceeded, false),
             output_truncated: Map.get(result, :output_truncated, false)
           }}

        {:ok, :pending_approval, proposal_id} ->
          # Preserve the proposal id for owner-side await/retry (coding validation,
          # ActionsExecutor). Do not convert this into a generic error string —
          # that path is what left stale irq_* records without a waiter.
          {:ok, :pending_approval, proposal_id}

        {:error, :unauthorized} ->
          Actions.emit_failed(__MODULE__, :unauthorized)

          {:error,
           "Shell execution unauthorized (missing capability or policy denied). " <>
             "If an approval was expected, the request was not escalated — check trust rules and grants."}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, format_error(reason)}
      end
    end

    # Authorize once through Trust (honors approved_invocation), then execute.
    # Do NOT call Shell.authorize_and_execute after a successful authorize_command:
    # that re-runs Security.authorize without Trust.ApprovalGuard and re-asks or
    # denies even after the operator already approved the exact invocation.
    #
    # Compound commands are rejected before authorize_command / allowlist / fs
    # work regardless of compound_shell_enabled or sandbox level.
    defp call_shell(command, opts, context) do
      case context[:agent_id] do
        agent_id when is_binary(agent_id) and agent_id != "" ->
          if Arbor.Shell.compound_command?(command) do
            {:error, {:compound_shell_unavailable, :security_boundary_incomplete}}
          else
            auth_opts = shell_auth_opts(opts, context)

            case Arbor.Actions.Shell.authorize_command(agent_id, command, auth_opts) do
              {:ok, :authorized} ->
                execute_authorized_shell(command, opts)

              {:ok, :pending_approval, proposal_id} ->
                {:ok, :pending_approval, proposal_id}

              {:error, reason} ->
                {:error, reason}
            end
          end

        _ ->
          # No agent principal — trusted system path (not an agent action surface).
          Arbor.Shell.execute(command, opts)
      end
    end

    defp shell_auth_opts(opts, context) do
      opts
      |> Keyword.take([:cwd, :path, :approved_invocation, :gate_command, :timeout, :sandbox])
      |> maybe_add_opt(:cwd, Keyword.get(opts, :cwd) || context[:cwd])
      |> maybe_add_opt(:approved_invocation, context[:approved_invocation])
      |> maybe_add_opt(:approval_context, shell_approval_context(opts, context))
    end

    defp shell_approval_context(opts, context) do
      case Keyword.get(opts, :approval_context) || context[:approval_context] do
        %{} = existing ->
          existing

        _ ->
          %{
            task_id: context[:task_id] || context["task_id"],
            session_id: context[:session_id] || context["session_id"],
            provenance: %{
              task_id: context[:task_id] || context["task_id"],
              session_id: context[:session_id] || context["session_id"]
            }
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()
          |> case do
            empty when empty == %{} -> nil
            map -> map
          end
      end
    end

    # Execute after Trust already authorized a non-compound command.
    # Call only public Arbor.Shell APIs — never Sandbox or CapShell internals.
    # System-only execute/2 is safe here because compounds were rejected above.
    defp execute_authorized_shell(command, opts) do
      Arbor.Shell.execute(command, opts)
    end

    # LLM-facing boundary: floor tiny/zero timeouts (0, 1, …) to the default.
    # Sub-second values are almost always optional-arg footguns, not intentional
    # budgets. Low-level Executor tests may still pass timeout: 100 directly.
    @min_action_timeout_ms 1_000

    defp effective_timeout(timeout, _default)
         when is_integer(timeout) and timeout >= @min_action_timeout_ms,
         do: timeout

    defp effective_timeout(_timeout, default), do: default

    # Forward through the public Arbor.Shell facade only — hard max / default
    # live in arbor_shell. Nil/invalid left unset so Shell applies its default;
    # Executor re-normalizes as defense in depth.
    defp normalize_forwarded_max_output_bytes(n) when is_integer(n) and n > 0,
      do: Arbor.Shell.normalize_max_output_bytes(n)

    defp normalize_forwarded_max_output_bytes(_n), do: nil

    defp maybe_add_opt(opts, _key, nil), do: opts
    defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

    defp maybe_add_context_opts(opts, context) do
      # Allow context to override options and carry approval/task provenance
      opts
      |> maybe_add_opt(:cwd, context[:cwd])
      |> maybe_add_opt(:env, context[:env])
      |> maybe_add_opt(:approved_invocation, context[:approved_invocation])
      |> maybe_add_opt(:task_id, context[:task_id] || context["task_id"])
      |> maybe_add_opt(:session_id, context[:session_id] || context["session_id"])
    end

    defp format_error({:blocked_command, cmd}), do: "Command blocked: #{cmd}"
    defp format_error({:dangerous_flags, flags}), do: "Dangerous flags blocked: #{inspect(flags)}"
    defp format_error(:eacces), do: "Shell execution failed: permission denied."

    defp format_error({:shell_metacharacters, chars}),
      do:
        "Shell metacharacters #{inspect(chars)} are not allowed. Use individual commands without chaining (no ;, &&, ||, |, etc.)."

    defp format_error({:compound_shell_unavailable, :security_boundary_incomplete}),
      do:
        "Compound shell execution is unavailable (security boundary incomplete). " <>
          "Use individual non-compound commands; CapShell is intentionally fail-closed."

    defp format_error(reason) when is_binary(reason), do: reason
    defp format_error(reason), do: "Shell execution failed: #{inspect(reason)}"
  end

  defmodule ExecuteScript do
    @moduledoc """
    Fail-closed multi-line shell script action (intentionally unavailable).

    **Intentional security API break:** static per-line sandbox admission is not
    a security proof of expanded runtime argv or script semantics. CapShell is
    retired; this action must not create temp files, authorize, or launch
    interpreters. Every `run/2` returns a stable unavailable error string.

    Schema is retained so the tool remains discoverable as unavailable rather
    than disappearing from catalogs mid-rollout.
    """

    use Jido.Action,
      name: "shell_execute_script",
      description:
        "Execute a multi-line shell script (unavailable: security boundary incomplete)",
      category: "shell",
      tags: ["shell", "script", "execution"],
      schema: [
        script: [
          type: :string,
          required: true,
          doc: "The shell script content to execute"
        ],
        shell: [
          type: :string,
          default: "/bin/bash",
          doc: "Shell interpreter to use"
        ],
        timeout: [
          type: :non_neg_integer,
          default: 60_000,
          doc: "Timeout in milliseconds"
        ],
        cwd: [
          type: :string,
          doc: "Working directory for script execution"
        ],
        env: [
          type: {:map, :string, :string},
          doc: "Environment variables to set"
        ],
        sandbox: [
          type: {:in, [:none, :basic, :strict]},
          default: :basic,
          doc: "Sandbox mode for script validation"
        ]
      ]

    # Exact stable string asserted by security regressions — keep in sync with
    # Execute.format_error/1 for the compound_shell_unavailable tuple.
    @unavailable_message "Compound shell execution is unavailable (security boundary incomplete). Use individual non-compound commands; CapShell is intentionally fail-closed."

    @impl true
    @spec run(map(), map()) :: {:error, String.t()}
    def run(_params, _context) do
      # Fail closed before emit / temp-file / auth / process / fs work.
      # Static line-by-line admission is intentionally unreachable.
      {:error, @unavailable_message}
    end
  end
end
