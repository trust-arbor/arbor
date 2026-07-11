defmodule Arbor.Orchestrator.Handlers.ShellHandler do
  @moduledoc """
  Handler that executes shell commands.

  Agent-authored commands are validated before authorization and execute only
  through `Arbor.Shell`'s closed direct-argv policy. Shell interpreters,
  dispatch wrappers, compound syntax, and environment-fed runtime expansion are
  unavailable while CapShell is absent. There is no `/bin/sh -c` fallback.

  Node attributes:
    - `command` - shell command to execute (required)
    - `timeout` - timeout in milliseconds (default: "120000")
    - `cwd` - compatibility attribute; immutable run authority owns the workdir
    - `sandbox` - sandbox mode: "none", "basic", "strict" (default: "basic")
    - `on_error` - behavior on non-zero exit: "fail" (default), "warn", "continue"
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Outcome, RunAuthorization}

  import Arbor.Orchestrator.Handlers.Helpers

  @default_timeout 120_000

  @impl true
  def execute(node, context, _graph, opts) do
    command = Map.get(node.attrs, "command")

    unless command do
      raise "shell handler requires 'command' attribute"
    end

    timeout = parse_int(Map.get(node.attrs, "timeout"), @default_timeout)
    on_error = Map.get(node.attrs, "on_error", "fail")

    sandbox = Map.get(node.attrs, "sandbox", "basic")
    _ = context

    with {:ok, authority} <- immutable_authority(opts),
         execution_opts = [
           cwd: authority.workdir,
           timeout: timeout,
           sandbox: sandbox_mode(sandbox)
         ],
         {:ok, prepared} <- Arbor.Shell.prepare_agent_command(command, execution_opts),
         :ok <- authorize_shell(authority, command, opts) do
      run_authorized(node, command, prepared, on_error, execution_opts)
    else
      {:error, {:authorization_denied, principal, reason}} ->
        %Outcome{
          status: :fail,
          failure_reason: "shell authorization denied for #{principal}: #{inspect(reason)}",
          context_updates: %{"shell.#{node.id}.error" => "unauthorized: #{inspect(reason)}"}
        }

      {:error, reason} ->
        %Outcome{
          status: :fail,
          failure_reason: "shell command rejected before execution: #{inspect(reason)}",
          context_updates: %{"shell.#{node.id}.error" => "rejected: #{inspect(reason)}"}
        }
    end
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "shell handler error: #{Exception.message(e)}"
      }
  end

  @impl true
  def idempotency, do: :side_effecting

  # --- Authorization (phase 0 capability gate) ---

  # Original execution path — reached ONLY after authorize_shell/4 passes.
  defp run_authorized(node, command, prepared, on_error, opts) do
    case run_command(command, prepared, opts) do
      {:ok, output, exit_code} ->
        # Shell stdout is exposed as `shell.<id>.output` only — NOT as
        # `last_response`. `last_response` is the LLM-output convention
        # (see handler_schema.ex compute ports). Pipelines of the shape
        # `LLM → shell → use last_response` previously lost the LLM
        # response because the shell node clobbered it with its own
        # stdout (often empty). Downstream nodes that want shell stdout
        # reference the namespaced key directly.
        base_updates = %{
          "shell.#{node.id}.exit_code" => exit_code,
          "shell.#{node.id}.output" => output
        }

        if exit_code == 0 do
          %Outcome{status: :success, notes: truncate(output, 500), context_updates: base_updates}
        else
          handle_error(on_error, exit_code, output, base_updates, node)
        end

      {:error, reason} ->
        %Outcome{
          status: :fail,
          failure_reason: "shell error: #{inspect(reason)}",
          context_updates: %{"shell.#{node.id}.error" => inspect(reason)}
        }
    end
  end

  # Capability gate. Returns :ok to proceed, or {:error, reason} to fail
  # closed (the node fails; the command never runs).
  #
  # SECURITY: the default authorizer enters the trust-layer policy gate, which
  # then delegates to the security kernel. Tests can inject a stub via
  # :shell_authorizer. The legacy "no facade → :ok (allow)" fail-open branch is
  # gone: a missing capability system can no longer let a shell command run
  # unauthorized.
  defp authorize_shell(%RunAuthorization{} = authority, command, opts) do
    authorize_fun = shell_authorizer(opts)
    auth_opts = [cwd: authority.workdir] ++ RunAuthorization.scope_opts(authority)

    case authorize_fun.(authority.execution_principal, command, auth_opts) do
      {:ok, :authorized} ->
        :ok

      {:ok, :pending_approval, proposal_id} ->
        {:error,
         {:authorization_denied, authority.execution_principal, {:pending_approval, proposal_id}}}

      {:error, reason} ->
        {:error, {:authorization_denied, authority.execution_principal, reason}}
    end
  end

  defp immutable_authority(opts) do
    case Keyword.get(opts, :run_authorization) do
      %RunAuthorization{} = authority ->
        with :ok <- RunAuthorization.verify_runtime(authority),
             :ok <- reject_system_escalation(authority.execution_principal) do
          {:ok, authority}
        else
          {:error, reason} -> {:error, {:invalid_run_authorization, reason}}
        end

      _ ->
        {:error, :missing_run_authorization}
    end
  end

  defp reject_system_escalation(principal) when principal in ["system", "agent_system"],
    do: {:error, :system_principal_shell_forbidden}

  defp reject_system_escalation(_principal), do: :ok

  # Resolve the shell authorizer:
  #   1. explicit override in opts (tests inject a stub via :shell_authorizer)
  #   2. trust-layer shell authorization — policy may mint, security enforces
  defp shell_authorizer(opts) do
    case opts[:shell_authorizer] do
      fun when is_function(fun, 3) -> fun
      _ -> &Arbor.Actions.Shell.authorize_command/3
    end
  end

  # --- Command execution ---

  defp run_command(command, prepared, opts), do: run_via_arbor_shell(command, prepared, opts)

  defp run_via_arbor_shell(command, prepared, opts) do
    try do
      case Arbor.Shell.execute_bound_agent_command(command, prepared, opts) do
        {:ok, %{timed_out: true}} ->
          {:error, :timeout}

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

  defp sandbox_mode("none"), do: :none
  defp sandbox_mode("strict"), do: :strict
  defp sandbox_mode(_), do: :basic

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
