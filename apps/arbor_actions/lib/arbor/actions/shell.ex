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

  defmodule Execute do
    @moduledoc """
    Execute a shell command.

    Wraps Arbor.Shell.execute/2 as a Jido action for consistent execution
    and LLM tool schema generation.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `command` | string | yes | The shell command to execute |
    | `timeout` | integer | no | Timeout in milliseconds (default: 30000) |
    | `cwd` | string | no | Working directory |
    | `env` | map | no | Environment variables |
    | `sandbox` | atom | no | Sandbox mode: :none, :basic, :strict (default: :basic) |

    ## Returns

    - `exit_code` - The command exit code
    - `stdout` - Standard output
    - `stderr` - Standard error
    - `duration_ms` - Execution duration in milliseconds
    - `timed_out` - Whether the command timed out
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
          doc: "Timeout in milliseconds"
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

    Data parameters that are just processed:
    - `env` - Environment variables are passed through
    - `timeout` - Numeric timeout doesn't affect security
    """
    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{
        command: :control,
        cwd: :control,
        sandbox: :control,
        env: :data,
        timeout: :data
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      opts =
        [
          timeout: params[:timeout] || 30_000,
          sandbox: params[:sandbox] || :basic
        ]
        |> maybe_add_opt(:cwd, params[:cwd])
        |> maybe_add_opt(:env, params[:env])
        |> maybe_add_context_opts(context)

      case Shell.execute(params.command, opts) do
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

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, format_error(reason)}
      end
    end

    defp maybe_add_opt(opts, _key, nil), do: opts
    defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

    defp maybe_add_context_opts(opts, context) do
      # Allow context to override options
      opts
      |> maybe_add_opt(:cwd, context[:cwd])
      |> maybe_add_opt(:env, context[:env])
    end

    defp format_error({:blocked_command, cmd}), do: "Command blocked: #{cmd}"
    defp format_error({:dangerous_flags, flags}), do: "Dangerous flags blocked: #{inspect(flags)}"
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

        opts =
          [
            timeout: params[:timeout] || 60_000,
            sandbox: sandbox_level
          ]
          |> maybe_add_opt(:cwd, params[:cwd])
          |> maybe_add_opt(:env, params[:env])
          |> maybe_add_context_opts(context)

        case Shell.execute(command, opts) do
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

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, format_error(reason)}
        end
      after
        # Clean up the temporary script file
        File.rm(script_path)
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
    end

    defp format_error({:blocked_command, cmd}), do: "Command blocked: #{cmd}"
    defp format_error({:dangerous_flags, flags}), do: "Dangerous flags blocked: #{inspect(flags)}"
    defp format_error(reason), do: "Script execution failed: #{inspect(reason)}"
  end
end
