defmodule Arbor.Actions.Coding.CrossApp.Shell do
  @moduledoc """
  Imperative shell for cross-app dependency-surface validation.

  Resolves an authorized workspace lease, freezes the candidate committable tree
  (tracked survivors + nonignored untracked, deleted omitted, ignored private
  apps excluded) with exact `apps/*/mix.exs` bytes and a path/mode/blob
  manifest bound to the tree OID, loads the base-commit blob manifest + mix.exs
  via argv-safe Git plumbing at the validated full lease OID, derives
  `changed_files` by comparing those two immutable manifests (never a live
  worktree `git diff`), compares topology in pure Core, and runs compile →
  xref → test-env compile → focused (or full-candidate) tests via
  `Arbor.Actions.Mix.run_mix/3`.

  Candidate selection uses only freeze snapshot bytes and manifests — never a
  later worktree read (ABA / changed-path skew defense). The same tree OID is
  the validation before-binding and evidence `validated_tree_oid`.

  Each compile is one exact `mix compile --warnings-as-errors` child. Mix
  compiles attested deps into the fresh private `MIX_BUILD_PATH` via
  `deps.loadpaths` (the validation image includes git so Git lock-status
  succeeds against checkout `.git`). The test-environment invocation runs
  under owner-controlled `MIX_ENV=test`. Xref and test children pass
  `--no-deps-check` against that populated build. The aggregate app-test monotonic deadline
  starts only after that stage succeeds, so cold test-env compilation cannot
  consume the full test-stage budget.

  Selected app test directories are expanded via git `ls-files` plus
  `ls-files --others --exclude-standard` into a deterministic bounded list of
  exact `*_test.exs` files (ignored/generated paths never enter validation). The
  selected root, every listed file, and intermediate path components are
  lstat'd without following symlinks. Verified paths are then partitioned into
  pure Core batches (at most 20 exact test files per child, Shell argv ceiling
  minus three fixed args, and <=64 KiB of path+separator argument bytes) so the
  complete inventory is preserved across sequential children without excluding
  slow or integration-tagged files. Each batch runs as one argv-safe
  `mix test --no-deps-check -- <exact paths...>` under
  `min(per-operation intensive ceiling, remaining aggregate stage budget)`.
  Never passes raw directories or shell-joined globs.
  """

  alias Arbor.Actions.Coding.BlobManifest
  alias Arbor.Actions.Coding.CrossApp.Core
  alias Arbor.Actions.Coding.CrossApp.ContinuationExecutionCore
  alias Arbor.Actions.Coding.CrossApp.Parser
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Mix, as: MixAction
  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  # Align with CrossApp.Parser per-file source ceiling for base blob reads.
  @base_mix_exs_max_file_bytes 64_000
  # Full lowercase hex commit OIDs only (SHA-1 40 or SHA-256 64) — lease authority.
  @full_commit_oid_re ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/

  @doc "Execute cross-app validation against a leased workspace."
  @spec run(Core.input(), map()) :: {:ok, map()} | {:error, term()}
  def run(input, context) when is_map(input) and is_map(context) do
    try do
      do_run(input, context, stage_deadline(Map.get(input, :stage_timeout)))
    catch
      {:execution_error, reason} -> {:error, reason}
    end
  end

  def run(_input, _context), do: {:error, :invalid_cross_app_input}

  @doc false
  # Test seam: sequential batch test stage under dual budgets.
  # 3-arity uses the same value for per-operation and aggregate stage ceilings.
  @spec run_app_tests(String.t(), [String.t()], pos_integer()) :: map()
  def run_app_tests(worktree_path, test_paths, timeout)
      when is_binary(worktree_path) and is_list(test_paths) and is_integer(timeout) do
    run_app_tests(worktree_path, test_paths, timeout, timeout)
  end

  @doc false
  @spec run_app_tests(String.t(), [String.t()], pos_integer(), pos_integer()) :: map()
  def run_app_tests(worktree_path, test_paths, operation_timeout, test_stage_timeout)
      when is_binary(worktree_path) and is_list(test_paths) and is_integer(operation_timeout) and
             is_integer(test_stage_timeout) do
    {ordered_apps, ordered_test_dirs} =
      with {:ok, apps} <- app_ids_from_test_dirs(test_paths),
           {:ok, dirs} <- test_dirs_for_apps(apps) do
        {apps, dirs}
      else
        {:error, _reason} -> throw({:execution_error, {:invalid_test_dir, test_paths}})
      end

    run_tests(
      worktree_path,
      ordered_test_dirs,
      ordered_apps,
      operation_timeout,
      test_stage_timeout,
      nil,
      nil
    )
  end

  @doc false
  # Fail-closed test seam for Shell interpretation of Core execution state,
  # including intentionally malformed state maps.
  @spec run_test_execution(String.t(), map(), integer(), map() | nil) :: map()
  def run_test_execution(worktree_path, execution, deadline, resource \\ nil)
      when is_binary(worktree_path) and is_map(execution) and is_integer(deadline) and
             (is_map(resource) or is_nil(resource)) do
    run_tests_sequential(worktree_path, execution, deadline, resource)
  end

  @doc false
  # Test seam: full compile → xref → test-compile → tests pipeline without lease setup.
  # Single timeout applies to per-operation and aggregate stage budgets.
  @spec run_validation_checks(String.t(), [String.t()], pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def run_validation_checks(worktree_path, test_paths, timeout)
      when is_binary(worktree_path) and is_list(test_paths) and is_integer(timeout) do
    run_validation_checks(worktree_path, %{test_paths: test_paths}, timeout, timeout, nil)
  end

  @doc false
  # 4-arity: either (timeout, resource) or (operation_timeout, test_stage_timeout).
  @spec run_validation_checks(String.t(), [String.t()], pos_integer(), map() | pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def run_validation_checks(worktree_path, test_paths, timeout, resource)
      when is_binary(worktree_path) and is_list(test_paths) and is_integer(timeout) and
             (is_map(resource) or is_nil(resource)) do
    run_validation_checks(worktree_path, %{test_paths: test_paths}, timeout, timeout, resource)
  end

  def run_validation_checks(worktree_path, test_paths, operation_timeout, test_stage_timeout)
      when is_binary(worktree_path) and is_list(test_paths) and is_integer(operation_timeout) and
             is_integer(test_stage_timeout) do
    run_validation_checks(
      worktree_path,
      %{test_paths: test_paths},
      operation_timeout,
      test_stage_timeout,
      nil
    )
  end

  @doc false
  @spec run_validation_checks(
          String.t(),
          map() | [String.t()],
          pos_integer(),
          pos_integer(),
          map() | nil
        ) ::
          {:ok, map()} | {:error, term()}
  def run_validation_checks(
        worktree_path,
        test_paths,
        operation_timeout,
        test_stage_timeout,
        resource
      )
      when is_binary(worktree_path) and is_list(test_paths) and is_integer(operation_timeout) and
             is_integer(test_stage_timeout) and (is_map(resource) or is_nil(resource)) do
    run_validation_checks(
      worktree_path,
      %{test_paths: test_paths},
      operation_timeout,
      test_stage_timeout,
      resource
    )
  end

  def run_validation_checks(
        worktree_path,
        selection,
        operation_timeout,
        test_stage_timeout,
        resource
      )
      when is_binary(worktree_path) and is_map(selection) and is_integer(operation_timeout) and
             is_integer(test_stage_timeout) and (is_map(resource) or is_nil(resource)) do
    try do
      run_checks(worktree_path, selection, operation_timeout, test_stage_timeout, nil, resource)
    catch
      {:execution_error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec run_validation_checks(
          String.t(),
          map() | [String.t()],
          pos_integer(),
          pos_integer(),
          pos_integer(),
          map() | nil
        ) ::
          {:ok, map()} | {:error, term()}
  def run_validation_checks(
        worktree_path,
        test_paths,
        operation_timeout,
        test_stage_timeout,
        stage_timeout,
        resource
      )
      when is_binary(worktree_path) and is_list(test_paths) and is_integer(operation_timeout) and
             is_integer(test_stage_timeout) and is_integer(stage_timeout) and
             (is_map(resource) or is_nil(resource)) do
    run_validation_checks(
      worktree_path,
      %{test_paths: test_paths},
      operation_timeout,
      test_stage_timeout,
      stage_timeout,
      resource
    )
  end

  def run_validation_checks(
        worktree_path,
        selection,
        operation_timeout,
        test_stage_timeout,
        stage_timeout,
        resource
      )
      when is_binary(worktree_path) and is_map(selection) and is_integer(operation_timeout) and
             is_integer(test_stage_timeout) and is_integer(stage_timeout) and
             (is_map(resource) or is_nil(resource)) do
    try do
      run_checks(
        worktree_path,
        selection,
        operation_timeout,
        test_stage_timeout,
        stage_deadline(stage_timeout),
        resource
      )
    catch
      {:execution_error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec resolve_selection(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resolve_selection(worktree_path, base_commit)
      when is_binary(worktree_path) and is_binary(base_commit) do
    # Selection authority is dual immutable snapshots only:
    # 1) candidate freeze (tree_oid + staged app_mix_exs + blob_manifest)
    # 2) base-commit ls-tree blob manifest
    # Never list_changed_files against the mutable worktree after/before freeze.
    with :ok <- validate_full_commit_oid(base_commit),
         {:ok, freeze} <- MixAction.committable_app_mix_inventory(worktree_path),
         :ok <- invoke_after_candidate_freeze_hook(worktree_path, freeze),
         {:ok, base_manifest} <- load_base_blob_manifest(worktree_path, base_commit),
         {:ok, changed_files} <-
           Core.diff_blob_manifests(base_manifest, Map.fetch!(freeze, :blob_manifest)),
         {:ok, base_sources} <- load_base_mix_exs(worktree_path, base_commit),
         {:ok, base_defs} <- Parser.parse_many(base_sources),
         {:ok, cand_defs} <- Parser.parse_many(Map.fetch!(freeze, :app_mix_exs)),
         {:ok, base_graph} <- Core.build_graph(base_defs),
         {:ok, cand_graph} <- Core.build_graph(cand_defs),
         {:ok, selection} <- Core.select_revisions(changed_files, base_graph, cand_graph) do
      {:ok,
       %{
         selection: selection,
         candidate_tree_oid: freeze.tree_oid,
         candidate_head: freeze.head,
         # Test/diagnostic only: exact freeze sources (not emitted in evidence).
         candidate_app_mix_exs: freeze.app_mix_exs,
         # Test/diagnostic only: immutable freeze path set for skew proofs.
         # Never copied into Core.show / feedback_json evidence.
         candidate_blob_manifest: freeze.blob_manifest
       }}
    end
  end

  def resolve_selection(_, _), do: {:error, :invalid_resolve_selection_input}

  # Test-only seam (Application env `:cross_app_after_committable_snapshot`).
  # Production default is nil. Tests may install a 1-arity fun
  # `(snapshot_path) -> :ok` that mutates the owner-issued snapshot after
  # materialize and before suffix execution / empty-suffix finalization.
  defp invoke_after_committable_snapshot_hook(snapshot_path)
       when is_binary(snapshot_path) and snapshot_path != "" do
    case Application.get_env(:arbor_actions, :cross_app_after_committable_snapshot) do
      nil ->
        :ok

      fun when is_function(fun, 1) ->
        case fun.(snapshot_path) do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:after_committable_snapshot_hook_failed, reason}}
          other -> {:error, {:after_committable_snapshot_hook_invalid_return, other}}
        end

      other ->
        {:error, {:invalid_after_committable_snapshot_hook, other}}
    end
  end

  # Test-only seam (Application env `:cross_app_after_candidate_freeze`).
  # Production default is nil — no hook, no behavior change. Tests may install
  # a 2-arity fun `(worktree_path, freeze) -> :ok` that mutates the worktree
  # immediately after the candidate freeze is captured, proving selection uses
  # only the held freeze (app_mix_exs + blob_manifest), not later disk state.
  defp invoke_after_candidate_freeze_hook(worktree_path, freeze)
       when is_binary(worktree_path) and is_map(freeze) do
    case Application.get_env(:arbor_actions, :cross_app_after_candidate_freeze) do
      nil ->
        :ok

      fun when is_function(fun, 2) ->
        case fun.(worktree_path, freeze) do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:after_candidate_freeze_hook_failed, reason}}
          other -> {:error, {:after_candidate_freeze_hook_invalid_return, other}}
        end

      other ->
        {:error, {:invalid_after_candidate_freeze_hook, other}}
    end
  end

  defp do_run(input, context, validation_deadline) do
    grant = Arbor.Actions.live_coding_cross_app_continuation_grant()
    legacy = Arbor.Actions.legacy_coding_cross_app_continuation_marker()

    case {grant, legacy} do
      {{:ok, live_grant}, _legacy} ->
        if continuation_grant_matches?(live_grant, input) do
          do_run_bound(input, live_grant, validation_deadline)
        else
          {:error, :continuation_execution_unauthorized}
        end

      {:none, nil} ->
        do_run_unbound(input, context, validation_deadline)

      {:none, _forged} ->
        {:error, :continuation_execution_unauthorized}
    end
  end

  defp continuation_grant_matches?(grant, input) do
    grant.action == Arbor.Actions.Coding.CrossApp.Validate and
      grant.workspace_id == input.workspace_id and
      grant.status == :attached
  end

  # Keep the ordinary action path isolated from continuation execution. In
  # particular it retains owner/context lease fallback and the exact historical
  # compile -> xref -> test_compile -> tests behavior.
  defp do_run_unbound(input, context, validation_deadline) do
    with {:ok, lease} <- resolve_lease(input.workspace_id, context),
         {:ok, worktree_path, base_commit} <- lease_paths(lease),
         # One candidate freeze: tree OID + staged app mix.exs bytes for selection.
         {:ok, resolved} <- resolve_selection(worktree_path, base_commit) do
      selection = resolved.selection

      before_binding = %{
        head: resolved.candidate_head,
        tree_oid: resolved.candidate_tree_oid
      }

      with {:ok, checks} <-
             MixAction.with_validation_resource(
               input.workspace_id,
               context,
               fn resource ->
                 run_checks(
                   worktree_path,
                   selection,
                   input.timeout,
                   input.test_stage_timeout,
                   validation_deadline,
                   resource
                 )
               end,
               validation_resource_opts(input.timeout, validation_deadline)
             ),
           {:ok, after_binding} <- MixAction.committable_tree_binding(worktree_path),
           :ok <- assert_validation_tree_stable(before_binding, after_binding) do
        evidence =
          Core.show(%{
            selection: selection,
            checks: checks,
            base_commit: base_commit
          })
          |> Map.put(:validated_tree_oid, before_binding.tree_oid)
          |> Map.put(:validated_head, before_binding.head)

        feedback_json = Jason.encode!(evidence)
        {:ok, Map.put(evidence, :feedback_json, feedback_json)}
      end
    end
  end

  defp do_run_bound(input, grant, validation_deadline) do
    with :ok <- Arbor.Actions.recheck_coding_cross_app_continuation_execution(),
         {:ok, admitted_window} <-
           ContinuationExecutionCore.admit_execution_window(grant.window, grant.receipt),
         :ok <- match_grant_window(grant, admitted_window) do
      execute_admitted_continuation(
        input,
        grant,
        admitted_window,
        grant.receipt,
        validation_deadline
      )
    else
      {:error, :continuation_execution_unauthorized} = error -> error
      {:error, :execution_grant_expired} -> {:error, :continuation_execution_unauthorized}
      {:error, :witness_unbound} -> {:error, :continuation_execution_unauthorized}
      {:error, _reason} -> {:error, :continuation_execution_unauthorized}
    end
  end

  defp match_grant_window(grant, window) do
    identities = window["identities"]

    if grant.continuation_id == window["continuation_id"] and
         grant.task_id == identities["task_id"] and
         grant.principal_id == identities["principal_id"] and
         grant.fence_generation == window["fence_generation"] and
         grant.expires_at == window["expires_at"] do
      :ok
    else
      {:error, :continuation_execution_unauthorized}
    end
  end

  defp execute_admitted_continuation(input, grant, window, receipt, validation_deadline) do
    result =
      with :ok <- Arbor.Actions.recheck_coding_cross_app_continuation_execution(),
           {:ok, lease} <-
             resolve_lease_by_lineage(grant.workspace_id, grant.task_id, grant.principal_id),
           {:ok, worktree_path, base_commit} <- lease_paths(lease),
           {:ok, base_tree_oid} <- commit_tree_oid(worktree_path, base_commit),
           {:ok, resolved} <- resolve_selection(worktree_path, base_commit),
           {:ok, prepared} <-
             prepare_continuation_batches(
               resolved.selection,
               resolved.candidate_blob_manifest
             ),
           {:ok, compact_plan} <- Core.compact_batch_plan(prepared.batches),
           {:ok, configuration_digest} <- Core.configuration_digest(input),
           {:ok, validation_plan_digest} <-
             ValidationCapacityHandoff.ordered_plan_digest(compact_plan),
           :ok <-
             match_continuation_execution(
               window,
               compact_plan,
               configuration_digest,
               validation_plan_digest,
               base_commit,
               base_tree_oid,
               resolved,
               input.timeout
             ) do
        before_binding = %{
          head: resolved.candidate_head,
          tree_oid: resolved.candidate_tree_oid,
          blob_manifest: resolved.candidate_blob_manifest
        }

        run_continuation_suffix(
          input,
          window,
          receipt,
          worktree_path,
          prepared.batches,
          before_binding,
          validation_deadline,
          window["per_batch_budget_ms"]
        )
      end

    case result do
      {:ok, progress} ->
        {:ok, progress}

      {:error, reason} ->
        continuation_failed_progress(window, receipt, [], failure_reason(reason))
    end
  rescue
    _ -> continuation_failed_progress(window, receipt, [], "validation_infrastructure_failed")
  catch
    _, _ -> continuation_failed_progress(window, receipt, [], "validation_infrastructure_failed")
  end

  defp resolve_lease_by_lineage(workspace_id, task_id, principal_id) do
    case WorkspaceLeaseRegistry.inspect_lease_by_lineage(
           workspace_id,
           task_id,
           principal_id
         ) do
      {:ok, lease} -> {:ok, lease}
      {:error, :not_found} -> {:error, :workspace_not_found}
      {:error, :unauthorized} -> {:error, :workspace_unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_tree_oid(worktree_path, commit) do
    with :ok <- validate_full_commit_oid(commit),
         {:ok, output} <- git(worktree_path, ["rev-parse", "--verify", "#{commit}^{tree}"]),
         oid <- String.trim(output),
         :ok <- validate_full_commit_oid(oid) do
      {:ok, oid}
    else
      _ -> {:error, :base_tree_oid_unavailable}
    end
  end

  defp prepare_continuation_batches(selection, candidate_blob_manifest) do
    with {:ok, normalized} <- normalize_selection(selection),
         {:ok, ordered_apps} <- execution_ordered_apps(normalized),
         {:ok, test_dirs} <- test_dirs_for_apps(ordered_apps),
         {:ok, files} <-
           frozen_test_files(candidate_blob_manifest, test_dirs, ordered_apps),
         {:ok, batches} <- Core.partition_test_batches(files, ordered_apps) do
      {:ok, %{ordered_apps: ordered_apps, test_dirs: test_dirs, batches: batches}}
    end
  end

  defp match_continuation_execution(
         window,
         compact_plan,
         configuration_digest,
         validation_plan_digest,
         base_commit,
         base_tree_oid,
         resolved,
         operation_timeout
       ) do
    identities = window["identities"]

    independently_derived = [
      {window["planned_batches"], compact_plan},
      {identities["validation_plan_digest"], validation_plan_digest},
      {identities["configuration_digest"], configuration_digest},
      {identities["base_commit"], base_commit},
      {identities["base_tree_oid"], base_tree_oid},
      {identities["candidate_head"], resolved.candidate_head},
      {identities["candidate_tree_oid"], resolved.candidate_tree_oid},
      {identities["validator_id"], "coding_cross_app_validate"},
      {window["per_batch_budget_ms"], operation_timeout}
    ]

    if Enum.all?(independently_derived, fn {known, derived} -> known === derived end),
      do: :ok,
      else: {:error, :continuation_identity_drift}
  end

  defp run_continuation_suffix(
         input,
         window,
         receipt,
         worktree_path,
         full_batches,
         before_binding,
         validation_deadline,
         operation_timeout
       ) do
    accepted_count = length(window["accepted_receipts"])
    suffix = Enum.drop(full_batches, accepted_count)

    case Arbor.Actions.recheck_coding_cross_app_continuation_execution() do
      :ok ->
        run_continuation_resource_suffix(
          input,
          window,
          receipt,
          worktree_path,
          full_batches,
          suffix,
          accepted_count,
          before_binding,
          validation_deadline,
          operation_timeout
        )

      {:error, _reason} ->
        continuation_failed_progress(
          window,
          receipt,
          [],
          "validation_infrastructure_failed"
        )
    end
  end

  defp run_continuation_resource_suffix(
         input,
         window,
         receipt,
         worktree_path,
         full_batches,
         suffix,
         accepted_count,
         before_binding,
         validation_deadline,
         operation_timeout
       ) do
    MixAction.with_validation_resource(
      input.workspace_id,
      %{
        task_id: window["identities"]["task_id"],
        agent_id: window["identities"]["principal_id"]
      },
      fn resource ->
        snapshot_path =
          Map.get(resource, :candidate_path) || Map.get(resource, "candidate_path")

        cond do
          not is_binary(snapshot_path) or snapshot_path == "" ->
            continuation_failed_progress(
              window,
              receipt,
              [],
              "validation_infrastructure_failed"
            )

          snapshot_path == worktree_path ->
            continuation_failed_progress(
              window,
              receipt,
              [],
              "validation_infrastructure_failed"
            )

          true ->
            with :ok <- invoke_after_committable_snapshot_hook(snapshot_path),
                 {:ok, observation} <-
                   execute_continuation_tests(
                     input.test_stage_timeout,
                     operation_timeout,
                     snapshot_path,
                     full_batches,
                     suffix,
                     accepted_count,
                     validation_deadline,
                     resource
                   ) do
              finalize_continuation_observation(
                observation,
                window,
                receipt,
                snapshot_path,
                before_binding,
                resource
              )
            else
              {:error, reason} ->
                continuation_failed_progress(window, receipt, [], failure_reason(reason))
            end
        end
      end,
      validation_resource_opts(operation_timeout, validation_deadline) ++
        [
          committable_snapshot: true,
          expected_tree_oid: before_binding.tree_oid,
          expected_head: before_binding.head,
          blob_manifest: Map.get(before_binding, :blob_manifest)
        ]
    )
  end

  defp execute_continuation_tests(
         _test_stage_timeout,
         _operation_timeout,
         _worktree_path,
         _full_batches,
         [],
         _accepted_count,
         _validation_deadline,
         _resource
       ) do
    {:ok, %{new_receipts: [], disposition: %{"type" => "completed"}}}
  end

  defp execute_continuation_tests(
         test_stage_timeout,
         operation_timeout,
         worktree_path,
         full_batches,
         suffix,
         accepted_count,
         validation_deadline,
         resource
       ) do
    {available_ms, test_deadline} =
      validation_test_budget(test_stage_timeout, validation_deadline)

    reserve_ms = MixAction.postflight_tree_binding_reserve_ms()

    case Core.admit_test_batches(suffix, available_ms, operation_timeout, reserve_ms) do
      :ok ->
        deadline = test_deadline || monotonic_ms() + test_stage_timeout

        with {:ok, execution} <- Core.new_test_execution(suffix, operation_timeout, reserve_ms) do
          continue_continuation_tests(
            worktree_path,
            execution,
            deadline,
            resource,
            full_batches,
            accepted_count,
            []
          )
        end

      {:capacity_exceeded, _check} ->
        continuation_capacity_observation(
          full_batches,
          accepted_count,
          [],
          nil,
          suffix,
          operation_timeout,
          []
        )

      {:error, reason} ->
        continuation_failure_observation([], failure_reason(reason))
    end
  end

  defp continue_continuation_tests(
         worktree_path,
         execution,
         deadline,
         resource,
         full_batches,
         accepted_count,
         receipts
       ) do
    remaining_ms = deadline - monotonic_ms()

    case Core.next_test_execution_step(execution, remaining_ms) do
      {:complete, _check} ->
        case after_continuation_child(resource) do
          :ok ->
            {:ok, %{new_receipts: receipts, disposition: %{"type" => "completed"}}}

          {:error, reason} ->
            continuation_failure_observation(receipts, failure_reason(reason))
        end

      {:capacity, completed, interrupted, unstarted} ->
        continuation_capacity_observation(
          full_batches,
          accepted_count,
          completed,
          interrupted,
          unstarted,
          execution.operation_timeout,
          receipts
        )

      {:run, attempt, budget_ms} ->
        opts =
          [timeout: budget_ms]
          |> Keyword.put(:validation_resource, resource)

        case run_mix(worktree_path, MixAction.test_argv(attempt.paths), opts) do
          {:ok, result} ->
            case after_continuation_child(resource) do
              :ok ->
                feedback = Core.feedback_from_result(result)

                case Core.record_test_execution_attempt(
                       execution,
                       attempt,
                       feedback,
                       Core.runner_timed_out?(result),
                       budget_ms,
                       deadline - monotonic_ms()
                     ) do
                  {:continue, next} ->
                    with {:ok, next_receipts} <-
                           collect_completed_receipts(execution, next, receipts) do
                      continue_continuation_tests(
                        worktree_path,
                        next,
                        deadline,
                        resource,
                        full_batches,
                        accepted_count,
                        next_receipts
                      )
                    end

                  {:terminal, check} ->
                    {:ok,
                     %{
                       new_receipts: receipts,
                       disposition: %{
                         "type" => "failed",
                         "reason" => check["reason"] || "tests_failed"
                       }
                     }}

                  {:capacity, completed, interrupted, unstarted} ->
                    with {:ok, completed_receipts} <-
                           collect_receipts_from_completed(completed, receipts) do
                      continuation_capacity_observation(
                        full_batches,
                        accepted_count,
                        completed,
                        interrupted,
                        unstarted,
                        execution.operation_timeout,
                        completed_receipts
                      )
                    end

                  {:error, reason} ->
                    continuation_failure_observation(receipts, failure_reason(reason))
                end

              {:error, reason} ->
                continuation_failure_observation(receipts, failure_reason(reason))
            end

          {:error, reason} ->
            case after_continuation_child(resource) do
              {:error, recapture_reason} ->
                continuation_failure_observation(receipts, failure_reason(recapture_reason))

              :ok ->
                case Core.record_test_execution_prelaunch_error(
                       execution,
                       reason,
                       deadline - monotonic_ms()
                     ) do
                  {:capacity, completed, interrupted, unstarted} ->
                    continuation_capacity_observation(
                      full_batches,
                      accepted_count,
                      completed,
                      interrupted,
                      unstarted,
                      execution.operation_timeout,
                      receipts
                    )

                  {:execution_error, error} ->
                    continuation_failure_observation(receipts, failure_reason(error))

                  {:error, error} ->
                    continuation_failure_observation(receipts, failure_reason(error))
                end
            end
        end

      {:error, reason} ->
        continuation_failure_observation(receipts, failure_reason(reason))
    end
  end

  defp after_continuation_child(resource) do
    with :ok <- Arbor.Actions.recheck_coding_cross_app_continuation_execution(),
         :ok <- MixAction.recapture_committable_snapshot(resource) do
      :ok
    end
  end

  defp collect_completed_receipts(before, after_state, receipts) do
    newly_completed =
      Enum.drop(after_state.completed_originals, length(before.completed_originals))

    Enum.reduce_while(newly_completed, {:ok, receipts}, fn batch, {:ok, acc} ->
      case Core.passed_batch_receipt(batch) do
        {:ok, receipt} -> {:cont, {:ok, acc ++ [receipt]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp collect_receipts_from_completed(completed, receipts) do
    completed
    |> Enum.drop(length(receipts))
    |> Enum.reduce_while({:ok, receipts}, fn batch, {:ok, acc} ->
      case Core.passed_batch_receipt(batch) do
        {:ok, receipt} -> {:cont, {:ok, acc ++ [receipt]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp continuation_capacity_observation(
         full_batches,
         accepted_count,
         completed,
         interrupted,
         unstarted,
         operation_timeout,
         receipts
       ) do
    prior = Enum.take(full_batches, accepted_count)

    case Core.capacity_handoff(
           :runtime,
           0,
           operation_timeout,
           prior ++ completed,
           interrupted,
           unstarted
         ) do
      {:ok, check} ->
        {:ok,
         %{
           new_receipts: receipts,
           disposition: %{
             "type" => "capacity_handoff",
             "capacity_handoff" => check["capacity_handoff"]
           }
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finalize_continuation_observation(
         observation,
         window,
         receipt,
         worktree_path,
         before_binding,
         resource
       ) do
    observation =
      case verify_final_continuation_tree(worktree_path, before_binding, resource) do
        :ok ->
          observation

        {:error, :validation_tree_mutated} ->
          %{
            observation
            | new_receipts: [],
              disposition: %{"type" => "failed", "reason" => "validation_tree_mutated"}
          }

        {:error, _reason} ->
          %{
            observation
            | new_receipts: [],
              disposition: %{
                "type" => "failed",
                "reason" => "validation_infrastructure_failed"
              }
          }
      end

    ContinuationExecutionCore.new_progress(
      window,
      receipt,
      %{
        "new_receipts" => observation.new_receipts,
        "disposition" => observation.disposition
      }
    )
  end

  defp verify_final_continuation_tree(_worktree_path, _before_binding, resource)
       when is_map(resource) do
    after_continuation_child(resource)
  end

  defp verify_final_continuation_tree(_worktree_path, _before_binding, _resource),
    do: {:error, :validation_resource_required}

  defp continuation_failed_progress(window, receipt, receipts, reason) do
    ContinuationExecutionCore.new_progress(window, receipt, %{
      "new_receipts" => receipts,
      "disposition" => %{"type" => "failed", "reason" => reason}
    })
  end

  defp continuation_failure_observation(receipts, reason) do
    {:ok,
     %{
       new_receipts: receipts,
       disposition: %{"type" => "failed", "reason" => reason}
     }}
  end

  # Stable, path-free progress vocabulary. Infrastructure details remain in
  # local logs/errors and never enter durable continuation progress.
  defp failure_reason(:validation_tree_mutated), do: "validation_tree_mutated"
  defp failure_reason({:validation_stage_timeout, _}), do: "validation_stage_timeout"
  defp failure_reason(_), do: "validation_infrastructure_failed"

  defp assert_validation_tree_stable(%{tree_oid: before}, %{tree_oid: after_oid})
       when is_binary(before) and before != "" and before == after_oid,
       do: :ok

  defp assert_validation_tree_stable(_before, _after),
    do: {:error, :validation_tree_mutated}

  defp resolve_lease(workspace_id, context) do
    caller = %{
      task_id: Workspace.context_task_id(context),
      principal_id: Workspace.context_principal_id(context)
    }

    case WorkspaceLeaseRegistry.inspect_lease(workspace_id, caller) do
      {:ok, lease} -> {:ok, lease}
      {:error, :not_found} -> {:error, :workspace_not_found}
      {:error, :unauthorized} -> {:error, :workspace_unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lease_paths(lease) when is_map(lease) do
    worktree = map_value(lease, :worktree_path)
    base = map_value(lease, :base_commit)

    cond do
      not is_binary(worktree) or worktree == "" ->
        {:error, :missing_worktree_path}

      not File.dir?(worktree) ->
        {:error, :worktree_missing}

      not is_binary(base) or base == "" ->
        {:error, :missing_base_commit}

      true ->
        {:ok, worktree, base}
    end
  end

  defp validate_full_commit_oid(oid) when is_binary(oid) do
    if Regex.match?(@full_commit_oid_re, oid) do
      :ok
    else
      {:error, :invalid_base_commit_oid}
    end
  end

  defp validate_full_commit_oid(_), do: {:error, :invalid_base_commit_oid}

  # Immutable base revision path/mode/blob manifest (commit tree only).
  defp load_base_blob_manifest(worktree_path, base_commit)
       when is_binary(worktree_path) and is_binary(base_commit) do
    with :ok <- validate_full_commit_oid(base_commit),
         {:ok, listing} <- git(worktree_path, ["ls-tree", "-r", "-z", base_commit]) do
      BlobManifest.parse_ls_tree_z(listing)
    else
      {:error, reason} -> {:error, {:base_blob_manifest_failed, reason}}
    end
  end

  defp load_base_blob_manifest(_, _), do: {:error, :invalid_base_blob_manifest_input}

  # Base inventory: commit-bound tree only. Never File.read the mutable worktree.
  # Requires a validated full lease base OID — no short-OID cat-file fallback.
  defp load_base_mix_exs(worktree_path, base_commit)
       when is_binary(worktree_path) and is_binary(base_commit) do
    with :ok <- validate_full_commit_oid(base_commit),
         {:ok, listing} <-
           git(worktree_path, ["ls-tree", "-r", "-z", "--name-only", base_commit, "--", "apps"]),
         paths <-
           listing
           |> split_z()
           |> Enum.map(&String.trim/1)
           |> Enum.reject(&(&1 == ""))
           |> Enum.filter(&base_mix_exs_path?/1)
           |> Enum.uniq()
           |> Enum.sort() do
      if length(paths) > Core.max_apps() do
        {:error, :too_many_mix_exs_files}
      else
        Enum.reduce_while(paths, {:ok, []}, fn rel, {:ok, acc} ->
          case app_dir_for_mix_exs(rel) do
            {:ok, dir} ->
              case read_base_mix_exs_blob(worktree_path, base_commit, rel) do
                {:ok, source} ->
                  {:cont, {:ok, [{dir, source} | acc]}}

                {:error, reason} ->
                  {:halt, {:error, {:base_mix_exs_read_failed, rel, reason}}}
              end

            :error ->
              {:halt, {:error, {:invalid_mix_exs_path, rel}}}
          end
        end)
        |> case do
          {:ok, entries} -> {:ok, Enum.reverse(entries)}
          {:error, _} = error -> error
        end
      end
    else
      {:error, reason} -> {:error, {:base_mix_inventory_failed, reason}}
    end
  end

  defp load_base_mix_exs(_, _), do: {:error, :invalid_base_mix_inventory_input}

  defp base_mix_exs_path?(path) when is_binary(path) do
    match?({:ok, _}, app_dir_for_mix_exs(path))
  end

  defp base_mix_exs_path?(_), do: false

  defp read_base_mix_exs_blob(worktree_path, base_commit, rel_path) do
    # Production base authority is the validated full lease OID only. Argv-safe
    # cat-file with discrete arguments — never shell strings, never short OIDs.
    with :ok <- validate_full_commit_oid(base_commit),
         :ok <- validate_base_blob_relpath(rel_path) do
      case git(worktree_path, ["cat-file", "-p", base_commit <> ":" <> rel_path]) do
        {:ok, source} when byte_size(source) <= @base_mix_exs_max_file_bytes ->
          {:ok, source}

        {:ok, _oversized} ->
          {:error, :app_mix_exs_too_large}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_base_blob_relpath(path) when is_binary(path) do
    cond do
      path == "" or String.contains?(path, <<0>>) ->
        {:error, :invalid_blob_path}

      String.starts_with?(path, "/") or String.contains?(path, "..") ->
        {:error, :invalid_blob_path}

      true ->
        :ok
    end
  end

  defp validate_base_blob_relpath(_), do: {:error, :invalid_blob_path}

  defp app_dir_for_mix_exs(path) do
    case Path.split(path) do
      ["apps", dir, "mix.exs"] when dir != "" ->
        case Core.normalize_app_id(dir) do
          {:ok, normalized} -> {:ok, normalized}
          {:error, _} -> :error
        end

      _ ->
        :error
    end
  end

  defp run_checks(
         worktree_path,
         selection,
         operation_timeout,
         test_stage_timeout,
         validation_deadline,
         resource
       ) do
    with {:ok, normalized_selection} <- normalize_selection(selection),
         {:ok, ordered_apps} <- execution_ordered_apps(normalized_selection),
         {:ok, ordered_test_dirs} <- test_dirs_for_apps(ordered_apps) do
      run_prepared_checks(
        worktree_path,
        ordered_test_dirs,
        ordered_apps,
        operation_timeout,
        test_stage_timeout,
        validation_deadline,
        resource
      )
    else
      {:error, reason} -> {:error, {:invalid_validation_selection, reason}}
    end
  end

  defp run_prepared_checks(
         worktree_path,
         ordered_test_dirs,
         ordered_apps,
         operation_timeout,
         test_stage_timeout,
         validation_deadline,
         resource
       ) do
    compile = run_compile(worktree_path, operation_timeout, validation_deadline, resource)

    if compile["passed"] do
      xref = run_xref(worktree_path, operation_timeout, validation_deadline, resource)

      if xref["passed"] do
        test_compile =
          run_test_compile(worktree_path, operation_timeout, validation_deadline, resource)

        test =
          if test_compile["passed"] do
            # Aggregate test-stage budget starts only after MIX_ENV=test compile.
            run_tests(
              worktree_path,
              ordered_test_dirs,
              ordered_apps,
              operation_timeout,
              test_stage_timeout,
              validation_deadline,
              resource
            )
          else
            Core.skipped_check("test_compile_failed")
          end

        {:ok, %{compile: compile, xref: xref, test_compile: test_compile, test: test}}
      else
        {:ok,
         %{
           compile: compile,
           xref: xref,
           test_compile: Core.skipped_check("xref_failed"),
           test: Core.skipped_check("xref_failed")
         }}
      end
    else
      {:ok,
       %{
         compile: compile,
         xref: Core.skipped_check("compile_failed"),
         test_compile: Core.skipped_check("compile_failed"),
         test: Core.skipped_check("compile_failed")
       }}
    end
  end

  defp normalize_selection(selection) when is_map(selection) do
    with {:ok, changed_files} <- selection_list(selection, :changed_files),
         {:ok, test_paths} <- selection_list(selection, :test_paths),
         {:ok, changed_apps} <- selection_app_list(selection, :changed_apps),
         {:ok, affected_apps} <- selection_app_list(selection, :affected_apps),
         {:ok, root_wide} <- selection_root_wide(selection) do
      {:ok,
       %{
         changed_files: changed_files,
         changed_apps: changed_apps,
         affected_apps: affected_apps,
         test_paths: test_paths,
         root_wide: root_wide
       }}
    end
  end

  defp normalize_selection(_selection), do: {:error, :invalid_selection}

  defp selection_list(selection, key) when is_map(selection) do
    case map_value(selection, key) do
      nil -> {:ok, []}
      list when is_list(list) -> {:ok, list}
      _ -> {:error, {:invalid_selection_list, key}}
    end
  end

  defp selection_app_list(selection, key) when is_map(selection) do
    with {:ok, app_ids} <- selection_list(selection, key),
         {:ok, normalized} <- Core.normalize_app_ids(app_ids) do
      {:ok, normalized}
    end
  end

  defp selection_root_wide(selection) when is_map(selection) do
    case map_value(selection, :root_wide) do
      nil -> {:ok, false}
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, :invalid_root_wide}
    end
  end

  defp execution_ordered_apps(selection) when is_map(selection) do
    changed_apps = Map.fetch!(selection, :changed_apps)
    affected_apps = Map.fetch!(selection, :affected_apps)
    selected_apps_result = app_ids_from_test_dirs(Map.fetch!(selection, :test_paths))

    cond do
      changed_apps == [] and affected_apps == [] ->
        selected_apps_result

      changed_apps != [] or affected_apps != [] ->
        with {:ok, order} <- Core.execution_app_order(changed_apps, affected_apps),
             {:ok, selected_apps} <- selected_apps_result do
          if MapSet.equal?(MapSet.new(selected_apps), MapSet.new(order.ordered)) do
            {:ok, order.ordered}
          else
            {:error, :invalid_app_order_input}
          end
        end

      true ->
        {:ok, []}
    end
  end

  defp app_ids_from_test_dirs(test_paths) do
    collect_app_ids_from_test_dirs(test_paths, Core.max_apps(), [])
  end

  defp collect_app_ids_from_test_dirs([], _remaining, acc) do
    acc
    |> Enum.reverse()
    |> Core.normalize_ordered_app_ids()
  end

  defp collect_app_ids_from_test_dirs([_path | _rest], 0, _acc),
    do: {:error, :invalid_app_order_input}

  defp collect_app_ids_from_test_dirs([path | rest], remaining, acc) do
    case Core.app_id_from_test_dir(path) do
      {:ok, app} -> collect_app_ids_from_test_dirs(rest, remaining - 1, [app | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_app_ids_from_test_dirs(_improper, _remaining, _acc),
    do: {:error, :invalid_test_path}

  defp test_dirs_for_apps(app_ids) do
    with {:ok, normalized_apps} <- Core.normalize_ordered_app_ids(app_ids) do
      Enum.reduce_while(normalized_apps, {:ok, []}, fn app_id, {:ok, acc} ->
        case Core.canonical_test_dir_for_app(app_id) do
          {:ok, test_dir} -> {:cont, {:ok, [test_dir | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, dirs} -> {:ok, Enum.reverse(dirs)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp run_compile(path, timeout, validation_deadline, resource) do
    case run_bounded_mix(
           path,
           MixAction.compile_argv(%{warnings_as_errors: true}),
           [validation_resource: resource],
           timeout,
           validation_deadline,
           :compile
         ) do
      {:ok, result} ->
        Core.completed_check(Core.feedback_from_result(result))

      {:error, reason} ->
        throw({:execution_error, {:compile_execution_failed, reason}})
    end
  end

  defp run_xref(path, timeout, validation_deadline, resource) do
    # Evidence only — do not pass --fail-above; this repository has baseline
    # compile-connected cycles. Zero-cycle validation is not claimed.
    case run_bounded_mix(
           path,
           MixAction.xref_graph_argv(),
           [validation_resource: resource],
           timeout,
           validation_deadline,
           :xref
         ) do
      {:ok, result} ->
        exit_code = Map.get(result, :exit_code) || Map.get(result, "exit_code")

        Core.completed_check(Core.feedback_from_result(result),
          reason: if(exit_code == 0, do: nil, else: "xref_failed")
        )

      {:error, reason} ->
        throw({:execution_error, {:xref_execution_failed, reason}})
    end
  end

  defp run_test_compile(path, timeout, validation_deadline, resource) do
    # Explicit MIX_ENV=test compile before the aggregate app-test deadline starts.
    # Owner-controlled safe env only; same per-operation timeout as other stages.
    case run_bounded_mix(
           path,
           MixAction.compile_argv(%{warnings_as_errors: true}),
           [validation_resource: resource, env: %{"MIX_ENV" => "test"}],
           timeout,
           validation_deadline,
           :test_compile
         ) do
      {:ok, result} ->
        feedback = Core.feedback_from_result(result)
        passed = Map.get(feedback, "passed") == true

        Core.completed_check(feedback,
          reason: if(passed, do: nil, else: "test_compile_failed")
        )

      {:error, reason} ->
        throw({:execution_error, {:test_compile_execution_failed, reason}})
    end
  end

  defp run_tests(
         _path,
         [],
         _ordered_apps,
         _operation_timeout,
         _test_stage_timeout,
         _validation_deadline,
         _resource
       ) do
    Core.empty_pass_check("no_affected_app_tests")
  end

  defp run_tests(
         path,
         test_paths,
         ordered_apps,
         operation_timeout,
         test_stage_timeout,
         validation_deadline,
         resource
       )
       when is_list(test_paths) do
    case expand_test_files(path, test_paths, ordered_apps) do
      {:ok, []} ->
        Core.empty_pass_check("no_existing_test_files")

      {:ok, files} ->
        case Core.partition_test_batches(files, ordered_apps) do
          {:ok, []} ->
            Core.empty_pass_check("no_existing_test_files")

          {:ok, batches} ->
            {available_ms, validation_test_deadline} =
              validation_test_budget(test_stage_timeout, validation_deadline)

            reserve_ms = MixAction.postflight_tree_binding_reserve_ms()

            case Core.admit_test_batches(
                   batches,
                   available_ms,
                   operation_timeout,
                   reserve_ms
                 ) do
              :ok ->
                # One shared absolute monotonic deadline for the whole test
                # stage, additionally capped by the whole-validation deadline.
                deadline =
                  validation_test_deadline || monotonic_ms() + test_stage_timeout

                case Core.new_test_execution(batches, operation_timeout, reserve_ms) do
                  {:ok, execution} ->
                    run_tests_sequential(path, execution, deadline, resource)

                  {:error, reason} ->
                    invalid_test_execution!(reason)
                end

              {:capacity_exceeded, check} ->
                check

              {:error, reason} ->
                case Core.next_test_step(
                       test_stage_timeout,
                       batches,
                       operation_timeout,
                       reserve_ms
                     ) do
                  {:error, invalid_step} ->
                    throw({:execution_error, {:invalid_test_step, invalid_step}})

                  _other ->
                    throw({:execution_error, {:test_batch_admission_failed, reason}})
                end
            end

          {:error, reason} ->
            throw({:execution_error, {:test_batch_partition_failed, reason}})
        end

      {:error, reason} ->
        throw({:execution_error, {:test_file_enumeration_failed, reason}})
    end
  end

  defp run_bounded_mix(path, args, opts, operation_timeout, validation_deadline, stage) do
    timeout = remaining_stage_timeout!(operation_timeout, validation_deadline, stage)
    result = run_mix(path, args, Keyword.put(opts, :timeout, timeout))
    assert_stage_deadline!(validation_deadline, stage)
    result
  end

  defp remaining_stage_timeout!(operation_timeout, nil, _stage), do: operation_timeout

  defp remaining_stage_timeout!(operation_timeout, deadline, stage)
       when is_integer(operation_timeout) and is_integer(deadline) do
    case deadline - monotonic_ms() do
      remaining when remaining > 0 -> min(operation_timeout, remaining)
      _exhausted -> throw({:execution_error, {:validation_stage_timeout, stage}})
    end
  end

  defp assert_stage_deadline!(nil, _stage), do: :ok

  defp assert_stage_deadline!(deadline, stage) when is_integer(deadline) do
    if deadline - monotonic_ms() > 0 do
      :ok
    else
      throw({:execution_error, {:validation_stage_timeout, stage}})
    end
  end

  defp stage_deadline(nil), do: nil
  defp stage_deadline(timeout) when is_integer(timeout), do: monotonic_ms() + timeout

  defp validation_test_budget(test_stage_timeout, nil), do: {test_stage_timeout, nil}

  defp validation_test_budget(test_stage_timeout, validation_deadline)
       when is_integer(validation_deadline) do
    now = monotonic_ms()
    deadline = min(now + test_stage_timeout, validation_deadline)
    {max(deadline - now, 0), deadline}
  end

  defp validation_resource_opts(timeout, nil), do: [timeout: timeout]

  defp validation_resource_opts(timeout, validation_deadline),
    do: [timeout: timeout, deadline_ms: validation_deadline]

  defp run_tests_sequential(worktree_path, execution, deadline, resource) do
    # Shared aggregate deadline checked before every child (including the first).
    remaining_ms = deadline - monotonic_ms()

    case Core.next_test_execution_step(execution, remaining_ms) do
      {:complete, check} ->
        check

      {:capacity, completed, interrupted, unstarted} ->
        emit_runtime_handoff(
          completed,
          interrupted,
          unstarted,
          execution.operation_timeout
        )

      {:run, attempt, budget_ms} ->
        mix_opts =
          [timeout: budget_ms]
          |> then(fn opts ->
            if resource, do: Keyword.put(opts, :validation_resource, resource), else: opts
          end)

        # Exact multi-file batch argv — never shell-joined strings or directories.
        case run_mix(worktree_path, MixAction.test_argv(attempt.paths), mix_opts) do
          {:ok, result} ->
            # Re-check shared deadline immediately after every child, including the final one.
            remaining_after = deadline - monotonic_ms()
            runner_timeout = Core.runner_timed_out?(result)
            feedback = Core.feedback_from_result(result)

            case Core.record_test_execution_attempt(
                   execution,
                   attempt,
                   feedback,
                   runner_timeout,
                   budget_ms,
                   remaining_after
                 ) do
              {:continue, next_execution} ->
                run_tests_sequential(worktree_path, next_execution, deadline, resource)

              {:terminal, check} ->
                check

              {:capacity, completed, interrupted, unstarted} ->
                emit_runtime_handoff(
                  completed,
                  interrupted,
                  unstarted,
                  execution.operation_timeout
                )

              {:error, reason} ->
                invalid_test_execution!(reason)
            end

          {:error, reason} ->
            remaining_after = deadline - monotonic_ms()

            case Core.record_test_execution_prelaunch_error(
                   execution,
                   reason,
                   remaining_after
                 ) do
              {:capacity, completed, interrupted, unstarted} ->
                emit_runtime_handoff(
                  completed,
                  interrupted,
                  unstarted,
                  execution.operation_timeout
                )

              {:execution_error, bounded_reason} ->
                throw({:execution_error, bounded_reason})

              {:error, invalid_reason} ->
                invalid_test_execution!(invalid_reason)
            end
        end

      {:error, reason} ->
        # Malformed state must never silently complete as success.
        invalid_test_execution!(reason)
    end
  end

  defp invalid_test_execution!({:invalid_test_execution_state, reason}),
    do: invalid_test_execution!(reason)

  defp invalid_test_execution!(reason),
    do: throw({:execution_error, {:invalid_test_execution_state, reason}})

  defp emit_runtime_handoff(completed, interrupted, unstarted, operation_timeout) do
    case Core.capacity_handoff(
           :runtime,
           0,
           operation_timeout,
           completed,
           interrupted,
           unstarted
         ) do
      {:ok, check} ->
        check

      {:error, reason} ->
        throw({:execution_error, {:invalid_capacity_handoff, reason}})
    end
  end

  # Continuation execution binds the complete test plan to the same immutable
  # candidate manifest/tree freeze used by selection. It must never re-list the
  # mutable worktree after that freeze.
  defp frozen_test_files(candidate_manifest, test_dirs, ordered_apps)
       when is_list(test_dirs) and is_list(ordered_apps) do
    with {:ok, entries} <- BlobManifest.canonical_entries(candidate_manifest),
         {:ok, selected_dirs} <- normalize_frozen_test_dirs(test_dirs),
         {:ok, selected_entries} <- select_frozen_test_entries(entries, selected_dirs),
         :ok <- bound_frozen_test_inventory(selected_entries),
         {:ok, files} <- regular_frozen_test_files(selected_entries) do
      Core.normalize_expanded_test_files(files, ordered_apps)
    end
  end

  defp frozen_test_files(_candidate_manifest, _test_dirs, _ordered_apps),
    do: {:error, :invalid_test_dir}

  defp normalize_frozen_test_dirs(test_dirs) do
    Enum.reduce_while(test_dirs, {:ok, []}, fn dir, {:ok, acc} ->
      case validate_test_dir_relpath(dir) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp select_frozen_test_entries(entries, selected_dirs) do
    {:ok,
     Enum.filter(entries, fn entry ->
       path_under_selected_dir?(entry.path, selected_dirs)
     end)}
  end

  defp bound_frozen_test_inventory(entries) do
    if length(entries) <= Core.max_git_inventory_entries(),
      do: :ok,
      else: {:error, :too_many_git_inventory_entries}
  end

  defp regular_frozen_test_files(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      if String.ends_with?(entry.path, "_test.exs") do
        case entry.mode do
          mode when mode in ["100644", "100755"] ->
            if length(acc) < Core.max_expanded_test_files() do
              {:cont, {:ok, [entry.path | acc]}}
            else
              {:halt, {:error, :too_many_test_files}}
            end

          "120000" ->
            {:halt, {:error, {:symlink_rejected, :test_file, entry.path}}}

          _other ->
            {:halt, {:error, {:unexpected_test_path_type, :test_file, entry.path}}}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, _} = error -> error
    end
  end

  defp path_under_selected_dir?(path, selected_dirs) when is_binary(path) do
    segments = Path.split(path)

    Enum.any?(selected_dirs, fn dir ->
      dir_segments = Path.split(dir)
      List.starts_with?(segments, dir_segments) and length(segments) > length(dir_segments)
    end)
  end

  # Expand selected app test directories into deterministic relative *_test.exs paths.
  # Inventory is git tracked + untracked (exclude-standard) only — ignored and
  # generated files never enter validation. Bound inventory size before any
  # per-entry lstat work. Symlink roots/components/files fail closed.
  defp expand_test_files(worktree_path, test_dirs, ordered_apps)
       when is_list(test_dirs) and is_list(ordered_apps) do
    with {:ok, selected_dirs} <- prepare_selected_test_dirs(worktree_path, test_dirs),
         {:ok, test_paths} <- git_list_test_paths(worktree_path, selected_dirs),
         {:ok, verified} <-
           verify_listed_test_files(worktree_path, selected_dirs, test_paths) do
      Core.normalize_expanded_test_files(verified, ordered_apps)
    end
  end

  defp expand_test_files(_worktree_path, _test_dirs, _ordered_apps),
    do: {:error, :invalid_test_dir}

  defp prepare_selected_test_dirs(worktree_path, test_dirs) do
    Enum.reduce_while(test_dirs, {:ok, []}, fn dir, {:ok, acc} ->
      case prepare_one_selected_dir(worktree_path, dir) do
        {:ok, :missing} ->
          {:cont, {:ok, acc}}

        {:ok, normalized} ->
          {:cont, {:ok, acc ++ [normalized]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp prepare_one_selected_dir(worktree_path, rel_dir) when is_binary(rel_dir) do
    with {:ok, trimmed} <- validate_test_dir_relpath(rel_dir) do
      abs_dir = Path.join(worktree_path, trimmed)

      case File.lstat(abs_dir) do
        {:error, :enoent} ->
          {:ok, :missing}

        {:ok, %File.Stat{type: :symlink}} ->
          {:error, {:symlink_rejected, :test_dir, trimmed}}

        {:ok, %File.Stat{type: :directory}} ->
          {:ok, trimmed}

        {:ok, %File.Stat{type: other}} ->
          {:error, {:unexpected_test_path_type, :test_dir, trimmed, other}}

        {:error, reason} ->
          {:error, {:test_path_stat_failed, :test_dir, trimmed, reason}}
      end
    end
  end

  defp prepare_one_selected_dir(_worktree_path, rel_dir),
    do: {:error, {:invalid_test_dir, rel_dir}}

  defp validate_test_dir_relpath(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" ->
        {:error, {:invalid_test_dir, path}}

      not String.valid?(trimmed) ->
        {:error, {:invalid_test_dir, path}}

      String.contains?(trimmed, <<0>>) ->
        {:error, {:invalid_test_dir, path}}

      String.starts_with?(trimmed, "/") ->
        {:error, {:invalid_test_dir, path}}

      String.contains?(trimmed, "..") ->
        {:error, {:invalid_test_dir, path}}

      true ->
        case Path.split(trimmed) do
          ["apps", app, "test"] when app != "" ->
            {:ok, Path.join(["apps", app, "test"])}

          _ ->
            {:error, {:invalid_test_dir, path}}
        end
    end
  end

  defp validate_test_dir_relpath(path), do: {:error, {:invalid_test_dir, path}}

  defp git_list_test_paths(_worktree_path, []) do
    {:ok, []}
  end

  defp git_list_test_paths(worktree_path, selected_dirs) when is_list(selected_dirs) do
    # Pathspecs are the already-validated selected dirs only (bounded by selection).
    with {:ok, tracked} <-
           git(worktree_path, ["ls-files", "--cached", "-z", "--" | selected_dirs]),
         {:ok, deleted} <-
           git(worktree_path, ["ls-files", "--deleted", "-z", "--" | selected_dirs]),
         {:ok, untracked} <-
           git(worktree_path, [
             "ls-files",
             "--others",
             "--exclude-standard",
             "-z",
             "--" | selected_dirs
           ]) do
      # Preserve exact NUL-delimited path bytes — never String.trim/1.
      # Bound the combined raw inventory before suffix filter / dedup / lstat.
      raw_entries =
        (split_z(tracked) ++ split_z(untracked))
        |> Enum.reject(&(&1 == ""))

      if length(raw_entries) > Core.max_git_inventory_entries() do
        {:error, :too_many_git_inventory_entries}
      else
        # A coding candidate is an unstaged committable tree. Cached paths that
        # the candidate deleted remain in `git ls-files --cached`; subtract
        # only Git's exact deleted inventory. Any other post-enumeration ENOENT
        # still fails closed in the lstat verification below.
        deleted = deleted |> split_z() |> MapSet.new()

        paths =
          raw_entries
          |> Enum.reject(&MapSet.member?(deleted, &1))
          |> Enum.filter(&String.ends_with?(&1, "_test.exs"))
          |> Enum.uniq()
          |> Enum.sort()

        if length(paths) > Core.max_expanded_test_files() do
          {:error, :too_many_test_files}
        else
          {:ok, paths}
        end
      end
    else
      {:error, reason} -> {:error, {:test_file_list_failed, reason}}
    end
  end

  defp verify_listed_test_files(worktree_path, selected_dirs, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case verify_one_listed_test_file(worktree_path, selected_dirs, path) do
        {:ok, verified_path} ->
          {:cont, {:ok, [verified_path | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, _} = error -> error
    end
  end

  defp verify_one_listed_test_file(worktree_path, selected_dirs, path) do
    with :ok <- assert_under_selected_dir(path, selected_dirs),
         :ok <- assert_no_symlink_path_components(worktree_path, path),
         :ok <- assert_regular_test_file(worktree_path, path) do
      {:ok, path}
    end
  end

  # Exact segment-prefix match against a selected dir (apps/<app>/test/...).
  defp assert_under_selected_dir(path, selected_dirs) when is_binary(path) do
    segs = Path.split(path)

    if Enum.any?(selected_dirs, fn dir ->
         dsegs = Path.split(dir)
         List.starts_with?(segs, dsegs) and length(segs) > length(dsegs)
       end) do
      :ok
    else
      {:error, {:path_outside_selection, path}}
    end
  end

  # lstat every path component without following symlinks so a symlink parent
  # cannot redirect reads outside the selected tree.
  defp assert_no_symlink_path_components(worktree_path, rel_path) do
    segs = Path.split(rel_path)
    total = length(segs)

    Enum.reduce_while(1..total, :ok, fn n, :ok ->
      partial = Path.join(Enum.take(segs, n))
      abs = Path.join(worktree_path, partial)
      is_leaf = n == total

      case File.lstat(abs) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:symlink_rejected, :path_component, partial}}}

        {:ok, %File.Stat{type: :directory}} when not is_leaf ->
          {:cont, :ok}

        {:ok, %File.Stat{type: :regular}} when is_leaf ->
          {:cont, :ok}

        {:ok, %File.Stat{type: other}} ->
          kind = if is_leaf, do: :test_file, else: :path_component
          {:halt, {:error, {:unexpected_test_path_type, kind, partial, other}}}

        {:error, reason} ->
          kind = if is_leaf, do: :test_file, else: :path_component
          {:halt, {:error, {:test_path_stat_failed, kind, partial, reason}}}
      end
    end)
  end

  defp assert_regular_test_file(worktree_path, rel_path) do
    abs = Path.join(worktree_path, rel_path)

    case File.lstat(abs) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:symlink_rejected, :test_file, rel_path}}

      {:ok, %File.Stat{type: other}} ->
        {:error, {:unexpected_test_path_type, :test_file, rel_path, other}}

      {:error, reason} ->
        {:error, {:test_path_stat_failed, :test_file, rel_path, reason}}
    end
  end

  # System-owned capacity for every contained Mix validation stage (compile,
  # xref, test-env compile, test). Not caller-controlled; never exposed on a
  # Jido schema. Shell validates the closed profile atom.
  defp run_mix(path, args, opts) do
    runner = Application.get_env(:arbor_actions, :cross_app_mix_runner, &MixAction.run_mix/3)
    opts = Keyword.put(opts, :resource_profile, :intensive)
    runner.(path, args, opts)
  end

  defp monotonic_ms do
    clock =
      Application.get_env(:arbor_actions, :cross_app_monotonic_ms, fn ->
        System.monotonic_time(:millisecond)
      end)

    clock.()
  end

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  defp split_z(output) when is_binary(output) do
    String.split(output, <<0>>, trim: true)
  end

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end
end
