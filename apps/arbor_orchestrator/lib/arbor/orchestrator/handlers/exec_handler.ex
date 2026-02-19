defmodule Arbor.Orchestrator.Handlers.ExecHandler do
  @moduledoc """
  Core handler for side-effecting execution — tools, shell commands, actions.

  Canonical type: `exec`
  Aliases: `tool`, `shell`

  Dispatches by `target` attribute:
    - `"tool"` (default) — delegates to ToolHandler
    - `"shell"` — delegates to ShellHandler
    - `"action"` — executes an Arbor action via Executor
    - `"function"` — calls a function reference from opts

  ## Node Attributes

    - `target` — execution target: "tool" (default), "shell", "action", "function"
    - All attributes from the delegated handler are supported
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.Outcome

  alias Arbor.Orchestrator.Handlers.{
    ShellHandler,
    ToolHandler
  }

  @impl true
  def execute(node, context, graph, opts) do
    target = Map.get(node.attrs, "target", "tool")

    case target do
      "tool" -> ToolHandler.execute(node, context, graph, opts)
      "shell" -> ShellHandler.execute(node, context, graph, opts)
      "action" -> execute_action(node, context, opts)
      "function" -> execute_function(node, context, opts)
      _ -> ToolHandler.execute(node, context, graph, opts)
    end
  end

  @impl true
  def idempotency, do: :side_effecting

  defp execute_action(node, context, _opts) do
    action_name = Map.get(node.attrs, "action")

    unless action_name do
      raise "exec with target=action requires 'action' attribute"
    end

    # Bridge to Arbor.Actions.Executor via runtime check
    if Code.ensure_loaded?(Arbor.Actions.Executor) do
      agent_id =
        Map.get(node.attrs, "agent_id") ||
          Arbor.Orchestrator.Engine.Context.get(context, "session.agent_id", "system")

      action_args = parse_action_args(node.attrs)

      try do
        case apply(Arbor.Actions.Executor, :execute, [agent_id, action_name, action_args]) do
          {:ok, result} ->
            %Outcome{
              status: :success,
              notes: "Action #{action_name} executed",
              context_updates: %{
                "exec.#{node.id}.result" => inspect(result),
                "last_response" => inspect(result)
              }
            }

          {:error, reason} ->
            %Outcome{
              status: :fail,
              failure_reason: "Action #{action_name} failed: #{inspect(reason)}"
            }
        end
      catch
        :exit, reason ->
          %Outcome{
            status: :fail,
            failure_reason: "Action #{action_name} process error: #{inspect(reason)}"
          }
      end
    else
      %Outcome{
        status: :fail,
        failure_reason: "Arbor.Actions.Executor not available"
      }
    end
  end

  defp execute_function(node, _context, opts) do
    case Keyword.get(opts, :function_handler) do
      fun when is_function(fun, 1) ->
        args = parse_action_args(node.attrs)

        case fun.(args) do
          {:ok, result} ->
            %Outcome{
              status: :success,
              notes: "Function executed",
              context_updates: %{
                "exec.#{node.id}.result" => inspect(result),
                "last_response" => inspect(result)
              }
            }

          {:error, reason} ->
            %Outcome{
              status: :fail,
              failure_reason: "Function failed: #{inspect(reason)}"
            }

          other ->
            %Outcome{
              status: :success,
              notes: "Function executed",
              context_updates: %{
                "exec.#{node.id}.result" => inspect(other),
                "last_response" => inspect(other)
              }
            }
        end

      nil ->
        %Outcome{
          status: :fail,
          failure_reason: "exec with target=function requires :function_handler in opts"
        }
    end
  end

  defp parse_action_args(attrs) do
    attrs
    |> Enum.filter(fn {k, _v} ->
      String.starts_with?(k, "arg.") or String.starts_with?(k, "param.")
    end)
    |> Enum.map(fn {k, v} ->
      key = k |> String.replace(~r/^(arg|param)\./, "")
      {key, v}
    end)
    |> Map.new()
  end
end
