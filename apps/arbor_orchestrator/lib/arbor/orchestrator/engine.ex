defmodule Arbor.Orchestrator.Engine do
  @moduledoc """
  Pipeline execution engine for Attractor graphs.

  This implementation currently covers:
  - traversal and deterministic edge selection
  - retry/failure routing and goal gates
  - checkpoint save/load resume
  - event callback stream
  - content-hash based skip logic
  """

  alias Arbor.Orchestrator.Engine.{
    Checkpoint,
    ContentHash,
    Context,
    Executor,
    Fidelity,
    FidelityTransformer,
    Outcome,
    Router,
    State
  }

  alias Arbor.Orchestrator.Event
  alias Arbor.Orchestrator.EventEmitter
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.{Handler, Registry}
  alias Arbor.Orchestrator.Validation.Validator

  @type event :: map()

  @type run_result :: %{
          run_id: String.t(),
          final_outcome: Outcome.t() | nil,
          completed_nodes: [String.t()],
          context: map(),
          node_durations: %{String.t() => non_neg_integer()}
        }

  # Public API delegations for backward compatibility
  defdelegate should_retry_exception?(exception), to: Executor

  @doc """
  Run a graph pipeline.

  Options:
  - `:validate` — run structural validation before execution (default: `false`).
    When called via `Orchestrator.run/2`, validation runs at the facade level.
    Set this to `true` when calling `Engine.run/2` directly.
  """
  @spec run(Graph.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(%Graph{} = graph, opts \\ []) do
    if Keyword.get(opts, :validate, false) do
      case Validator.validate_or_error(graph) do
        :ok -> do_run(graph, opts)
        {:error, _} = err -> err
      end
    else
      do_run(graph, opts)
    end
  end

  defp do_run(%Graph{} = graph, opts) do
    logs_root = Keyword.get(opts, :logs_root, Path.join(System.tmp_dir!(), "arbor_orchestrator"))
    max_steps = Keyword.get(opts, :max_steps, 500)
    pipeline_started_at = System.monotonic_time(:millisecond)
    run_id = Keyword.get_lazy(opts, :run_id, fn -> generate_run_id(graph.id) end)

    # Thread run_id through opts so all events and checkpoints include it
    opts = Keyword.put(opts, :run_id, run_id)
    opts = Keyword.put_new(opts, :pipeline_id, run_id)

    # Compute graph hash for version checking on resume
    graph_hash = Keyword.get(opts, :graph_hash)
    dot_source_path = Keyword.get(opts, :dot_source_path)

    # Initialize process-local lifecycle tracking via RunState CRC core.
    # This is the Engine's own tracking — no external GenServer dependency.
    run_state =
      Arbor.Orchestrator.RunState.Core.new(run_id, graph.id, map_size(graph.nodes),
        now: DateTime.utc_now(),
        pipeline_id: Keyword.get(opts, :pipeline_id, run_id),
        owner_node: Kernel.node(),
        source_node: Keyword.get(opts, :source_node, Kernel.node()),
        spawning_pid: Keyword.get(opts, :spawning_pid)
      )

    sync_run_state(run_id, run_state)

    :ok = write_manifest(graph, logs_root, run_id)

    emit(
      opts,
      Event.pipeline_started(graph.id,
        run_id: run_id,
        logs_root: logs_root,
        node_count: map_size(graph.nodes),
        graph_hash: graph_hash,
        dot_source_path: dot_source_path,
        spawning_pid: Keyword.get(opts, :spawning_pid)
      )
    )

    case initial_state(graph, logs_root, opts) do
      {:ok,
       %{next_node_id: nil, context: context, completed_nodes: completed, outcomes: outcomes}} ->
        completed = Enum.reverse(completed)
        last_id = List.last(completed)
        final_outcome = last_id && Map.get(outcomes, last_id)
        duration_ms = System.monotonic_time(:millisecond) - pipeline_started_at

        emit(opts, Event.pipeline_completed(completed, duration_ms))
        Checkpoint.cleanup(run_id)

        {:ok,
         %{
           run_id: run_id,
           final_outcome: final_outcome,
           completed_nodes: completed,
           context: Context.snapshot(context),
           node_durations: %{}
         }}

      {:ok, state} ->
        tracking =
          case state do
            %{content_hashes: hashes} ->
              %{%State{}.tracking | content_hashes: hashes}

            _ ->
              %State{}.tracking
          end

        # Restore WAL state from checkpoint on resume
        tracking =
          tracking
          |> Map.put(:pending_intents, Map.get(state, :pending_intents, %{}))
          |> Map.put(:execution_digests, Map.get(state, :execution_digests, %{}))

        engine_state = %State{
          graph: graph,
          node_id: state.next_node_id,
          incoming_edge: nil,
          context: state.context,
          logs_root: logs_root,
          max_steps: max_steps,
          completed: state.completed_nodes,
          retries: state.retries,
          outcomes: state.outcomes,
          pending: [],
          opts: opts,
          pipeline_started_at: pipeline_started_at,
          tracking: tracking,
          run_state: run_state
        }

        loop(engine_state)

      {:error, reason} = error ->
        duration_ms = System.monotonic_time(:millisecond) - pipeline_started_at
        emit(opts, Event.pipeline_failed(reason, duration_ms))
        error
    end
  end

  defp initial_state(graph, logs_root, opts) do
    if Keyword.get(opts, :resume, false) or Keyword.has_key?(opts, :resume_from) do
      checkpoint_path = Keyword.get(opts, :resume_from, Path.join(logs_root, "checkpoint.json"))

      with {:ok, checkpoint} <-
             Checkpoint.load(checkpoint_path, run_id: Keyword.get(opts, :run_id)),
           :ok <- maybe_revalidate_capabilities(graph, opts),
           :ok <- check_indeterminate_intents(checkpoint, graph, opts),
           {:ok, state} <- state_from_checkpoint(graph, checkpoint) do
        emit(opts, Event.pipeline_resumed(checkpoint_path, checkpoint.current_node))

        {:ok,
         state
         |> Map.put(:content_hashes, checkpoint.content_hashes || %{})
         |> Map.put(:pending_intents, checkpoint.pending_intents || %{})
         |> Map.put(:execution_digests, checkpoint.execution_digests || %{})}
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
    context = %{
      Context.new(checkpoint.context_values || %{})
      | lineage: checkpoint.context_lineage || %{}
    }

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
          next_id = resolve_next_node_id(node, last_outcome, context, graph)

          {:ok,
           %{
             next_node_id: next_id,
             context: context,
             completed_nodes: completed,
             retries: retries,
             outcomes: outcomes
           }}
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

  defp loop(%State{max_steps: max_steps, opts: opts, pipeline_started_at: pipeline_started_at})
       when max_steps <= 0 do
    duration_ms = System.monotonic_time(:millisecond) - pipeline_started_at
    emit(opts, Event.pipeline_failed(:max_steps_exceeded, duration_ms))
    {:error, :max_steps_exceeded}
  end

  # Heartbeat interval for distributed liveness detection (30 seconds)
  @heartbeat_interval_ms 30_000

  defp loop(%State{} = state) do
    # Touch pipeline heartbeat periodically for distributed liveness detection
    state = maybe_touch_heartbeat(state)

    node = Map.fetch!(state.graph.nodes, state.node_id)
    fidelity = Fidelity.resolve(node, state.incoming_edge, state.graph, state.context)

    context =
      state.context
      |> Context.set("current_node", node.id, node.id)
      |> Context.set("internal.fidelity.mode", fidelity.mode, node.id)
      |> maybe_set_fidelity_thread(fidelity, node.id)

    # Content-hash skip check
    computed_hash = ContentHash.compute(node, context)
    stored_hash = Map.get(state.tracking.content_hashes, node.id)
    handler = Registry.resolve(node)

    cached_outcome = Map.get(state.outcomes, node.id)

    skip? =
      stored_hash != nil and
        ContentHash.can_skip?(node, computed_hash, stored_hash, handler, cached_outcome)

    if skip? do
      emit(state.opts, Event.stage_skipped(node.id, :content_hash_match))

      # Restore the previous outcome if available, otherwise success
      outcome = Map.get(state.outcomes, node.id, %Outcome{status: :skipped})
      completed = [node.id | state.completed]

      context =
        context
        |> Context.set("outcome", to_string(outcome.status), node.id)
        |> Context.set("__completed_nodes__", completed, node.id)

      tracking =
        state.tracking
        |> put_in([:content_hashes, node.id], computed_hash)

      checkpoint =
        Checkpoint.from_state(
          node.id,
          Enum.reverse(completed),
          state.retries,
          context,
          state.outcomes,
          content_hashes: tracking.content_hashes,
          run_id: Keyword.get(state.opts, :run_id),
          graph_hash: Keyword.get(state.opts, :graph_hash),
          pending_intents: state.tracking.pending_intents,
          execution_digests: state.tracking.execution_digests
        )

      :ok = Checkpoint.write(checkpoint, state.logs_root)

      updated_state = %{state | context: context, completed: completed, tracking: tracking}

      if Router.terminal?(node) do
        handle_terminal(node, outcome, updated_state)
      else
        advance_with_fan_in(node, outcome, updated_state)
      end
    else
      # Normal execution path
      emit(state.opts, Event.stage_started(node.id))
      emit(state.opts, Event.fidelity_resolved(node.id, fidelity.mode, fidelity.thread_id))

      # Update RunState with node_started + sync to ETS
      run_state =
        if state.run_state do
          rs = Arbor.Orchestrator.RunState.Core.node_started(state.run_state, node.id)
          sync_run_state(Keyword.get(state.opts, :run_id), rs)
          rs
        else
          state.run_state
        end

      stage_started_at = System.monotonic_time(:millisecond)

      # Determine idempotency class for WAL wrapping
      idempotency = Handler.idempotency_of(handler)
      is_side_effecting = idempotency == :side_effecting

      # Generate deterministic execution ID for side-effecting nodes
      execution_id =
        if is_side_effecting do
          Checkpoint.generate_execution_id(
            Keyword.get(state.opts, :run_id),
            node.id,
            computed_hash
          )
        else
          nil
        end

      handler_opts =
        state.opts
        |> Keyword.put_new(:logs_root, state.logs_root)
        |> Keyword.put(:stage_started_at, stage_started_at)
        |> then(fn opts ->
          if execution_id, do: Keyword.put(opts, :execution_id, execution_id), else: opts
        end)

      # WAL: Write PendingIntent before executing side-effecting nodes
      tracking =
        if is_side_effecting do
          intent =
            Checkpoint.build_pending_intent(
              to_string(handler),
              computed_hash,
              execution_id
            )

          put_in(state.tracking, [:pending_intents, node.id], intent)
        else
          state.tracking
        end

      # Apply fidelity transform only when explicitly set on node/edge/graph
      handler_context =
        if fidelity.explicit? do
          FidelityTransformer.transform(context, fidelity.mode, handler_opts)
        else
          context
        end

      {outcome, retries} =
        Executor.execute_with_retry(
          node,
          handler_context,
          state.graph,
          state.retries,
          handler_opts
        )

      # auto_status: when enabled and handler didn't produce a success,
      # synthesize SUCCESS so the pipeline continues (spec §4.5)
      outcome = maybe_auto_status(outcome, node)

      # WAL: Promote PendingIntent to ExecutionDigest after successful execution
      tracking =
        if is_side_effecting do
          digest =
            Checkpoint.build_execution_digest(
              computed_hash,
              outcome.status,
              execution_id
            )

          tracking
          |> put_in([:execution_digests, node.id], digest)
          |> update_in([:pending_intents], &Map.delete(&1, node.id))
        else
          tracking
        end

      completed = [node.id | state.completed]
      outcomes = Map.put(state.outcomes, node.id, outcome)
      stage_duration = System.monotonic_time(:millisecond) - stage_started_at

      # Update RunState with node_completed + sync to ETS
      run_state =
        if run_state do
          rs = Arbor.Orchestrator.RunState.Core.node_completed(run_state, node.id, stage_duration)
          sync_run_state(Keyword.get(state.opts, :run_id), rs)
          rs
        else
          run_state
        end

      tracking =
        tracking
        |> put_in([:node_durations, node.id], stage_duration)
        |> put_in([:content_hashes, node.id], computed_hash)

      context =
        context
        |> Context.apply_updates(outcome.context_updates || %{}, node.id)
        |> Context.set("outcome", to_string(outcome.status), node.id)
        |> Context.set("__completed_nodes__", completed, node.id)
        |> maybe_set_preferred_label(outcome, node.id)

      # Check for graph adaptation (graph.adapt handler stores mutated graph in context)
      {graph, context} = check_graph_adaptation(state.graph, context)

      checkpoint =
        Checkpoint.from_state(node.id, Enum.reverse(completed), retries, context, outcomes,
          content_hashes: tracking.content_hashes,
          run_id: Keyword.get(state.opts, :run_id),
          graph_hash: Keyword.get(state.opts, :graph_hash),
          pending_intents: tracking.pending_intents,
          execution_digests: tracking.execution_digests
        )

      :ok = Checkpoint.write(checkpoint, state.logs_root)
      :ok = write_node_status(node.id, outcome, state.logs_root)
      maybe_store_artifact(state.opts, node.id, outcome)

      emit(
        state.opts,
        Event.checkpoint_saved(node.id, Path.join(state.logs_root, "checkpoint.json"))
      )

      updated_state = %{
        state
        | graph: graph,
          context: context,
          completed: completed,
          retries: retries,
          outcomes: outcomes,
          tracking: tracking,
          run_state: run_state
      }

      if Router.terminal?(node) do
        handle_terminal(node, outcome, updated_state)
      else
        advance_with_fan_in(node, outcome, updated_state)
      end
    end
  end

  # Extracted terminal node handling to reduce duplication
  defp handle_terminal(_node, outcome, %State{} = state) do
    case Router.resolve_goal_gate_retry_target(state.graph, state.outcomes) do
      {:ok, nil} ->
        # Before completing, check if there are pending fan-out branches
        case Router.find_next_ready(state.pending, state.graph, state.completed) do
          {next_id, next_edge, remaining} ->
            emit(state.opts, Event.fan_out_branch_resuming(next_id, length(remaining)))

            loop(%{
              state
              | node_id: next_id,
                incoming_edge: next_edge,
                max_steps: state.max_steps - 1,
                pending: remaining
            })

          nil ->
            finish_pipeline(outcome, state)
        end

      {:ok, retry_target} ->
        emit(state.opts, Event.goal_gate_retrying(retry_target))

        loop(%{state | node_id: retry_target, incoming_edge: nil, max_steps: state.max_steps - 1})

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - state.pipeline_started_at
        emit(state.opts, Event.pipeline_failed(reason, duration_ms))
        {:error, reason}
    end
  end

  defp finish_pipeline(outcome, %State{} = state) do
    ordered = Enum.reverse(state.completed)
    duration_ms = System.monotonic_time(:millisecond) - state.pipeline_started_at
    run_id = Keyword.get(state.opts, :run_id)

    # Update RunState to :completed and sync to ETS
    if state.run_state do
      alias Arbor.Orchestrator.RunState.Core, as: RS
      completed_state = RS.mark_completed(state.run_state, duration_ms, now: DateTime.utc_now())
      sync_run_state(run_id, completed_state)
    end

    emit(state.opts, Event.pipeline_completed(ordered, duration_ms))

    # Clean up checkpoint from durable store (no longer needed)
    if run_id, do: Checkpoint.cleanup(run_id)

    {:ok,
     %{
       run_id: run_id,
       final_outcome: outcome,
       completed_nodes: ordered,
       context: Context.snapshot(state.context),
       node_durations: state.tracking.node_durations
     }}
  end

  # Restart the pipeline from a target node with a fresh log directory.
  # Used by loop_restart edges (spec §3.2 step 7). Context is preserved
  # so the new iteration can see results from the previous one.
  defp restart_pipeline(target_node_id, %State{} = state) do
    new_logs_root = next_versioned_path(state.logs_root)
    File.mkdir_p!(new_logs_root)
    :ok = write_manifest(state.graph, new_logs_root)

    loop(%{
      state
      | node_id: target_node_id,
        incoming_edge: nil,
        logs_root: new_logs_root,
        completed: [],
        retries: %{},
        outcomes: %{},
        pending: [],
        tracking: %State{}.tracking
    })
  end

  defp next_versioned_path(path) do
    case Regex.run(~r/-v(\d+)$/, path) do
      [_, n] -> String.replace(path, ~r/-v\d+$/, "-v#{String.to_integer(n) + 1}")
      nil -> "#{path}-v2"
    end
  end

  defp maybe_auto_status(%Outcome{status: status} = outcome, node)
       when status in [:fail, :retry] do
    if Map.get(node.attrs, "auto_status") in [true, "true"] do
      %Outcome{
        status: :success,
        notes: "auto-status: handler completed without writing status",
        context_updates: outcome.context_updates
      }
    else
      outcome
    end
  end

  defp maybe_auto_status(outcome, _node), do: outcome

  # Touch pipeline heartbeat if enough time has passed since the last one.
  # Uses monotonic time in tracking to avoid DateTime overhead on every node.
  defp maybe_touch_heartbeat(%State{} = state) do
    now_mono = System.monotonic_time(:millisecond)
    last = Map.get(state.tracking, :last_heartbeat_touch, 0)

    if now_mono - last >= @heartbeat_interval_ms do
      # Update RunState heartbeat + sync to ETS (new path)
      run_state =
        if state.run_state do
          rs = Arbor.Orchestrator.RunState.Core.touch_heartbeat(state.run_state, DateTime.utc_now())
          sync_run_state(Keyword.get(state.opts, :run_id), rs)
          rs
        else
          state.run_state
        end

      # Also touch the legacy JobRegistry for backward compatibility
      # during the migration period. Can be removed once the
      # RecoveryCoordinator fully migrates to PipelineStatus.
      run_id = Keyword.get(state.opts, :run_id)

      if run_id do
        try do
          Arbor.Orchestrator.JobRegistry.touch_heartbeat(run_id)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end

      tracking = Map.put(state.tracking, :last_heartbeat_touch, now_mono)
      %{state | tracking: tracking, run_state: run_state}
    else
      state
    end
  end

  # Fan-in aware advancement: uses Router for routing,
  # but also detects implicit fan-out (multiple unconditional edges) and
  # queues sibling branches in pending. Before executing any node, checks
  # that all predecessors are complete (fan-in gate).
  defp advance_with_fan_in(node, outcome, %State{} = state) do
    # Use existing routing logic to pick the preferred next target
    preferred = Router.select_next_step(node, outcome, state.context, state.graph)

    preferred_id =
      case preferred do
        {:edge, edge} -> edge.to
        {:node_id, id} -> id
        nil -> nil
      end

    # Detect fan-out: collect sibling unconditional edges (excluding preferred)
    fan_out_edges = Router.collect_fan_out_siblings(node, outcome, state.context, state.graph)

    extra_targets =
      fan_out_edges
      |> Enum.map(fn e -> {e.to, e} end)
      |> Enum.reject(fn {id, _} -> id == preferred_id or id in state.completed end)

    new_pending = Router.merge_pending(extra_targets, state.pending)

    if extra_targets != [] do
      all_targets = [preferred_id | Enum.map(extra_targets, fn {id, _} -> id end)]
      emit(state.opts, Event.fan_out_detected(node.id, length(extra_targets) + 1, all_targets))
    end

    updated_state = %{state | pending: new_pending}

    # Try the preferred target, with fan-in gate check
    case preferred do
      {:edge, edge} ->
        if Map.get(edge, :loop_restart, false) do
          emit(state.opts, Event.loop_restart(edge.from, edge.to))
          restart_pipeline(edge.to, updated_state)
        else
          advance_to_target(edge.to, edge, outcome, updated_state)
        end

      {:node_id, target_id} ->
        advance_to_target(target_id, nil, outcome, updated_state)

      nil ->
        # No preferred target -- check pending for ready nodes
        case Router.find_next_ready(new_pending, state.graph, state.completed) do
          {next_id, next_edge, remaining} ->
            loop(%{
              updated_state
              | node_id: next_id,
                incoming_edge: next_edge,
                max_steps: state.max_steps - 1,
                pending: remaining
            })

          nil ->
            finish_pipeline(outcome, updated_state)
        end
    end
  end

  # Advance to a specific target node, checking fan-in readiness first.
  # The fan-in gate only activates when we're actively tracking fan-out
  # branches (pending is non-empty). This avoids blocking targets whose
  # predecessors were executed internally by handlers (e.g., ParallelHandler).
  defp advance_to_target(target_id, edge, last_outcome, %State{} = state) do
    fan_in_ready =
      state.pending == [] or
        Router.all_predecessors_complete?(state.graph, target_id, state.completed)

    if fan_in_ready do
      loop(%{state | node_id: target_id, incoming_edge: edge, max_steps: state.max_steps - 1})
    else
      # Target not ready -- add to pending and find next ready node
      waiting_for =
        state.graph
        |> Graph.incoming_edges(target_id)
        |> Enum.map(& &1.from)
        |> Enum.reject(&(&1 in state.completed))

      emit(state.opts, Event.fan_in_deferred(target_id, waiting_for))

      all_pending = [{target_id, edge} | state.pending]

      case Router.find_next_ready(all_pending, state.graph, state.completed) do
        {next_id, next_edge, remaining} ->
          loop(%{
            state
            | node_id: next_id,
              incoming_edge: next_edge,
              max_steps: state.max_steps - 1,
              pending: remaining
          })

        nil ->
          # Nothing ready -- pipeline complete or deadlock
          finish_pipeline(last_outcome, %{state | pending: all_pending})
      end
    end
  end

  defp maybe_set_preferred_label(context, %Outcome{preferred_label: label}, node_id)
       when is_binary(label) do
    Context.set(context, "preferred_label", label, node_id)
  end

  defp maybe_set_preferred_label(context, _, _node_id), do: context

  defp maybe_set_fidelity_thread(context, %{thread_id: nil}, _node_id), do: context

  defp maybe_set_fidelity_thread(context, %{thread_id: thread_id}, node_id) do
    Context.set(context, "internal.fidelity.thread_id", thread_id, node_id)
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

    # Stamp every event with pipeline_id and run_id so downstream
    # consumers (JobRegistry, SignalsBridge) can identify which pipeline
    # the event belongs to. Without these, completion/failure events
    # arrive anonymous and the JobRegistry can't update the correct entry
    # — causing zombie :running entries that accumulate forever.
    event =
      event
      |> Map.put_new(:timestamp, DateTime.utc_now())
      |> Map.put_new(:pipeline_id, pipeline_id)
      |> Map.put_new(:run_id, Keyword.get(opts, :run_id))

    EventEmitter.emit(pipeline_id, event, opts)
  end

  # Write the RunState to the shared ETS table for dashboard/Facade visibility.
  # Non-blocking: if the write fails (ETS table gone, process exit), the Engine
  # continues executing. Dashboard goes stale; agent keeps thinking.
  # This is the "graceful degradation" model the council recommended.
  defp sync_run_state(run_id, %Arbor.Orchestrator.RunState.Core{} = run_state) do
    now = DateTime.utc_now()
    synced = Arbor.Orchestrator.RunState.Core.mark_synced(run_state, now)
    entry = Arbor.Orchestrator.RunState.Core.to_ets_entry(synced)
    :ets.insert(:arbor_pipeline_runs, {run_id, entry})
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp sync_run_state(_run_id, nil), do: :ok

  defp write_manifest(graph, logs_root, run_id \\ nil) do
    payload = %{
      graph_id: graph.id,
      run_id: run_id,
      goal: Map.get(graph.attrs, "goal", ""),
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with :ok <- File.mkdir_p(logs_root),
         :ok <- File.mkdir_p(Path.join(logs_root, "artifacts")),
         {:ok, encoded} <- Jason.encode(payload, pretty: true) do
      File.write(Path.join(logs_root, "manifest.json"), encoded)
    end
  end

  # Re-validate that the resuming agent still has required capabilities.
  # Only checked when Security is available and agent_id is provided.
  defp maybe_revalidate_capabilities(_graph, opts) do
    agent_id = Keyword.get(opts, :agent_id)

    if agent_id && Code.ensure_loaded?(Arbor.Security) &&
         function_exported?(Arbor.Security, :authorize, 3) do
      case apply(Arbor.Security, :authorize, [
             agent_id,
             "arbor://orchestrator/execute",
             :resume
           ]) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:unauthorized_resume, reason}}
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  # Check for orphaned PendingIntents on resume.
  # If a side-effecting node started but never completed, the pipeline is in an
  # indeterminate state. Default: halt. Override: force_replay or on_resume="retry".
  defp check_indeterminate_intents(checkpoint, graph, opts) do
    orphaned = Checkpoint.orphaned_intents(checkpoint)

    cond do
      orphaned == [] ->
        :ok

      Keyword.get(opts, :force_replay, false) ->
        # force_replay overrides — clear intents and proceed
        :ok

      true ->
        # Check if ALL orphaned nodes have on_resume="retry" attribute
        all_retriable =
          Enum.all?(orphaned, fn {node_id, _} ->
            node = Map.get(graph.nodes, node_id)
            node != nil and Map.get(node.attrs, "on_resume") == "retry"
          end)

        if all_retriable do
          :ok
        else
          [{node_id, intent} | _] = orphaned
          {:error, {:indeterminate_side_effect, node_id, intent.execution_id}}
        end
    end
  end

  @doc "Generates a unique run ID for a pipeline execution."
  def generate_run_id(graph_id) do
    ts = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    node = Kernel.node() |> to_string()
    "run_#{graph_id}_#{node}_#{ts}_#{suffix}"
  end

  alias Arbor.Orchestrator.Engine.ArtifactStore

  defp maybe_store_artifact(opts, node_id, %Outcome{} = outcome) do
    case Keyword.get(opts, :artifact_store) do
      nil ->
        :ok

      store ->
        store_response_artifact(store, node_id, outcome)
        store_notes_artifact(store, node_id, outcome)
        :ok
    end
  end

  defp store_response_artifact(store, node_id, outcome) do
    case Map.get(outcome.context_updates || %{}, "last_response") do
      nil -> :ok
      response -> ArtifactStore.store(store, node_id, "response.txt", to_string(response))
    end
  end

  defp store_notes_artifact(_store, _node_id, %Outcome{notes: nil}), do: :ok

  defp store_notes_artifact(store, node_id, %Outcome{notes: notes}) do
    ArtifactStore.store(store, node_id, "notes.txt", notes)
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

  defp resolve_next_node_id(node, last_outcome, context, graph) do
    case Router.select_next_step(node, last_outcome, context, graph) do
      nil -> nil
      {:edge, edge} -> if Map.get(edge, :loop_restart, false), do: nil, else: edge.to
      {:node_id, target} -> target
    end
  end
end
