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

  require Logger

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

    if action_name in [nil, ""] do
      raise "exec with target=action requires non-empty 'action' attribute"
    end

    # Injectable for tests (defaults to the real executor in production).
    executor = Keyword.get(opts, :actions_executor, Arbor.Orchestrator.ActionsExecutor)

    if Code.ensure_loaded?(executor) do
      agent_id =
        Map.get(node.attrs, "agent_id") ||
          Context.get(context, "session.agent_id", "system")

      action_args = build_action_args(node.id, node.attrs, context)
      workdir = Context.get(context, "workdir") || Keyword.get(opts, :workdir, ".")
      task_id = Context.get(context, "session.task_id")

      output_prefix = Map.get(node.attrs, "output_prefix")

      # Preserve the aggregate taint for operation-level authorization, egress,
      # and telemetry while also carrying each runtime parameter's exact label
      # to the action enforcement boundary. Static attr args are author-written;
      # only context_keys values can be runtime-tainted.
      context_keys = consumed_context_keys(node.attrs)
      input_taint = Context.worst_taint(context, context_keys)

      executor_opts =
        [
          agent_id: agent_id,
          signer: Keyword.get(opts, :signer),
          task_id: task_id,
          taint: input_taint
        ]
        |> maybe_put_param_taint(context, context_keys)

      try do
        case executor.execute(action_name, action_args, workdir, executor_opts) do
          {:ok, result} ->
            %Outcome{
              status: :success,
              notes: "Action #{action_name} executed",
              context_updates:
                flatten_context_updates(node.id, result)
                |> maybe_add_prefixed_keys(node.id, result, output_prefix),
              # Provenance (Phase 1): if this action is an ingress (e.g. web
              # fetch -> :untrusted, or a foreign-path file read), label its
              # output keys so downstream nodes that consume them are gated at
              # control params. Params let path-based actions decide provenance.
              output_taint: action_output_taint(executor, action_name, action_args)
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
        args = parse_attr_args(node.id, node.attrs)

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
  defp build_action_args(node_id, attrs, context) do
    # 1. Collect arg.*/param.* prefixed attrs
    attr_args = parse_attr_args(node_id, attrs)

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
            case Context.get(context, key) do
              nil ->
                # Silent param loss is the bug: action runs with a
                # partial param set and the operator gets no signal.
                # Warn so the missing key is visible in logs even
                # when the action's eventual error doesn't point here.
                Logger.warning(
                  "[ExecHandler] #{node_id}: context_keys references " <>
                    "\"#{key}\" but no such key in context; param will " <>
                    "be missing from action call"
                )

                acc

              value ->
                Map.put(acc, key, value)
            end
          end)
      end

    Map.merge(attr_args, context_args)
  end

  # The context keys whose values are interpolated into this action's params.
  # These are the only runtime-tainted inputs (static arg.*/param.* attrs are
  # author-written and trusted). Mirrors the context_keys parsing in
  # build_action_args/3.
  defp consumed_context_keys(attrs) do
    case Map.get(attrs, "context_keys") do
      nil ->
        []

      keys_csv ->
        keys_csv
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp maybe_put_param_taint(opts, _context, []), do: opts

  defp maybe_put_param_taint(opts, context, context_keys) do
    param_taint =
      Enum.reduce(context_keys, %{}, fn key, acc ->
        case Context.get(context, key) do
          nil -> acc
          _value -> Map.put(acc, key, Context.taint_label(context, key))
        end
      end)

    Keyword.put(opts, :param_taint, param_taint)
  end

  # Provenance taint this action assigns to its own output, via the executor's
  # output_taint/1 resolver (nil for non-ingress actions or standalone mode).
  defp action_output_taint(executor, action_name, params) do
    cond do
      function_exported?(executor, :output_taint, 2) -> executor.output_taint(action_name, params)
      function_exported?(executor, :output_taint, 1) -> executor.output_taint(action_name)
      true -> nil
    end
  end

  defp parse_attr_args(node_id, attrs) do
    attrs
    |> Enum.filter(fn {k, _v} ->
      String.starts_with?(k, "arg.") or String.starts_with?(k, "param.")
    end)
    |> Enum.map(fn {k, v} ->
      key = k |> String.replace(~r/^(arg|param)\./, "")
      # Jido action schemas use flat atom keys. A nested attr like
      # `arg.foo.bar` produces a string key "foo.bar" that won't
      # match any schema atom and silently gets ignored by the
      # action — dead weight with no signal. Warn so the typo
      # (or hallucinated nested form) surfaces.
      if String.contains?(key, ".") do
        Logger.warning(
          "[ExecHandler] #{node_id}: attr \"#{k}\" produced nested param " <>
            "key \"#{key}\" — Jido schemas use flat atom keys, so this " <>
            "param will be silently dropped by the action. Did you mean " <>
            "to use \"_\" instead of \".\" after the prefix?"
        )
      end

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
