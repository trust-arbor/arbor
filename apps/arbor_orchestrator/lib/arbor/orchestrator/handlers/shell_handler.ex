defmodule Arbor.Orchestrator.Handlers.ShellHandler do
  @moduledoc """
  Handler that executes shell commands.

  Uses `Arbor.Shell.execute/2` when available (full umbrella with sandbox,
  signals, security), falls back to raw `System.cmd` when running standalone.

  Node attributes:
    - `command` - shell command to execute (required)
    - `timeout` - timeout in milliseconds (default: "120000")
    - `cwd` - working directory (optional, defaults to context "workdir" or ".")
    - `sandbox` - sandbox mode: "none", "basic", "strict" (default: "basic")
    - `on_error` - behavior on non-zero exit: "fail" (default), "warn", "continue"
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  import Arbor.Orchestrator.Handlers.Helpers

  @default_timeout 120_000

  @impl true
  def execute(node, context, _graph, opts) do
    try do
      command = Map.get(node.attrs, "command")

      unless command do
        raise "shell handler requires 'command' attribute"
      end

      timeout = parse_int(Map.get(node.attrs, "timeout"), @default_timeout)
      on_error = Map.get(node.attrs, "on_error", "fail")

      cwd =
        Map.get(node.attrs, "cwd") ||
          Context.get(context, "workdir") ||
          Keyword.get(opts, :workdir, ".")

      sandbox = Map.get(node.attrs, "sandbox", "basic")

      case run_command(command, cwd: cwd, timeout: timeout, sandbox: sandbox) do
        {:ok, output, exit_code} ->
          base_updates = %{
            "shell.#{node.id}.exit_code" => exit_code,
            "shell.#{node.id}.output" => output,
            "last_response" => output
          }

          if exit_code == 0 do
            %Outcome{
              status: :success,
              notes: truncate(output, 500),
              context_updates: base_updates
            }
          else
            handle_error(on_error, exit_code, output, base_updates, node)
          end

        {:error, reason} ->
          %Outcome{
            status: :fail,
            failure_reason: "shell error: #{inspect(reason)}",
            context_updates: %{
              "shell.#{node.id}.error" => inspect(reason)
            }
          }
      end
    rescue
      e ->
        %Outcome{
          status: :fail,
          failure_reason: "shell handler error: #{Exception.message(e)}"
        }
    end
  end

  @impl true
  def idempotency, do: :side_effecting

  # --- Command execution with runtime bridge ---

  defp run_command(command, opts) do
    if arbor_shell_available?() do
      case run_via_arbor_shell(command, opts) do
        {:error, {:noproc, _}} -> run_via_system_cmd(command, opts)
        result -> result
      end
    else
      run_via_system_cmd(command, opts)
    end
  end

  defp arbor_shell_available? do
    Code.ensure_loaded?(Arbor.Shell) and
      function_exported?(Arbor.Shell, :execute, 2)
  end

  defp run_via_arbor_shell(command, opts) do
    sandbox_mode =
      case Keyword.get(opts, :sandbox, "basic") do
        "none" -> :none
        "strict" -> :strict
        _ -> :basic
      end

    shell_opts = [
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      sandbox: sandbox_mode
    ]

    shell_opts =
      case Keyword.get(opts, :cwd) do
        nil -> shell_opts
        cwd -> Keyword.put(shell_opts, :cwd, cwd)
      end

    try do
      case apply(Arbor.Shell, :execute, [command, shell_opts]) do
        {:ok, result} ->
          output = Map.get(result, :stdout, "") <> Map.get(result, :stderr, "")
          exit_code = Map.get(result, :exit_code, 0)
          {:ok, output, exit_code}

        {:error, reason} ->
          {:error, reason}
      end
    catch
      :exit, {reason, _} -> {:error, {:noproc, reason}}
    end
  end

  defp run_via_system_cmd(command, opts) do
    cwd = Keyword.get(opts, :cwd, ".")
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    port =
      Port.open(
        {:spawn, command},
        [:binary, :exit_status, :stderr_to_stdout, {:cd, to_charlist(cwd)}]
      )

    collect_output(port, <<>>, timeout)
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data, timeout)

      {^port, {:exit_status, code}} ->
        {:ok, acc, code}
    after
      timeout ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  # --- Error handling ---

  defp handle_error("warn", exit_code, output, updates, _node) do
    %Outcome{
      status: :success,
      notes: "Command exited with code #{exit_code}: #{truncate(output, 300)}",
      context_updates: updates
    }
  end

  defp handle_error("continue", exit_code, _output, updates, _node) do
    %Outcome{
      status: :success,
      notes: "Command exited with code #{exit_code} (continuing)",
      context_updates: updates
    }
  end

  defp handle_error(_fail, exit_code, output, updates, _node) do
    %Outcome{
      status: :fail,
      failure_reason: "Command exited with code #{exit_code}: #{truncate(output, 500)}",
      context_updates: updates
    }
  end

  # --- Utilities ---

  defp truncate(str, max) when is_binary(str) and byte_size(str) > max do
    String.slice(str, -max, max)
  end

  defp truncate(str, _max), do: str
end
