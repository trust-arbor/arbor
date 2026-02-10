defmodule Arbor.Orchestrator.Handlers.ToolHandler do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.ToolHooks

  @impl true
  def execute(node, context, graph, opts) do
    command = Map.get(node.attrs, "tool_command", "")
    hooks = resolve_hooks(node, graph, opts)
    pre_payload = %{phase: "pre", tool_name: node.id, tool_call_id: node.id, command: command}
    pre_result = ToolHooks.run(:pre, hooks.pre, pre_payload, opts)
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

        post_result = ToolHooks.run(:post, hooks.post, post_payload, opts)
        emit(opts, %{type: :tool_hook_post, node_id: node.id, tool: node.id, result: post_result})

        outcome
    end
  end

  @impl true
  def idempotency, do: :side_effecting

  defp run_command(command, _node, context, opts) do
    try do
      [executable | args] = OptionParser.split(command)
      cmd_opts = [stderr_to_stdout: true] ++ workdir_opt(context, opts)

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
          failure_reason: "Tool command exited with code #{exit_code}: #{String.slice(output, 0, 500)}",
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
