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

  alias Arbor.Contracts.Security.SigningAuthority

  alias Arbor.Orchestrator.Engine.{
    Checkpoint,
    ContentHash,
    Context,
    EffectOwner,
    Executor,
    Fidelity,
    FidelityTransformer,
    Outcome,
    Router,
    RunAuthorization,
    State
  }

  alias Arbor.Orchestrator.Event
  alias Arbor.Orchestrator.EventEmitter
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.{Handler, Registry}
  alias Arbor.Orchestrator.JsonSafe
  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RunLifecycle.EffectRecoveryCore
  alias Arbor.Orchestrator.Validation.Validator

  @type event :: map()

  @type run_result :: %{
          run_id: String.t(),
          final_outcome: Outcome.t() | nil,
          completed_nodes: [String.t()],
          context: map(),
          taint: %{String.t() => Arbor.Contracts.Security.Taint.t()},
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
  - `:journal_opts` — keyword list selecting the RunJournal target for this
    run's lifecycle operations (e.g. `server:` for an isolated journal).
    Defaults to `[]` (process-global journal), matching
    `RecoveryCoordinator`. Validated once before lifecycle admission;
    invalid values fail closed with `{:error, :invalid_journal_opts}` and
    never silently fall back to the global journal. Kept process-local —
    never written into Engine context or checkpoints.
  """
  @spec run(Graph.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(%Graph{} = graph, opts \\ []) do
    # H16: cap subgraph / pipeline.run / graph.compose nesting so an LLM-
    # generated or malicious DOT pipeline can't recurse without bound and
    # exhaust CPU, memory, or LLM API budget. SubgraphHandler and
    # PipelineRunHandler decrement :max_depth before invoking run/2 again.
    # Default ceiling is 3 levels — empirically deep enough for the
    # legitimate "user pipeline → stdlib → primitive" pattern, tight enough
    # to fail fast on runaway compositions.
    case Keyword.get(opts, :max_depth, 3) do
      depth when is_integer(depth) and depth < 0 ->
        {:error, :max_depth_exceeded}

      _ ->
        if Keyword.get(opts, :validate, false) do
          case Validator.validate_or_error(graph) do
            :ok -> do_run(graph, opts)
            {:error, _} = err -> err
          end
        else
          do_run(graph, opts)
        end
    end
  end

  defp do_run(%Graph{} = graph, opts) do
    with {:ok, {run_authorization, opts}} <- RunAuthorization.prepare(graph, opts) do
      do_prepared_run(graph, run_authorization, opts)
    end
  end

  defp do_prepared_run(%Graph{} = graph, run_authorization, opts) do
    logs_root = Keyword.get(opts, :logs_root, Path.join(System.tmp_dir!(), "arbor_orchestrator"))
    max_steps = Keyword.get(opts, :max_steps, 500)
    pipeline_started_at = System.monotonic_time(:millisecond)
    pipeline_started_at_dt = DateTime.utc_now()
    run_id = Keyword.get_lazy(opts, :run_id, fn -> generate_run_id(graph.id) end)

    # Thread run_id through opts so all events and checkpoints include it
    opts = Keyword.put(opts, :run_id, run_id)
    opts = Keyword.put_new(opts, :pipeline_id, run_id)
    opts = Keyword.put(opts, :pipeline_started_at, pipeline_started_at_dt)

    # Derive checkpoint HMAC secret from the operator's identity, if one
    # was supplied. The HMAC binds checkpoint integrity to the identity
    # that started the run — only the same operator can resume.
    #
    # SigningAuthority path uses Arbor.Security.derive_secret_with_authority/2
    # with domain label :engine_checkpoint_hmac_v3. Derivation failure aborts
    # the authorized run/resume — it must not silently disable resumability.
    #
    # Legacy identity_private_key path uses the pinned v2 HMAC derivation.
    # If no identity is supplied (unsigned dev/test runs), no secret is
    # derived. Checkpoints are written unsigned and resume accepts them
    # only when authorization is off.
    case apply_checkpoint_hmac_secret(opts) do
      {:ok, opts} ->
        do_prepared_run_with_hmac(
          graph,
          run_authorization,
          opts,
          logs_root,
          max_steps,
          pipeline_started_at
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp do_prepared_run_with_hmac(
         %Graph{} = graph,
         run_authorization,
         opts,
         logs_root,
         max_steps,
         pipeline_started_at
       ) do
    # Validate journal target once before any lifecycle read/write or handler
    # dispatch. Invalid values fail closed — never fall back to the global journal.
    # Resume identity is checked first so lifecycle admission cannot expose
    # whether a caller-selected run exists before checkpoint authentication.
    with :ok <- require_resume_identity_before_admission(opts),
         {:ok, opts} <- validate_and_normalize_journal_opts(opts) do
      do_prepared_run_with_journal(
        graph,
        run_authorization,
        opts,
        logs_root,
        max_steps,
        pipeline_started_at
      )
    end
  end

  defp do_prepared_run_with_journal(
         %Graph{} = graph,
         run_authorization,
         opts,
         logs_root,
         max_steps,
         pipeline_started_at
       ) do
    pipeline_started_at_dt = Keyword.get(opts, :pipeline_started_at, DateTime.utc_now())
    run_id = Keyword.fetch!(opts, :run_id)

    # Authorized resume is meaningful only when the checkpoint can be
    # authenticated. Session runs already opt out explicitly; secure ad-hoc
    # runs without checkpoint key material are made non-resumable here rather
    # than writing an unsigned authority projection that can never be trusted.
    # Authority-path derivation failures already aborted above — this only
    # covers the legacy "no key material" case.
    opts = maybe_disable_unverifiable_resume(opts, run_authorization)

    # Compute graph hash for version checking on resume
    graph_hash = Keyword.get(opts, :graph_hash)
    dot_source_path = Keyword.get(opts, :dot_source_path)

    # Initialize process-local lifecycle tracking via RunState CRC core.
    # On resume, seed progress from the claimed/current journal record so we
    # never publish a blank running row over completed_count/nodes/durations
    # before the checkpoint is loaded.
    #
    # Fresh admission + initial lifecycle publication are one atomic
    # RunJournal owner operation (no TOCTOU get-then-put). Resume/recovery
    # revalidates :recovering claim + execution_principal at the journal.
    run_state =
      seed_run_state(
        run_id,
        graph,
        opts,
        pipeline_started_at_dt
      )

    lifecycle_meta =
      lifecycle_meta_from_opts(opts, logs_root, graph_hash, dot_source_path)
      |> put_execution_principal_meta(opts, run_authorization)

    admission = if resume_or_recovery?(opts), do: :resume, else: :fresh
    journal_opts = journal_opts_from(opts)

    case admit_and_sync_run_state(run_state, lifecycle_meta, admission, journal_opts) do
      :ok ->
        # Catch recoverable raise/throw/exit. Terminalization always uses the
        # journal's latest progress (atomic finalize), not a stale lexical RunState.
        try do
          execute_prepared_pipeline(
            graph,
            run_authorization,
            opts,
            logs_root,
            max_steps,
            pipeline_started_at,
            run_id,
            run_state,
            lifecycle_meta,
            graph_hash,
            dot_source_path
          )
        rescue
          e ->
            fail_engine_exception(run_state, run_id, opts, lifecycle_meta, pipeline_started_at, e)
        catch
          :throw, value ->
            fail_engine_throw(run_state, run_id, opts, lifecycle_meta, pipeline_started_at, value)

          # All exits settle — including :normal, :shutdown, and {:shutdown, _}.
          # Filtering those out strands :running records when a handler/link exits cleanly.
          :exit, reason ->
            fail_engine_exit(run_state, run_id, opts, lifecycle_meta, pipeline_started_at, reason)
        end

      {:error, _} = err ->
        err
    end
  end

  defp execute_prepared_pipeline(
         graph,
         run_authorization,
         opts,
         logs_root,
         max_steps,
         pipeline_started_at,
         run_id,
         run_state,
         lifecycle_meta,
         graph_hash,
         dot_source_path
       ) do
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

        journal_opts = journal_opts_from(opts)

        # Canonical effect recovery (L3C) after authenticated checkpoint load
        # and before any handler dispatch OR terminal finalization. Pure
        # decision + shell interpretation. Terminal checkpoints (next_node_id
        # nil) share this path so pending/completed-unapplied effects cannot
        # bypass recovery and be finalized as completed.
        case recover_canonical_effect(
               run_state,
               state,
               run_id,
               lifecycle_meta,
               journal_opts,
               opts
             ) do
          {:error, reason} = error ->
            handle_prepared_pipeline_error(
              reason,
              error,
              run_state,
              run_id,
              opts,
              lifecycle_meta,
              pipeline_started_at
            )

          {:ok, run_state} ->
            after_canonical_recovery(
              state,
              run_state,
              graph,
              run_authorization,
              logs_root,
              max_steps,
              pipeline_started_at,
              run_id,
              lifecycle_meta,
              opts,
              tracking
            )
        end

      {:error, reason} = error ->
        # Pre-execution resume/recovery failures (checkpoint load, HMAC,
        # capability/auth, identity, canonical effect recovery) must not be
        # terminalized here — the outer claim owner (public resume /
        # RecoveryCoordinator) classifies and settles exactly once
        # (retryable → :interrupted, corruption → :failed).
        handle_prepared_pipeline_error(
          reason,
          error,
          run_state,
          run_id,
          opts,
          lifecycle_meta,
          pipeline_started_at
        )
    end
  end

  # Shared post-recovery branch for every successful authenticated initial_state.
  # Checkpoint.completed_nodes is chronological (from_state persists
  # Enum.reverse of newest-first internal state). Engine State.completed is
  # newest-first. Terminal resumes finalize with chronological order unchanged.
  defp after_canonical_recovery(
         %{next_node_id: nil, context: context, completed_nodes: completed, outcomes: outcomes},
         run_state,
         _graph,
         _run_authorization,
         _logs_root,
         _max_steps,
         pipeline_started_at,
         run_id,
         lifecycle_meta,
         opts,
         _tracking
       ) do
    # Chronological checkpoint order — do not reverse.
    last_id = List.last(completed)
    final_outcome = last_id && Map.get(outcomes, last_id)
    duration_ms = System.monotonic_time(:millisecond) - pipeline_started_at

    case finalize_terminal(
           run_state,
           run_id,
           :completed,
           nil,
           duration_ms,
           opts,
           lifecycle_meta,
           completed_nodes: completed
         ) do
      :ok ->
        Checkpoint.cleanup(run_id)

        {:ok,
         %{
           run_id: run_id,
           final_outcome: final_outcome,
           completed_nodes: completed,
           context: Context.snapshot(context),
           taint: Context.taint_map(context),
           node_durations: %{}
         }}

      {:error, reason} ->
        {:error, {:lifecycle_finalize_failed, reason}}
    end
  end

  defp after_canonical_recovery(
         state,
         run_state,
         graph,
         run_authorization,
         logs_root,
         max_steps,
         pipeline_started_at,
         _run_id,
         _lifecycle_meta,
         opts,
         tracking
       ) do
    engine_state = %State{
      graph: graph,
      node_id: state.next_node_id,
      incoming_edge: nil,
      context: state.context,
      logs_root: logs_root,
      max_steps: max_steps,
      # Chronological checkpoint → newest-first internal representation.
      completed: Enum.reverse(state.completed_nodes || []),
      retries: state.retries,
      outcomes: state.outcomes,
      pending: [],
      opts: opts,
      pipeline_started_at: pipeline_started_at,
      tracking: tracking,
      run_state: run_state,
      run_authorization: run_authorization
    }

    safe_loop(engine_state)
  end

  defp handle_prepared_pipeline_error(
         reason,
         error,
         run_state,
         run_id,
         opts,
         lifecycle_meta,
         pipeline_started_at
       ) do
    if resume_or_recovery?(opts) and pre_execution_resume_failure?(reason) do
      error
    else
      duration_ms = System.monotonic_time(:millisecond) - pipeline_started_at

      case finalize_terminal(
             run_state,
             run_id,
             :failed,
             reason,
             duration_ms,
             opts,
             lifecycle_meta
           ) do
        :ok -> error
        {:error, finalize_reason} -> {:error, {:lifecycle_finalize_failed, finalize_reason}}
      end
    end
  end

  # Each loop iteration catches recoverable failures against the *current* State
  # so late exceptions finalize current progress, not the initial RunState.
  defp safe_loop(%State{} = state) do
    try do
      loop(state)
    rescue
      e ->
        fail_from_engine_state(state, {:engine_exception, Exception.message(e)})
    catch
      :throw, value ->
        fail_from_engine_state(state, {:engine_throw, inspect(value)})

      # Settle every exit reason — :normal/:shutdown/{:shutdown,_} must not
      # leave a seeded run stranded in :running/:recovering.
      :exit, reason ->
        fail_from_engine_state(state, {:engine_exit, classify_exit_reason(reason)})
    end
  end

  defp fail_from_engine_state(%State{} = state, reason) do
    duration_ms = System.monotonic_time(:millisecond) - state.pipeline_started_at
    run_id = Keyword.get(state.opts, :run_id)

    case finalize_terminal(
           state.run_state,
           run_id,
           :failed,
           reason,
           duration_ms,
           state.opts,
           lifecycle_meta_from_state(state)
         ) do
      :ok -> {:error, reason}
      {:error, finalize_reason} -> {:error, {:lifecycle_finalize_failed, finalize_reason}}
    end
  end

  defp fail_engine_exception(run_state, run_id, opts, lifecycle_meta, started_at, e) do
    reason = {:engine_exception, Exception.message(e)}
    duration_ms = System.monotonic_time(:millisecond) - started_at

    case finalize_terminal(run_state, run_id, :failed, reason, duration_ms, opts, lifecycle_meta) do
      :ok -> {:error, reason}
      {:error, finalize_reason} -> {:error, {:lifecycle_finalize_failed, finalize_reason}}
    end
  end

  defp fail_engine_throw(run_state, run_id, opts, lifecycle_meta, started_at, value) do
    reason = {:engine_throw, inspect(value)}
    duration_ms = System.monotonic_time(:millisecond) - started_at

    case finalize_terminal(run_state, run_id, :failed, reason, duration_ms, opts, lifecycle_meta) do
      :ok -> {:error, reason}
      {:error, finalize_reason} -> {:error, {:lifecycle_finalize_failed, finalize_reason}}
    end
  end

  defp fail_engine_exit(run_state, run_id, opts, lifecycle_meta, started_at, exit_reason) do
    reason = {:engine_exit, classify_exit_reason(exit_reason)}
    duration_ms = System.monotonic_time(:millisecond) - started_at

    case finalize_terminal(run_state, run_id, :failed, reason, duration_ms, opts, lifecycle_meta) do
      :ok -> {:error, reason}
      {:error, finalize_reason} -> {:error, {:lifecycle_finalize_failed, finalize_reason}}
    end
  end

  # Bound exit terms before they enter failure_reason / durable metadata.
  defp classify_exit_reason(:normal), do: "normal"
  defp classify_exit_reason(:shutdown), do: "shutdown"
  defp classify_exit_reason({:shutdown, reason}), do: {"shutdown", classify_exit_reason(reason)}
  defp classify_exit_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp classify_exit_reason(reason) when is_binary(reason), do: reason
  defp classify_exit_reason(reason), do: inspect(reason, limit: 20, printable_limit: 200)

  defp initial_state(graph, logs_root, opts) do
    if Keyword.get(opts, :resume, false) or Keyword.has_key?(opts, :resume_from) do
      checkpoint_path = Keyword.get(opts, :resume_from, Path.join(logs_root, "checkpoint.json"))

      with :ok <- require_identity_on_resume(opts),
           {:ok, checkpoint} <-
             Checkpoint.load(checkpoint_path,
               run_id: Keyword.get(opts, :run_id),
               hmac_secret: Keyword.get(opts, :hmac_secret)
             ),
           :ok <-
             RunAuthorization.verify_checkpoint(
               Keyword.get(opts, :run_authorization),
               checkpoint.run_authorization
             ),
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
      initial_values = Keyword.get(opts, :initial_values, %{})
      run_authorization = Keyword.get(opts, :run_authorization)

      pipeline_dt = Keyword.get(opts, :pipeline_started_at, DateTime.utc_now())

      values =
        %{
          "graph.goal" => Map.get(graph.attrs, "goal", ""),
          "graph.label" => Map.get(graph.attrs, "label", "")
        }
        |> Map.merge(initial_values)
        |> RunAuthorization.seed_values(run_authorization, Keyword.get(opts, :workdir))

      context =
        Context.new(
          values,
          pipeline_started_at: pipeline_dt,
          # Inherit provenance taint from a parent pipeline (subgraph/parallel
          # boundary). Defaults to empty for a top-level run.
          taint: Keyword.get(opts, :initial_taint, %{})
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
    context =
      Context.new(
        checkpoint.context_values || %{},
        pipeline_started_at: checkpoint.pipeline_started_at
      )

    context = %{
      context
      | lineage: checkpoint.context_lineage || %{},
        # Restore provenance taint so resume isn't fail-open (a resumed pipeline
        # must remember which keys were untrusted). Taint-tracking-rebuild Phase 2.
        taint: checkpoint.context_taint || %{}
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

  defp loop(
         %State{
           max_steps: max_steps,
           opts: opts,
           pipeline_started_at: pipeline_started_at,
           run_state: run_state
         } = state
       )
       when max_steps <= 0 do
    duration_ms = System.monotonic_time(:millisecond) - pipeline_started_at
    run_id = Keyword.get(opts, :run_id)

    case finalize_terminal(
           run_state,
           run_id,
           :failed,
           :max_steps_exceeded,
           duration_ms,
           opts,
           lifecycle_meta_from_state(state)
         ) do
      :ok -> {:error, :max_steps_exceeded}
      {:error, reason} -> {:error, {:lifecycle_finalize_failed, reason}}
    end
  end

  # Heartbeat interval for distributed liveness detection (30 seconds)
  @heartbeat_interval_ms 30_000

  defp loop(%State{} = state) do
    # Touch pipeline heartbeat periodically for distributed liveness detection
    state = maybe_touch_heartbeat(state)

    node = Map.fetch!(state.graph.nodes, state.node_id)

    # Context is data, never authority. Reassert the JSON-clean mirrors before
    # every node so a prior outcome cannot redirect legacy handlers that still
    # read session.agent_id/workdir from context.
    authority_context =
      RunAuthorization.enforce_context(state.context, state.run_authorization)

    fidelity = Fidelity.resolve(node, state.incoming_edge, state.graph, authority_context)

    # Capture a single logical timestamp for all context lineage entries created
    # while processing this node. This gives "one node execution step = one time"
    # for lineage queries while still allowing pure callers to inject a deterministic
    # timestamp via the new Context.set/5 and apply_updates/4 APIs.
    step_now = DateTime.utc_now()

    context =
      authority_context
      |> Context.set("current_node", node.id, node.id, step_now)
      |> Context.set("internal.fidelity.mode", fidelity.mode, node.id, step_now)
      |> maybe_set_fidelity_thread(fidelity, node.id, step_now)

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

      # Re-apply the cached outcome's context updates. Skipping the WORK
      # must still produce the EFFECT — otherwise a loop that revisits an
      # idempotent node loses that node's output_key writes if another
      # node clobbered the slot between visits. Mirrors the apply_updates
      # call in the normal-execution path.
      context =
        context
        |> Context.apply_updates(outcome.context_updates || %{}, node.id, step_now)
        |> record_node_taint(node, outcome)
        |> apply_taint_reductions(node, outcome)
        |> Context.set("outcome", to_string(outcome.status), node.id, step_now)
        |> Context.set("__completed_nodes__", completed, node.id, step_now)

      tracking =
        state.tracking
        |> put_in([:content_hashes, node.id], computed_hash)

      if resumable?(state.opts) do
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
            execution_digests: state.tracking.execution_digests,
            pipeline_started_at: Context.pipeline_started_at(context),
            run_authorization: RunAuthorization.projection(state.run_authorization)
          )

        :ok =
          Checkpoint.write(checkpoint, state.logs_root,
            hmac_secret: Keyword.get(state.opts, :hmac_secret)
          )
      end

      updated_state = %{state | context: context, completed: completed, tracking: tracking}

      if Router.terminal?(node) do
        handle_terminal(node, outcome, updated_state)
      else
        advance_with_fan_in(node, outcome, updated_state)
      end
    else
      execute_node_visit(
        node,
        handler,
        context,
        fidelity,
        computed_hash,
        step_now,
        state
      )
    end
  end

  # Normal node visit: journaled handlers (:idempotent_with_key / :side_effecting)
  # follow the PipelineStatus effect-owner protocol. Other classes keep the
  # lightweight path (no effect envelope; no new pending_intents).
  # Journaled visits write Checkpoint.execution_digests as the current-visit
  # recovery marker after a successful receipt and before checkpoint persist.
  defp execute_node_visit(
         node,
         handler,
         context,
         fidelity,
         computed_hash,
         step_now,
         %State{} = state
       ) do
    emit(state.opts, Event.stage_started(node.id))
    emit(state.opts, Event.fidelity_resolved(node.id, fidelity.mode, fidelity.thread_id))

    idempotency = Handler.idempotency_of(handler)
    journaled? = EffectOwner.journaled?(idempotency)
    run_id = Keyword.get(state.opts, :run_id)
    journal_opts = journal_opts_from(state.opts)
    lifecycle_meta = lifecycle_meta_from_state(state)
    stage_started_at = System.monotonic_time(:millisecond)

    case sync_node_started(
           state.run_state,
           node.id,
           run_id,
           lifecycle_meta,
           journal_opts,
           journaled?
         ) do
      {:error, reason, run_state} ->
        fail_from_engine_state(%{state | run_state: run_state}, reason)

      {:error, reason} ->
        fail_from_engine_state(state, reason)

      {:ok, run_state} ->
        case maybe_prepare_effect(
               journaled?,
               run_id,
               node,
               handler,
               idempotency,
               computed_hash,
               journal_opts
             ) do
          {:error, reason} ->
            # Preserve node_started RunState when prepare fails closed.
            fail_from_engine_state(%{state | run_state: run_state}, reason)

          {:ok, effect_ctx} ->
            execution_id = effect_ctx && effect_ctx.execution_id

            handler_opts =
              state.opts
              |> Keyword.put_new(:logs_root, state.logs_root)
              |> Keyword.put(:stage_started_at, stage_started_at)
              |> then(fn opts ->
                if execution_id, do: Keyword.put(opts, :execution_id, execution_id), else: opts
              end)

            # No new legacy pending_intents on this path. Loaded legacy
            # pending_intents remain for resume compat; execution_digests are
            # updated after receipt as the current-visit recovery marker.
            tracking = state.tracking

            handler_context =
              if fidelity.explicit? do
                FidelityTransformer.transform(context, fidelity.mode, handler_opts)
              else
                context
              end

            # Long-running handlers can block for minutes; refresh heartbeat while
            # the call is in flight. Journal target stays process-local on the ticker.
            {outcome, retries} =
              with_in_call_heartbeat(run_id, journal_opts, fn ->
                Executor.execute_with_retry(
                  node,
                  handler_context,
                  state.graph,
                  state.retries,
                  handler_opts
                )
              end)

            outcome = maybe_auto_status(outcome, node)
            stage_duration = System.monotonic_time(:millisecond) - stage_started_at

            post_execute_visit(
              node,
              outcome,
              retries,
              context,
              computed_hash,
              step_now,
              stage_duration,
              run_state,
              tracking,
              effect_ctx,
              journaled?,
              %{state | run_state: run_state}
            )
        end
    end
  end

  defp sync_node_started(nil, _node_id, _run_id, _meta, _journal_opts, true) do
    {:error, {:effect_node_start_sync_failed, :run_state_missing}}
  end

  defp sync_node_started(nil, _node_id, _run_id, _meta, _journal_opts, false), do: {:ok, nil}

  defp sync_node_started(run_state, node_id, run_id, meta, journal_opts, journaled?) do
    rs = Arbor.Orchestrator.RunState.Core.node_started(run_state, node_id)

    case sync_run_state(run_id, rs, meta, journal_opts) do
      :ok ->
        {:ok, rs}

      {:error, reason} ->
        if journaled? do
          {:error, {:effect_node_start_sync_failed, reason}, rs}
        else
          # Non-journaled path preserves prior best-effort progress sync.
          {:ok, rs}
        end
    end
  end

  defp maybe_prepare_effect(false, _run_id, _node, _handler, _idempotency, _hash, _jopts) do
    {:ok, nil}
  end

  defp maybe_prepare_effect(
         true,
         run_id,
         node,
         handler,
         idempotency,
         computed_hash,
         journal_opts
       )
       when is_binary(run_id) do
    # Impure inputs obtained once at the Engine boundary, then pure construction.
    execution_id = EffectOwner.fresh_execution_id(:crypto.strong_rand_bytes(16))
    started_at = DateTime.utc_now() |> DateTime.to_iso8601()

    attrs =
      EffectOwner.prepare_attrs(
        run_id,
        node.id,
        execution_id,
        EffectOwner.handler_identity(handler),
        idempotency,
        computed_hash,
        started_at
      )

    case PipelineStatus.prepare_effect(run_id, attrs, journal_opts) do
      {:ok, tag, effect} when tag in [:prepared, :already_prepared] ->
        generation = effect["generation"]

        {:ok,
         %{
           execution_id: execution_id,
           generation: generation,
           run_id: run_id,
           journal_opts: journal_opts,
           input_hash: computed_hash
         }}

      {:error, reason} ->
        {:error, {:effect_prepare_failed, reason}}
    end
  end

  defp maybe_prepare_effect(true, _run_id, _node, _handler, _idempotency, _hash, _jopts) do
    {:error, {:effect_prepare_failed, :run_id_missing}}
  end

  defp post_execute_visit(
         node,
         outcome,
         retries,
         context,
         computed_hash,
         step_now,
         stage_duration,
         run_state,
         tracking,
         effect_ctx,
         journaled?,
         %State{} = state
       ) do
    # Always carry the newest process-local engine state into terminal finalization
    # on failure paths. RunJournal retains effect evidence independently.
    base_state = %{state | run_state: run_state}

    case maybe_record_effect_receipt(journaled?, effect_ctx, outcome) do
      {:error, reason} ->
        fail_from_engine_state(base_state, reason)

      {:ok, effect_ctx_after_receipt} ->
        # After successful journal receipt and before checkpoint persistence,
        # bind the current visit marker in execution_digests (execution_id,
        # input_hash, outcome_status, timestamp). Recovery requires this exact
        # visit identity — node_id alone is insufficient when DOT nodes repeat.
        case put_effect_execution_digest(
               journaled?,
               tracking,
               node,
               effect_ctx_after_receipt,
               outcome
             ) do
          {:error, reason} ->
            fail_from_engine_state(base_state, reason)

          {:ok, tracking} ->
            case apply_outcome_and_checkpoint(
                   node,
                   outcome,
                   retries,
                   context,
                   computed_hash,
                   step_now,
                   stage_duration,
                   run_state,
                   tracking,
                   journaled?,
                   state
                 ) do
              {:error, reason, partial_state} ->
                fail_from_engine_state(partial_state, reason)

              {:ok, applied} ->
                partial_after_apply = %{
                  state
                  | graph: applied.graph,
                    context: applied.context,
                    completed: applied.completed,
                    retries: applied.retries,
                    outcomes: applied.outcomes,
                    tracking: applied.tracking,
                    run_state: applied.run_state
                }

                case sync_node_completed(
                       applied.run_state,
                       node.id,
                       stage_duration,
                       Keyword.get(state.opts, :run_id),
                       lifecycle_meta_from_state(partial_after_apply),
                       journal_opts_from(state.opts),
                       journaled?
                     ) do
                  {:error, reason, rs} ->
                    # Prefer the post-node_completed RunState even when journal sync fails.
                    fail_from_engine_state(%{partial_after_apply | run_state: rs}, reason)

                  {:error, reason} ->
                    fail_from_engine_state(partial_after_apply, reason)

                  {:ok, run_state2} ->
                    partial_after_progress = %{partial_after_apply | run_state: run_state2}

                    case maybe_settle_effect(journaled?, effect_ctx) do
                      {:error, reason} ->
                        fail_from_engine_state(partial_after_progress, reason)

                      :ok ->
                        # Status/artifact publication and graph routing only after
                        # settle (or non-journaled path with no effect protocol).
                        if status_files_enabled?(),
                          do: :ok = write_node_status(node.id, outcome, state.logs_root)

                        maybe_store_artifact(state.opts, node.id, outcome)

                        if Router.terminal?(node) do
                          handle_terminal(node, outcome, partial_after_progress)
                        else
                          advance_with_fan_in(node, outcome, partial_after_progress)
                        end
                    end
                end
            end
        end
    end
  end

  defp maybe_record_effect_receipt(false, effect_ctx, _outcome), do: {:ok, effect_ctx}

  defp maybe_record_effect_receipt(true, effect_ctx, outcome) do
    %{run_id: run_id, generation: generation, execution_id: execution_id, journal_opts: jopts} =
      effect_ctx

    completed_at = DateTime.utc_now() |> DateTime.to_iso8601()

    case EffectOwner.receipt_attrs(outcome, completed_at) do
      {:error, reason} ->
        {:error, {:effect_receipt_failed, reason}}

      {:ok, receipt} ->
        case PipelineStatus.record_effect_receipt(
               run_id,
               generation,
               execution_id,
               receipt,
               jopts
             ) do
          {:ok, tag, effect} when tag in [:recorded, :already_recorded] and is_map(effect) ->
            # Keep the durable receipt envelope so the visit marker cannot drift
            # from journal-recorded completed_at / outcome_status / digests.
            {:ok, Map.put(effect_ctx, :recorded_effect, effect)}

          {:error, reason} ->
            {:error, {:effect_receipt_failed, reason}}
        end
    end
  end

  # Per-node current-visit recovery marker (overwrites prior visit for same node_id).
  # Durable effect supplies execution_id / input_hash / completed_at; Outcome.status
  # is the atom written to the marker after it is proven equal to the receipt's
  # outcome_status string. Fail closed before checkpoint/progress/settle when the
  # envelope and Outcome disagree or required marker fields are invalid.
  defp put_effect_execution_digest(false, tracking, _node, _effect_ctx, _outcome),
    do: {:ok, tracking}

  defp put_effect_execution_digest(true, tracking, node, effect_ctx, %Outcome{} = outcome)
       when is_map(effect_ctx) and is_map(tracking) do
    case Map.get(effect_ctx, :recorded_effect) do
      effect when is_map(effect) ->
        build_effect_execution_digest(tracking, node, effect, outcome)

      _ ->
        {:error, {:effect_execution_marker_failed, :recorded_effect_missing}}
    end
  end

  defp put_effect_execution_digest(true, _tracking, _node, _effect_ctx, _outcome),
    do: {:error, {:effect_execution_marker_failed, :invalid_marker_inputs}}

  defp put_effect_execution_digest(_journaled?, tracking, _node, _effect_ctx, _outcome),
    do: {:ok, tracking}

  defp build_effect_execution_digest(tracking, node, effect, %Outcome{} = outcome)
       when is_map(tracking) and is_map(effect) do
    exec_id = effect["execution_id"]
    hash = effect["input_hash"]
    effect_status = effect["outcome_status"]
    completed_at = effect["completed_at"]
    outcome_status = outcome.status

    cond do
      not nonblank_binary?(exec_id) ->
        {:error, {:effect_execution_marker_failed, :invalid_execution_id}}

      not nonblank_binary?(hash) ->
        {:error, {:effect_execution_marker_failed, :invalid_input_hash}}

      not nonblank_binary?(completed_at) ->
        {:error, {:effect_execution_marker_failed, :invalid_completed_at}}

      not is_atom(outcome_status) ->
        {:error, {:effect_execution_marker_failed, :invalid_outcome_status}}

      not is_binary(effect_status) or effect_status == "" ->
        {:error, {:effect_execution_marker_failed, :invalid_effect_outcome_status}}

      Atom.to_string(outcome_status) != effect_status ->
        {:error, {:effect_execution_marker_failed, :outcome_status_mismatch}}

      true ->
        digest = %{
          input_hash: hash,
          # Receipt-validated Outcome atom — never invent atoms or retain strings.
          outcome_status: outcome_status,
          completed_at: completed_at,
          execution_id: exec_id
        }

        {:ok, put_in(tracking, [:execution_digests, node.id], digest)}
    end
  end

  defp nonblank_binary?(value) when is_binary(value), do: value != ""
  defp nonblank_binary?(_), do: false

  defp apply_outcome_and_checkpoint(
         node,
         outcome,
         retries,
         context,
         computed_hash,
         step_now,
         stage_duration,
         run_state,
         tracking,
         journaled?,
         %State{} = state
       ) do
    completed = [node.id | state.completed]
    outcomes = Map.put(state.outcomes, node.id, outcome)

    tracking =
      tracking
      |> put_in([:node_durations, node.id], stage_duration)
      |> put_in([:content_hashes, node.id], computed_hash)

    context =
      context
      |> Context.apply_updates(outcome.context_updates || %{}, node.id, step_now)
      |> record_node_taint(node, outcome)
      |> apply_taint_reductions(node, outcome)
      |> Context.set("outcome", to_string(outcome.status), node.id, step_now)
      |> Context.set("__completed_nodes__", completed, node.id, step_now)
      |> maybe_set_preferred_label(outcome, node.id, step_now)

    {graph, context} = check_graph_adaptation(state.graph, context)

    applied = %{
      graph: graph,
      context: context,
      completed: completed,
      retries: retries,
      outcomes: outcomes,
      tracking: tracking,
      run_state: run_state
    }

    # Newest in-process graph/context/outcomes even if checkpoint persistence fails.
    partial_state = %{
      state
      | graph: graph,
        context: context,
        completed: completed,
        retries: retries,
        outcomes: outcomes,
        tracking: tracking,
        run_state: run_state
    }

    if resumable?(state.opts) do
      checkpoint =
        Checkpoint.from_state(node.id, Enum.reverse(completed), retries, context, outcomes,
          content_hashes: tracking.content_hashes,
          run_id: Keyword.get(state.opts, :run_id),
          graph_hash: Keyword.get(state.opts, :graph_hash),
          # Preserve loaded legacy pending_intents; execution_digests hold the
          # current-visit recovery marker written after effect receipt.
          pending_intents: tracking.pending_intents,
          execution_digests: tracking.execution_digests,
          pipeline_started_at: Context.pipeline_started_at(context),
          run_authorization: RunAuthorization.projection(state.run_authorization)
        )

      case Checkpoint.persist(checkpoint, state.logs_root,
             hmac_secret: Keyword.get(state.opts, :hmac_secret)
           ) do
        {:ok, _receipt} ->
          emit(
            state.opts,
            Event.checkpoint_saved(node.id, Path.join(state.logs_root, "checkpoint.json"))
          )

          {:ok, applied}

        {:error, reason} ->
          # Phase-specific tag for journaled visits; non-journaled keeps a
          # stable checkpoint-failure shape for the same terminal path.
          err =
            if journaled?,
              do: {:effect_checkpoint_failed, reason},
              else: {:checkpoint_persist_failed, reason}

          {:error, err, partial_state}
      end
    else
      {:ok, applied}
    end
  end

  defp sync_node_completed(nil, _node_id, _duration, _run_id, _meta, _jopts, true) do
    {:error, {:effect_completed_progress_failed, :run_state_missing}}
  end

  defp sync_node_completed(nil, _node_id, _duration, _run_id, _meta, _jopts, false),
    do: {:ok, nil}

  defp sync_node_completed(
         run_state,
         node_id,
         stage_duration,
         run_id,
         meta,
         journal_opts,
         journaled?
       ) do
    # Compute newest process-local progress first; journal sync may fail while
    # this RunState is still the correct finalization input.
    rs = Arbor.Orchestrator.RunState.Core.node_completed(run_state, node_id, stage_duration)

    case sync_run_state(run_id, rs, meta, journal_opts) do
      :ok ->
        {:ok, rs}

      {:error, reason} ->
        if journaled? do
          {:error, {:effect_completed_progress_failed, reason}, rs}
        else
          {:ok, rs}
        end
    end
  end

  defp maybe_settle_effect(false, _effect_ctx), do: :ok

  defp maybe_settle_effect(true, effect_ctx) do
    %{run_id: run_id, generation: generation, execution_id: execution_id, journal_opts: jopts} =
      effect_ctx

    case PipelineStatus.settle_effect(run_id, generation, execution_id, jopts) do
      {:ok, tag, _effect} when tag in [:settled, :already_settled] ->
        :ok

      {:error, reason} ->
        {:error, {:effect_settle_failed, reason}}
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

            safe_loop(%{
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

        safe_loop(%{
          state
          | node_id: retry_target,
            incoming_edge: nil,
            max_steps: state.max_steps - 1
        })

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - state.pipeline_started_at
        run_id = Keyword.get(state.opts, :run_id)

        case finalize_terminal(
               state.run_state,
               run_id,
               :failed,
               reason,
               duration_ms,
               state.opts,
               lifecycle_meta_from_state(state)
             ) do
          :ok -> {:error, reason}
          {:error, finalize_reason} -> {:error, {:lifecycle_finalize_failed, finalize_reason}}
        end
    end
  end

  defp finish_pipeline(outcome, %State{} = state) do
    ordered = Enum.reverse(state.completed)
    duration_ms = System.monotonic_time(:millisecond) - state.pipeline_started_at
    run_id = Keyword.get(state.opts, :run_id)

    case finalize_terminal(
           state.run_state,
           run_id,
           :completed,
           nil,
           duration_ms,
           state.opts,
           lifecycle_meta_from_state(state),
           completed_nodes: ordered
         ) do
      :ok ->
        # Clean up checkpoint from durable store (no longer needed)
        if run_id, do: Checkpoint.cleanup(run_id)

        {:ok,
         %{
           run_id: run_id,
           final_outcome: outcome,
           completed_nodes: ordered,
           context: Context.snapshot(state.context),
           taint: Context.taint_map(state.context),
           node_durations: state.tracking.node_durations
         }}

      {:error, reason} ->
        {:error, {:lifecycle_finalize_failed, reason}}
    end
  end

  # Restart the pipeline from a target node with a fresh log directory.
  # Used by loop_restart edges (spec §3.2 step 7). Context is preserved
  # so the new iteration can see results from the previous one.
  defp restart_pipeline(target_node_id, %State{} = state) do
    new_logs_root = next_versioned_path(state.logs_root)
    File.mkdir_p!(new_logs_root)
    :ok = write_manifest(state.graph, new_logs_root)

    safe_loop(%{
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
      run_state =
        if state.run_state do
          rs =
            Arbor.Orchestrator.RunState.Core.touch_heartbeat(state.run_state, DateTime.utc_now())

          sync_run_state(
            Keyword.get(state.opts, :run_id),
            rs,
            lifecycle_meta_from_state(state),
            journal_opts_from(state.opts)
          )

          rs
        else
          state.run_state
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
            safe_loop(%{
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
      safe_loop(%{
        state
        | node_id: target_id,
          incoming_edge: edge,
          max_steps: state.max_steps - 1
      })
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
          safe_loop(%{
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

  defp maybe_set_preferred_label(context, %Outcome{preferred_label: label}, node_id, now)
       when is_binary(label) do
    Context.set(context, "preferred_label", label, node_id, now)
  end

  defp maybe_set_preferred_label(context, _, _node_id, _now), do: context

  # Record provenance taint on a node's output keys (taint-tracking-rebuild
  # Phases 1-3).
  #
  # - Phase 1: an ingress/reduction action declares its own provenance
  #   (`outcome.output_taint` — web -> :untrusted, LLM -> :derived). That
  #   declaration is authoritative for this node's outputs.
  # - Phase 3 (per-edge propagation): when a node declares NO provenance, its
  #   outputs inherit the worst taint of the context keys it declared as inputs
  #   (source_key/input_key/graph_source_key/prompt_context_key/context_keys).
  #   This closes the laundering hole where a transform node read untrusted data
  #   and re-emitted it under a new, unlabeled key. We propagate only across
  #   DECLARED edges (not the ambient "worst of the whole context"), so a node
  #   that didn't read a tainted key doesn't inherit its taint.
  #
  # Taint is read from `context` BEFORE this node's own outputs are recorded, so
  # input lookups see upstream provenance, not this node's writes.
  defp record_node_taint(context, node, %Outcome{} = outcome) do
    Context.propagate_output_taint(
      context,
      Map.keys(outcome.context_updates || %{}),
      outcome.output_taint,
      node_input_keys(node)
    )
  end

  # Apply taint reductions a node requested on EXISTING context keys (e.g. a
  # human-approved gate reducing reviewed data via :human_review). Lowering-only
  # (Context.reduce_taint guards against raising); emits :taint_reduced per key
  # whose level actually changed. Taint-tracking-rebuild Phase 4.
  defp apply_taint_reductions(context, node, %Outcome{taint_reductions: reductions})
       when is_list(reductions) and reductions != [] do
    Enum.reduce(reductions, context, fn {key, target, reason}, ctx ->
      from = Context.taint_level(ctx, key)
      new_ctx = Context.reduce_taint(ctx, key, target, reason)
      to = Context.taint_level(new_ctx, key)
      if to != from, do: emit_taint_reduced(from, to, reason, node, new_ctx)
      new_ctx
    end)
  end

  defp apply_taint_reductions(context, _node, _outcome), do: context

  defp emit_taint_reduced(from_level, to_level, reason, node, context) do
    data = %{
      from_level: from_level,
      to_level: to_level,
      reason: reason,
      node_id: node.id,
      agent_id: Context.get(context, "session.agent_id")
    }

    # arbor_signals is a hard dep — durable_emit is always available.
    Arbor.Signals.durable_emit(:security, :taint_reduced, data, stream_id: "security:events")
  rescue
    _ -> :ok
  end

  # The context keys a node declares it reads. Mirrors the input-key attrs the
  # taint middleware and ExecHandler use. `context_keys`/`pass_context` are
  # comma-separated lists; the rest are single keys.
  #
  # When a node declares NO explicit input key, we fall back to `last_response`
  # — many handlers (transform/read/validate/map/compose) default
  # `source_key`/`result_key` to "last_response", so it IS their implicit input.
  # We do NOT add `last_response` unconditionally: a node that declares explicit
  # inputs is consuming those, and treating `last_response` as a universal input
  # would recreate the "everything becomes tainted" cascade.
  #
  # Subgraph/parallel boundary inheritance is handled by those handlers setting
  # `output_taint` explicitly (from the child/branch result taint), so this
  # generic extraction doesn't special-case pass_context/pass_all_context.
  defp node_input_keys(%{attrs: attrs}) when is_map(attrs) do
    single =
      ["source_key", "input_key", "graph_source_key", "prompt_context_key"]
      |> Enum.map(&Map.get(attrs, &1))
      |> Enum.reject(&is_nil/1)

    csv = split_csv_attr(attrs, "context_keys")

    case Enum.uniq(single ++ csv) do
      [] -> ["last_response"]
      explicit -> explicit
    end
  end

  defp node_input_keys(_), do: []

  defp split_csv_attr(attrs, key) do
    case Map.get(attrs, key) do
      list when is_binary(list) ->
        list |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp maybe_set_fidelity_thread(context, %{thread_id: nil}, _node_id, _now), do: context

  defp maybe_set_fidelity_thread(context, %{thread_id: thread_id}, node_id, now) do
    Context.set(context, "internal.fidelity.thread_id", thread_id, node_id, now)
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

  # Sync RunState through the canonical PipelineStatus/RunJournal boundary.
  # Non-blocking: if the journal is unavailable, Engine continues executing.
  # Dashboard goes stale; agent keeps thinking (graceful degradation).
  @doc false
  # Test-only thin wrappers around the private heartbeat helpers. Lets
  # `EngineInCallHeartbeatTest` exercise the refresh mechanics without
  # standing up the full engine. Optional second arg is journal target opts.
  def touch_in_call_heartbeat_for_test(run_id, journal_opts \\ []) do
    touch_in_call_heartbeat(run_id, journal_opts)
  end

  def with_in_call_heartbeat_for_test(run_id, fun) do
    with_in_call_heartbeat(run_id, [], fun)
  end

  def with_in_call_heartbeat_for_test(run_id, journal_opts, fun) do
    with_in_call_heartbeat(run_id, journal_opts, fun)
  end

  # Refresh heartbeat every 30 s while a single handler call is in flight.
  # Picked to be < the 90 s stale threshold (and < the 30 s check cadence)
  # so a multi-minute LLM call doesn't trip RecoveryCoordinator's stale-
  # heartbeat warning.
  @in_call_heartbeat_interval_ms 30_000

  defp with_in_call_heartbeat(nil, _journal_opts, fun), do: fun.()

  defp with_in_call_heartbeat(run_id, journal_opts, fun)
       when is_binary(run_id) and is_list(journal_opts) do
    ticker_pid =
      spawn(fn ->
        in_call_heartbeat_loop(run_id, journal_opts, @in_call_heartbeat_interval_ms)
      end)

    try do
      fun.()
    after
      Process.exit(ticker_pid, :kill)
    end
  end

  defp with_in_call_heartbeat(_run_id, _journal_opts, fun), do: fun.()

  defp in_call_heartbeat_loop(run_id, journal_opts, interval_ms) do
    receive do
    after
      interval_ms ->
        touch_in_call_heartbeat(run_id, journal_opts)
        in_call_heartbeat_loop(run_id, journal_opts, interval_ms)
    end
  end

  defp touch_in_call_heartbeat(run_id, journal_opts)
       when is_binary(run_id) and is_list(journal_opts) do
    try do
      Arbor.Orchestrator.PipelineStatus.touch_heartbeat(run_id, journal_opts)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp touch_in_call_heartbeat(_run_id, _journal_opts), do: :ok

  # Atomic terminal transition via RunJournal.finalize/5.
  # Uses the latest stored Record for progress (not a stale lexical RunState).
  # Emits a terminal event only on a fresh `:transitioned` result.
  # Does not swallow durable/unavailable failures.
  defp finalize_terminal(
         run_state,
         run_id,
         status,
         reason,
         duration_ms,
         opts,
         meta,
         event_opts \\ []
       )

  defp finalize_terminal(
         _run_state,
         nil,
         _status,
         _reason,
         _duration_ms,
         _opts,
         _meta,
         _event_opts
       ),
       do: :ok

  defp finalize_terminal(run_state, run_id, status, reason, duration_ms, opts, meta, event_opts)
       when is_binary(run_id) do
    meta =
      meta
      |> Map.new()
      |> Map.merge(progress_meta_from_run_state(run_state))
      |> Map.merge(progress_meta_from_event_opts(event_opts))

    journal_opts = journal_opts_from(opts)

    case Arbor.Orchestrator.PipelineStatus.finalize(
           run_id,
           status,
           reason,
           duration_ms,
           meta,
           journal_opts
         ) do
      {:ok, :transitioned, _record} ->
        case status do
          :completed ->
            completed = Keyword.get(event_opts, :completed_nodes, [])
            emit(opts, Event.pipeline_completed(completed, duration_ms))

          :failed ->
            emit(opts, Event.pipeline_failed(reason, duration_ms))

          _ ->
            :ok
        end

        :ok

      {:ok, :already_terminal, _record} ->
        # Same terminal status — idempotent success, no second event.
        :ok

      {:error, {:terminal_conflict, existing, requested}} ->
        # Conflicting terminal state — never report contradictory success.
        {:error, {:terminal_conflict, existing, requested}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resume_or_recovery?(opts) do
    Keyword.get(opts, :resume, false) or Keyword.has_key?(opts, :resume_from) or
      Keyword.get(opts, :recovery, false)
  end

  # Validate once: must be a keyword list (or omitted → []). Fail closed —
  # never silently fall back to the process-global journal on bad shapes.
  defp validate_and_normalize_journal_opts(opts) when is_list(opts) do
    case Keyword.fetch(opts, :journal_opts) do
      :error ->
        {:ok, Keyword.put(opts, :journal_opts, [])}

      {:ok, list} when is_list(list) ->
        if Keyword.keyword?(list) do
          {:ok, Keyword.put(opts, :journal_opts, list)}
        else
          {:error, :invalid_journal_opts}
        end

      {:ok, _} ->
        {:error, :invalid_journal_opts}
    end
  end

  defp validate_and_normalize_journal_opts(_), do: {:error, :invalid_journal_opts}

  defp journal_opts_from(opts) when is_list(opts) do
    Keyword.fetch!(opts, :journal_opts)
  end

  # Atomic admit + initial lifecycle publication at the journal owner.
  # Maps journal errors to Engine public shapes (no silent overwrite).
  defp admit_and_sync_run_state(
         %Arbor.Orchestrator.RunState.Core{} = run_state,
         meta,
         admission,
         journal_opts
       )
       when admission in [:fresh, :resume] and is_list(journal_opts) do
    now = DateTime.utc_now()
    synced = Arbor.Orchestrator.RunState.Core.mark_synced(run_state, now)
    admit_opts = Keyword.put(journal_opts, :admission, admission)

    case Arbor.Orchestrator.PipelineStatus.admit_and_put_run_state(synced, meta, admit_opts) do
      :ok ->
        :ok

      {:error, :journal_unavailable} ->
        {:error, :journal_unavailable}

      {:error, {:already_terminal, status}} ->
        {:error, {:already_terminal, status}}

      {:error, {:run_id_in_use, status}} ->
        {:error, {:run_id_in_use, status}}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, {:invalid_resume_status, status}} ->
        {:error, {:invalid_resume_status, status}}

      {:error, :execution_principal_mismatch} ->
        {:error, :execution_principal_mismatch}

      {:error, reason} ->
        # Initial lifecycle publish failed — do not pretend the run is tracked.
        {:error, {:lifecycle_write_failed, reason}}
    end
  end

  defp put_execution_principal_meta(meta, opts, run_authorization) when is_map(meta) do
    principal =
      execution_principal_from_opts(opts) ||
        execution_principal_from_auth(run_authorization) ||
        Map.get(meta, :execution_principal)

    if is_binary(principal) and principal != "" do
      Map.put(meta, :execution_principal, principal)
    else
      meta
    end
  end

  # Failures that occur before the execution loop starts on a resume path.
  # Outer claim owner settles these; Engine must not mark :failed first.
  # Explicit typed match only — no string-contains atom heuristics.
  # Retryable vs structural-corrupt classification lives in the outer settler.
  defp pre_execution_resume_failure?(reason) do
    case reason do
      # Retryable credential / backend unavailability
      :identity_required_for_resume -> true
      :authentication_unavailable -> true
      :checkpoint_not_found -> true
      :checkpoint_hmac_invalid -> true
      :checkpoint_hmac_missing -> true
      :invalid_signing_authority -> true
      :mixed_signing_credentials -> true
      {:unauthorized_resume, _} -> true
      {:checkpoint_load_failed, _} -> true
      {:checkpoint_hmac_derivation_failed, _} -> true
      {:capability_revalidation_failed, _} -> true
      {:indeterminate_intents, _} -> true
      {:indeterminate_side_effect, _, _} -> true
      # L3C canonical effect recovery (pre-handler). Outer settler classifies
      # indeterminate / unapplied as retryable; structural inconsistency as failed.
      {:indeterminate_effect, _, _} -> true
      {:completed_effect_unapplied, _, _} -> true
      {:effect_recovery_inconsistent, _} -> true
      {:invalid_current_effect, _} -> true
      {:effect_recovery_progress_sync_failed, _} -> true
      {:effect_recovery_settle_failed, _} -> true
      {:effect_recovery_record_unavailable, _} -> true
      # Structurally corrupt checkpoint / graph state (still pre-exec; outer
      # settler marks :failed rather than reopening arbitrary terminals)
      :checkpoint_current_node_missing -> true
      {:checkpoint_invalid, _} -> true
      :checkpoint_corrupt -> true
      {:checkpoint_corrupt, _} -> true
      _ -> false
    end
  end

  defp progress_meta_from_run_state(%Arbor.Orchestrator.RunState.Core{} = rs) do
    %{
      completed_count: rs.completed_count,
      completed_nodes: Enum.reverse(rs.completed_nodes || []),
      node_durations: rs.node_durations || %{},
      total_nodes: rs.total_nodes,
      graph_id: rs.graph_id,
      pipeline_id: rs.pipeline_id,
      started_at: rs.started_at,
      spawning_pid: rs.spawning_pid
    }
  end

  defp progress_meta_from_run_state(_), do: %{}

  defp progress_meta_from_event_opts(event_opts) when is_list(event_opts) do
    case Keyword.get(event_opts, :completed_nodes) do
      nodes when is_list(nodes) and nodes != [] ->
        %{completed_nodes: nodes, completed_count: length(nodes)}

      _ ->
        %{}
    end
  end

  defp progress_meta_from_event_opts(_), do: %{}

  defp seed_run_state(run_id, graph, opts, pipeline_started_at_dt) do
    base =
      Arbor.Orchestrator.RunState.Core.new(run_id, graph.id, map_size(graph.nodes),
        now: pipeline_started_at_dt,
        pipeline_id: Keyword.get(opts, :pipeline_id, run_id),
        owner_node: Kernel.node(),
        source_node: Keyword.get(opts, :source_node, Kernel.node()),
        spawning_pid: Keyword.get(opts, :spawning_pid)
      )

    resuming? =
      Keyword.get(opts, :resume, false) or Keyword.has_key?(opts, :resume_from) or
        Keyword.get(opts, :recovery, false)

    if resuming? do
      case Arbor.Orchestrator.PipelineStatus.get_record(run_id, journal_opts_from(opts)) do
        %Arbor.Orchestrator.RunLifecycle.Record{} = record ->
          %{
            base
            | completed_count: record.completed_count || 0,
              completed_nodes: Enum.reverse(record.completed_nodes || []),
              node_durations: record.node_durations || %{},
              current_node: record.current_node,
              started_at: record.started_at || base.started_at,
              status: :running
          }

        _ ->
          base
      end
    else
      base
    end
  end

  # Fold authenticated checkpoint progress into process-local RunState and the
  # durable journal. Sync failures are first-class — never ignore them on the
  # resume path (exact reconciliation / continue both depend on published progress).
  defp seed_run_state_from_checkpoint(run_state, state, run_id, lifecycle_meta, journal_opts) do
    completed = state.completed_nodes || []

    if length(completed) > (run_state.completed_count || 0) do
      # RunState stores completed_nodes newest-first (see Core.node_completed).
      rs = %{
        run_state
        | completed_count: length(completed),
          completed_nodes: Enum.reverse(completed)
      }

      case sync_run_state(run_id, rs, lifecycle_meta, journal_opts) do
        :ok -> {:ok, rs}
        {:error, reason} -> {:error, {:effect_recovery_progress_sync_failed, reason}}
      end
    else
      {:ok, run_state}
    end
  end

  # L3C: classify canonical current_effect after authenticated checkpoint load.
  # Pure decision in EffectRecoveryCore; journal sync/settle interpreted here.
  # force_replay / on_resume="retry" never bypass pending or completed-unapplied.
  defp recover_canonical_effect(
         run_state,
         state,
         run_id,
         lifecycle_meta,
         journal_opts,
         opts
       ) do
    if resume_or_recovery?(opts) do
      case PipelineStatus.get_record(run_id, journal_opts) do
        {:error, reason} ->
          {:error, {:effect_recovery_record_unavailable, reason}}

        nil ->
          # No journal row (legacy-only resume): leave legacy intent handling intact.
          seed_run_state_from_checkpoint(
            run_state,
            state,
            run_id,
            lifecycle_meta,
            journal_opts
          )

        %Arbor.Orchestrator.RunLifecycle.Record{} = record ->
          checkpoint_view = %{
            completed_nodes: state.completed_nodes || [],
            outcomes: state.outcomes || %{},
            execution_digests: Map.get(state, :execution_digests, %{})
          }

          case EffectRecoveryCore.decide(record, checkpoint_view) do
            {:ok, :continue} ->
              seed_run_state_from_checkpoint(
                run_state,
                state,
                run_id,
                lifecycle_meta,
                journal_opts
              )

            {:ok, :reconcile, actions} ->
              apply_effect_recovery_actions(
                actions,
                run_state,
                state,
                run_id,
                lifecycle_meta,
                journal_opts
              )

            {:error, reason} ->
              {:error, reason}
          end
      end
    else
      # Fresh runs never carry a prior current_effect into this path.
      {:ok, run_state}
    end
  end

  defp apply_effect_recovery_actions(
         actions,
         run_state,
         state,
         run_id,
         lifecycle_meta,
         journal_opts
       )
       when is_list(actions) do
    Enum.reduce_while(actions, {:ok, run_state}, fn action, {:ok, rs} ->
      case apply_effect_recovery_action(action, rs, state, run_id, lifecycle_meta, journal_opts) do
        {:ok, next_rs} -> {:cont, {:ok, next_rs}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp apply_effect_recovery_action(
         {:sync_progress, completed_nodes},
         run_state,
         _state,
         run_id,
         lifecycle_meta,
         journal_opts
       )
       when is_list(completed_nodes) do
    rs = %{
      run_state
      | completed_count: length(completed_nodes),
        completed_nodes: Enum.reverse(completed_nodes)
    }

    case sync_run_state(run_id, rs, lifecycle_meta, journal_opts) do
      :ok -> {:ok, rs}
      {:error, reason} -> {:error, {:effect_recovery_progress_sync_failed, reason}}
    end
  end

  defp apply_effect_recovery_action(
         {:settle, generation, execution_id},
         run_state,
         _state,
         run_id,
         _lifecycle_meta,
         journal_opts
       )
       when is_integer(generation) and is_binary(execution_id) do
    case PipelineStatus.settle_effect(run_id, generation, execution_id, journal_opts) do
      {:ok, tag, _effect} when tag in [:settled, :already_settled] ->
        {:ok, run_state}

      {:error, reason} ->
        {:error, {:effect_recovery_settle_failed, reason}}
    end
  end

  defp apply_effect_recovery_action(_action, _run_state, _state, _run_id, _meta, _jopts) do
    {:error, {:effect_recovery_inconsistent, :unknown_recovery_action}}
  end

  defp lifecycle_meta_from_opts(opts, logs_root, graph_hash, dot_source_path) do
    %{
      logs_root: logs_root,
      graph_hash: graph_hash,
      dot_source_path: dot_source_path,
      execution_principal: execution_principal_from_opts(opts),
      origin_trust_zone: Keyword.get(opts, :origin_trust_zone),
      spawning_pid: Keyword.get(opts, :spawning_pid)
    }
  end

  defp lifecycle_meta_from_state(%State{} = state) do
    opts = state.opts || []

    %{
      logs_root: state.logs_root,
      graph_hash: Keyword.get(opts, :graph_hash),
      dot_source_path: Keyword.get(opts, :dot_source_path),
      execution_principal:
        execution_principal_from_opts(opts) ||
          execution_principal_from_auth(state.run_authorization),
      origin_trust_zone: Keyword.get(opts, :origin_trust_zone),
      spawning_pid: Keyword.get(opts, :spawning_pid)
    }
  end

  defp execution_principal_from_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :execution_principal) do
      principal when is_binary(principal) and principal != "" ->
        principal

      _ ->
        execution_principal_from_auth(Keyword.get(opts, :run_authorization))
    end
  end

  defp execution_principal_from_opts(_), do: nil

  defp execution_principal_from_auth(%RunAuthorization{execution_principal: principal})
       when is_binary(principal) and principal != "",
       do: principal

  defp execution_principal_from_auth(_), do: nil

  # Surfaces lifecycle write errors — callers decide whether to fail closed.
  # Does not swallow durable failures as `:ok`.
  #
  # Node-progress / heartbeat sync is best-effort relative to terminal
  # finalization: write errors are returned to callers and must be observed,
  # but L1/L2 does not claim durable-first completion of every mid-run
  # progress tick (that remains L3 work when a fenced durable backend lands).
  defp sync_run_state(
         _run_id,
         %Arbor.Orchestrator.RunState.Core{} = run_state,
         meta,
         journal_opts
       )
       when is_list(journal_opts) do
    now = DateTime.utc_now()
    synced = Arbor.Orchestrator.RunState.Core.mark_synced(run_state, now)

    case Arbor.Orchestrator.PipelineStatus.put_run_state(synced, meta, journal_opts) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  # Resume requires identity. Without it, we can't verify the
  # checkpoint's HMAC, which means an attacker who can write the
  # checkpoint file can substitute a poisoned payload undetected.
  # The legacy fail-open (accept any unsigned checkpoint) is now
  # closed — callers must thread :identity_private_key through.
  defp require_resume_identity_before_admission(opts) do
    if resume_or_recovery?(opts), do: require_identity_on_resume(opts), else: :ok
  end

  defp require_identity_on_resume(opts) do
    if Keyword.get(opts, :hmac_secret) do
      :ok
    else
      {:error, :identity_required_for_resume}
    end
  end

  @doc false
  # Derive the HMAC secret used to sign engine checkpoints.
  # See the comment at the call site in do_run/2 for the trust model.
  #
  # ## SigningAuthority path (v3)
  # When the `:signing_authority` **key is present** (Keyword.fetch), derive via
  # the broker:
  # `Arbor.Security.derive_secret_with_authority(authority, :engine_checkpoint_hmac_v3)`.
  # Presence is decided by key presence, not value validity:
  # - present valid `%SigningAuthority{}` + any legacy credential key →
  #   `{:error, :mixed_signing_credentials}` (never legacy HMAC)
  # - present nil or any non-`%SigningAuthority{}` value →
  #   `{:error, :invalid_signing_authority}` (never legacy HMAC, even when
  #   `identity_private_key` is also present)
  # - present partial/forged struct-tagged maps are canonicalized via
  #   `SigningAuthority.canonicalize/1` before any Security call
  # Derivation failure returns `{:error, reason}` so the caller aborts —
  # never silently falls back to unsigned checkpoints / disabled resume.
  #
  # ## Legacy identity_private_key path (v2)
  # Only when `:signing_authority` is **absent**. C7 review fix (2026-06-09):
  # this previously used HKDF when Arbor.Security.Crypto was loaded and fell
  # back to plain HMAC otherwise — two DIFFERENT secrets for the same key.
  # Collapsed to a single, load-INDEPENDENT derivation using only `:crypto`:
  # `HMAC-SHA256(key, "arbor-checkpoint-hmac-v2")`.
  #
  # Exposed (@doc false) so the derivation can be pinned by a regression test.
  @spec derive_checkpoint_hmac_secret(keyword()) ::
          binary() | nil | {:error, term()}
  def derive_checkpoint_hmac_secret(opts) when is_list(opts) do
    case Keyword.fetch(opts, :signing_authority) do
      {:ok, %SigningAuthority{} = authority} ->
        # Canonicalize first so partial/forged struct tags fail as invalid
        # authority (shaped error) before mixed-credential checks.
        case SigningAuthority.canonicalize(authority) do
          {:ok, %SigningAuthority{} = authority} ->
            # Key-presence exclusivity: any present legacy credential key
            # (even nil/malformed) is mixed credentials.
            if mixed_legacy_credential_keys?(opts) do
              {:error, :mixed_signing_credentials}
            else
              derive_checkpoint_hmac_via_authority(authority)
            end

          {:error, _reason} ->
            {:error, :invalid_signing_authority}
        end

      {:ok, _invalid} ->
        # Present nil or malformed authority never falls through to legacy HMAC.
        {:error, :invalid_signing_authority}

      :error ->
        private_key = Keyword.get(opts, :identity_private_key)

        if is_binary(private_key) and byte_size(private_key) > 0 do
          :crypto.mac(:hmac, :sha256, private_key, "arbor-checkpoint-hmac-v2")
        else
          nil
        end
    end
  end

  defp mixed_legacy_credential_keys?(opts) do
    Keyword.has_key?(opts, :identity_private_key) or
      Keyword.has_key?(opts, :signer) or
      Keyword.has_key?(opts, :authorizer)
  end

  defp derive_checkpoint_hmac_via_authority(%SigningAuthority{} = authority) do
    case Arbor.Security.derive_secret_with_authority(
           authority,
           :engine_checkpoint_hmac_v3
         ) do
      {:ok, secret} when is_binary(secret) and byte_size(secret) > 0 ->
        secret

      {:ok, _invalid} ->
        {:error, {:checkpoint_hmac_derivation_failed, :invalid_secret}}

      {:error, reason} ->
        {:error, {:checkpoint_hmac_derivation_failed, reason}}

      other ->
        {:error, {:checkpoint_hmac_derivation_failed, other}}
    end
  end

  defp apply_checkpoint_hmac_secret(opts) do
    case derive_checkpoint_hmac_secret(opts) do
      nil ->
        {:ok, opts}

      secret when is_binary(secret) ->
        {:ok, Keyword.put(opts, :hmac_secret, secret)}

      {:error, _reason} = error ->
        error
    end
  end

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
  #
  # SECURITY: when an agent_id is present this gate ALWAYS fires —
  # `Arbor.Security.authorize/3` is a direct, unguarded call. It must never be
  # skipped on a module-presence check (the "security ceilings fail open
  # silently" class): a `Code.ensure_loaded?`/`function_exported?` guard around
  # the authorize meant a false guard silently bypassed authorization. With
  # arbor_security a hard dep the module is always loaded; the call is direct so
  # any future refactor that drops it is caught by the compiler and the
  # security-regression test. We also do NOT rescue exceptions to `:ok` here —
  # an error during the check must surface as denial, never as a silent pass.
  defp maybe_revalidate_capabilities(_graph, opts) do
    authority = Keyword.get(opts, :run_authorization)

    agent_id =
      case authority do
        %RunAuthorization{execution_principal: principal} -> principal
        _ -> Keyword.get(opts, :agent_id)
      end

    auth_opts =
      case authority do
        %RunAuthorization{} -> RunAuthorization.scope_opts(authority)
        _ -> []
      end

    case agent_id do
      nil ->
        :ok

      agent_id ->
        with result <-
               Arbor.Security.authorize(
                 agent_id,
                 "arbor://orchestrator/execute",
                 :resume,
                 auth_opts
               ),
             :ok <- normalize_resume_authorization(result),
             :ok <- revalidate_resume_caller(authority, auth_opts) do
          :ok
        end
    end
  end

  defp normalize_resume_authorization(:ok), do: :ok
  defp normalize_resume_authorization({:ok, :authorized}), do: :ok

  defp normalize_resume_authorization({:error, reason}),
    do: {:error, {:unauthorized_resume, reason}}

  defp normalize_resume_authorization(other),
    do: {:error, {:unauthorized_resume, {:unexpected_result, other}}}

  defp revalidate_resume_caller(nil, _scope_opts), do: :ok

  defp revalidate_resume_caller(
         %RunAuthorization{caller_id: caller, execution_principal: caller},
         _scope_opts
       ),
       do: :ok

  defp revalidate_resume_caller(%RunAuthorization{caller_id: caller}, scope_opts) do
    with {:ok, capabilities} <- Arbor.Security.list_capabilities(caller, scope_opts),
         true <-
           Enum.any?(capabilities, fn capability ->
             Arbor.Security.capability_authorizes?(
               capability,
               "arbor://orchestrator/execute",
               scope_opts
             )
           end) do
      :ok
    else
      _ -> {:error, {:unauthorized_resume, :caller_authority_missing}}
    end
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
        # json_safe/1: status.json is an audit dump (never read back for resume),
        # so a non-Jason-encodable term in context_updates or failure_reason — e.g.
        # a typed struct without a Jason.Encoder, a pid, a tuple — must NOT crash
        # the whole run (it did, at this `Jason.encode`). Lossy sanitization is
        # correct here precisely because nothing round-trips this file.
        context_updates: JsonSafe.coerce(sanitized_updates),
        notes: outcome.notes,
        failure_reason: JsonSafe.coerce(outcome.failure_reason),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        status: to_string(outcome.status)
      }

    with :ok <- File.mkdir_p(node_dir),
         {:ok, encoded} <- Jason.encode(payload, pretty: true) do
      File.write(status_path, encoded)
    end
  end

  # `checkpoint.json` is RESUME state, not the audit record (audit is the event
  # stream + status.json). Only runs that can actually resume need it written —
  # `mix arbor.pipeline.run/resume` + RecoveryCoordinator. Turn/heartbeat runs
  # never resume (Session passes `resumable: false`), so writing per-node resume
  # state for them is unused I/O. Default `true` preserves prior behavior.
  defp maybe_disable_unverifiable_resume(opts, nil), do: opts

  defp maybe_disable_unverifiable_resume(opts, %RunAuthorization{}) do
    if Keyword.get(opts, :hmac_secret) do
      opts
    else
      Keyword.put(opts, :resumable, false)
    end
  end

  defp resumable?(opts), do: Keyword.get(opts, :resumable, true)

  # The on-disk per-node `status.json` audit dump. Default on (behavior-preserving);
  # set `config :arbor_orchestrator, :status_files_enabled, false` to retire it once
  # the durable event stream (enriched stage_completed) is the trusted audit record.
  defp status_files_enabled?,
    do: Application.get_env(:arbor_orchestrator, :status_files_enabled, true)

  defp resolve_next_node_id(node, last_outcome, context, graph) do
    case Router.select_next_step(node, last_outcome, context, graph) do
      nil -> nil
      {:edge, edge} -> if Map.get(edge, :loop_restart, false), do: nil, else: edge.to
      {:node_id, target} -> target
    end
  end
end
