defmodule Arbor.Orchestrator.Handlers.ManagerLoopHandler do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Condition, Context, Outcome}

  @impl true
  def execute(node, context, graph, opts) do
    poll_interval_ms = parse_duration_ms(Map.get(node.attrs, "manager.poll_interval", "45s"))
    max_cycles = parse_int(Map.get(node.attrs, "manager.max_cycles", 1000), 1000)
    stop_condition = Map.get(node.attrs, "manager.stop_condition", "")
    actions = parse_actions(Map.get(node.attrs, "manager.actions", "observe,wait"))

    local = Context.snapshot(context)

    local =
      maybe_autostart_child(local, node, graph, opts)
      |> Map.put("manager.cycle", 0)

    run_cycles(node, local, actions, stop_condition, poll_interval_ms, max_cycles, opts)
  end

  defp run_cycles(_node, local, _actions, _stop_condition, _poll_interval_ms, max_cycles, _opts)
       when max_cycles <= 0 do
    %Outcome{
      status: :fail,
      failure_reason: "Max cycles exceeded",
      context_updates: local
    }
  end

  defp run_cycles(node, local, actions, stop_condition, poll_interval_ms, max_cycles, opts) do
    cycle = parse_int(Map.get(local, "manager.cycle", 0), 0) + 1
    local = Map.put(local, "manager.cycle", cycle)

    local = if "observe" in actions, do: apply_observe(local, node, opts), else: local
    local = if "steer" in actions, do: apply_steer(local, node, opts), else: local

    case check_stop(local, stop_condition) do
      {:done, :success, reason} ->
        %Outcome{status: :success, notes: reason, context_updates: local}

      {:done, :fail, reason} ->
        %Outcome{status: :fail, failure_reason: reason, context_updates: local}

      :continue ->
        if "wait" in actions do
          sleep_fn = Keyword.get(opts, :sleep_fn, fn ms -> Process.sleep(ms) end)
          sleep_fn.(poll_interval_ms)
        end

        if cycle >= max_cycles do
          %Outcome{
            status: :fail,
            failure_reason: "Max cycles exceeded",
            context_updates: local
          }
        else
          run_cycles(node, local, actions, stop_condition, poll_interval_ms, max_cycles, opts)
        end
    end
  end

  defp maybe_autostart_child(local, node, graph, opts) do
    child_dotfile = Map.get(graph.attrs, "stack.child_dotfile", "")

    autostart? =
      Map.get(node.attrs, "stack.child_autostart", "true")
      |> truthy?()

    cond do
      not autostart? ->
        local

      child_dotfile in [nil, ""] ->
        local

      true ->
        starter = Keyword.get(opts, :manager_start_child)
        started = apply_hook(starter, [child_dotfile, local, node, graph, opts])

        case started do
          %{} = updates ->
            Map.merge(local, updates)

          _ ->
            local
            |> Map.put_new("context.stack.child.dotfile", child_dotfile)
            |> Map.put_new("context.stack.child.status", "running")
        end
    end
  end

  defp apply_observe(local, node, opts) do
    observer = Keyword.get(opts, :manager_observe)
    updates = apply_hook(observer, [local, node, opts])
    if is_map(updates), do: Map.merge(local, updates), else: local
  end

  defp apply_steer(local, node, opts) do
    steerer = Keyword.get(opts, :manager_steer)
    updates = apply_hook(steerer, [local, node, opts])
    if is_map(updates), do: Map.merge(local, updates), else: local
  end

  defp apply_hook(nil, _args), do: nil
  defp apply_hook(fun, args) when is_function(fun), do: apply_dynamic(fun, args)
  defp apply_hook(_, _args), do: nil

  defp apply_dynamic(fun, args) when is_function(fun, 1), do: fun.(Enum.at(args, 0))

  defp apply_dynamic(fun, args) when is_function(fun, 2),
    do: fun.(Enum.at(args, 0), Enum.at(args, 1))

  defp apply_dynamic(fun, args) when is_function(fun, 3),
    do: fun.(Enum.at(args, 0), Enum.at(args, 1), Enum.at(args, 2))

  defp apply_dynamic(fun, args) when is_function(fun, 4),
    do: fun.(Enum.at(args, 0), Enum.at(args, 1), Enum.at(args, 2), Enum.at(args, 3))

  defp apply_dynamic(fun, args) when is_function(fun, 5),
    do:
      fun.(
        Enum.at(args, 0),
        Enum.at(args, 1),
        Enum.at(args, 2),
        Enum.at(args, 3),
        Enum.at(args, 4)
      )

  defp apply_dynamic(_fun, _args), do: nil

  defp check_stop(local, stop_condition) do
    status = get_child_value(local, "status")
    child_outcome = get_child_value(local, "outcome")

    cond do
      status == "completed" and child_outcome == "success" ->
        {:done, :success, "Child completed"}

      status == "failed" ->
        {:done, :fail, "Child failed"}

      stop_condition not in [nil, ""] and
          Condition.eval(stop_condition, %Outcome{status: :success}, Context.new(local)) ->
        {:done, :success, "Stop condition satisfied"}

      true ->
        :continue
    end
  end

  defp get_child_value(local, key) do
    Map.get(local, "context.stack.child.#{key}", Map.get(local, "stack.child.#{key}", ""))
    |> to_string()
  end

  defp parse_actions(actions) when is_binary(actions) do
    actions
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_actions(_), do: ["observe", "wait"]

  defp parse_duration_ms(value) when is_integer(value), do: max(value, 0)
  defp parse_duration_ms(value) when is_float(value), do: trunc(max(value, 0.0))

  defp parse_duration_ms(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      Regex.match?(~r/^\d+ms$/i, trimmed) ->
        trimmed |> String.replace(~r/ms$/i, "") |> parse_int(45_000)

      Regex.match?(~r/^\d+s$/i, trimmed) ->
        (trimmed |> String.replace(~r/s$/i, "") |> parse_int(45)) * 1000

      Regex.match?(~r/^\d+$/, trimmed) ->
        parse_int(trimmed, 45_000)

      true ->
        45_000
    end
  end

  defp parse_duration_ms(_), do: 45_000

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false
end
