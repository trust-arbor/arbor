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
    Checkpoint,
    Context,
    Executor,
    Fidelity,
    Outcome,
    Router
  }

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node

  @type event :: map()

  @type run_result :: %{
          final_outcome: Outcome.t() | nil,
          completed_nodes: [String.t()],
          context: map(),
          node_durations: %{String.t() => non_neg_integer()}
        }

  # Public API delegations for backward compatibility
  defdelegate should_retry_exception?(exception), to: Executor

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

        emit(opts, %{
          type: :pipeline_completed,
          completed_nodes: completed,
          duration_ms: duration_ms
        })

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

        if Router.terminal?(node) do
          case Router.resolve_goal_gate_retry_target(graph, outcomes) do
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
          case Router.select_next_step(node, last_outcome, context, graph) do
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

    handler_opts =
      opts
      |> Keyword.put_new(:logs_root, logs_root)
      |> Keyword.put(:stage_started_at, stage_started_at)

    {outcome, retries} = Executor.execute_with_retry(node, context, graph, retries, handler_opts)

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
      Router.terminal?(node) ->
        case Router.resolve_goal_gate_retry_target(graph, outcomes) do
          {:ok, nil} ->
            # Before completing, check if there are pending fan-out branches
            case Router.find_next_ready(pending, graph, completed) do
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

                emit(opts, %{
                  type: :pipeline_completed,
                  completed_nodes: ordered,
                  duration_ms: duration_ms
                })

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

  # Fan-in aware advancement: uses Router for routing,
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
    preferred = Router.select_next_step(node, outcome, context, graph)

    preferred_id =
      case preferred do
        {:edge, edge} -> edge.to
        {:node_id, id} -> id
        nil -> nil
      end

    # Detect fan-out: collect sibling unconditional edges (excluding preferred)
    fan_out_edges = Router.collect_fan_out_siblings(node, outcome, context, graph)

    extra_targets =
      fan_out_edges
      |> Enum.map(fn e -> {e.to, e} end)
      |> Enum.reject(fn {id, _} -> id == preferred_id or id in completed end)

    new_pending = Router.merge_pending(extra_targets, pending)

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
        # No preferred target -- check pending for ready nodes
        case Router.find_next_ready(new_pending, graph, completed) do
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

            emit(opts, %{
              type: :pipeline_completed,
              completed_nodes: ordered,
              duration_ms: duration_ms
            })

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
      pending == [] or Router.all_predecessors_complete?(graph, target_id, completed)

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
      # Target not ready -- add to pending and find next ready node
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

      case Router.find_next_ready(all_pending, graph, completed) do
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
          # Nothing ready -- pipeline complete or deadlock
          ordered = Enum.reverse(completed)
          duration_ms = System.monotonic_time(:millisecond) - pipeline_started_at

          emit(opts, %{
            type: :pipeline_completed,
            completed_nodes: ordered,
            duration_ms: duration_ms
          })

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

  defp maybe_set_preferred_label(context, %Outcome{preferred_label: label})
       when is_binary(label) do
    Context.set(context, "preferred_label", label)
  end

  defp maybe_set_preferred_label(context, _), do: context

  defp maybe_set_fidelity_thread(context, %{thread_id: nil}), do: context

  defp maybe_set_fidelity_thread(context, %{thread_id: thread_id}) do
    Context.set(context, "internal.fidelity.thread_id", thread_id)
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

  defp emit(opts, event) do
    pipeline_id = Keyword.get(opts, :pipeline_id, :all)
    Arbor.Orchestrator.EventEmitter.emit(pipeline_id, event, opts)
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
