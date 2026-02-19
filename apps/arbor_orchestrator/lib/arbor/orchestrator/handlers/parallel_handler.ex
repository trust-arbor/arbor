defmodule Arbor.Orchestrator.Handlers.ParallelHandler do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Condition, Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Handlers.Registry

  import Arbor.Orchestrator.Handlers.Helpers

  @impl true
  def execute(node, context, graph, opts) do
    branches = Graph.outgoing_edges(graph, node.id)

    if branches == [] do
      %Outcome{status: :fail, failure_reason: "parallel node has no branches"}
    else
      started_at = System.monotonic_time()
      max_parallel = parse_int(Map.get(node.attrs, "max_parallel", 4), 4)
      join_policy = Map.get(node.attrs, "join_policy", "wait_all")
      error_policy = Map.get(node.attrs, "error_policy", "continue")
      join_target = Map.get(node.attrs, "join_target") || infer_join_target(graph, branches)

      branch_executor = Keyword.get(opts, :parallel_branch_executor, &default_branch_executor/5)
      emit(opts, %{type: :parallel_started, node_id: node.id, branch_count: length(branches)})

      results =
        case String.downcase(to_string(error_policy)) do
          "fail_fast" ->
            run_branches_fail_fast(
              branches,
              node.id,
              join_target,
              context,
              graph,
              opts,
              branch_executor
            )

          _ ->
            run_branches_continue(
              branches,
              node.id,
              join_target,
              context,
              graph,
              opts,
              branch_executor,
              max_parallel
            )
        end

      effective_results =
        case String.downcase(to_string(error_policy)) do
          "ignore" -> Enum.filter(results, &result_success?/1)
          _ -> results
        end

      success_count =
        Enum.count(effective_results, &(&1["status"] in ["success", "partial_success"]))

      fail_count = Enum.count(effective_results, &(&1["status"] == "fail"))
      total = length(effective_results)

      emit(opts, %{
        type: :parallel_completed,
        node_id: node.id,
        duration_ms: duration_ms(started_at),
        success_count: success_count,
        failure_count: fail_count
      })

      status =
        if effective_results == [] and String.downcase(to_string(error_policy)) == "ignore" do
          :fail
        else
          join_status(join_policy, node.attrs, success_count, fail_count, total)
        end

      %Outcome{
        status: status,
        suggested_next_ids: maybe_list(join_target),
        context_updates: %{
          "parallel.results" => effective_results,
          "parallel.success_count" => success_count,
          "parallel.fail_count" => fail_count,
          "parallel.total_count" => total
        },
        notes: "Parallel branches executed: #{total}"
      }
    end
  end

  @impl true
  def idempotency, do: :side_effecting

  defp execute_branch(branch_node_id, join_target, context, graph, opts, branch_executor) do
    branch_context = Context.new(Context.snapshot(context))

    cond do
      is_function(branch_executor, 5) ->
        branch_executor.(branch_node_id, join_target, branch_context, graph, opts)

      is_function(branch_executor, 4) ->
        branch_executor.(branch_node_id, branch_context, graph, opts)

      true ->
        default_branch_executor(branch_node_id, join_target, branch_context, graph, opts)
    end
  end

  defp default_branch_executor(branch_node_id, join_target, context, graph, opts) do
    max_steps = parse_int(Keyword.get(opts, :parallel_branch_max_steps, 100), 100)
    do_run_branch(branch_node_id, join_target, context, graph, opts, 0, max_steps, nil)
  end

  defp do_run_branch(
         _node_id,
         _join_target,
         _context,
         _graph,
         _opts,
         steps,
         max_steps,
         last_result
       )
       when steps >= max_steps do
    base = last_result || %{"id" => "unknown", "status" => "fail", "score" => 0.0}
    Map.merge(base, %{"status" => "fail", "failure_reason" => "branch max steps exceeded"})
  end

  defp do_run_branch(node_id, join_target, context, graph, opts, steps, max_steps, last_result) do
    cond do
      node_id in [nil, ""] ->
        %{
          "id" => "unknown",
          "status" => "fail",
          "score" => 0.0,
          "failure_reason" => "branch terminated early"
        }

      node_id == join_target ->
        last_result ||
          %{
            "id" => node_id,
            "status" => "success",
            "score" => score_from_context(context),
            "context_updates" => Context.snapshot(context)
          }

      true ->
        case Map.fetch(graph.nodes, node_id) do
          :error ->
            %{
              "id" => node_id,
              "status" => "fail",
              "score" => 0.0,
              "failure_reason" => "missing branch node"
            }

          {:ok, node} ->
            {handler, resolved_node} = Registry.resolve_with_attrs(node)

            outcome =
              try do
                handler.execute(resolved_node, context, graph, opts)
              rescue
                exception -> %Outcome{status: :fail, failure_reason: Exception.message(exception)}
              end

            updated_context = Context.apply_updates(context, outcome.context_updates || %{})

            current_result = %{
              "id" => node_id,
              "status" => to_string(outcome.status),
              "score" => score_from(outcome, updated_context),
              "notes" => outcome.notes,
              "failure_reason" => outcome.failure_reason,
              "context_updates" => outcome.context_updates || %{}
            }

            cond do
              outcome.status in [:fail, :retry] ->
                current_result

              terminal?(node) ->
                current_result

              true ->
                next_id =
                  select_next_branch_node(node, outcome, updated_context, graph, join_target)

                do_run_branch(
                  next_id,
                  join_target,
                  updated_context,
                  graph,
                  opts,
                  steps + 1,
                  max_steps,
                  current_result
                )
            end
        end
    end
  end

  defp join_status("first_success", _attrs, success_count, _fail_count, _total) do
    if success_count > 0, do: :success, else: :fail
  end

  defp join_status("k_of_n", attrs, success_count, _fail_count, _total) do
    k = parse_int(Map.get(attrs, "join_k", 1), 1)
    if success_count >= max(k, 1), do: :success, else: :fail
  end

  defp join_status("quorum", attrs, success_count, _fail_count, total) do
    threshold = parse_float(Map.get(attrs, "quorum_fraction", 0.5), 0.5)
    ratio = if total > 0, do: success_count / total, else: 0.0
    if ratio >= threshold, do: :success, else: :fail
  end

  defp join_status(_default, _attrs, _success_count, fail_count, _total) do
    if fail_count == 0, do: :success, else: :partial_success
  end

  defp infer_join_target(graph, branches) do
    branch_ids = Enum.map(branches, & &1.to)

    common_targets =
      branch_ids
      |> Enum.map(&reachable_from(graph, &1))
      |> intersect_many()
      |> MapSet.to_list()

    fan_in_target =
      Enum.find(common_targets, fn node_id ->
        case Map.get(graph.nodes, node_id) do
          nil -> false
          node -> Registry.node_type(node) == "parallel.fan_in"
        end
      end)

    fan_in_target || List.first(Enum.sort(common_targets))
  end

  defp intersect_many([]), do: MapSet.new()
  defp intersect_many([first | rest]), do: Enum.reduce(rest, first, &MapSet.intersection/2)

  defp reachable_from(graph, start_id) do
    do_reachable(graph, [start_id], MapSet.new())
  end

  defp do_reachable(_graph, [], visited), do: visited

  defp do_reachable(graph, [node_id | rest], visited) do
    if MapSet.member?(visited, node_id) do
      do_reachable(graph, rest, visited)
    else
      next =
        graph
        |> Graph.outgoing_edges(node_id)
        |> Enum.map(& &1.to)

      do_reachable(graph, rest ++ next, MapSet.put(visited, node_id))
    end
  end

  defp maybe_list(nil), do: []
  defp maybe_list(""), do: []
  defp maybe_list(value), do: [value]

  defp select_next_branch_node(node, outcome, context, graph, join_target) do
    candidates = outcome.suggested_next_ids || []

    case Enum.find(candidates, &valid_target?(graph, &1)) do
      target when is_binary(target) ->
        target

      _ ->
        edges = Graph.outgoing_edges(graph, node.id)

        if join_target && Enum.any?(edges, &(&1.to == join_target)) do
          join_target
        else
          selected =
            edges
            |> Enum.filter(&edge_matches?(&1, outcome, context))
            |> best_by_weight_then_lexical()

          if selected, do: selected.to, else: nil
        end
    end
  end

  defp edge_matches?(edge, outcome, context) do
    condition = Map.get(edge.attrs, "condition", "")
    condition in [nil, ""] or Condition.eval(condition, outcome, context)
  end

  defp best_by_weight_then_lexical([]), do: nil

  defp best_by_weight_then_lexical(edges) do
    Enum.sort_by(edges, fn edge -> {-parse_int(Map.get(edge.attrs, "weight", 0), 0), edge.to} end)
    |> List.first()
  end

  defp valid_target?(graph, target) when is_binary(target), do: Map.has_key?(graph.nodes, target)
  defp valid_target?(_graph, _), do: false

  defp terminal?(node) do
    Map.get(node.attrs, "shape") == "Msquare" or String.downcase(node.id) in ["exit", "end"]
  end

  defp score_from(%Outcome{} = outcome, context) do
    parse_float(
      Map.get(outcome.context_updates || %{}, "score", score_from_context(context)),
      0.0
    )
  end

  defp score_from_context(context) do
    context
    |> Context.get("score", Context.get(context, "branch.score", 0.0))
    |> parse_float(0.0)
  end

  defp parse_float(value, _default) when is_float(value), do: value
  defp parse_float(value, _default) when is_integer(value), do: value / 1

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp parse_float(_, default), do: default

  defp run_branches_continue(
         branches,
         parallel_node_id,
         join_target,
         context,
         graph,
         opts,
         branch_executor,
         max_parallel
       ) do
    branches
    |> Enum.with_index(1)
    |> Task.async_stream(
      fn {edge, index} ->
        branch_started_at = System.monotonic_time()

        emit(opts, %{
          type: :parallel_branch_started,
          node_id: parallel_node_id,
          branch: edge.to,
          index: index
        })

        result = execute_branch(edge.to, join_target, context, graph, opts, branch_executor)

        emit(opts, %{
          type: :parallel_branch_completed,
          node_id: parallel_node_id,
          branch: edge.to,
          index: index,
          duration_ms: duration_ms(branch_started_at),
          success: result_success?(result)
        })

        result
      end,
      max_concurrency: max_parallel,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, result} ->
        result

      {:exit, reason} ->
        %{"id" => "unknown", "status" => "fail", "reason" => inspect(reason), "score" => 0.0}
    end)
  end

  defp run_branches_fail_fast(
         branches,
         parallel_node_id,
         join_target,
         context,
         graph,
         opts,
         branch_executor
       ) do
    branches
    |> Enum.with_index(1)
    |> Enum.reduce_while([], fn {edge, index}, acc ->
      branch_started_at = System.monotonic_time()

      emit(opts, %{
        type: :parallel_branch_started,
        node_id: parallel_node_id,
        branch: edge.to,
        index: index
      })

      result = execute_branch(edge.to, join_target, context, graph, opts, branch_executor)

      emit(opts, %{
        type: :parallel_branch_completed,
        node_id: parallel_node_id,
        branch: edge.to,
        index: index,
        duration_ms: duration_ms(branch_started_at),
        success: result_success?(result)
      })

      next = acc ++ [result]

      if result_success?(result) do
        {:cont, next}
      else
        {:halt, next}
      end
    end)
  end

  defp duration_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp result_success?(%{"status" => status}) when status in ["success", "partial_success"],
    do: true

  defp result_success?(%{"status" => status}) when status in [:success, :partial_success],
    do: true

  defp result_success?(_), do: false

  defp emit(opts, event) do
    case Keyword.get(opts, :on_event) do
      callback when is_function(callback, 1) -> callback.(event)
      _ -> :ok
    end
  end
end
