defmodule Arbor.Orchestrator.Handlers.ToolHandler do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.ToolHooks

  @impl true
  def execute(node, context, graph, opts) do
    command = Map.get(node.attrs, "tool_command", "")
    hooks = resolve_hooks(node, graph, opts)
    # H5 (codex command-execution.orchestrator-tool-hooks-shell): tool hooks are
    # shell commands too. Thread the node's sandbox level into the hook runs so
    # ToolHooks gates them through Arbor.Shell.Sandbox — same gate the tool
    # *command* uses (H3). Without this, a graph-authored hook bypassed the gate.
    hook_opts = Keyword.put(opts, :sandbox_level, sandbox_level_for(node))
    pre_payload = %{phase: "pre", tool_name: node.id, tool_call_id: node.id, command: command}
    pre_result = ToolHooks.run(:pre, hooks.pre, pre_payload, hook_opts)
    emit(opts, %{type: :tool_hook_pre, node_id: node.id, tool: node.id, result: pre_result})

    cond do
      command == "" ->
        %Outcome{status: :fail, failure_reason: "No tool_command specified"}

      pre_result.decision == :skip ->
        %Outcome{
          status: :skipped,
          notes: pre_result.reason || "tool command skipped by pre-hook",
          context_updates: %{"tool.hook.pre.status" => to_string(pre_result.status)}
        }

      true ->
        outcome =
          case Keyword.get(opts, :tool_command_runner) do
            runner when is_function(runner, 1) ->
              output = runner.(command)

              %Outcome{
                status: :success,
                notes: "Tool completed: #{command}",
                context_updates: %{"tool.output" => output}
              }

            _ ->
              run_command(command, node, context, opts)
          end

        post_payload = %{
          phase: "post",
          tool_name: node.id,
          tool_call_id: node.id,
          command: command,
          result: outcome.context_updates
        }

        post_result = ToolHooks.run(:post, hooks.post, post_payload, hook_opts)
        emit(opts, %{type: :tool_hook_post, node_id: node.id, tool: node.id, result: post_result})

        outcome
    end
  end

  @impl true
  def idempotency, do: :side_effecting

  defp run_command(command, node, context, opts) do
    # H3: pre-fix, ToolHandler called System.cmd directly — bypassing the
    # Arbor.Shell.Sandbox filter that the rest of the shell-execution paths
    # consult. The sandbox isn't OS-level isolation (the full containment
    # work is bigger than this commit can take), but the allowlist /
    # denylist / metacharacter check IS the project's documented preflight
    # gate for shell execution. Routing ToolHandler through it closes the
    # specific bypass the audit flagged.
    #
    # arbor_orchestrator is Standalone in the library hierarchy, so the
    # Shell.Sandbox dependency is consulted via a runtime bridge (same
    # pattern other Standalone modules use). If Arbor.Shell.Sandbox isn't
    # loaded at runtime, the request defaults to the strict "deny unless
    # explicitly allowed" posture rather than fail-open.
    sandbox_level = sandbox_level_for(node)

    case sandbox_check(command, sandbox_level) do
      {:ok, :allowed} ->
        execute_after_sandbox_check(command, context, opts)

      {:error, reason} ->
        %Outcome{
          status: :fail,
          failure_reason:
            "Tool command rejected by sandbox (level=#{sandbox_level}, reason=#{inspect(reason)}): " <>
              String.slice(command, 0, 200)
        }
    end
  end

  defp sandbox_check(command, level) do
    sandbox_mod = Arbor.Shell.Sandbox

    if Code.ensure_loaded?(sandbox_mod) and function_exported?(sandbox_mod, :check, 2) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(sandbox_mod, :check, [command, level])
    else
      # Sandbox module unreachable. Strict-deny: if the operator hasn't set
      # up the sandbox, an unsanboxed tool execution should not be allowed
      # through silently.
      {:error, :sandbox_unavailable}
    end
  end

  defp sandbox_level_for(node) do
    case Map.get(node.attrs, "sandbox") do
      "none" -> :none
      "basic" -> :basic
      "strict" -> :strict
      "container" -> :container
      _ -> Application.get_env(:arbor_orchestrator, :default_tool_sandbox_level, :basic)
    end
  end

  defp execute_after_sandbox_check(command, context, opts) do
    [executable | args] = OptionParser.split(command)
    cmd_opts = [stderr_to_stdout: true] ++ workdir_opt(context, opts)

    # credo:disable-for-next-line Credo.Check.Security.UnsafeSystemCmd
    {output, exit_code} = System.cmd(executable, args, cmd_opts)

    if exit_code == 0 do
      %Outcome{
        status: :success,
        notes: "Tool completed: #{command}",
        context_updates: %{"tool.output" => output}
      }
    else
      %Outcome{
        status: :fail,
        failure_reason:
          "Tool command exited with code #{exit_code}: #{String.slice(output, 0, 500)}",
        context_updates: %{"tool.output" => output}
      }
    end
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "Tool execution error: #{Exception.message(e)}"
      }
  end

  defp workdir_opt(context, opts) do
    workdir =
      Context.get(context, "workdir") ||
        Keyword.get(opts, :workdir)

    if workdir && workdir != "", do: [cd: workdir], else: []
  end

  defp resolve_hooks(node, graph, opts) do
    hooks_opt = Keyword.get(opts, :tool_hooks, %{})

    pre =
      Map.get(node.attrs, "tool_hooks.pre") ||
        Map.get(graph.attrs, "tool_hooks.pre") ||
        hook_from_opt(hooks_opt, :pre)

    post =
      Map.get(node.attrs, "tool_hooks.post") ||
        Map.get(graph.attrs, "tool_hooks.post") ||
        hook_from_opt(hooks_opt, :post)

    %{pre: pre, post: post}
  end

  defp hook_from_opt(hooks, key) when is_map(hooks),
    do: Map.get(hooks, key) || Map.get(hooks, to_string(key))

  defp hook_from_opt(hooks, key) when is_list(hooks), do: Keyword.get(hooks, key)
  defp hook_from_opt(_, _), do: nil

  defp emit(opts, event) do
    case Keyword.get(opts, :on_event) do
      callback when is_function(callback, 1) -> callback.(event)
      _ -> :ok
    end
  end
end
