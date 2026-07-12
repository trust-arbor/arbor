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

  Single-command `Execute` uses Arbor.Shell's closed direct-executable policy:

  - `:none` - Compatibility value only; cannot widen agent execution
  - `:basic` / `:strict` - Also use the same closed direct policy

  Non-empty child environments are intentionally unavailable on this generic
  action. Schema-specific Git/Mix actions retain structured argv and their
  bounded environment handling.

  ## Examples

      # Simple command
      context = %{agent_id: "agent_authenticated"}
      {:ok, result} = Arbor.Actions.Shell.Execute.run(%{command: "echo hello"}, context)
      result.stdout  # => "hello\\n"

      # With sandbox
      {:ok, result} = Arbor.Actions.Shell.Execute.run(
        %{command: "ls", sandbox: :strict},
        context
      )
  """

  alias Arbor.Shell

  @doc false
  @spec authorize_command(String.t(), String.t(), keyword()) ::
          {:ok, :authorized}
          | {:ok, :pending_approval, String.t()}
          | {:error, :unauthorized | term()}
          | {:error, {:compound_shell_unavailable, :security_boundary_incomplete}}
  def authorize_command(agent_id, command, opts \\ [])

  def authorize_command(agent_id, command, opts)
      when is_binary(command) and is_list(opts) do
    with :ok <- validate_agent_principal(agent_id),
         {:ok, prepared} <- Shell.prepare_agent_command(command, opts) do
      authorize_prepared(agent_id, command, prepared, opts)
    end
  end

  def authorize_command(_agent_id, _command, _opts), do: {:error, :invalid_agent_principal}

  @doc false
  @spec authorize_and_execute_command(String.t(), String.t(), keyword()) ::
          {:ok, map()}
          | {:ok, :pending_approval, String.t()}
          | {:error, term()}
  def authorize_and_execute_command(agent_id, command, opts \\ [])

  def authorize_and_execute_command(agent_id, command, opts)
      when is_binary(command) and is_list(opts) do
    with :ok <- validate_agent_principal(agent_id),
         {:ok, prepared} <- Shell.prepare_agent_command(command, opts) do
      case authorize_prepared(agent_id, command, prepared, opts) do
        {:ok, :authorized} -> execute_prepared(prepared, opts)
        {:ok, :pending_approval, proposal_id} -> {:ok, :pending_approval, proposal_id}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def authorize_and_execute_command(_agent_id, _command, _opts),
    do: {:error, :invalid_agent_principal}

  defp validate_agent_principal(agent_id) when is_binary(agent_id) do
    if String.trim(agent_id) == "", do: {:error, :invalid_agent_principal}, else: :ok
  end

  defp validate_agent_principal(_agent_id), do: {:error, :invalid_agent_principal}

  defp authorize_prepared(agent_id, command, prepared, opts) do
    resource = "arbor://shell/exec/#{prepared.command_name}"

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
      _other -> {:error, :unauthorized}
    end
  end

  defp execute_prepared(%{executable: executable, args: args}, opts) do
    execution_opts =
      opts
      |> Keyword.drop([
        :env,
        :allowlist,
        :gate_command,
        :approved_invocation,
        :approval_context,
        :task_id,
        :session_id,
        :params,
        :path
      ])
      |> Keyword.put(:sandbox, :basic)

    Shell.execute_direct(executable, args, execution_opts)
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

    Environment is execution control on a generic process boundary:
    - `env` - Rejected when non-empty; loader/runtime variables can execute code

    Data parameters that are just processed:
    - `timeout` - Numeric timeout doesn't affect security
    """
    @spec taint_roles() :: %{atom() => Arbor.Actions.Taint.role()}
    def taint_roles do
      %{
        command: {:control, requires: [:command_injection]},
        cwd: {:control, requires: [:path_traversal]},
        sandbox: :control,
        env: :control,
        timeout: :data,
        max_output_bytes: :control
      }
    end

    # Exact stable string for compound rejection at the action surface.
    # Keep in sync with format_error/1 and ExecuteScript.
    @unavailable_message "Compound shell execution is unavailable (security boundary incomplete). Use individual non-compound commands; CapShell is intentionally fail-closed."

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, context) do
      command = Map.get(params, :command) || Map.get(params, "command")

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

      # Closed executable admission and authority both happen before action
      # signals, approval creation, registry, or process work.
      with {:ok, _prepared} <- Arbor.Shell.prepare_agent_command(command, opts),
           {:ok, agent_id} <- exact_principal(context) do
        Actions.emit_started(__MODULE__, params)

        case call_shell(agent_id, command, opts, context) do
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
            # ActionsExecutor). Do not convert this into a generic error string.
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
      else
        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end

    # Authorize once through Trust (honors approved_invocation), then execute.
    # Do NOT call Shell.authorize_and_execute after a successful authorize_command:
    # that re-runs Security.authorize without Trust.ApprovalGuard and re-asks or
    # denies even after the operator already approved the exact invocation.
    #
    # Defense in depth: compounds are also rejected here if run/2's gate is
    # bypassed. Missing agent_id never falls through to system execute for
    # compounds.
    defp call_shell(agent_id, command, opts, context) do
      auth_opts = shell_auth_opts(opts, context)
      Arbor.Actions.Shell.authorize_and_execute_command(agent_id, command, auth_opts)
    end

    defp shell_auth_opts(opts, context) do
      opts
      |> Keyword.take([
        :cwd,
        :path,
        :approved_invocation,
        :gate_command,
        :timeout,
        :sandbox,
        :max_output_bytes
      ])
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

    defp exact_principal(context) when is_map(context) do
      case {Map.fetch(context, :agent_id), Map.fetch(context, "agent_id")} do
        {{:ok, agent_id}, :error} when is_binary(agent_id) ->
          validate_exact_principal(agent_id)

        {:error, {:ok, agent_id}} when is_binary(agent_id) ->
          validate_exact_principal(agent_id)

        {{:ok, _atom_id}, {:ok, _string_id}} ->
          {:error, :ambiguous_shell_principal}

        _other ->
          {:error, :missing_shell_principal}
      end
    end

    defp exact_principal(_context), do: {:error, :missing_shell_principal}

    defp validate_exact_principal(agent_id) do
      if String.trim(agent_id) == "",
        do: {:error, :missing_shell_principal},
        else: {:ok, agent_id}
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

    defp format_error({:agent_executable_not_allowed, cmd}),
      do: "Generic agent shell executable is not allowed: #{cmd}"

    defp format_error({:agent_executable_path_not_allowed, path}),
      do: "Generic agent shell executable path is not allowed: #{path}"

    defp format_error({:agent_argv_not_allowed, command, reason}),
      do: "Generic agent shell arguments rejected for #{command}: #{inspect(reason)}"

    defp format_error({:agent_shell_option_not_allowed, :env}),
      do: "Generic agent shell environment overrides are unavailable."

    defp format_error({:agent_shell_gate_mismatch, gate, command}),
      do: "Shell authorization target #{gate} does not match executable #{command}."

    defp format_error(:missing_shell_principal),
      do: "Shell execution requires one authenticated principal in context."

    defp format_error(:ambiguous_shell_principal),
      do: "Shell execution rejected ambiguous principal identity in context."

    defp format_error(:invalid_agent_principal),
      do: "Shell execution rejected an invalid authenticated principal."

    defp format_error(:eacces), do: "Shell execution failed: permission denied."

    defp format_error({:shell_metacharacters, chars}),
      do:
        "Shell metacharacters #{inspect(chars)} are not allowed. Use individual commands without chaining (no ;, &&, ||, |, etc.)."

    defp format_error({:compound_shell_unavailable, :security_boundary_incomplete}),
      do: @unavailable_message

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
