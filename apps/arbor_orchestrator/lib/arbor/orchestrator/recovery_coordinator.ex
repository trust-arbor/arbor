defmodule Arbor.Orchestrator.RecoveryCoordinator do
  @moduledoc """
  Discovers and resumes interrupted pipelines on boot.

  Starts after RunJournal/PipelineStatus in the supervision tree. On init,
  queries the canonical lifecycle boundary for `status: :interrupted`
  (including dead-owner liveness corrections and durable rehydrate
  boot-normalization). Bounded historical JobRegistry records are merged
  for discovery only via `RunLifecycle.LegacyJobAdapter` when the journal
  is available — never as an outage fall-through.

  ## Authenticated resume

  Recovery never calls `Engine.run/2` without checkpoint authentication
  material. Options are obtained from an injected, owner-scoped
  `resume_options_resolver` (and/or explicit opts). Credentials and
  signing authorities are **not** persisted. With no resolver/authority,
  the run stays `:interrupted` and recovery reports a retryable
  `:authentication_unavailable` outcome — no claim, no terminalization.

  Every recovery path **claims** atomically before resume (local GenServer
  claim only — L4 will add fenced cross-node CAS). Task error/crash leaves
  an explicit interrupted or failed lifecycle state — never stranded
  `:recovering`. Settle results are checked; retryable failures return to
  `:interrupted`.

  ## Automatic crash recovery vs manual resume

  Automatic discovery / orphan / stale recovery runs **only** when
  `RunJournal.durability_status/0` reports a healthy crash-durable class
  (`:application_restart` or `:node_restart` with `durable: true`). A
  volatile or `:process_lifetime` backend may still support **explicit
  manual resume** while the journal is alive, but is never treated as
  automatic crash recovery. There is no force flag and no module-name
  heuristic — classification is honest durability status only.
  """

  use GenServer

  require Logger

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Orchestrator.PipelineStatus
  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.RunLifecycle.LegacyJobAdapter
  alias Arbor.Orchestrator.RunLifecycle.Record

  @default_max_concurrent 3
  @default_delay_ms 1_000
  @heartbeat_check_interval_ms 30_000
  @stale_heartbeat_ms 90_000
  # If a pipeline has completed 0 nodes for longer than this, mark it
  # abandoned even if the owner node is still connected. The spawning
  # Session process has almost certainly died without cleaning up.
  # 10 minutes is generous — a healthy first node executes in seconds.
  @zero_progress_abandon_ms 600_000
  @pg_group {:arbor, :recovery_coordinators}
  @settlement_retry_interval_ms 5_000
  @crash_durable_classes [:application_restart, :node_restart]

  # Public API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the current recovery status."
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _ -> %{status: :unavailable}
  end

  @doc """
  Pure eligibility for automatic crash recovery from a durability status map.

  Requires healthy crash-durable class (`:application_restart` or
  `:node_restart`) and `durable: true`. Volatile / process-lifetime /
  degraded backends refuse automatic recovery.
  """
  @spec automatic_recovery_eligibility(map()) :: :ok | {:error, term()}
  def automatic_recovery_eligibility(%{} = durability) do
    class = Map.get(durability, :durability_class, :volatile)
    durable? = Map.get(durability, :durable, false) == true

    cond do
      durable? and class in @crash_durable_classes ->
        :ok

      class in [:volatile, :process_lifetime, nil] ->
        {:error,
         {:automatic_recovery_disabled, :durability_not_crash_durable, class || :volatile}}

      not durable? ->
        {:error, {:automatic_recovery_disabled, :durability_unhealthy, class}}

      true ->
        {:error, {:automatic_recovery_disabled, :durability_not_crash_durable, class}}
    end
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    enabled =
      Keyword.get(
        opts,
        :enabled,
        Application.get_env(:arbor_orchestrator, :recovery_enabled, true)
      )

    max_concurrent =
      Keyword.get(
        opts,
        :max_concurrent,
        Application.get_env(
          :arbor_orchestrator,
          :recovery_max_concurrent,
          @default_max_concurrent
        )
      )

    delay_ms =
      Keyword.get(
        opts,
        :delay_ms,
        Application.get_env(:arbor_orchestrator, :recovery_delay_ms, @default_delay_ms)
      )

    # Owner-scoped resolver: (Record.t() -> {:ok, keyword()} | {:error, term()}).
    # Must not persist credentials; returns short-lived resume opts only.
    # Resolver receives the full Record including execution_principal.
    resume_options_resolver =
      Keyword.get(opts, :resume_options_resolver) ||
        Application.get_env(:arbor_orchestrator, :recovery_resume_options_resolver)

    recovery_root =
      Keyword.get(opts, :recovery_root) ||
        Application.get_env(
          :arbor_orchestrator,
          :recovery_materialization_root,
          Path.join(System.tmp_dir!(), "arbor_orchestrator/recovery")
        )

    # Optional journal server opts (tests / multi-journal). Default is the
    # process-global RunJournal queried via durability_status/0.
    journal_opts = Keyword.get(opts, :journal_opts, [])

    durability = RunJournal.durability_status(journal_opts)

    {automatic_recovery, automatic_recovery_disabled_reason} =
      case automatic_recovery_eligibility(durability) do
        :ok ->
          {true, nil}

        {:error, reason} ->
          {false, reason}
      end

    state = %{
      enabled: enabled,
      automatic_recovery: automatic_recovery,
      automatic_recovery_disabled_reason: automatic_recovery_disabled_reason,
      durability: durability,
      journal_opts: journal_opts,
      max_concurrent: max_concurrent,
      delay_ms: delay_ms,
      resume_options_resolver: resume_options_resolver,
      recovery_root: recovery_root,
      recovering: %{},
      recovered: [],
      failed: [],
      pending: [],
      # Settlement failures retained for retry — never silently leave :recovering.
      settlement_failures: []
    }

    if enabled do
      join_pg_group()
      :net_kernel.monitor_nodes(true)
      Process.send_after(self(), :retry_settlements, @settlement_retry_interval_ms)

      if automatic_recovery do
        Process.send_after(self(), :discover_interrupted, delay_ms)
        Process.send_after(self(), :check_stale_heartbeats, @heartbeat_check_interval_ms)
      else
        Logger.warning(
          "[RecoveryCoordinator] Automatic crash recovery disabled: " <>
            inspect(automatic_recovery_disabled_reason) <>
            " (manual resume while journal is alive remains available)"
        )
      end
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    durability = Map.get(state, :durability) || %{}

    status = %{
      enabled: state.enabled,
      automatic_recovery: Map.get(state, :automatic_recovery, false),
      automatic_recovery_disabled_reason: Map.get(state, :automatic_recovery_disabled_reason),
      durability_class: Map.get(durability, :durability_class),
      durable: Map.get(durability, :durable, false),
      durability_mode: Map.get(durability, :mode),
      recovering: map_size(state.recovering),
      recovered: length(state.recovered),
      failed: length(state.failed),
      pending: length(state.pending),
      settlement_failures: length(Map.get(state, :settlement_failures, []))
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:discover_interrupted, state) do
    if automatic_recovery_active?(state) do
      interrupted = list_interrupted_for_recovery(journal_opts(state))

      if interrupted == [] do
        Logger.debug("[RecoveryCoordinator] No interrupted pipelines found")
        {:noreply, state}
      else
        Logger.info("[RecoveryCoordinator] Found #{length(interrupted)} interrupted pipeline(s)")

        state = %{state | pending: interrupted}
        send(self(), :recover_next)
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(:recover_next, %{pending: []} = state) do
    if state.recovering == %{} do
      Logger.info(
        "[RecoveryCoordinator] Recovery complete. " <>
          "Recovered: #{length(state.recovered)}, " <>
          "Failed: #{length(state.failed)}"
      )
    end

    {:noreply, state}
  end

  def handle_info(:recover_next, state) do
    available_slots = state.max_concurrent - map_size(state.recovering)

    if available_slots <= 0 do
      {:noreply, state}
    else
      {to_recover, remaining} = Enum.split(state.pending, available_slots)

      {recovering, failed, settlement_failures} =
        Enum.reduce(
          to_recover,
          {state.recovering, state.failed, Map.get(state, :settlement_failures, [])},
          fn candidate, {acc, fails, settlements} ->
            key = candidate.record.run_id

            case attempt_recovery(candidate, state) do
              {:ok, task_ref, claimed} ->
                {Map.put(acc, task_ref, %{
                   run_id: key,
                   source: claimed.source,
                   record: claimed.record,
                   settled?: false
                 }), fails, settlements}

              {:error, :authentication_unavailable} = err ->
                Logger.warning(
                  "[RecoveryCoordinator] Auth unavailable for #{key}; leaving interrupted"
                )

                {acc, [{key, elem(err, 1)} | fails], settlements}

              {:error, {:resume_settlement_failed, settle_reason, reason}} ->
                Logger.warning(
                  "[RecoveryCoordinator] Settlement failed for #{key}: #{inspect(settle_reason)}"
                )

                failure = %{
                  run_id: key,
                  source: Map.get(candidate, :source, :current),
                  reason: reason,
                  settle_reason: settle_reason,
                  attempts: 1
                }

                {acc, [{key, {:resume_settlement_failed, settle_reason, reason}} | fails],
                 [failure | settlements]}

              {:error, reason} ->
                Logger.warning("[RecoveryCoordinator] Cannot recover #{key}: #{inspect(reason)}")

                {acc, [{key, reason} | fails], settlements}
            end
          end
        )

      {:noreply,
       %{
         state
         | pending: remaining,
           recovering: recovering,
           failed: failed,
           settlement_failures: settlement_failures
       }}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.recovering, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{run_id: pipeline_id} = meta, recovering} ->
        state =
          case result do
            {:ok, _} ->
              Logger.info("[RecoveryCoordinator] Recovered pipeline #{pipeline_id}")
              %{state | recovering: recovering, recovered: [pipeline_id | state.recovered]}

            {:error, reason} ->
              Logger.warning(
                "[RecoveryCoordinator] Failed to recover #{pipeline_id}: " <>
                  inspect(reason)
              )

              state_after =
                apply_settlement(
                  %{
                    state
                    | recovering: recovering,
                      failed: [{pipeline_id, reason} | state.failed]
                  },
                  meta,
                  reason
                )

              state_after
          end

        if state.pending != [] do
          Process.send_after(self(), :recover_next, state.delay_ms)
        end

        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.recovering, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{run_id: pipeline_id} = meta, recovering} ->
        Logger.warning(
          "[RecoveryCoordinator] Recovery task crashed for #{pipeline_id}: " <>
            inspect(reason)
        )

        state =
          apply_settlement(
            %{
              state
              | recovering: recovering,
                failed: [{pipeline_id, {:crashed, reason}} | state.failed]
            },
            meta,
            {:crashed, reason}
          )

        if state.pending != [] do
          Process.send_after(self(), :recover_next, state.delay_ms)
        end

        {:noreply, state}
    end
  end

  def handle_info(:retry_settlements, state) do
    if state.enabled do
      state = retry_failed_settlements(state)
      Process.send_after(self(), :retry_settlements, @settlement_retry_interval_ms)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:nodedown, dead_node}, state) do
    if automatic_recovery_active?(state) do
      Logger.info(
        "[RecoveryCoordinator] Node #{dead_node} went down, scanning for orphaned pipelines"
      )

      jopts = journal_opts(state)
      orphaned = list_by_owner_for_recovery(dead_node, jopts)

      if orphaned != [] do
        Logger.info(
          "[RecoveryCoordinator] Found #{length(orphaned)} orphaned pipeline(s) from #{dead_node}"
        )

        # Only mark interrupted here; atomic claim happens in attempt_recovery.
        pending_orphans =
          Enum.map(orphaned, fn candidate ->
            mark_interrupted_entry(candidate, jopts)
            %Record{} = rec = candidate.record
            %{candidate | record: %{rec | status: :interrupted}}
          end)

        if pending_orphans != [] do
          state = %{state | pending: state.pending ++ pending_orphans}
          send(self(), :recover_next)
          {:noreply, state}
        else
          {:noreply, state}
        end
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:nodeup, _node}, state), do: {:noreply, state}

  def handle_info(:check_stale_heartbeats, state) do
    if automatic_recovery_active?(state) do
      now = DateTime.utc_now()
      jopts = journal_opts(state)

      current_stale =
        case PipelineStatus.list_stale_heartbeat_records(@stale_heartbeat_ms, now, jopts) do
          {:ok, records} ->
            Enum.map(records, fn %Record{} = r -> %{record: r, source: :current} end)

          {:error, reason} ->
            Logger.warning(
              "[RecoveryCoordinator] journal unavailable during stale heartbeat scan: " <>
                inspect(reason)
            )

            []
        end

      legacy_stale =
        LegacyJobAdapter.list_stale_heartbeats(@stale_heartbeat_ms, now)
        |> Enum.map(fn %Record{} = r -> %{record: r, source: :legacy} end)

      stale =
        (current_stale ++ legacy_stale)
        |> Enum.uniq_by(fn %{record: %Record{run_id: id}} -> id end)

      if stale != [] do
        connected = MapSet.new([Kernel.node() | Node.list()])

        recoverable =
          Enum.flat_map(stale, fn candidate ->
            %Record{} = entry = candidate.record
            owner_connected = MapSet.member?(connected, entry.owner_node)

            if not owner_connected do
              mark_interrupted_entry(candidate, jopts)

              [
                %{
                  candidate
                  | record: %Record{entry | status: :interrupted}
                }
              ]
            else
              spawner_alive = spawning_process_alive?(entry.spawning_pid)

              age_ms =
                if entry.started_at do
                  DateTime.diff(now, entry.started_at, :millisecond)
                else
                  0
                end

              cond do
                entry.spawning_pid != nil and not spawner_alive ->
                  mark_abandoned_entry(candidate, jopts)

                  Logger.info(
                    "[RecoveryCoordinator] Abandoned pipeline #{entry.run_id}: " <>
                      "spawning process #{inspect(entry.spawning_pid)} is dead"
                  )

                (entry.completed_count || 0) == 0 and age_ms > @zero_progress_abandon_ms ->
                  mark_abandoned_entry(candidate, jopts)

                  Logger.info(
                    "[RecoveryCoordinator] Abandoned pipeline #{entry.run_id}: " <>
                      "zero progress for #{div(age_ms, 60_000)} min, likely orphaned"
                  )

                true ->
                  Logger.warning(
                    "[RecoveryCoordinator] Pipeline #{entry.run_id} has stale heartbeat " <>
                      "but owner #{entry.owner_node} is still connected"
                  )
              end

              []
            end
          end)

        state =
          if recoverable != [] do
            send(self(), :recover_next)
            %{state | pending: state.pending ++ recoverable}
          else
            state
          end

        Process.send_after(self(), :check_stale_heartbeats, @heartbeat_check_interval_ms)
        {:noreply, state}
      else
        Process.send_after(self(), :check_stale_heartbeats, @heartbeat_check_interval_ms)
        {:noreply, state}
      end
    else
      # Keep the ticker only while automatic recovery remains eligible so a
      # later healthy durability class can be re-evaluated without force flags.
      if state.enabled and Map.get(state, :automatic_recovery, false) do
        Process.send_after(self(), :check_stale_heartbeats, @heartbeat_check_interval_ms)
      end

      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp automatic_recovery_active?(%{enabled: true, automatic_recovery: true}), do: true
  defp automatic_recovery_active?(_), do: false

  # ---------------------------------------------------------------------------
  # Recovery flow: claim → locate checkpoint → resume
  # ---------------------------------------------------------------------------

  # Candidate is always `%{record: %Record{}, source: :current | :legacy}`.

  defp attempt_recovery(%{record: %Record{}, source: _} = candidate, state) do
    jopts = journal_opts(state)

    # Auth material before claim — never claim without resume credentials.
    case resolve_resume_options(candidate.record, state) do
      {:error, :authentication_unavailable} = err ->
        err

      {:error, reason} ->
        {:error, reason}

      {:ok, resume_opts} ->
        case attempt_claim(candidate, jopts) do
          {:ok, claimed} ->
            # Every post-claim exit must settle exactly once (interrupted or failed).
            try do
              with {:ok, checkpoint_source} <- locate_checkpoint(claimed.record),
                   :ok <- validate_graph_unchanged(claimed.record) do
                recovery_root = state.recovery_root

                task =
                  Task.Supervisor.async_nolink(
                    Arbor.Orchestrator.Session.TaskSupervisor,
                    fn ->
                      do_resume(claimed.record, checkpoint_source, resume_opts, recovery_root)
                    end
                  )

                {:ok, task.ref, claimed}
              else
                {:error, reason} ->
                  settle_or_report(
                    %{run_id: claimed.record.run_id, source: claimed.source},
                    reason,
                    jopts
                  )
              end
            rescue
              e ->
                reason = {:recovery_exception, Exception.message(e)}

                settle_or_report(
                  %{run_id: claimed.record.run_id, source: claimed.source},
                  reason,
                  jopts
                )
            catch
              :throw, value ->
                reason = {:recovery_throw, inspect(value, limit: 20, printable_limit: 200)}

                settle_or_report(
                  %{run_id: claimed.record.run_id, source: claimed.source},
                  reason,
                  jopts
                )

              # Every post-claim exit settles — :normal/:shutdown/{:shutdown,_} included.
              :exit, exit_reason ->
                reason = {:recovery_exit, classify_recovery_exit(exit_reason)}

                settle_or_report(
                  %{run_id: claimed.record.run_id, source: claimed.source},
                  reason,
                  jopts
                )
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Injected owner-scoped resolver supplies short-lived auth opts only.
  # Never persists credentials or SigningAuthority values.
  # Runs without a recoverable principal remain authentication_unavailable.
  defp resolve_resume_options(%Record{} = record, state) do
    stored_principal = record.execution_principal

    if not is_binary(stored_principal) or stored_principal == "" do
      {:error, :authentication_unavailable}
    else
      case invoke_resume_resolver(record, state.resume_options_resolver) do
        {:ok, opts} ->
          with :ok <- ensure_auth_present(opts),
               :ok <- ensure_principal_match(opts, stored_principal) do
            {:ok, opts}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp invoke_resume_resolver(_record, nil), do: {:error, :authentication_unavailable}

  defp invoke_resume_resolver(record, fun) when is_function(fun, 1) do
    normalize_resolver_result(fun.(record))
  rescue
    _ -> {:error, :authentication_unavailable}
  catch
    _, _ -> {:error, :authentication_unavailable}
  end

  defp invoke_resume_resolver(record, {mod, fun, extra_args})
       when is_atom(mod) and is_atom(fun) and is_list(extra_args) do
    normalize_resolver_result(apply(mod, fun, [record | extra_args]))
  rescue
    _ -> {:error, :authentication_unavailable}
  catch
    _, _ -> {:error, :authentication_unavailable}
  end

  defp invoke_resume_resolver(record, {mod, fun}) when is_atom(mod) and is_atom(fun) do
    normalize_resolver_result(apply(mod, fun, [record]))
  rescue
    _ -> {:error, :authentication_unavailable}
  catch
    _, _ -> {:error, :authentication_unavailable}
  end

  defp invoke_resume_resolver(_, _), do: {:error, :authentication_unavailable}

  defp normalize_resolver_result({:ok, opts}) when is_list(opts), do: {:ok, opts}

  defp normalize_resolver_result({:error, :authentication_unavailable}),
    do: {:error, :authentication_unavailable}

  defp normalize_resolver_result({:error, reason}), do: {:error, reason}

  defp normalize_resolver_result(opts) when is_list(opts),
    do: normalize_resolver_result({:ok, opts})

  defp normalize_resolver_result(_), do: {:error, :authentication_unavailable}

  defp ensure_auth_present(opts) when is_list(opts) do
    if resume_auth_present?(opts), do: :ok, else: {:error, :authentication_unavailable}
  end

  defp resume_auth_present?(opts) when is_list(opts) do
    Keyword.has_key?(opts, :signing_authority) or
      (is_binary(Keyword.get(opts, :identity_private_key)) and
         byte_size(Keyword.get(opts, :identity_private_key)) > 0) or
      is_binary(Keyword.get(opts, :hmac_secret))
  end

  # Accept only credentials whose canonical principal matches the stored one.
  defp ensure_principal_match(opts, stored_principal) when is_binary(stored_principal) do
    case credential_principal(opts) do
      {:ok, ^stored_principal} ->
        :ok

      {:ok, _other} ->
        {:error, :authentication_unavailable}

      :missing ->
        # Legacy hmac_secret / identity_private_key without embedded principal:
        # require explicit execution_principal opt matching the stored value.
        case Keyword.get(opts, :execution_principal) do
          ^stored_principal -> :ok
          _ -> {:error, :authentication_unavailable}
        end
    end
  end

  defp credential_principal(opts) do
    case Keyword.get(opts, :signing_authority) do
      %SigningAuthority{} = auth ->
        case SigningAuthority.canonicalize(auth) do
          {:ok, %SigningAuthority{principal_id: principal}} when is_binary(principal) ->
            {:ok, principal}

          _ ->
            :missing
        end

      _ ->
        :missing
    end
  end

  defp locate_checkpoint(%Record{} = entry) do
    run_id = entry.run_id
    logs_root = entry.logs_root
    local_path = if logs_root, do: Path.join(logs_root, "checkpoint.json")

    cond do
      local_path && File.exists?(local_path) ->
        {:ok, {:file, local_path}}

      run_id != nil ->
        case Arbor.Persistence.BufferedStore.get(
               run_id,
               name: :arbor_orchestrator_checkpoints
             ) do
          {:ok, checkpoint_data} when checkpoint_data != nil ->
            {:ok, {:store, checkpoint_data}}

          _ ->
            case fetch_checkpoint_from_peers(logs_root) do
              {:ok, data} -> {:ok, {:remote_data, data}}
              _ -> {:error, :checkpoint_not_found}
            end
        end

      true ->
        {:error, :no_checkpoint_source}
    end
  end

  defp fetch_checkpoint_from_peers(nil), do: {:error, :no_logs_root}

  defp fetch_checkpoint_from_peers(logs_root) do
    checkpoint_path = Path.join(logs_root, "checkpoint.json")

    Enum.find_value(Node.list(), {:error, :checkpoint_not_on_peers}, fn node ->
      try do
        case :erpc.call(node, File, :read, [checkpoint_path], 5_000) do
          {:ok, data} -> {:ok, data}
          _ -> nil
        end
      catch
        _, _ -> nil
      end
    end)
  end

  # Fail closed: hash means source identity matters — missing/unreadable path
  # is an explicit error, never a silent pass-through.
  defp validate_graph_unchanged(%Record{} = entry) do
    original_hash = entry.graph_hash
    path = entry.dot_source_path

    cond do
      is_nil(original_hash) ->
        :ok

      not is_binary(path) or path == "" ->
        {:error, :graph_source_unavailable}

      true ->
        case File.read(path) do
          {:ok, source} ->
            current_hash = compute_graph_hash(source)

            if current_hash == original_hash do
              :ok
            else
              {:error, :graph_changed}
            end

          {:error, reason} ->
            {:error, {:graph_source_unavailable, reason}}
        end
    end
  end

  defp do_resume(%Record{} = entry, checkpoint_source, resume_opts, recovery_root_config) do
    run_id = entry.run_id

    with {:ok, recovery_root} <- ensure_canonical_private_recovery_root(recovery_root_config),
         {:ok, logs_root} <- exclusive_attempt_logs_root(run_id, recovery_root),
         {:ok, resume_from} <-
           materialize_checkpoint(checkpoint_source, logs_root, recovery_root) do
      base_opts = [
        run_id: run_id,
        logs_root: logs_root,
        recovery: true,
        resume: true,
        graph_hash: entry.graph_hash,
        dot_source_path: entry.dot_source_path,
        execution_principal: entry.execution_principal,
        resume_from: resume_from
      ]

      # Auth opts first; identity/path fields from the record win over resolver.
      opts = Keyword.merge(resume_opts, base_opts)

      case load_graph_for_resume(entry) do
        {:ok, graph} ->
          Arbor.Orchestrator.Engine.run(graph, opts)

        {:error, reason} ->
          {:error, {:cannot_load_graph, reason}}
      end
    end
  end

  defp recovery_materialization_root_config do
    Application.get_env(
      :arbor_orchestrator,
      :recovery_materialization_root,
      Path.join(System.tmp_dir!(), "arbor_orchestrator/recovery")
    )
  end

  # Canonical private configured root: real directory only (never a symlink
  # or non-directory). Mode 0o700. All write materialization happens under it.
  # Uses the trusted configured root from coordinator state (or explicit test
  # injection) — does not reread Application env on each materialization.
  defp ensure_canonical_private_recovery_root(raw) do
    if not is_binary(raw) or raw == "" do
      {:error, {:recovery_root_unavailable, :invalid_config}}
    else
      expanded = Path.expand(raw)

      case ensure_real_private_directory(expanded) do
        {:ok, path} ->
          case SafePath.resolve_real(path) do
            {:ok, real} ->
              case File.lstat(real) do
                {:ok, %File.Stat{type: :directory}} ->
                  _ = File.chmod(real, 0o700)
                  {:ok, real}

                {:ok, %File.Stat{type: other}} ->
                  {:error, {:recovery_root_not_directory, other}}

                {:error, reason} ->
                  {:error, {:recovery_root_unavailable, reason}}
              end

            {:error, reason} ->
              {:error, {:recovery_root_unavailable, reason}}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp ensure_real_private_directory(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        _ = File.chmod(path, 0o700)
        {:ok, path}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :recovery_root_is_symlink}

      {:ok, %File.Stat{type: other}} ->
        {:error, {:recovery_root_not_directory, other}}

      {:error, :enoent} ->
        parent = Path.dirname(path)

        with :ok <- ensure_parent_chain(parent),
             :ok <- exclusive_mkdir(path),
             {:ok, %File.Stat{type: :directory}} <- File.lstat(path) do
          _ = File.chmod(path, 0o700)
          {:ok, path}
        else
          {:ok, %File.Stat{type: :symlink}} ->
            _ = File.rmdir(path)
            {:error, :recovery_root_is_symlink}

          {:ok, %File.Stat{type: other}} ->
            _ = File.rmdir(path)
            {:error, {:recovery_root_not_directory, other}}

          {:error, reason} ->
            {:error, {:recovery_root_unavailable, reason}}
        end

      {:error, reason} ->
        {:error, {:recovery_root_unavailable, reason}}
    end
  end

  defp ensure_parent_chain(path) when is_binary(path) do
    case File.mkdir_p(path) do
      :ok ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} -> :ok
          {:ok, %File.Stat{type: :symlink}} -> {:error, :recovery_parent_is_symlink}
          {:ok, %File.Stat{type: other}} -> {:error, {:recovery_parent_not_directory, other}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exclusive_mkdir(path) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :eexist}
      {:error, reason} -> {:error, reason}
    end
  end

  # Collision-free private attempt directory under the recovery root.
  # Never reuses retained logs_root (may be attacker-controlled / outside root).
  defp exclusive_attempt_logs_root(run_id, recovery_root) do
    safe_id = sanitize_attempt_id(run_id)
    exclusive_attempt_logs_root_retry(recovery_root, safe_id, 0)
  end

  defp exclusive_attempt_logs_root_retry(_recovery_root, _safe_id, attempt)
       when attempt >= 8 do
    {:error, {:recovery_root_unavailable, :attempt_dir_collision}}
  end

  defp exclusive_attempt_logs_root_retry(recovery_root, safe_id, attempt) do
    token =
      8
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    name =
      "attempt_#{safe_id}_#{System.unique_integer([:positive])}_#{token}"

    case SafePath.safe_join(recovery_root, name) do
      {:ok, path} ->
        case exclusive_mkdir(path) do
          :ok ->
            case File.lstat(path) do
              {:ok, %File.Stat{type: :directory}} ->
                _ = File.chmod(path, 0o700)
                {:ok, path}

              {:ok, %File.Stat{type: :symlink}} ->
                _ = File.rmdir(path)
                {:error, :recovery_attempt_is_symlink}

              {:ok, %File.Stat{type: other}} ->
                _ = File.rmdir(path)
                {:error, {:recovery_attempt_not_directory, other}}

              {:error, reason} ->
                _ = File.rmdir(path)
                {:error, {:recovery_root_unavailable, reason}}
            end

          {:error, :eexist} ->
            exclusive_attempt_logs_root_retry(recovery_root, safe_id, attempt + 1)

          {:error, reason} ->
            {:error, {:recovery_root_unavailable, reason}}
        end

      {:error, reason} ->
        {:error, {:unsafe_recovery_path, reason}}
    end
  end

  defp sanitize_attempt_id(run_id) when is_binary(run_id) and run_id != "" do
    run_id
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> String.slice(0, 64)
  end

  defp sanitize_attempt_id(_), do: "run"

  # Read-only acceptance of an existing checkpoint file; store/remote payloads
  # are written only under the exclusive attempt directory via exclusive create.
  defp materialize_checkpoint({:file, path}, _logs_root, _recovery_root) do
    cond do
      not is_binary(path) ->
        {:error, :checkpoint_not_found}

      true ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular}} ->
            {:ok, path}

          {:ok, %File.Stat{type: :symlink}} ->
            {:error, :checkpoint_is_symlink}

          _ ->
            {:error, :checkpoint_not_found}
        end
    end
  end

  defp materialize_checkpoint({:store, checkpoint_data}, logs_root, recovery_root) do
    write_checkpoint_exclusive(logs_root, recovery_root, checkpoint_data)
  end

  defp materialize_checkpoint({:remote_data, raw_data}, logs_root, recovery_root) do
    write_checkpoint_exclusive(logs_root, recovery_root, raw_data)
  end

  defp write_checkpoint_exclusive(logs_root, recovery_root, data) do
    with {:ok, resolved_root} <- ensure_path_within_real(logs_root, recovery_root),
         {:ok, local_path} <- SafePath.safe_join(resolved_root, "checkpoint.json"),
         {:ok, payload} <- encode_checkpoint_payload(data) do
      case File.lstat(local_path) do
        {:ok, _} ->
          # Must exclusively create — never overwrite pre-existing path/symlink.
          {:error, :checkpoint_path_exists}

        {:error, :enoent} ->
          case File.open(local_path, [:write, :binary, :exclusive], fn io ->
                 IO.binwrite(io, payload)
               end) do
            {:ok, :ok} ->
              case File.lstat(local_path) do
                {:ok, %File.Stat{type: :regular}} ->
                  {:ok, local_path}

                {:ok, %File.Stat{type: other}} ->
                  _ = File.rm(local_path)
                  {:error, {:checkpoint_materialize_failed, {:not_regular, other}}}

                {:error, reason} ->
                  _ = File.rm(local_path)
                  {:error, {:checkpoint_materialize_failed, reason}}
              end

            {:ok, {:error, reason}} ->
              {:error, {:checkpoint_materialize_failed, reason}}

            {:error, :eexist} ->
              {:error, :checkpoint_path_exists}

            {:error, reason} ->
              {:error, {:checkpoint_materialize_failed, reason}}
          end

        {:error, reason} ->
          {:error, {:checkpoint_materialize_failed, reason}}
      end
    else
      {:error, reason} -> {:error, {:unsafe_recovery_path, reason}}
    end
  end

  defp encode_checkpoint_payload(data) when is_binary(data), do: {:ok, data}

  defp encode_checkpoint_payload(data) when is_map(data) do
    case Jason.encode(data) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_checkpoint_payload(_), do: {:error, :invalid_checkpoint_payload}

  defp ensure_path_within_real(path, root) do
    with {:ok, resolved} <- SafePath.resolve_within(path, root),
         {:ok, real_path} <- SafePath.resolve_real(resolved),
         {:ok, real_root} <- SafePath.resolve_real(root),
         true <- path_under_root?(real_path, real_root),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(resolved) do
      {:ok, resolved}
    else
      false -> {:error, :path_traversal}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :path_is_symlink}
      {:ok, %File.Stat{type: other}} -> {:error, {:not_directory, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp path_under_root?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp load_graph_for_resume(%Record{} = entry) do
    path = entry.dot_source_path

    if is_binary(path) do
      case File.read(path) do
        {:ok, source} -> Arbor.Orchestrator.compile(source)
        {:error, reason} -> {:error, {:dot_file_unavailable, reason}}
      end
    else
      {:error, :no_dot_source_path}
    end
  end

  defp attempt_claim(%{record: %Record{} = entry, source: source}, journal_opts) do
    key = entry.run_id

    my_zone = resolve_trust_zone()
    origin_zone = entry.origin_trust_zone || 0
    origin_zone = if is_integer(origin_zone), do: origin_zone, else: 0

    if my_zone > origin_zone do
      Logger.warning(
        "[RecoveryCoordinator] Cannot claim #{key}: " <>
          "our zone (#{my_zone}) > origin zone (#{origin_zone})"
      )

      {:error, :trust_zone_violation}
    else
      if am_i_leader?() do
        case claim_entry(key, source, journal_opts) do
          {:ok, %Record{} = claimed} ->
            Logger.info("[RecoveryCoordinator] Claimed pipeline #{key} for recovery")
            {:ok, %{record: claimed, source: source}}

          {:error, reason} ->
            Logger.debug("[RecoveryCoordinator] Could not claim #{key}: #{inspect(reason)}")
            {:error, reason}
        end
      else
        Logger.debug("[RecoveryCoordinator] Not leader, skipping claim for #{key}")
        {:error, :not_leader}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Canonical + legacy discovery (typed Records only)
  # ---------------------------------------------------------------------------

  defp journal_opts(%{journal_opts: opts}) when is_list(opts), do: opts
  defp journal_opts(_), do: []

  defp list_interrupted_for_recovery(journal_opts) do
    # Recovery must distinguish journal unavailability from empty.
    # Never fall through to legacy state during a journal outage.
    # Always target the coordinator's configured journal (custom server: when set).
    case PipelineStatus.list_interrupted_records(journal_opts) do
      {:ok, records} ->
        current =
          Enum.map(records, fn %Record{} = r -> %{record: r, source: :current} end)

        current_ids = MapSet.new(current, & &1.record.run_id)

        legacy =
          LegacyJobAdapter.list_interrupted()
          |> Enum.reject(fn %Record{run_id: id} -> MapSet.member?(current_ids, id) end)
          |> Enum.map(fn %Record{} = r -> %{record: r, source: :legacy} end)

        current ++ legacy

      {:error, reason} ->
        Logger.warning(
          "[RecoveryCoordinator] journal unavailable during interrupted discovery: " <>
            inspect(reason) <> "; refusing legacy fall-through"
        )

        []
    end
  end

  defp list_by_owner_for_recovery(node_name, journal_opts) do
    # Probe the configured journal first so outages refuse legacy fall-through
    # (list_by_owner_records degrades to [] for dashboard callers).
    case RunJournal.list_records(journal_opts) do
      {:ok, _} ->
        current =
          node_name
          |> PipelineStatus.list_by_owner_records(journal_opts)
          |> Enum.map(fn %Record{} = r -> %{record: r, source: :current} end)

        current_ids = MapSet.new(current, & &1.record.run_id)

        legacy =
          LegacyJobAdapter.list_by_owner(node_name)
          |> Enum.reject(fn %Record{run_id: id} -> MapSet.member?(current_ids, id) end)
          |> Enum.map(fn %Record{} = r -> %{record: r, source: :legacy} end)

        current ++ legacy

      {:error, reason} ->
        Logger.warning(
          "[RecoveryCoordinator] journal unavailable during owner discovery: " <>
            inspect(reason) <> "; refusing legacy fall-through"
        )

        []
    end
  end

  defp classify_recovery_exit(:normal), do: "normal"
  defp classify_recovery_exit(:shutdown), do: "shutdown"

  defp classify_recovery_exit({:shutdown, reason}),
    do: {"shutdown", classify_recovery_exit(reason)}

  defp classify_recovery_exit(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp classify_recovery_exit(reason) when is_binary(reason), do: reason
  defp classify_recovery_exit(reason), do: inspect(reason, limit: 20, printable_limit: 200)

  defp claim_entry(key, :current, journal_opts) do
    PipelineStatus.claim_for_recovery_record(key, Kernel.node(), journal_opts)
  end

  defp claim_entry(key, :legacy, _journal_opts) do
    LegacyJobAdapter.claim_for_recovery(key)
  end

  defp claim_entry(key, _, journal_opts) do
    case PipelineStatus.claim_for_recovery_record(key, Kernel.node(), journal_opts) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> LegacyJobAdapter.claim_for_recovery(key)
      other -> other
    end
  end

  defp mark_interrupted_entry(%{record: %Record{run_id: key}, source: source}, journal_opts) do
    if source == :legacy do
      LegacyJobAdapter.mark_interrupted(key)
    else
      PipelineStatus.mark_interrupted(key, journal_opts)
    end
  end

  defp mark_abandoned_entry(%{record: %Record{run_id: key}, source: source}, journal_opts) do
    if source == :legacy do
      LegacyJobAdapter.mark_abandoned(key)
    else
      PipelineStatus.mark_abandoned(key, journal_opts)
    end
  end

  # After claim, recovery failure must not leave :recovering stranded.
  # Prefer recoverable :interrupted; use :failed only for terminal non-retryable
  # graph identity/source / structural checkpoint corruption.
  # Never reopen an already-failed record. Settlement failures are retained.
  defp settle_or_report(meta, reason, journal_opts) do
    case settle_recovery_failure(meta, reason, journal_opts) do
      :ok ->
        {:error, reason}

      {:ok, _, _} ->
        {:error, reason}

      {:error, settle_reason} ->
        {:error, {:resume_settlement_failed, settle_reason, reason}}

      other when other == :ok ->
        {:error, reason}

      _ ->
        {:error, reason}
    end
  end

  defp settle_recovery_failure(%{run_id: run_id, source: source}, reason, journal_opts) do
    case current_status(run_id, source, journal_opts) do
      status when status in [:completed, :failed, :abandoned] ->
        {:ok, :already_terminal, status}

      nil ->
        {:error, :not_found}

      _ ->
        result =
          if non_retryable_recovery_error?(reason) do
            mark_failed_entry(run_id, source, reason, journal_opts)
          else
            mark_interrupted_by_source(run_id, source, journal_opts)
          end

        case result do
          :ok -> :ok
          {:error, _} = err -> err
          other -> {:error, {:unexpected_settlement_result, other}}
        end
    end
  end

  defp apply_settlement(state, meta, reason) do
    jopts = journal_opts(state)

    case settle_recovery_failure(meta, reason, jopts) do
      :ok ->
        state

      {:ok, _, _} ->
        state

      {:error, settle_reason} ->
        Logger.warning(
          "[RecoveryCoordinator] settlement failed for #{meta.run_id}: #{inspect(settle_reason)}; retaining for retry"
        )

        failure = %{
          run_id: meta.run_id,
          source: Map.get(meta, :source, :current),
          reason: reason,
          settle_reason: settle_reason,
          attempts: 1
        }

        failures = [failure | Map.get(state, :settlement_failures, [])]
        %{state | settlement_failures: failures}
    end
  end

  defp retry_failed_settlements(state) do
    failures = Map.get(state, :settlement_failures, [])
    jopts = journal_opts(state)

    if failures == [] do
      state
    else
      remaining =
        Enum.reduce(failures, [], fn failure, keep ->
          meta = %{run_id: failure.run_id, source: failure.source}

          case settle_recovery_failure(meta, failure.reason, jopts) do
            :ok ->
              keep

            {:ok, _, _} ->
              keep

            {:error, settle_reason} ->
              updated = %{
                failure
                | settle_reason: settle_reason,
                  attempts: (failure.attempts || 1) + 1
              }

              [updated | keep]
          end
        end)

      %{state | settlement_failures: remaining}
    end
  end

  defp current_status(run_id, :legacy, _journal_opts) do
    case LegacyJobAdapter.get(run_id) do
      %Record{status: status} -> status
      _ -> nil
    end
  end

  defp current_status(run_id, _, journal_opts) do
    case PipelineStatus.get_record(run_id, journal_opts) do
      %Record{status: status} -> status
      _ -> nil
    end
  end

  defp mark_interrupted_by_source(run_id, :legacy, _journal_opts),
    do: LegacyJobAdapter.mark_interrupted(run_id)

  defp mark_interrupted_by_source(run_id, _, journal_opts),
    do: PipelineStatus.mark_interrupted(run_id, journal_opts)

  defp mark_failed_entry(run_id, :legacy, _reason, _journal_opts) do
    LegacyJobAdapter.mark_abandoned(run_id)
  end

  defp mark_failed_entry(run_id, _, reason, journal_opts) do
    PipelineStatus.mark_failed(run_id, reason, journal_opts)
  end

  # Explicit typed classification (no string-contains heuristics).
  # Graph hash / parse / required-pointer corruption → nonretryable.
  # Typed filesystem/mount I/O unavailability → retryable.
  # Nested `{:cannot_load_graph, cause}` is classified by inspecting cause.
  defp non_retryable_recovery_error?(:graph_changed), do: true
  defp non_retryable_recovery_error?(:graph_source_unavailable), do: true
  defp non_retryable_recovery_error?(:no_dot_source_path), do: true
  defp non_retryable_recovery_error?(:checkpoint_current_node_missing), do: true
  defp non_retryable_recovery_error?(:checkpoint_corrupt), do: true
  defp non_retryable_recovery_error?({:checkpoint_corrupt, _}), do: true
  defp non_retryable_recovery_error?({:checkpoint_invalid, _}), do: true
  defp non_retryable_recovery_error?({:unsafe_recovery_path, _}), do: true
  defp non_retryable_recovery_error?(:checkpoint_is_symlink), do: true
  defp non_retryable_recovery_error?(:checkpoint_path_exists), do: true
  defp non_retryable_recovery_error?(:recovery_root_is_symlink), do: true
  defp non_retryable_recovery_error?(:recovery_attempt_is_symlink), do: true
  defp non_retryable_recovery_error?({:recovery_root_not_directory, _}), do: true
  defp non_retryable_recovery_error?({:recovery_attempt_not_directory, _}), do: true

  defp non_retryable_recovery_error?({:cannot_load_graph, cause}),
    do: non_retryable_recovery_error?(cause)

  defp non_retryable_recovery_error?({:graph_source_unavailable, reason}),
    do: not filesystem_io_unavailable?(reason)

  defp non_retryable_recovery_error?({:dot_file_unavailable, reason}),
    do: not filesystem_io_unavailable?(reason)

  defp non_retryable_recovery_error?({:recovery_root_unavailable, reason}),
    do: not filesystem_io_unavailable?(reason)

  defp non_retryable_recovery_error?({:checkpoint_materialize_failed, reason}),
    do: not filesystem_io_unavailable?(reason)

  # Parse / compile / graph identity failures nested under cannot_load_graph
  defp non_retryable_recovery_error?({:parse_error, _}), do: true
  defp non_retryable_recovery_error?({:compile_error, _}), do: true
  defp non_retryable_recovery_error?({:invalid_graph, _}), do: true

  # Retryable credential / backend unavailability
  defp non_retryable_recovery_error?(:authentication_unavailable), do: false
  defp non_retryable_recovery_error?(:identity_required_for_resume), do: false
  defp non_retryable_recovery_error?(:checkpoint_not_found), do: false
  defp non_retryable_recovery_error?(:checkpoint_hmac_invalid), do: false
  defp non_retryable_recovery_error?(:checkpoint_hmac_missing), do: false
  defp non_retryable_recovery_error?({:unauthorized_resume, _}), do: false
  defp non_retryable_recovery_error?({:checkpoint_load_failed, _}), do: false
  defp non_retryable_recovery_error?(_), do: false

  # Transient filesystem / mount I/O — leave interrupted for retry.
  defp filesystem_io_unavailable?(reason)
       when reason in [
              :eio,
              :enxio,
              :enodev,
              :estale,
              :ebusy,
              :emfile,
              :enfile,
              :enomem,
              :eagain,
              :ehostdown,
              :ehostunreach,
              :enetdown,
              :enetunreach,
              :etimedout,
              :econnrefused,
              :econnreset,
              :econnaborted,
              :eunavailable,
              :erofs
            ],
       do: true

  defp filesystem_io_unavailable?(_), do: false

  defp am_i_leader? do
    case :pg.get_members(@pg_group) do
      [] ->
        true

      members ->
        sorted = Enum.sort_by(members, fn pid -> node(pid) end)
        List.first(sorted) == self()
    end
  rescue
    _ -> true
  end

  defp join_pg_group do
    case :pg.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :pg.join(@pg_group, self())
  rescue
    _ -> :ok
  end

  defp resolve_trust_zone do
    mod = Arbor.Cartographer.ClusterKeeper

    if Code.ensure_loaded?(mod) and function_exported?(mod, :trust_zone, 1) do
      apply(mod, :trust_zone, [Kernel.node()])
    else
      0
    end
  rescue
    _ -> 0
  end

  @doc false
  def compute_graph_hash(dot_source) when is_binary(dot_source) do
    :crypto.hash(:sha256, dot_source) |> Base.encode16(case: :lower)
  end

  # Test-only hooks for symlink-safe materialization (not production API).
  # Optional recovery_root overrides Application env so hermetic tests match
  # the production state.recovery_root threading path.
  @doc false
  def __test_ensure_recovery_root__(recovery_root \\ nil) do
    ensure_canonical_private_recovery_root(
      recovery_root || recovery_materialization_root_config()
    )
  end

  @doc false
  def __test_materialize_store_checkpoint__(checkpoint_data, run_id, recovery_root \\ nil)
      when is_binary(run_id) do
    configured = recovery_root || recovery_materialization_root_config()

    with {:ok, root} <- ensure_canonical_private_recovery_root(configured),
         {:ok, logs_root} <- exclusive_attempt_logs_root(run_id, root) do
      case materialize_checkpoint({:store, checkpoint_data}, logs_root, root) do
        {:ok, path} -> {:ok, %{path: path, logs_root: logs_root, recovery_root: root}}
        {:error, _} = err -> err
      end
    end
  end

  @doc false
  def __test_non_retryable_recovery_error__(reason),
    do: non_retryable_recovery_error?(reason)

  defp spawning_process_alive?(nil), do: false

  defp spawning_process_alive?(pid) when is_pid(pid) do
    # Tri-state: only treat proven :dead as not alive. :unknown (partition/RPC)
    # must not drive abandon/interrupt decisions.
    case Arbor.Orchestrator.PipelineStatus.process_liveness(pid) do
      :alive -> true
      :dead -> false
      :unknown -> true
    end
  end

  defp spawning_process_alive?(_), do: false
end
