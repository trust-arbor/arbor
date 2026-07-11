defmodule Arbor.Actions.Shell do
  @moduledoc """
  Shell command execution actions.

  This module provides Jido-compatible actions for executing shell commands
  with sandbox support and observability through Arbor.Signals.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Execute` | Execute a single shell command |
  | `ExecuteScript` | Execute a multi-line shell script |

  ## Sandbox Support

  All shell actions support sandboxing through Arbor.Shell:

  - `:none` - No restrictions
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

      # Script execution
      {:ok, result} = Arbor.Actions.Shell.ExecuteScript.run(
        %{script: "echo hello\\necho world"},
        %{}
      )
  """

  alias Arbor.Shell

  @doc false
  @spec authorize_command(String.t(), String.t(), keyword()) ::
          {:ok, :authorized}
          | {:ok, :pending_approval, String.t()}
          | {:error, :unauthorized | term()}
  def authorize_command(agent_id, command, opts \\ [])
      when is_binary(agent_id) and is_binary(command) do
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
    defp call_shell(command, opts, context) do
      case context[:agent_id] do
        agent_id when is_binary(agent_id) and agent_id != "" ->
          auth_opts = shell_auth_opts(opts, context)

          case Arbor.Actions.Shell.authorize_command(agent_id, command, auth_opts) do
            {:ok, :authorized} ->
              execute_authorized_shell(agent_id, command, opts)

            {:ok, :pending_approval, proposal_id} ->
              {:ok, :pending_approval, proposal_id}

            {:error, reason} ->
              {:error, reason}
          end

        _ ->
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

    # Execute after Trust already authorized. When the shell facade opts into
    # CapShell (`Arbor.Shell.compound_shell_enabled?/0`, default false), compound
    # commands go through CapShell for per-token path/capability checks; otherwise
    # (and for simple commands) use the bounded Executor via execute/2.
    defp execute_authorized_shell(agent_id, command, opts) do
      if Arbor.Shell.compound_shell_enabled?() and Arbor.Shell.Sandbox.compound?(command) do
        case Arbor.Shell.CapShell.run(agent_id, command, opts) do
          {:ok, %{exit_code: code, stdout: out, stderr: err} = result} ->
            {:ok,
             %{
               exit_code: code,
               stdout: out,
               stderr: err,
               duration_ms: Map.get(result, :duration_ms, 0),
               timed_out: Map.get(result, :timed_out, false)
             }}

          {:ok, result} when is_map(result) ->
            {:ok, result}

          {:error, reason} ->
            {:error, reason}
        end
      else
        Arbor.Shell.execute(command, opts)
      end
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

    defp format_error(reason) when is_binary(reason), do: reason
    defp format_error(reason), do: "Shell execution failed: #{inspect(reason)}"
  end

  defmodule ExecuteScript do
    @moduledoc """
    Execute a multi-line shell script.

    Creates a temporary script file and executes it with the specified shell.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `script` | string | yes | The script content to execute |
    | `shell` | string | no | Shell to use (default: "/bin/bash") |
    | `timeout` | integer | no | Timeout in milliseconds (default: 60000) |
    | `cwd` | string | no | Working directory |
    | `env` | map | no | Environment variables |
    | `sandbox` | atom | no | Sandbox mode (default: :basic) |

    ## Returns

    - `exit_code` - The script exit code
    - `stdout` - Standard output
    - `stderr` - Standard error
    - `duration_ms` - Execution duration in milliseconds
    - `timed_out` - Whether the script timed out
    """

    use Jido.Action,
      name: "shell_execute_script",
      description: "Execute a multi-line shell script",
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

    alias Arbor.Actions
    alias Arbor.Shell.Sandbox

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      sandbox_level = params[:sandbox] || :basic

      # Validate each line of the script against the sandbox BEFORE execution
      case validate_script_content(params.script, sandbox_level) do
        :ok ->
          execute_script(params, context, sandbox_level)

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, format_error(reason)}
      end
    end

    defp execute_script(params, context, sandbox_level) do
      # Create a temporary script file
      script_path = create_temp_script(params.script)

      try do
        shell = params[:shell] || "/bin/bash"
        command = "#{shell} #{script_path}"

        # The script CONTENT was already validated line-by-line at
        # `sandbox_level` by validate_script_content/2 above. The interpreter
        # invocation itself (`/bin/bash <tmpfile>`) is this action's controlled
        # mechanism, so run it at :none — re-checking it against the sandbox
        # command denylist is redundant and, now that interpreters are blocked
        # at :basic/:strict (codex sandbox.shell-basic-nested-command-bypass),
        # would deny the action outright. Capability/approval auth in call_shell
        # still applies regardless of sandbox level.
        _ = sandbox_level

        opts =
          [
            timeout: params[:timeout] || 60_000,
            sandbox: :none
          ]
          |> maybe_add_opt(:cwd, params[:cwd])
          |> maybe_add_opt(:env, params[:env])
          |> maybe_add_context_opts(context)

        case call_shell(command, opts, context) do
          {:ok, result} ->
            Actions.emit_completed(__MODULE__, result)

            {:ok,
             %{
               exit_code: result.exit_code,
               stdout: result.stdout,
               stderr: result.stderr,
               duration_ms: result.duration_ms,
               timed_out: result.timed_out
             }}

          {:ok, :pending_approval, proposal_id} ->
            {:ok, :pending_approval, proposal_id}

          {:error, :unauthorized} ->
            Actions.emit_failed(__MODULE__, :unauthorized)

            {:error,
             "Shell execution requires approval. The command will be submitted for user review. Try again and the user will be prompted to approve."}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, format_error(reason)}
        end
      after
        # Clean up the temporary script file
        File.rm(script_path)
      end
    end

    # Delegate to facade authorize_and_execute when agent_id is in context
    defp call_shell(command, opts, context) do
      if context[:agent_id] do
        with {:ok, :authorized} <-
               Arbor.Actions.Shell.authorize_command(context[:agent_id], command, opts) do
          Shell.authorize_and_execute(context[:agent_id], command, opts)
        end
      else
        Shell.execute(command, opts)
      end
    end

    defp validate_script_content(_script, :none), do: :ok

    defp validate_script_content(script, sandbox_level) do
      script
      |> String.split("\n")
      |> Enum.reject(fn line ->
        trimmed = String.trim(line)
        trimmed == "" or String.starts_with?(trimmed, "#")
      end)
      |> Enum.reduce_while(:ok, fn line, :ok ->
        case Sandbox.check(String.trim(line), sandbox_level) do
          {:ok, :allowed} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:script_line_blocked, line, reason}}}
        end
      end)
    end

    defp create_temp_script(script_content) do
      path =
        Path.join(System.tmp_dir!(), "arbor_script_#{:erlang.unique_integer([:positive])}.sh")

      File.write!(path, script_content)
      File.chmod!(path, 0o700)
      path
    end

    defp maybe_add_opt(opts, _key, nil), do: opts
    defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

    defp maybe_add_context_opts(opts, context) do
      opts
      |> maybe_add_opt(:cwd, context[:cwd])
      |> maybe_add_opt(:env, context[:env])
      |> maybe_add_opt(:approved_invocation, context[:approved_invocation])
    end

    defp format_error({:blocked_command, cmd}), do: "Command blocked: #{cmd}"
    defp format_error({:dangerous_flags, flags}), do: "Dangerous flags blocked: #{inspect(flags)}"
    defp format_error(:eacces), do: "Script execution failed: permission denied."

    defp format_error({:shell_metacharacters, chars}),
      do:
        "Shell metacharacters #{inspect(chars)} are not allowed. Use individual commands without chaining (no ;, &&, ||, |, etc.)."

    defp format_error(reason) when is_binary(reason), do: reason
    defp format_error(reason), do: "Script execution failed: #{inspect(reason)}"
  end
end
