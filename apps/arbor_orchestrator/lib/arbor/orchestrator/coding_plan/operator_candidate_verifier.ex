defmodule Arbor.Orchestrator.CodingPlan.OperatorCandidateVerifier do
  @moduledoc false

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Coding.VerificationReport
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Orchestrator.CodingPlan.{CandidateVerifier, ValidationProgram}
  alias Arbor.Orchestrator.Config

  @authority_purpose :coding_candidate_operator
  @required_request_keys ~w[agent_id task_id workspace_id]
  @optional_request_keys ~w[review_attestation_id]
  @max_id_bytes 256
  @max_wall_clock_ms 86_400_000
  @max_workspace_inventory_items 16
  @worker_reply_tag :operator_candidate_verification_result
  @guard_ready_tag :operator_candidate_guard_ready
  @guard_registered_tag :operator_candidate_guard_registered
  @guard_acquire_authority_tag :operator_candidate_guard_acquire_authority
  @guard_authority_reply_tag :operator_candidate_guard_authority_reply
  @guard_cancel_request_tag :operator_candidate_guard_cancel_request
  @guard_cancel_started_tag :operator_candidate_guard_cancel_started
  @guard_cancel_done_tag :operator_candidate_guard_cancel_done
  @guard_done_tag :operator_candidate_guard_done
  @worker_down_timeout_ms 1_000
  @signing_authority_close_timeout_ms 30_000
  @approval_cleanup_timeout_ms 5_000
  @cancellation_scheduler_margin_ms 2_000
  @cancellation_grace_ms @worker_down_timeout_ms +
                           @signing_authority_close_timeout_ms +
                           @worker_down_timeout_ms +
                           @approval_cleanup_timeout_ms +
                           @worker_down_timeout_ms +
                           @cancellation_scheduler_margin_ms
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @work_packet_digest_pattern ~r/\Asha256:[0-9a-f]{64}\z/

  @doc false
  @spec cancellation_grace_ms() :: pos_integer()
  def cancellation_grace_ms, do: @cancellation_grace_ms

  @doc false
  @spec verify(term(), term()) :: {:ok, map()} | {:error, term()}
  def verify(plan, request), do: verify_for_requester(plan, request, self())

  @doc false
  @spec verify_for_requester(term(), term(), pid()) :: {:ok, map()} | {:error, term()}
  def verify_for_requester(plan, request, requester) when is_pid(requester) do
    started_at = System.monotonic_time(:millisecond)
    requester_monitor = Process.monitor(requester)

    try do
      with {:ok, request} <- normalize_request(request),
           :ok <- requester_available(requester_monitor, requester),
           {:ok, reviewed} <- bind_reviewed_compilation(plan, request.task_id),
           {:ok, workspace} <- workspace_provenance(request, reviewed.compilation),
           :ok <- requester_available(requester_monitor, requester),
           {:ok, timeout_ms} <- remaining_timeout(reviewed.compilation, started_at) do
        run_verification_worker(request, reviewed, workspace, requester, timeout_ms)
      else
        {:error, :candidate_verification_cancelled} ->
          cleanup_result =
            case normalize_request(request) do
              {:ok, normalized_request} ->
                bounded_approval_cleanup(normalized_request, :task_cancellation)

              _ ->
                :ok
            end

          {:error, {:candidate_verification_cancelled, cleanup_result}}

        {:error, _reason} = error ->
          error
      end
    after
      Process.demonitor(requester_monitor, [:flush])
    end
  rescue
    _exception -> {:error, :operator_candidate_verification_failed}
  catch
    _kind, _reason -> {:error, :operator_candidate_verification_failed}
  end

  def verify_for_requester(_plan, _request, _requester),
    do: {:error, :invalid_operator_candidate_requester}

  defp normalize_request(request) when is_map(request) and not is_struct(request) do
    keys = Map.keys(request)
    allowed_keys = @required_request_keys ++ @optional_request_keys

    with true <- Enum.all?(keys, &is_binary/1),
         true <- Enum.all?(@required_request_keys, &Map.has_key?(request, &1)),
         true <- Enum.all?(keys, &(&1 in allowed_keys)),
         true <- length(keys) == length(Enum.uniq(keys)),
         {:ok, agent_id} <- agent_id(request["agent_id"]),
         {:ok, task_id} <- bounded_id(request["task_id"], :invalid_task_id),
         {:ok, workspace_id} <-
           bounded_id(request["workspace_id"], :invalid_workspace_id),
         {:ok, review_attestation_id} <- review_attestation_id(request),
         {:ok, _encoded} <- Jason.encode(request) do
      {:ok,
       %{
         agent_id: agent_id,
         task_id: task_id,
         workspace_id: workspace_id,
         review_attestation_id: review_attestation_id
       }}
    else
      {:error, reason}
      when reason in [
             :invalid_agent_id,
             :invalid_task_id,
             :invalid_workspace_id,
             :invalid_review_attestation_id
           ] ->
        {:error, reason}

      _other ->
        {:error, :invalid_operator_candidate_request}
    end
  end

  defp normalize_request(_request), do: {:error, :invalid_operator_candidate_request}

  defp bind_reviewed_compilation(caller_plan, task_id) do
    with {:ok, archive} <- read_task_compilation(task_id),
         {:ok, reviewed_compilation} <-
           compile_for_provenance(archive["plan"]),
         :ok <- archived_compilation_matches?(reviewed_compilation, archive),
         {:ok, caller_compilation} <- compile_for_provenance(caller_plan),
         :ok <- caller_plan_matches?(caller_compilation, reviewed_compilation),
         {:ok, validation_program} <- validation_program(reviewed_compilation),
         {:ok, provenance} <-
           compilation_provenance(reviewed_compilation, archive, task_id) do
      {:ok,
       %{
         compilation: reviewed_compilation,
         validation_program: validation_program,
         provenance: provenance
       }}
    else
      {:error, :coding_compilation_provenance_unavailable} = error -> error
      _ -> {:error, :coding_plan_provenance_mismatch}
    end
  end

  defp read_task_compilation(task_id) do
    store = Config.coding_plan_artifact_store()

    if is_atom(store) and Code.ensure_loaded?(store) and
         function_exported?(store, :read_task_compilation, 2) do
      case store.read_task_compilation(Config.coding_pipeline_logs_root(), task_id) do
        {:ok, archive} when is_map(archive) and not is_struct(archive) -> {:ok, archive}
        _ -> {:error, :coding_compilation_provenance_unavailable}
      end
    else
      {:error, :coding_compilation_provenance_unavailable}
    end
  rescue
    _ -> {:error, :coding_compilation_provenance_unavailable}
  catch
    _, _ -> {:error, :coding_compilation_provenance_unavailable}
  end

  defp compile_for_provenance(plan) do
    case Arbor.Orchestrator.compile_coding_plan(plan) do
      {:ok, compilation} when is_map(compilation) and not is_struct(compilation) ->
        {:ok, compilation}

      _ ->
        {:error, :coding_plan_provenance_mismatch}
    end
  end

  defp archived_compilation_matches?(compilation, archive) do
    if compilation["plan_map"] == archive["plan"] and
         compilation["dot_source"] == archive["dot_source"] and
         compilation["manifest"] == archive["manifest"] and
         valid_sha256?(archive["manifest_sha256"]) do
      :ok
    else
      {:error, :coding_plan_provenance_mismatch}
    end
  end

  defp caller_plan_matches?(caller, reviewed) do
    if caller["plan_map"] == reviewed["plan_map"] and
         caller["plan_fingerprint"] == reviewed["plan_fingerprint"] do
      :ok
    else
      {:error, :coding_plan_provenance_mismatch}
    end
  end

  defp compilation_provenance(compilation, archive, task_id) do
    plan = compilation["plan_map"]
    fingerprint = compilation["plan_fingerprint"]
    plan_version = plan["version"]
    validation_profile = plan["validation_profile"]
    review_profile = plan["review_profile"]
    work_packet_digest = plan["work_packet_digest"]

    if plan_version == 2 and valid_sha256?(fingerprint) and
         valid_work_packet_digest?(work_packet_digest) and
         safe_nonblank_text?(validation_profile, @max_id_bytes) and
         safe_nonblank_text?(review_profile, @max_id_bytes) do
      {:ok,
       %{
         "task_id" => task_id,
         "plan_fingerprint" => fingerprint,
         "plan_version" => plan_version,
         "validation_profile" => validation_profile,
         "review_profile" => review_profile,
         "work_packet_digest" => work_packet_digest,
         "compile_manifest_sha256" => archive["manifest_sha256"]
       }}
    else
      {:error, :coding_plan_provenance_mismatch}
    end
  end

  defp validation_program(compilation)
       when is_map(compilation) and not is_struct(compilation) do
    with initial_values when is_map(initial_values) and not is_struct(initial_values) <-
           Map.get(compilation, "initial_values"),
         program when is_map(program) and not is_struct(program) <-
           Map.get(initial_values, "coding_plan_validation_program"),
         :ok <- ValidationProgram.validate(program),
         {:ok, _encoded} <- Jason.encode(program) do
      {:ok, program}
    else
      _other -> {:error, :invalid_coding_plan_validation_program}
    end
  end

  defp validation_program(_compilation),
    do: {:error, :invalid_coding_plan_validation_program}

  defp workspace_provenance(request, compilation) do
    facade = Config.coding_reconciliation_resource_facade()
    repo_root = get_in(compilation, ["plan_map", "repo_root"])

    opts = [
      task_id: request.task_id,
      principal_id: request.agent_id,
      max_items: @max_workspace_inventory_items
    ]

    with true <- is_atom(facade) and Code.ensure_loaded?(facade),
         true <- function_exported?(facade, :coding_resource_inventory, 1),
         {:ok, inventory} <- apply(facade, :coding_resource_inventory, [opts]),
         {:ok, resource, state} <- select_workspace_resource(inventory, request),
         {:ok, canonical_repo_path} <-
           bind_canonical_repo(repo_root, resource["repo_path"]),
         {:ok, encoded} <- encode_canonical(resource),
         true <- byte_size(encoded) <= 64_000 do
      {:ok,
       %{
         facade: facade,
         resource: resource,
         observed_state: state,
         canonical_repo_path: canonical_repo_path,
         provenance_sha256: sha256(encoded)
       }}
    else
      _ -> {:error, :workspace_provenance_mismatch}
    end
  rescue
    _ -> {:error, :workspace_provenance_mismatch}
  catch
    _, _ -> {:error, :workspace_provenance_mismatch}
  end

  defp select_workspace_resource(inventory, request)
       when is_map(inventory) and not is_struct(inventory) do
    resources = Map.get(inventory, "resources")

    candidates =
      if is_list(resources) do
        Enum.filter(resources, fn resource ->
          is_map(resource) and not is_struct(resource) and
            resource["workspace_id"] == request.workspace_id and
            resource["task_id"] == request.task_id and
            resource["principal_id"] == request.agent_id and
            resource["resource_type"] == "retained_workspace_record"
        end)
      else
        []
      end

    with false <- Map.get(inventory, "truncated"),
         false <- get_in(inventory, ["journal", "quarantined"]),
         false <-
           Enum.any?(resources || [], fn resource ->
             is_map(resource) and resource["resource_type"] == "quarantine"
           end),
         [resource] <- candidates do
      case {resource["resource_type"], resource["active"]} do
        {"retained_workspace_record", false} -> {:ok, resource, :retained}
        _ -> {:error, :workspace_provenance_mismatch}
      end
    else
      _ -> {:error, :workspace_provenance_mismatch}
    end
  end

  defp select_workspace_resource(_inventory, _request),
    do: {:error, :workspace_provenance_mismatch}

  defp bind_canonical_repo(plan_repo_root, resource_repo_path) do
    with {:ok, canonical_plan_repo} <- canonical_existing_directory(plan_repo_root),
         {:ok, canonical_resource_repo} <- canonical_existing_directory(resource_repo_path),
         true <- canonical_plan_repo == canonical_resource_repo do
      {:ok, canonical_plan_repo}
    else
      _ -> {:error, :workspace_provenance_mismatch}
    end
  end

  defp canonical_existing_directory(path) when is_binary(path) do
    with true <- SafePath.absolute?(path),
         :ok <- SafePath.validate(path),
         {:ok, canonical} <- SafePath.resolve_real(path),
         true <- canonical == path,
         true <- File.dir?(canonical) do
      {:ok, canonical}
    else
      _ -> {:error, :workspace_provenance_mismatch}
    end
  end

  defp canonical_existing_directory(_path),
    do: {:error, :workspace_provenance_mismatch}

  defp remaining_timeout(compilation, started_at) do
    wall_clock_ms = get_in(compilation, ["plan_map", "budgets", "wall_clock_ms"])

    if is_integer(wall_clock_ms) and wall_clock_ms > 0 and
         wall_clock_ms <= @max_wall_clock_ms do
      elapsed_ms = max(System.monotonic_time(:millisecond) - started_at, 0)
      remaining_ms = wall_clock_ms - elapsed_ms

      if remaining_ms > 0,
        do: {:ok, remaining_ms},
        else: {:error, :candidate_verification_timeout}
    else
      {:error, :invalid_coding_plan_wall_clock}
    end
  end

  defp run_verification_worker(request, reviewed, workspace, requester, timeout_ms) do
    owner = self()
    reply_ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    {worker, monitor} =
      spawn_monitor(fn ->
        run_owned_worker(owner, requester, reply_ref, request, reviewed, workspace)
      end)

    await_verification_worker(
      request,
      reply_ref,
      worker,
      monitor,
      nil,
      deadline
    )
  end

  defp await_verification_worker(request, reply_ref, worker, monitor, guard, deadline) do
    receive do
      {@guard_registered_tag, ^reply_ref, registered_guard}
      when is_pid(registered_guard) ->
        await_verification_worker(
          request,
          reply_ref,
          worker,
          monitor,
          registered_guard,
          deadline
        )

      {@worker_reply_tag, ^reply_ref, result} ->
        Process.demonitor(monitor, [:flush])
        finalize_worker_result(result, request)

      {@guard_cancel_started_tag, ^reply_ref, guard, _reason} ->
        await_guard_cancellation(guard, reply_ref, monitor, worker)

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        receive do
          {@worker_reply_tag, ^reply_ref, result} ->
            finalize_worker_result(result, request)

          {@guard_cancel_started_tag, ^reply_ref, guard, _reason} ->
            await_guard_cancellation(guard, reply_ref, monitor, worker)
        after
          10 ->
            cleanup_or_replace_error(
              {:error, :operator_candidate_verification_failed},
              request,
              :task_termination
            )
        end
    after
      remaining_ms(deadline) ->
        cancel_for_deadline(guard, request, reply_ref, monitor, worker)
    end
  end

  defp run_owned_worker(owner, requester, reply_ref, request, reviewed, workspace) do
    case start_lifecycle_guard(owner, requester, reply_ref, request) do
      {:ok, guard} ->
        send(owner, {@guard_registered_tag, reply_ref, guard})

        result =
          try do
            with {:ok, workspace_lifecycle} <-
                   activate_workspace(workspace, request),
                 {:ok, security} <- security_facade(),
                 {:ok, authority} <-
                   acquire_guarded_signing_authority(guard, security, request.agent_id) do
              verify_with_authority(
                security,
                authority,
                request,
                reviewed,
                workspace,
                workspace_lifecycle
              )
            end
          rescue
            _exception -> {:error, :operator_candidate_verification_failed}
          catch
            _kind, _reason -> {:error, :operator_candidate_verification_failed}
          end

        send(owner, {@worker_reply_tag, reply_ref, result})
        send(guard, {@guard_done_tag, self()})

      {:cancelled, _guard} ->
        :ok

      {:error, _reason} ->
        send(owner, {@worker_reply_tag, reply_ref, {:error, :candidate_verification_unavailable}})
    end
  end

  defp start_lifecycle_guard(owner, requester, reply_ref, request) do
    worker = self()

    guard =
      spawn(fn ->
        owner_monitor = Process.monitor(owner)
        requester_monitor = Process.monitor(requester)
        worker_monitor = Process.monitor(worker)

        receive do
          {:DOWN, ^owner_monitor, :process, ^owner, reason} ->
            send(worker, {@guard_ready_tag, self(), :cancelled})

            cancel_guarded_worker(
              owner,
              false,
              worker,
              worker_monitor,
              reply_ref,
              request,
              {:owner_down, reason},
              nil
            )

          {:DOWN, ^requester_monitor, :process, ^requester, reason} ->
            send(worker, {@guard_ready_tag, self(), :cancelled})

            cancel_guarded_worker(
              owner,
              true,
              worker,
              worker_monitor,
              reply_ref,
              request,
              {:requester_down, reason},
              nil
            )
        after
          0 ->
            send(worker, {@guard_ready_tag, self(), :ok})

            watch_lifecycle(
              owner,
              owner_monitor,
              requester,
              requester_monitor,
              worker,
              worker_monitor,
              reply_ref,
              request,
              nil
            )
        end
      end)

    receive do
      {@guard_ready_tag, ^guard, :ok} -> {:ok, guard}
      {@guard_ready_tag, ^guard, :cancelled} -> {:cancelled, guard}
    after
      @worker_down_timeout_ms ->
        Process.exit(guard, :kill)
        {:error, :lifecycle_guard_unavailable}
    end
  end

  defp watch_lifecycle(
         owner,
         owner_monitor,
         requester,
         requester_monitor,
         worker,
         worker_monitor,
         reply_ref,
         request,
         authority_state
       ) do
    receive do
      {@guard_acquire_authority_tag, ^worker, security, agent_id, authority_ref} ->
        result = acquire_signing_authority(security, agent_id, self())

        next_authority_state =
          case result do
            {:ok, authority} -> {security, authority}
            _ -> authority_state
          end

        send(worker, {@guard_authority_reply_tag, authority_ref, result})

        watch_lifecycle(
          owner,
          owner_monitor,
          requester,
          requester_monitor,
          worker,
          worker_monitor,
          reply_ref,
          request,
          next_authority_state
        )

      {@guard_cancel_request_tag, ^owner, ^reply_ref, reason} ->
        cancel_guarded_worker(
          owner,
          true,
          worker,
          worker_monitor,
          reply_ref,
          request,
          reason,
          authority_state
        )

      {:DOWN, ^owner_monitor, :process, ^owner, reason} ->
        cancel_guarded_worker(
          owner,
          false,
          worker,
          worker_monitor,
          reply_ref,
          request,
          {:owner_down, reason},
          authority_state
        )

      {:DOWN, ^requester_monitor, :process, ^requester, reason} ->
        cancel_guarded_worker(
          owner,
          true,
          worker,
          worker_monitor,
          reply_ref,
          request,
          {:requester_down, reason},
          authority_state
        )

      {:DOWN, ^worker_monitor, :process, ^worker, _reason} ->
        _ = close_guard_authority(authority_state)
        Process.demonitor(owner_monitor, [:flush])
        Process.demonitor(requester_monitor, [:flush])
        :ok

      {@guard_done_tag, ^worker} ->
        _ = close_guard_authority(authority_state)
        Process.demonitor(owner_monitor, [:flush])
        Process.demonitor(requester_monitor, [:flush])
        Process.demonitor(worker_monitor, [:flush])
        :ok
    end
  end

  defp cancel_guarded_worker(
         owner,
         notify_owner?,
         worker,
         worker_monitor,
         reply_ref,
         request,
         reason,
         authority_state
       ) do
    if notify_owner? and Process.alive?(owner) do
      send(owner, {@guard_cancel_started_tag, reply_ref, self(), reason})
    end

    Process.exit(worker, :kill)
    worker_status = await_monitored_down(worker_monitor, worker)
    authority_status = close_guard_authority(authority_state)
    cleanup_status = bounded_approval_cleanup(request, :task_cancellation)

    if notify_owner? and Process.alive?(owner) do
      status =
        if worker_status == :ok and authority_status == :ok and cleanup_status == :ok,
          do: :ok,
          else: :unconfirmed

      send(owner, {@guard_cancel_done_tag, reply_ref, self(), status, reason})
    end
  end

  defp await_guard_cancellation(guard, reply_ref, monitor, _worker) do
    receive do
      {@guard_cancel_done_tag, ^reply_ref, ^guard, status, reason} ->
        Process.demonitor(monitor, [:flush])

        cancellation_result(status, reason)
    after
      @cancellation_grace_ms ->
        Process.demonitor(monitor, [:flush])
        {:error, {:candidate_verification_cancelled, :unconfirmed}}
    end
  end

  defp cancellation_result(:ok, :deadline), do: {:error, :candidate_verification_timeout}

  defp cancellation_result(:ok, _reason),
    do: {:error, {:candidate_verification_cancelled, :ok}}

  defp cancellation_result(_status, :deadline),
    do: {:error, :candidate_verification_cancellation_unconfirmed}

  defp cancellation_result(_status, _reason),
    do: {:error, {:candidate_verification_cancelled, :unconfirmed}}

  defp cancel_for_deadline(guard, _request, reply_ref, monitor, worker)
       when is_pid(guard) do
    send(guard, {@guard_cancel_request_tag, self(), reply_ref, :deadline})

    receive do
      {@guard_cancel_started_tag, ^reply_ref, ^guard, :deadline} ->
        await_guard_cancellation(guard, reply_ref, monitor, worker)
    after
      @worker_down_timeout_ms ->
        Process.demonitor(monitor, [:flush])
        {:error, :candidate_verification_cancellation_unconfirmed}
    end
  end

  defp cancel_for_deadline(_guard, request, _reply_ref, monitor, worker) do
    worker_status = terminate_worker(monitor, worker)
    cleanup_status = bounded_approval_cleanup(request, :task_cancellation)

    if worker_status == :ok and cleanup_status == :ok,
      do: {:error, :candidate_verification_timeout},
      else: {:error, :candidate_verification_cancellation_unconfirmed}
  end

  defp terminate_worker(monitor, worker) do
    Process.exit(worker, :kill)
    await_monitored_down(monitor, worker)
  end

  defp await_monitored_down(monitor, worker) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      @worker_down_timeout_ms ->
        Process.demonitor(monitor, [:flush])
        :unconfirmed
    end
  end

  defp finalize_worker_result({:ok, _report} = success, _request), do: success

  defp finalize_worker_result({:error, _reason} = error, request),
    do: cleanup_or_replace_error(error, request, :task_termination)

  defp finalize_worker_result(_other, request) do
    cleanup_or_replace_error(
      {:error, :operator_candidate_verification_failed},
      request,
      :task_termination
    )
  end

  defp cleanup_or_replace_error(error, request, reason) do
    case bounded_approval_cleanup(request, reason) do
      :ok -> error
      :unconfirmed -> {:error, :approval_cleanup_unconfirmed}
    end
  end

  defp bounded_approval_cleanup(request, reason) when is_map(request) do
    {pid, monitor} =
      spawn_monitor(fn ->
        exit({:approval_cleanup_result, cleanup_approvals(request, reason)})
      end)

    receive do
      {:DOWN, ^monitor, :process, ^pid, {:approval_cleanup_result, :ok}} ->
        :ok

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :unconfirmed
    after
      @approval_cleanup_timeout_ms ->
        Process.exit(pid, :kill)
        _ = await_monitored_down(monitor, pid)
        :unconfirmed
    end
  end

  defp bounded_approval_cleanup(_request, _reason), do: :unconfirmed

  defp cleanup_approvals(request, reason) do
    facade = Config.coding_reconciliation_approval_facade()

    cleanup_opts = [
      caller_id: request.agent_id,
      principal_id: request.agent_id,
      cleanup_reason: reason
    ]

    inventory_opts = [
      authorize?: false,
      caller_id: request.agent_id,
      task_id: request.task_id,
      principal_id: request.agent_id,
      principal_scope: :subject,
      max_items: 64
    ]

    with true <- is_atom(facade) and Code.ensure_loaded?(facade),
         true <- function_exported?(facade, :cleanup_approvals_for_task, 2),
         true <- function_exported?(facade, :pending_approval_inventory, 1),
         :ok <-
           apply(facade, :cleanup_approvals_for_task, [
             request.task_id,
             cleanup_opts
           ]),
         {:ok, inventory} <-
           apply(facade, :pending_approval_inventory, [inventory_opts]),
         :ok <- confirm_no_pending_approvals(inventory) do
      :ok
    else
      _ -> :unconfirmed
    end
  rescue
    _ -> :unconfirmed
  catch
    _, _ -> :unconfirmed
  end

  defp confirm_no_pending_approvals(inventory)
       when is_map(inventory) and not is_struct(inventory) do
    counts = Map.get(inventory, "counts")

    if Map.get(inventory, "truncated") == false and is_map(counts) and
         Map.get(counts, "matching") == 0 and
         Map.get(counts, "truncated", 0) == 0 and
         Map.get(counts, "backend_omitted", 0) == 0 and
         Map.get(counts, "quarantined", 0) == 0 do
      :ok
    else
      :unconfirmed
    end
  end

  defp confirm_no_pending_approvals(_inventory), do: :unconfirmed

  defp activate_workspace(%{observed_state: :retained} = workspace, request) do
    facade = workspace.facade

    with true <- function_exported?(facade, :reactivate_retained_coding_workspace, 3),
         {:ok, lease} <-
           apply(facade, :reactivate_retained_coding_workspace, [
             request.workspace_id,
             request.task_id,
             request.agent_id
           ]),
         true <- lease_identity_matches?(lease, workspace, request) do
      {:ok, "retained_reactivated"}
    else
      _ -> {:error, :retained_workspace_reactivation_failed}
    end
  rescue
    _ -> {:error, :retained_workspace_reactivation_failed}
  catch
    _, _ -> {:error, :retained_workspace_reactivation_failed}
  end

  defp lease_identity_matches?(lease, workspace, request)
       when is_map(lease) and not is_struct(lease) do
    map_value(lease, :workspace_id) == request.workspace_id and
      optional_lease_identity_matches?(lease, :task_id, request.task_id) and
      optional_lease_identity_matches?(lease, :principal_id, request.agent_id) and
      map_value(lease, :repo_path) == workspace.canonical_repo_path and
      map_value(lease, :worktree_path) == workspace.resource["worktree_path"]
  end

  defp lease_identity_matches?(_lease, _workspace, _request), do: false

  # The production Actions facade authorizes exact lineage arguments but omits
  # task/principal from its public lease view. A facade may return them, in which
  # case conflicting values still fail closed.
  defp optional_lease_identity_matches?(lease, key, expected) do
    case {Map.fetch(lease, key), Map.fetch(lease, Atom.to_string(key))} do
      {:error, :error} -> true
      {{:ok, ^expected}, :error} -> true
      {:error, {:ok, ^expected}} -> true
      _ -> false
    end
  end

  defp requester_available(monitor, requester) do
    receive do
      {:DOWN, ^monitor, :process, ^requester, _reason} ->
        {:error, :candidate_verification_cancelled}
    after
      0 -> :ok
    end
  end

  defp security_facade do
    security = Config.security_module()

    if is_atom(security) and Code.ensure_loaded?(security) and
         function_exported?(security, :load_signing_key, 1) and
         function_exported?(security, :build_signing_authority_acquisition_proof, 3) and
         function_exported?(security, :open_signing_authority, 1) and
         function_exported?(security, :close_signing_authority, 1) do
      {:ok, security}
    else
      {:error, :candidate_verification_unavailable}
    end
  end

  defp acquire_guarded_signing_authority(guard, security, agent_id) do
    authority_ref = make_ref()

    send(
      guard,
      {@guard_acquire_authority_tag, self(), security, agent_id, authority_ref}
    )

    receive do
      {@guard_authority_reply_tag, ^authority_ref, result} -> result
    after
      @approval_cleanup_timeout_ms -> {:error, :signing_authority_acquisition_failed}
    end
  end

  defp acquire_signing_authority(security, agent_id, owner) when is_pid(owner) do
    with {:ok, private_key} <- security.load_signing_key(agent_id),
         true <- is_binary(private_key) and private_key != "",
         {:ok, proof} <-
           security.build_signing_authority_acquisition_proof(
             agent_id,
             private_key,
             purpose: @authority_purpose,
             owner: owner
           ),
         {:ok, opened_authority} <- security.open_signing_authority(proof) do
      case SigningAuthority.canonicalize(opened_authority) do
        {:ok, %SigningAuthority{} = authority} ->
          {:ok, authority}

        {:error, _reason} ->
          _ = close_signing_authority(security, opened_authority)
          {:error, :signing_authority_acquisition_failed}
      end
    else
      false -> {:error, :invalid_signing_key}
      {:error, :no_signing_key} -> {:error, :no_signing_key}
      {:error, _reason} -> {:error, :signing_authority_acquisition_failed}
      _other -> {:error, :signing_authority_acquisition_failed}
    end
  rescue
    _exception ->
      {:error, :signing_authority_acquisition_failed}
  catch
    _kind, _reason -> {:error, :signing_authority_acquisition_failed}
  end

  defp close_guard_authority(authority_state) do
    {pid, monitor} =
      spawn_monitor(fn ->
        exit({:authority_close_result, do_close_guard_authority(authority_state)})
      end)

    receive do
      {:DOWN, ^monitor, :process, ^pid, {:authority_close_result, result}}
      when result in [:ok, :unconfirmed] ->
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :unconfirmed
    after
      @signing_authority_close_timeout_ms ->
        Process.exit(pid, :kill)
        _ = await_monitored_down(monitor, pid)
        :unconfirmed
    end
  end

  defp do_close_guard_authority(nil), do: :ok

  defp do_close_guard_authority({security, authority}) do
    case close_signing_authority(security, authority) do
      :ok -> :ok
      {:error, :authority_not_found} -> :ok
      {:error, _reason} -> :unconfirmed
    end
  end

  defp do_close_guard_authority(_authority_state), do: :unconfirmed

  defp verify_with_authority(
         security,
         authority,
         request,
         reviewed,
         workspace,
         workspace_lifecycle
       ) do
    invoke_and_close(
      security,
      authority,
      request,
      reviewed,
      workspace,
      workspace_lifecycle
    )
  rescue
    _exception -> {:error, :operator_candidate_verification_failed}
  catch
    :throw, {:operator_candidate_authority_close_failed, _reason} ->
      {:error, :signing_authority_close_failed}

    _kind, _reason ->
      {:error, :operator_candidate_verification_failed}
  end

  defp invoke_and_close(
         security,
         authority,
         request,
         reviewed,
         workspace,
         workspace_lifecycle
       ) do
    provenance =
      reviewed.provenance
      |> Map.merge(%{
        "version" => 1,
        "workspace_id" => request.workspace_id,
        "principal_id" => request.agent_id,
        "workspace_provenance_sha256" => workspace.provenance_sha256,
        "workspace_lifecycle" => workspace_lifecycle
      })

    request
    |> candidate(reviewed.validation_program)
    |> CandidateVerifier.verify(
      agent_id: request.agent_id,
      task_id: request.task_id,
      signing_authority: authority
    )
    |> normalize_verification_result(provenance)
  after
    ensure_authority_closed!(security, authority)
  end

  defp candidate(request, validation_program) do
    %{
      "workspace_id" => request.workspace_id,
      "validation_program" => validation_program
    }
    |> maybe_put("review_attestation_id", request.review_attestation_id)
  end

  defp normalize_verification_result({:ok, report}, provenance) do
    report
    |> Map.put("provenance", provenance)
    |> VerificationReport.normalize()
    |> case do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, :invalid_verification_report}
    end
  end

  defp normalize_verification_result({:error, _reason} = error, _provenance), do: error

  defp normalize_verification_result(_other, _provenance),
    do: {:error, :candidate_verification_failed}

  defp ensure_authority_closed!(security, authority) do
    case close_signing_authority(security, authority) do
      :ok -> :ok
      {:error, reason} -> throw({:operator_candidate_authority_close_failed, reason})
    end
  end

  defp close_signing_authority(security, authority) do
    case security.close_signing_authority(authority) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_close_result, other}}
    end
  rescue
    exception -> {:error, {:authority_close_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:authority_close_failed, {kind, reason}}}
  end

  defp agent_id(value) do
    with {:ok, value} <- bounded_id(value, :invalid_agent_id),
         true <- String.starts_with?(value, "agent_") and byte_size(value) > 6 do
      {:ok, value}
    else
      _other -> {:error, :invalid_agent_id}
    end
  end

  defp review_attestation_id(request) do
    case Map.fetch(request, "review_attestation_id") do
      :error -> {:ok, nil}
      {:ok, value} -> bounded_id(value, :invalid_review_attestation_id)
    end
  end

  defp bounded_id(value, error) do
    if safe_nonblank_text?(value, @max_id_bytes), do: {:ok, value}, else: {:error, error}
  end

  defp safe_nonblank_text?(value, maximum) do
    is_binary(value) and byte_size(value) > 0 and byte_size(value) <= maximum and
      String.valid?(value) and String.trim(value) == value and
      not String.contains?(value, <<0>>) and not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

  defp valid_sha256?(value),
    do: is_binary(value) and Regex.match?(@sha256_pattern, value)

  defp valid_work_packet_digest?(value),
    do: is_binary(value) and Regex.match?(@work_packet_digest_pattern, value)

  defp encode_canonical(value) do
    value
    |> canonicalize()
    |> Jason.encode()
  end

  defp canonicalize(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.sort_by(fn {key, _child} -> key end)
    |> Enum.map(fn {key, child} -> {key, canonicalize(child)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(value), do: value

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp remaining_ms(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    case {Map.fetch(map, key), Map.fetch(map, Atom.to_string(key))} do
      {{:ok, value}, :error} -> value
      {:error, {:ok, value}} -> value
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
