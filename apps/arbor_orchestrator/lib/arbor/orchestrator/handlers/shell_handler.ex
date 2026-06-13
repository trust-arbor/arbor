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
    agent_id = resolve_agent_id(node, context)

    # Capability gate (phase 0, 2026-06-10). This handler previously ran
    # `command` with NO authorization — any agent that could author or
    # influence a DOT graph got arbitrary shell, including the
    # `sandbox="none"` real-`/bin/sh -c` path. Authorize the resolved
    # principal before *any* execution mechanism; fail closed on
    # denial/escalation. ExecHandler's sibling `target="action"` branch
    # already authorizes; `target="shell"` was the orphan path.
    # See .arbor/roadmap/1-brainstorming/safe-shell-execution.md (Phase 0).
    case authorize_shell(agent_id, command, cwd, opts) do
      :ok ->
        run_authorized(node, command, on_error, cwd: cwd, timeout: timeout, sandbox: sandbox)

      {:error, reason} ->
        %Outcome{
          status: :fail,
          failure_reason: "shell authorization denied for #{agent_id}: #{inspect(reason)}",
          context_updates: %{"shell.#{node.id}.error" => "unauthorized: #{inspect(reason)}"}
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
  defp run_authorized(node, command, on_error, opts) do
    case run_command(command, opts) do
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

  # Resolve the principal whose capabilities govern this shell node. Mirrors
  # ExecHandler's action path: explicit node override, else the session's
  # agent, else the "system" default.
  defp resolve_agent_id(node, context) do
    Map.get(node.attrs, "agent_id") ||
      Context.get(context, "session.agent_id", "system")
  end

  # Capability gate. Returns :ok to proceed, or {:error, reason} to fail
  # closed (the node fails; the command never runs).
  defp authorize_shell(agent_id, command, cwd, opts) do
    case shell_authorizer(opts) do
      nil ->
        # No security facade available (standalone orchestrator without
        # arbor_shell). There is no capability system to consult and no
        # agent system to attack — preserve legacy direct execution for
        # dev/test standalone use. In the full umbrella the facade is
        # loaded and the branch below runs.
        :ok

      authorize_fun ->
        auth_opts = if cwd, do: [cwd: cwd], else: []

        case authorize_fun.(agent_id, command, auth_opts) do
          {:ok, :authorized} -> :ok
          {:ok, :pending_approval, proposal_id} -> {:error, {:pending_approval, proposal_id}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Resolve the shell authorizer:
  #   1. explicit override in opts (tests inject a stub via :shell_authorizer)
  #   2. Arbor.Shell.authorize/3 when the security facade is loaded (production)
  #   3. nil — standalone mode, no capability system present
  #
  # Runtime indirection (Code.ensure_loaded?/apply) because arbor_orchestrator
  # is standalone and must not take a compile-time dep on arbor_shell.
  defp shell_authorizer(opts) do
    cond do
      is_function(opts[:shell_authorizer], 3) ->
        opts[:shell_authorizer]

      Code.ensure_loaded?(Arbor.Shell) and function_exported?(Arbor.Shell, :authorize, 3) ->
        fn agent_id, command, auth_opts ->
          apply(Arbor.Shell, :authorize, [agent_id, command, auth_opts])
        end

      true ->
        nil
    end
  end

  # --- Command execution with runtime bridge ---

  defp run_command(command, opts) do
    sandbox = Keyword.get(opts, :sandbox, "basic")

    cond do
      sandbox == "none" ->
        # Explicit sandbox="none" in DOT spec — caller accepts unsandboxed execution.
        # Skip Arbor.Shell entirely to avoid :noproc when process isn't running.
        run_via_system_cmd(command, opts)

      arbor_shell_available?() ->
        run_via_arbor_shell(command, opts)

      true ->
        # Fail-closed: don't silently fall back to unsandboxed Port.open
        # when Arbor.Shell is unavailable. The :noproc fallback previously
        # removed all sandboxing on transient process failures.
        {:error, :sandbox_unavailable}
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

    # IMPORTANT: use `:spawn_executable` with an explicit `/bin/sh -c`,
    # NOT `{:spawn, command}`. The `:spawn` form tokenizes the command
    # via shell-like splitting and execs the first token directly —
    # there is NO real shell, so operators like `&&`, `||`, `|`, `;`,
    # `$(…)`, and globbing are passed as literal argv tokens. For
    # example, `mkdir -p X && printf Y` becomes `mkdir` invoked with
    # `[-p, X, &&, printf, Y]` (mkdir -p happily creates all of these
    # as directories), `printf` is never executed, and stdout is empty
    # despite exit code 0. Using `/bin/sh -c "<command>"` gives the
    # caller the shell semantics they expect.
    port =
      Port.open(
        {:spawn_executable, ~c"/bin/sh"},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:cd, to_charlist(cwd)},
          {:args, ["-c", command]}
        ]
      )

    collect_output(port, <<>>, timeout)
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data, timeout)

      {^port, {:exit_status, code}} ->
        # `:exit_status` and trailing `{:data, _}` are not ordered on
        # the spawn port — for compound commands (e.g. `mkdir && printf`)
        # the exit signal can race ahead of the final stdout flush,
        # giving callers an empty string. Drain remaining data with a
        # 0-timeout receive before returning.
        {:ok, drain_remaining(port, acc), code}
    after
      timeout ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  # Wait briefly for trailing {:data, _} after :exit_status. The spawn
  # port doesn't guarantee that all stdout has been delivered to the
  # owner process's mailbox before :exit_status arrives — for compound
  # commands the final chunk can still be in flight. 50ms is enough to
  # let normal pipe-buffered output land while keeping the fast path
  # fast; anything still in flight after that is genuinely stuck and
  # bounded losses are preferable to hangs.
  @drain_timeout_ms 50

  defp drain_remaining(port, acc) do
    receive do
      {^port, {:data, data}} -> drain_remaining(port, acc <> data)
    after
      @drain_timeout_ms -> acc
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
