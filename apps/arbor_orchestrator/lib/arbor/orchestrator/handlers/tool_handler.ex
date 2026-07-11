defmodule Arbor.Orchestrator.Handlers.ToolHandler do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome, RunAuthorization}
  alias Arbor.Orchestrator.ToolHooks

  @impl true
  def execute(node, context, graph, opts) do
    command = Map.get(node.attrs, "tool_command", "")

    case admit_command(command, node, context, opts) do
      {:ok, authority, prepared} ->
        execute_authorized(command, node, context, graph, opts, authority, prepared)

      :trusted_runner ->
        execute_admitted(command, node, context, graph, opts, nil)

      {:error, :missing_command} ->
        %Outcome{status: :fail, failure_reason: "No tool_command specified"}

      {:error, reason} ->
        rejected_outcome(command, node, reason)
    end
  end

  defp execute_authorized(
         command,
         node,
         context,
         graph,
         opts,
         %RunAuthorization{} = authority,
         prepared
       ) do
    shell_opts = shell_opts(node, context, opts, authority)

    case Arbor.Actions.Shell.authorize_command(
           authority.execution_principal,
           command,
           RunAuthorization.scope_opts(authority) ++ shell_opts
         ) do
      {:ok, :authorized} ->
        execute_admitted(command, node, context, graph, opts, prepared)

      {:ok, :pending_approval, proposal_id} ->
        %Outcome{
          status: :fail,
          failure_reason:
            "Tool shell authorization requires approval for immutable principal #{authority.execution_principal}: #{proposal_id}"
        }

      {:error, reason} ->
        %Outcome{
          status: :fail,
          failure_reason:
            "Tool shell authorization denied for immutable principal #{authority.execution_principal}: #{inspect(reason)}"
        }
    end
  end

  defp execute_admitted(command, node, context, graph, opts, prepared) do
    hooks = resolve_hooks(node, graph, opts)
    # String hooks fail closed in ToolHooks while CapShell is unavailable. Keep
    # the level in opts for trusted injected hook runners that inspect it.
    hook_opts = Keyword.put(opts, :sandbox_level, sandbox_level_for(node))
    pre_payload = %{phase: "pre", tool_name: node.id, tool_call_id: node.id, command: command}
    pre_result = ToolHooks.run(:pre, hooks.pre, pre_payload, hook_opts)
    emit(opts, %{type: :tool_hook_pre, node_id: node.id, tool: node.id, result: pre_result})

    if pre_result.decision == :skip do
      %Outcome{
        status: :skipped,
        notes: pre_result.reason || "tool command skipped by pre-hook",
        context_updates: %{"tool.hook.pre.status" => to_string(pre_result.status)}
      }
    else
      outcome =
        case Keyword.get(opts, :tool_command_runner) do
          runner when is_function(runner, 1) ->
            # Explicitly injected runners are trusted system-only seams. The
            # default graph path below always uses the closed agent policy.
            output = runner.(command)

            %Outcome{
              status: :success,
              notes: "Tool completed: #{command}",
              context_updates: %{"tool.output" => output}
            }

          _ ->
            run_command(command, prepared, node, context, opts)
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

  defp run_command(command, prepared, node, context, opts) do
    sandbox_level = sandbox_level_for(node)
    authority = Keyword.fetch!(opts, :run_authorization)
    shell_opts = shell_opts(node, context, opts, authority)

    case Arbor.Shell.execute_bound_agent_command(command, prepared, shell_opts) do
      {:ok, result} ->
        output = Map.get(result, :stdout, "") <> Map.get(result, :stderr, "")
        exit_code = Map.get(result, :exit_code, 0)

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

      {:error, reason} ->
        %Outcome{
          status: :fail,
          failure_reason:
            "Tool command rejected by direct-executable policy (level=#{sandbox_level}, reason=#{inspect(reason)}): " <>
              String.slice(command, 0, 200)
        }
    end
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "Tool execution error: #{Exception.message(e)}"
      }
  end

  # Default graph execution is agent-facing, so reject malformed executable
  # argv before pre-hooks can authorize, launch a process, or touch files. An
  # explicitly injected command runner remains the established trusted-system
  # seam and owns its own admission policy.
  defp admit_command("", _node, _context, _opts), do: {:error, :missing_command}

  defp admit_command(command, node, context, opts) do
    case Keyword.get(opts, :tool_command_runner) do
      runner when is_function(runner, 1) ->
        :trusted_runner

      _ ->
        case Arbor.Shell.prepare_agent_command(command, shell_opts(node, context, opts, nil)) do
          {:ok, prepared} ->
            case immutable_authority(opts) do
              {:ok, authority} -> {:ok, authority, prepared}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp shell_opts(node, context, opts, authority) do
    shell_opts = [sandbox: sandbox_level_for(node)]

    case workdir(context, opts, authority) do
      nil -> shell_opts
      cwd -> Keyword.put(shell_opts, :cwd, cwd)
    end
  end

  defp immutable_authority(opts) do
    case Keyword.get(opts, :run_authorization) do
      %RunAuthorization{} = authority ->
        case RunAuthorization.verify_runtime(authority) do
          :ok -> {:ok, authority}
          {:error, reason} -> {:error, {:invalid_run_authorization, reason}}
        end

      _ ->
        {:error, :missing_run_authorization}
    end
  end

  defp rejected_outcome(command, node, reason) do
    %Outcome{
      status: :fail,
      failure_reason:
        "Tool command rejected by direct-executable policy (level=#{sandbox_level_for(node)}, reason=#{inspect(reason)}): " <>
          String.slice(command, 0, 200)
    }
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

  defp workdir(_context, _opts, %RunAuthorization{} = authority), do: authority.workdir

  defp workdir(context, opts, nil) do
    value =
      Context.get(context, "workdir") ||
        Keyword.get(opts, :workdir)

    if value && value != "", do: value, else: nil
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
