defmodule Arbor.Orchestrator.Engine do
  @moduledoc """
  Pipeline execution engine for Attractor graphs.

  This implementation currently covers:
  - traversal and deterministic edge selection
  - retry/failure routing and goal gates
  - checkpoint save/load resume
  - event callback stream
  """

  alias Arbor.Orchestrator.Engine.{
    Authorization,
    Checkpoint,
    Condition,
    Context,
    Fidelity,
    Outcome
  }

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.Registry

  @type event :: map()

  @type run_result :: %{
          final_outcome: Outcome.t() | nil,
          completed_nodes: [String.t()],
          context: map(),
          node_durations: %{String.t() => non_neg_integer()}
        }

  @spec run(Graph.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(%Graph{} = graph, opts \\ []) do
    logs_root = Keyword.get(opts, :logs_root, Path.join(System.tmp_dir!(), "arbor_orchestrator"))
    max_steps = Keyword.get(opts, :max_steps, 500)
    pipeline_started_at = System.monotonic_time(:millisecond)

    :ok = write_manifest(graph, logs_root)
    emit(opts, %{
      type: :pipeline_started,
      graph_id: graph.id,
      logs_root: logs_root,
      node_count: map_size(graph.nodes)
    })

    case initial_state(graph, logs_root, opts) do
      {:ok,
       %{next_node_id: nil, context: context, completed_nodes: completed, outcomes: outcomes}} ->
        completed = Enum.reverse(completed)
        last_id = List.last(completed)
        final_outcome = last_id && Map.get(outcomes, last_id)
        duration_ms = System.monotonic_time(:millisecond) - pipeline_started_at
        emit(opts, %{type: :pipeline_completed, completed_nodes: completed, duration_ms: duration_ms})

        {:ok,
         %{
           final_outcome: final_outcome,
           completed_nodes: completed,
           context: Context.snapshot(context),
           node_durations: %{}
         }}

      {:ok, state} ->
        loop(
          graph,
          state.next_node_id,
          nil,
          state.context,
          logs_root,
          max_steps,
          state.completed_nodes,
          state.retries,
          state.outcomes,
          _pending = [],
          opts,
          pipeline_started_at,
          %{}
        )

      {:error, reason} = error ->
        duration_ms = System.monotonic_time(:millisecond) - pipeline_started_at
        emit(opts, %{type: :pipeline_failed, reason: reason, duration_ms: duration_ms})
        error
    end
  end

  defp initial_state(graph, logs_root, opts) do
    if Keyword.get(opts, :resume, false) or Keyword.has_key?(opts, :resume_from) do
      checkpoint_path = Keyword.get(opts, :resume_from, Path.join(logs_root, "checkpoint.json"))

      with {:ok, checkpoint} <- Checkpoint.load(checkpoint_path),
           {:ok, state} <- state_from_checkpoint(graph, checkpoint) do
        emit(opts, %{
          type: :pipeline_resumed,
          checkpoint: checkpoint_path,
          current_node: checkpoint.current_node
        })

        {:ok, state}
      end
    else
      workdir = Keyword.get(opts, :workdir)
      initial_values = Keyword.get(opts, :initial_values, %{})

      context =
        Context.new(
          %{
            "graph.goal" => Map.get(graph.attrs, "goal", ""),
            "graph.label" => Map.get(graph.attrs, "label", "")
          }
          |> then(fn ctx -> if workdir, do: Map.put(ctx, "workdir", workdir), else: ctx end)
          |> Map.merge(initial_values)
        )

      with {:ok, start_id} <- find_start_node(graph) do
        {:ok,
         %{
           next_node_id: start_id,
           context: context,
           completed_nodes: [],
           retries: %{},
           outcomes: %{}
         }}
      end
    end
  end

  defp state_from_checkpoint(graph, checkpoint) do
    context = Context.new(checkpoint.context_values || %{})
    completed = checkpoint.completed_nodes || []
    retries = checkpoint.node_retries || %{}
    outcomes = checkpoint.node_outcomes || %{}
    current_node_id = checkpoint.current_node

    cond do
      current_node_id in [nil, ""] ->
        with {:ok, start_id} <- find_start_node(graph) do
          {:ok,
           %{
             next_node_id: start_id,
             context: context,
             completed_nodes: completed,
             retries: retries,
             outcomes: outcomes
           }}
        end

      not Map.has_key?(graph.nodes, current_node_id) ->
        {:error, :checkpoint_current_node_missing}

      true ->
        node = Map.fetch!(graph.nodes, current_node_id)
        last_outcome = Map.get(outcomes, current_node_id, infer_outcome_from_context(context))

        if terminal?(node) do
          case resolve_goal_gate_retry_target(graph, outcomes) do
            {:ok, nil} ->
              {:ok,
               %{
                 next_node_id: nil,
                 context: context,
                 completed_nodes: completed,
                 retries: retries,
                 outcomes: outcomes
               }}

            {:ok, retry_target} ->
              {:ok,
               %{
                 next_node_id: retry_target,
                 context: context,
                 completed_nodes: completed,
                 retries: retries,
                 outcomes: outcomes
               }}

            {:error, reason} ->
              {:error, reason}
          end
        else
          case select_next_step(node, last_outcome, context, graph) do
            nil ->
              {:ok,
               %{
                 next_node_id: nil,
                 context: context,
                 completed_nodes: completed,
                 retries: retries,
                 outcomes: outcomes
               }}

            {:edge, edge} ->
              {:ok,
               %{
                 next_node_id: edge.to,
                 context: context,
                 completed_nodes: completed,
                 retries: retries,
                 outcomes: outcomes
               }}

            {:node_id, target} ->
              {:ok,
               %{
                 next_node_id: target,
                 context: context,
                 completed_nodes: completed,
                 retries: retries,
                 outcomes: outcomes
               }}
          end
        end
    end
  end

  defp infer_outcome_from_context(context) do
    %Outcome{
      status: parse_status(Context.get(context, "outcome", "success")),
      preferred_label: Context.get(context, "preferred_label"),
      suggested_next_ids: [],
      context_updates: %{},
      notes: nil,
      failure_reason: nil
    }
  end

  defp parse_status("success"), do: :success
  defp parse_status("partial_success"), do: :partial_success
  defp parse_status("retry"), do: :retry
  defp parse_status("fail"), do: :fail
  defp parse_status("skipped"), do: :skipped
  defp parse_status(_), do: :success

  defp loop(
         _graph,
         _node_id,
         _incoming_edge,
         _context,
         _logs_root,
         max_steps,
         _done,
         _retries,
         _outcomes,
         _pending,
         opts,
         pipeline_started_at,
         _node_durations
       )
       when max_steps <= 0 do
    duration_ms = System.monotonic_time(:millisecond) - pipeline_started_at
    emit(opts, %{type: :pipeline_failed, reason: :max_steps_exceeded, duration_ms: duration_ms})
    {:error, :max_steps_exceeded}
  end

  defp loop(
         graph,
         node_id,
         incoming_edge,
         context,
         logs_root,
         max_steps,
         completed,
         retries,
         outcomes,
         pending,
         opts,
         pipeline_started_at,
         node_durations
       ) do
    node = Map.fetch!(graph.nodes, node_id)

    fidelity = Fidelity.resolve(node, incoming_edge, graph, context)

    context =
      context
      |> Context.set("current_node", node.id)
      |> Context.set("internal.fidelity.mode", fidelity.mode)
      |> maybe_set_fidelity_thread(fidelity)

    emit(opts, %{type: :stage_started, node_id: node.id})

    emit(opts, %{
      type: :fidelity_resolved,
      node_id: node.id,
      mode: fidelity.mode,
      thread_id: fidelity.thread_id
    })

    stage_started_at = System.monotonic_time(:millisecond)
    handler_opts = opts |> Keyword.put_new(:logs_root, logs_root) |> Keyword.put(:stage_started_at, stage_started_at)
    {outcome, retries} = execute_with_retry(node, context, graph, retries, handler_opts)

    completed = [node.id | completed]
    outcomes = Map.put(outcomes, node.id, outcome)
    stage_duration = System.monotonic_time(:millisecond) - stage_started_at
    node_durations = Map.put(node_durations, node.id, stage_duration)

    context =
      context
      |> Context.apply_updates(outcome.context_updates || %{})
      |> Context.set("outcome", to_string(outcome.status))
      |> Context.set("__completed_nodes__", completed)
      |> maybe_set_preferred_label(outcome)

    # Check for graph adaptation (graph.adapt handler stores mutated graph in context)
    {graph, context} = check_graph_adaptation(graph, context)

    checkpoint =
      Checkpoint.from_state(node.id, Enum.reverse(completed), retries, context, outcomes)

    :ok = Checkpoint.write(checkpoint, logs_root)
    :ok = write_node_status(node.id, outcome, logs_root)

    emit(opts, %{
      type: :checkpoint_saved,
      node_id: node.id,
      path: Path.join(logs_root, "checkpoint.json")
    })

    cond do
      terminal?(node) ->
        case resolve_goal_gate_retry_target(graph, outcomes) do
          {:ok, nil} ->
            # Before completing, check if there are pending fan-out branches
            case find_next_ready(pending, graph, completed) do
              {next_id, next_edge, remaining} ->
                emit(opts, %{
                  type: :fan_out_branch_resuming,
                  node_id: next_id,
                  pending_count: length(remaining)
                })

                loop(
                  graph,
                  next_id,
                  next_edge,
                  context,
                  logs_root,
                  max_steps - 1,
                  completed,
                  retries,
                  outcomes,
                  remaining,
                  opts,
                  pipeline_started_at,
                  node_durations
                )

              nil ->
                ordered = Enum.reverse(completed)
                duration_ms = System.monotonic_time(:millisecond) - pipeline_started_at
                emit(opts, %{type: :pipeline_completed, completed_nodes: ordered, duration_ms: duration_ms})

                {:ok,
                 %{
                   final_outcome: outcome,
                   completed_nodes: ordered,
                   context: Context.snapshot(context),
                   node_durations: node_durations
                 }}
            end

          {:ok, retry_target} ->
            emit(opts, %{type: :goal_gate_retrying, target: retry_target})

            loop(
              graph,
              retry_target,
              nil,
              context,
              logs_root,
              max_steps - 1,
              completed,
              retries,
              outcomes,
              pending,
              opts,
              pipeline_started_at,
              node_durations
            )

          {:error, reason} ->
            duration_ms = System.monotonic_time(:millisecond) - pipeline_started_at
            emit(opts, %{type: :pipeline_failed, reason: reason, duration_ms: duration_ms})
            {:error, reason}
        end

      true ->
        advance_with_fan_in(
          graph,
          node,
          outcome,
          context,
          logs_root,
          max_steps,
          completed,
          retries,
          outcomes,
          pending,
          opts,
          pipeline_started_at,
          node_durations
        )
    end
  end

  # Fan-in aware advancement: uses existing select_next_step for routing,
  # but also detects implicit fan-out (multiple unconditional edges) and
  # queues sibling branches in pending. Before executing any node, checks
  # that all predecessors are complete (fan-in gate).
  defp advance_with_fan_in(
         graph,
         node,
         outcome,
         context,
         logs_root,
         max_steps,
         completed,
         retries,
         outcomes,
         pending,
         opts,
         pipeline_started_at,
         node_durations
       ) do
    # Use existing routing logic to pick the preferred next target
    preferred = select_next_step(node, outcome, context, graph)

    preferred_id =
      case preferred do
        {:edge, edge} -> edge.to
        {:node_id, id} -> id
        nil -> nil
      end

    # Detect fan-out: collect sibling unconditional edges (excluding preferred)
    fan_out_edges = collect_fan_out_siblings(node, outcome, context, graph)

    extra_targets =
      fan_out_edges
      |> Enum.map(fn e -> {e.to, e} end)
      |> Enum.reject(fn {id, _} -> id == preferred_id or id in completed end)

    new_pending = merge_pending(extra_targets, pending)

    if extra_targets != [] do
      emit(opts, %{
        type: :fan_out_detected,
        node_id: node.id,
        branch_count: length(extra_targets) + 1,
        targets: [preferred_id | Enum.map(extra_targets, fn {id, _} -> id end)]
      })
    end

    # Try the preferred target, with fan-in gate check
    case preferred do
      {:edge, edge} ->
        advance_to_target(
          edge.to,
          edge,
          graph,
          context,
          logs_root,
          max_steps,
          completed,
          retries,
          outcomes,
          new_pending,
          outcome,
          opts,
          pipeline_started_at,
          node_durations
        )

      {:node_id, target_id} ->
        advance_to_target(
          target_id,
          nil,
          graph,
          context,
          logs_root,
          max_steps,
          completed,
          retries,
          outcomes,
          new_pending,
          outcome,
          opts,
          pipeline_started_at,
          node_durations
        )

      nil ->
        # No preferred target — check pending for ready nodes
        case find_next_ready(new_pending, graph, completed) do
          {next_id, next_edge, remaining} ->
            loop(
              graph,
              next_id,
              next_edge,
              context,
              logs_root,
              max_steps - 1,
              completed,
              retries,
              outcomes,
              remaining,
              opts,
              pipeline_started_at,
              node_durations
            )

          nil ->
            ordered = Enum.reverse(completed)
            duration_ms = System.monotonic_time(:millisecond) - pipeline_started_at
            emit(opts, %{type: :pipeline_completed, completed_nodes: ordered, duration_ms: duration_ms})

            {:ok,
             %{
               final_outcome: outcome,
               completed_nodes: ordered,
               context: Context.snapshot(context),
               node_durations: node_durations
             }}
        end
    end
  end

  # Advance to a specific target node, checking fan-in readiness first.
  # The fan-in gate only activates when we're actively tracking fan-out
  # branches (pending is non-empty). This avoids blocking targets whose
  # predecessors were executed internally by handlers (e.g., ParallelHandler).
  defp advance_to_target(
         target_id,
         edge,
         graph,
         context,
         logs_root,
         max_steps,
         completed,
         retries,
         outcomes,
         pending,
         last_outcome,
         opts,
         pipeline_started_at,
         node_durations
       ) do
    fan_in_ready =
      pending == [] or all_predecessors_complete?(graph, target_id, completed)

    if fan_in_ready do
      loop(
        graph,
        target_id,
        edge,
        context,
        logs_root,
        max_steps - 1,
        completed,
        retries,
        outcomes,
        pending,
        opts,
        pipeline_started_at,
        node_durations
      )
    else
      # Target not ready — add to pending and find next ready node
      emit(opts, %{
        type: :fan_in_deferred,
        node_id: target_id,
        waiting_for:
          graph
          |> Graph.incoming_edges(target_id)
          |> Enum.map(& &1.from)
          |> Enum.reject(&(&1 in completed))
      })

      all_pending = [{target_id, edge} | pending]

      case find_next_ready(all_pending, graph, completed) do
        {next_id, next_edge, remaining} ->
          loop(
            graph,
            next_id,
            next_edge,
            context,
            logs_root,
            max_steps - 1,
            completed,
            retries,
            outcomes,
            remaining,
            opts,
            pipeline_started_at,
            node_durations
          )

        nil ->
          # Nothing ready — pipeline complete or deadlock
          ordered = Enum.reverse(completed)
          duration_ms = System.monotonic_time(:millisecond) - pipeline_started_at
          emit(opts, %{type: :pipeline_completed, completed_nodes: ordered, duration_ms: duration_ms})

          {:ok,
           %{
             final_outcome: last_outcome,
             completed_nodes: ordered,
             context: Context.snapshot(context),
             node_durations: node_durations
           }}
      end
    end
  end

  defp execute_with_retry(node, context, graph, retries, opts) do
    handler = Registry.resolve(node)
    max_attempts = parse_max_attempts(node, graph)
    current_retry_count = parse_int(Map.get(retries, node.id, 0))

    do_execute_with_retry(
      handler,
      node,
      context,
      graph,
      retries,
      opts,
      current_retry_count + 1,
      max_attempts
    )
  end

  defp do_execute_with_retry(handler, node, context, graph, retries, opts, attempt, max_attempts) do
    try do
      outcome = Authorization.authorize_and_execute(handler, node, context, graph, opts)

      case outcome.status do
        status when status in [:success, :partial_success] ->
          duration_ms = System.monotonic_time(:millisecond) - Keyword.get(opts, :stage_started_at, 0)
          emit(opts, %{type: :stage_completed, node_id: node.id, status: status, duration_ms: duration_ms})
          {outcome, Map.delete(retries, node.id)}

        status when status in [:retry, :fail] ->
          if attempt < max_attempts do
            delay = retry_delay_ms(node, graph, attempt, opts)

            if status == :fail do
              emit(opts, %{
                type: :stage_failed,
                node_id: node.id,
                error: outcome.failure_reason || "stage failed",
                will_retry: true
              })
            end

            emit(opts, %{
              type: :stage_retrying,
              node_id: node.id,
              attempt: attempt,
              delay_ms: delay
            })

            sleep(opts, delay)

            retries = Map.put(retries, node.id, attempt)

            do_execute_with_retry(
              handler,
              node,
              context,
              graph,
              retries,
              opts,
              attempt + 1,
              max_attempts
            )
          else
            terminal_outcome =
              case status do
                :retry ->
                  if truthy?(Map.get(node.attrs, "allow_partial", false)) do
                    %Outcome{
                      status: :partial_success,
                      notes: "retries exhausted, partial accepted"
                    }
                  else
                    %Outcome{status: :fail, failure_reason: "max retries exceeded"}
                  end

                :fail ->
                  outcome
              end

            emit_stage_terminal(opts, node.id, terminal_outcome)
            {terminal_outcome, retries}
          end

        :skipped ->
          duration_ms = System.monotonic_time(:millisecond) - Keyword.get(opts, :stage_started_at, 0)
          emit(opts, %{type: :stage_completed, node_id: node.id, status: :skipped, duration_ms: duration_ms})
          {outcome, retries}
      end
    rescue
      exception ->
        if should_retry_exception?(exception) and attempt < max_attempts do
          delay = retry_delay_ms(node, graph, attempt, opts)

          emit(opts, %{
            type: :stage_failed,
            node_id: node.id,
            error: Exception.message(exception),
            will_retry: true
          })

          emit(opts, %{type: :stage_retrying, node_id: node.id, attempt: attempt, delay_ms: delay})

          sleep(opts, delay)

          retries = Map.put(retries, node.id, attempt)

          do_execute_with_retry(
            handler,
            node,
            context,
            graph,
            retries,
            opts,
            attempt + 1,
            max_attempts
          )
        else
          outcome = %Outcome{status: :fail, failure_reason: Exception.message(exception)}
          duration_ms = System.monotonic_time(:millisecond) - Keyword.get(opts, :stage_started_at, 0)

          emit(opts, %{
            type: :stage_failed,
            node_id: node.id,
            error: Exception.message(exception),
            will_retry: false,
            duration_ms: duration_ms
          })

          {outcome, retries}
        end
    end
  end

  defp emit_stage_terminal(opts, node_id, %Outcome{status: :fail, failure_reason: reason}) do
    duration_ms = System.monotonic_time(:millisecond) - Keyword.get(opts, :stage_started_at, 0)
    emit(opts, %{type: :stage_failed, node_id: node_id, error: reason, will_retry: false, duration_ms: duration_ms})
  end

  defp emit_stage_terminal(opts, node_id, %Outcome{status: status}) do
    duration_ms = System.monotonic_time(:millisecond) - Keyword.get(opts, :stage_started_at, 0)
    emit(opts, %{type: :stage_completed, node_id: node_id, status: status, duration_ms: duration_ms})
  end

  @doc false
  def should_retry_exception?(exception) do
    message =
      exception
      |> Exception.message()
      |> String.downcase()

    cond do
      String.contains?(message, "timeout") -> true
      String.contains?(message, "timed out") -> true
      String.contains?(message, "network") -> true
      String.contains?(message, "connection") -> true
      String.contains?(message, "rate limit") -> true
      String.contains?(message, "429") -> true
      String.contains?(message, "5xx") -> true
      String.contains?(message, "server error") -> true
      String.contains?(message, "401") -> false
      String.contains?(message, "403") -> false
      String.contains?(message, "400") -> false
      String.contains?(message, "validation") -> false
      true -> false
    end
  end

  # --- Fan-in/fan-out helpers ---

  # Returns sibling fan-out edges (unconditional parallel branches) from a node.
  # Fan-out is ON by default for unconditional edges — multiple outgoing edges
  # without conditions are treated as parallel branches automatically.
  # Set fan_out="false" to force single-path selection (decision nodes).
  defp collect_fan_out_siblings(node, outcome, _context, graph) do
    fan_out_disabled = Map.get(node.attrs, "fan_out") == "false"

    if fan_out_disabled or outcome.status == :fail do
      []
    else
      edges = Graph.outgoing_edges(graph, node.id)
      Enum.filter(edges, &(Map.get(&1.attrs, "condition", "") in ["", nil]))
    end
  end

  # Check if all predecessor nodes (incoming edges) are in the completed list.
  defp all_predecessors_complete?(graph, node_id, completed) do
    graph
    |> Graph.incoming_edges(node_id)
    |> Enum.all?(fn edge -> edge.from in completed end)
  end

  # Find the first ready node from candidates where all predecessors are complete.
  # Returns {node_id, edge, remaining_candidates} or nil.
  defp find_next_ready(candidates, graph, completed) do
    {ready, not_ready} =
      Enum.split_with(candidates, fn {id, _edge} ->
        id not in completed and all_predecessors_complete?(graph, id, completed)
      end)

    case ready do
      [{next_id, next_edge} | rest] ->
        {next_id, next_edge, rest ++ not_ready}

      [] ->
        nil
    end
  end

  # Merge new targets into pending, avoiding duplicates by node_id.
  defp merge_pending(new_targets, existing_pending) do
    existing_ids = MapSet.new(existing_pending, fn {id, _} -> id end)

    new_unique =
      Enum.reject(new_targets, fn {id, _} -> MapSet.member?(existing_ids, id) end)

    existing_pending ++ new_unique
  end

  defp select_next_step(node, outcome, context, graph) do
    if outcome.status == :fail do
      select_fail_step(node, outcome, context, graph)
    else
      case select_handler_suggested_target(node, outcome, graph) do
        {:node_id, _target} = routed ->
          routed

        nil ->
          case select_next_edge(node, outcome, context, graph) do
            nil -> nil
            edge -> {:edge, edge}
          end
      end
    end
  end

  # Some virtual handlers (for example parallel fan-out) need to jump to an
  # inferred target that is not a direct outgoing edge from the current node.
  # Keep this path separate so ordinary edge routing still follows spec section 3.3.
  defp select_handler_suggested_target(node, %Outcome{suggested_next_ids: ids}, graph) do
    outgoing_target_ids =
      graph
      |> Graph.outgoing_edges(node.id)
      |> Enum.map(& &1.to)
      |> MapSet.new()

    ids
    |> Enum.find(fn target ->
      valid_target?(graph, target) and not MapSet.member?(outgoing_target_ids, target)
    end)
    |> case do
      nil -> nil
      target -> {:node_id, target}
    end
  end

  # Failure routing order (spec 3.7):
  # 1) fail edge condition outcome=fail
  # 2) node retry_target
  # 3) node fallback_retry_target
  # 4) terminate
  defp select_fail_step(node, outcome, context, graph) do
    edges = Graph.outgoing_edges(graph, node.id)

    fail_edges =
      Enum.filter(edges, fn edge ->
        case Map.get(edge.attrs, "condition", "") do
          cond when is_binary(cond) and cond != "" -> Condition.eval(cond, outcome, context)
          _ -> false
        end
      end)

    cond do
      fail_edges != [] ->
        {:edge, best_by_weight_then_lexical(fail_edges)}

      valid_target?(graph, Map.get(node.attrs, "retry_target")) ->
        {:node_id, Map.get(node.attrs, "retry_target")}

      valid_target?(graph, Map.get(node.attrs, "fallback_retry_target")) ->
        {:node_id, Map.get(node.attrs, "fallback_retry_target")}

      true ->
        nil
    end
  end

  defp select_next_edge(node, outcome, context, graph) do
    edges = Graph.outgoing_edges(graph, node.id)

    cond do
      edges == [] ->
        nil

      true ->
        condition_matched = Enum.filter(edges, &edge_condition_matches?(&1, outcome, context))
        unconditional = Enum.filter(edges, &(Map.get(&1.attrs, "condition", "") in ["", nil]))

        cond do
          condition_matched != [] ->
            best_by_weight_then_lexical(condition_matched)

          outcome.preferred_label not in [nil, ""] ->
            Enum.find(unconditional, fn edge ->
              normalize_label(Map.get(edge.attrs, "label", "")) ==
                normalize_label(outcome.preferred_label || "")
            end) || best_by_weight_then_lexical(unconditional_or_all(unconditional, edges))

          outcome.suggested_next_ids != [] ->
            Enum.find_value(outcome.suggested_next_ids, fn suggested_id ->
              Enum.find(unconditional, fn edge -> edge.to == suggested_id end)
            end) || best_by_weight_then_lexical(unconditional_or_all(unconditional, edges))

          true ->
            best_by_weight_then_lexical(unconditional_or_all(unconditional, edges))
        end
    end
  end

  defp unconditional_or_all([], edges), do: edges
  defp unconditional_or_all(unconditional, _edges), do: unconditional

  defp edge_condition_matches?(edge, outcome, context) do
    condition = Map.get(edge.attrs, "condition", "")

    if condition in [nil, ""] do
      false
    else
      Condition.eval(condition, outcome, context)
    end
  end

  defp resolve_goal_gate_retry_target(graph, outcomes) do
    failed_gate =
      outcomes
      |> Enum.find_value(fn {node_id, outcome} ->
        node = Map.get(graph.nodes, node_id)

        if node != nil and truthy?(Map.get(node.attrs, "goal_gate", false)) and
             outcome.status not in [:success, :partial_success] do
          node
        else
          nil
        end
      end)

    if failed_gate == nil do
      {:ok, nil}
    else
      targets = [
        Map.get(failed_gate.attrs, "retry_target"),
        Map.get(failed_gate.attrs, "fallback_retry_target"),
        Map.get(graph.attrs, "retry_target"),
        Map.get(graph.attrs, "fallback_retry_target")
      ]

      case Enum.find(targets, &valid_target?(graph, &1)) do
        nil -> {:error, :goal_gate_unsatisfied_no_retry_target}
        target -> {:ok, target}
      end
    end
  end

  defp retry_delay_ms(node, graph, attempt, opts) do
    profile = retry_profile(node, graph)

    initial_delay =
      parse_int(Map.get(node.attrs, "retry_initial_delay_ms"), profile.initial_delay_ms)

    factor = parse_float(Map.get(node.attrs, "retry_backoff_factor"), profile.backoff_factor)
    max_delay = parse_int(Map.get(node.attrs, "retry_max_delay_ms"), profile.max_delay_ms)
    jitter? = parse_bool(Map.get(node.attrs, "retry_jitter"), profile.jitter)

    delay = trunc(initial_delay * :math.pow(factor, attempt - 1))
    delay = min(delay, max_delay)
    maybe_apply_jitter(delay, jitter?, opts)
  end

  defp maybe_apply_jitter(delay, false, _opts), do: delay
  defp maybe_apply_jitter(delay, _jitter, _opts) when delay <= 0, do: delay

  defp maybe_apply_jitter(delay, true, opts) do
    rand_fn = Keyword.get(opts, :rand_fn, &:rand.uniform/0)

    rand =
      rand_fn.()
      |> case do
        v when is_float(v) -> v
        v when is_integer(v) -> v / 1
        _ -> 0.5
      end
      |> min(1.0)
      |> max(0.0)

    jitter_factor = 0.5 + rand
    trunc(delay * jitter_factor)
  end

  defp best_by_weight_then_lexical(edges) do
    Enum.sort_by(edges, fn edge -> {-parse_int(Map.get(edge.attrs, "weight", 0)), edge.to} end)
    |> List.first()
  end

  defp maybe_set_preferred_label(context, %Outcome{preferred_label: label})
       when is_binary(label) do
    Context.set(context, "preferred_label", label)
  end

  defp maybe_set_preferred_label(context, _), do: context

  defp maybe_set_fidelity_thread(context, %{thread_id: nil}), do: context

  defp maybe_set_fidelity_thread(context, %{thread_id: thread_id}) do
    Context.set(context, "internal.fidelity.thread_id", thread_id)
  end

  defp parse_max_attempts(node, graph) do
    cond do
      Map.has_key?(node.attrs, "max_retries") ->
        parse_int(Map.get(node.attrs, "max_retries")) + 1

      Map.has_key?(graph.attrs, "default_max_retry") ->
        parse_int(Map.get(graph.attrs, "default_max_retry")) + 1

      true ->
        retry_profile(node, graph).max_attempts
    end
  end

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> 0
    end
  end

  defp parse_int(_), do: 0

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp parse_float(nil, default), do: default
  defp parse_float(value, _default) when is_float(value), do: value
  defp parse_float(value, _default) when is_integer(value), do: value / 1

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp parse_float(_, default), do: default

  defp parse_bool(nil, default), do: default
  defp parse_bool(value, _default) when is_boolean(value), do: value
  defp parse_bool("true", _default), do: true
  defp parse_bool("false", _default), do: false
  defp parse_bool(1, _default), do: true
  defp parse_bool(0, _default), do: false
  defp parse_bool(_, default), do: default

  defp retry_profile(node, graph) do
    preset_name =
      Map.get(node.attrs, "retry_policy", Map.get(graph.attrs, "retry_policy", "none"))
      |> to_string()
      |> String.downcase()

    case preset_name do
      "standard" ->
        %{
          max_attempts: 5,
          initial_delay_ms: 200,
          backoff_factor: 2.0,
          max_delay_ms: 60_000,
          jitter: true
        }

      "aggressive" ->
        %{
          max_attempts: 5,
          initial_delay_ms: 500,
          backoff_factor: 2.0,
          max_delay_ms: 60_000,
          jitter: true
        }

      "linear" ->
        %{
          max_attempts: 3,
          initial_delay_ms: 500,
          backoff_factor: 1.0,
          max_delay_ms: 60_000,
          jitter: true
        }

      "patient" ->
        %{
          max_attempts: 3,
          initial_delay_ms: 2_000,
          backoff_factor: 3.0,
          max_delay_ms: 60_000,
          jitter: true
        }

      "none" ->
        %{
          max_attempts: 1,
          initial_delay_ms: 200,
          backoff_factor: 2.0,
          max_delay_ms: 60_000,
          jitter: false
        }

      _ ->
        %{
          max_attempts: 1,
          initial_delay_ms: 200,
          backoff_factor: 2.0,
          max_delay_ms: 60_000,
          jitter: true
        }
    end
  end

  defp find_start_node(graph) do
    start =
      graph.nodes
      |> Map.values()
      |> Enum.find(fn node ->
        Map.get(node.attrs, "shape") == "Mdiamond" or String.downcase(node.id) == "start"
      end)

    case start do
      %Node{id: id} -> {:ok, id}
      _ -> {:error, :missing_start_node}
    end
  end

  defp terminal?(node) do
    Map.get(node.attrs, "shape") == "Msquare" or String.downcase(node.id) in ["exit", "end"]
  end

  # --- Graph adaptation (self-modifying pipelines) ---

  defp check_graph_adaptation(graph, context) do
    case Context.get(context, "__adapted_graph__") do
      %Graph{} = new_graph ->
        # Clear the adaptation key so it doesn't re-trigger on next iteration
        context = Context.set(context, "__adapted_graph__", nil)
        {new_graph, context}

      _ ->
        {graph, context}
    end
  end

  defp normalize_label(label) do
    label
    |> to_string()
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/^\[[a-z0-9]\]\s*/i, "")
    |> String.replace(~r/^[a-z0-9]\)\s*/i, "")
    |> String.replace(~r/^[a-z0-9]\s*-\s*/i, "")
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp valid_target?(_graph, target) when target in [nil, ""], do: false
  defp valid_target?(graph, target) when is_binary(target), do: Map.has_key?(graph.nodes, target)
  defp valid_target?(_graph, _target), do: false

  defp emit(opts, event) do
    pipeline_id = Keyword.get(opts, :pipeline_id, :all)
    Arbor.Orchestrator.EventEmitter.emit(pipeline_id, event, opts)
  end

  defp sleep(opts, delay_ms) do
    sleep_fn = Keyword.get(opts, :sleep_fn, fn ms -> Process.sleep(ms) end)
    sleep_fn.(delay_ms)
  end

  defp write_manifest(graph, logs_root) do
    payload = %{
      graph_id: graph.id,
      goal: Map.get(graph.attrs, "goal", ""),
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with :ok <- File.mkdir_p(logs_root),
         :ok <- File.mkdir_p(Path.join(logs_root, "artifacts")),
         {:ok, encoded} <- Jason.encode(payload, pretty: true) do
      File.write(Path.join(logs_root, "manifest.json"), encoded)
    end
  end

  # Internal context keys that contain non-JSON-serializable values (e.g., %Graph{}).
  @internal_context_keys ~w(__adapted_graph__ __completed_nodes__)

  defp write_node_status(node_id, %Outcome{} = outcome, logs_root) do
    node_dir = Path.join(logs_root, node_id)
    status_path = Path.join(node_dir, "status.json")

    sanitized_updates = Map.drop(outcome.context_updates || %{}, @internal_context_keys)

    payload =
      %{
        outcome: to_string(outcome.status),
        preferred_next_label: outcome.preferred_label || "",
        suggested_next_ids: outcome.suggested_next_ids || [],
        context_updates: sanitized_updates,
        notes: outcome.notes,
        failure_reason: outcome.failure_reason,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        status: to_string(outcome.status)
      }

    with :ok <- File.mkdir_p(node_dir),
         {:ok, encoded} <- Jason.encode(payload, pretty: true) do
      File.write(status_path, encoded)
    end
  end
end
