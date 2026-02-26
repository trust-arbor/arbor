defmodule Arbor.Orchestrator.Handlers.ExecHandler do
  @moduledoc """
  Core handler for side-effecting execution — tools, shell commands, actions.

  Canonical type: `exec`
  Aliases: `tool`, `shell`

  Dispatches by `target` attribute:
    - `"tool"` (default) — delegates to ToolHandler
    - `"shell"` — delegates to ShellHandler
    - `"action"` — executes an Arbor action via ActionsExecutor
    - `"function"` — calls a function reference from opts

  ## Node Attributes

    - `target` — execution target: "tool" (default), "shell", "action", "function"
    - `action` — action name (required when target="action"), e.g. "eval_pipeline.load_dataset"
    - `arg.*` / `param.*` — action parameters extracted from attrs
    - `context_keys` — comma-separated context keys to merge as action params
    - All attributes from the delegated handler are supported
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

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

  defp execute_action(node, context, opts) do
    action_name = Map.get(node.attrs, "action")

    unless action_name do
      raise "exec with target=action requires 'action' attribute"
    end

    executor = Arbor.Orchestrator.ActionsExecutor

    if Code.ensure_loaded?(executor) do
      agent_id =
        Map.get(node.attrs, "agent_id") ||
          Context.get(context, "session.agent_id", "system")

      action_args = build_action_args(node.attrs, context)
      workdir = Context.get(context, "workdir") || Keyword.get(opts, :workdir, ".")

      output_prefix = Map.get(node.attrs, "output_prefix")

      try do
        case executor.execute(action_name, action_args, workdir, agent_id: agent_id) do
          {:ok, result} ->
            %Outcome{
              status: :success,
              notes: "Action #{action_name} executed",
              context_updates:
                flatten_context_updates(node.id, result)
                |> maybe_add_prefixed_keys(node.id, result, output_prefix)
            }

          {:error, reason} ->
            %Outcome{
              status: :fail,
              failure_reason: "Action #{action_name} failed: #{reason}"
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
        failure_reason: "Arbor.Orchestrator.ActionsExecutor not available"
      }
    end
  end

  defp execute_function(node, _context, opts) do
    case Keyword.get(opts, :function_handler) do
      fun when is_function(fun, 1) ->
        args = parse_attr_args(node.attrs)

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

  # Build action args from both attr-prefixed values AND context keys.
  defp build_action_args(attrs, context) do
    # 1. Collect arg.*/param.* prefixed attrs
    attr_args = parse_attr_args(attrs)

    # 2. If context_keys attr is set, merge context values as params
    context_args =
      case Map.get(attrs, "context_keys") do
        nil ->
          %{}

        keys_csv ->
          keys_csv
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.reduce(%{}, fn key, acc ->
            value = Context.get(context, key)
            if value != nil, do: Map.put(acc, key, value), else: acc
          end)
      end

    Map.merge(attr_args, context_args)
  end

  defp parse_attr_args(attrs) do
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

  # Flatten action result into context updates.
  # If result is a JSON map, spread its keys as "exec.{node_id}.{key}".
  defp flatten_context_updates(node_id, result) when is_binary(result) do
    base = %{
      "exec.#{node_id}.result" => result,
      "last_response" => result
    }

    case Jason.decode(result) do
      {:ok, map} when is_map(map) ->
        spread =
          Enum.reduce(map, %{}, fn {k, v}, acc ->
            Map.put(acc, "exec.#{node_id}.#{k}", v)
          end)

        Map.merge(base, spread)

      _ ->
        base
    end
  end

  defp flatten_context_updates(node_id, result) do
    %{
      "exec.#{node_id}.result" => inspect(result),
      "last_response" => inspect(result)
    }
  end

  # When output_prefix is set, duplicate each spread key under the prefix namespace.
  # Example: output_prefix="session" + result key "cognitive_mode"
  # → writes both "exec.node_id.cognitive_mode" AND "session.cognitive_mode"
  defp maybe_add_prefixed_keys(updates, _node_id, _result, nil), do: updates

  defp maybe_add_prefixed_keys(updates, _node_id, result, prefix) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, map} when is_map(map) ->
        prefixed =
          Enum.reduce(map, %{}, fn {k, v}, acc ->
            Map.put(acc, "#{prefix}.#{k}", v)
          end)

        Map.merge(updates, prefixed)

      _ ->
        updates
    end
  end

  defp maybe_add_prefixed_keys(updates, _node_id, result, prefix) when is_map(result) do
    prefixed =
      Enum.reduce(result, %{}, fn {k, v}, acc ->
        Map.put(acc, "#{prefix}.#{k}", v)
      end)

    Map.merge(updates, prefixed)
  end

  defp maybe_add_prefixed_keys(updates, _node_id, _result, _prefix), do: updates
end
