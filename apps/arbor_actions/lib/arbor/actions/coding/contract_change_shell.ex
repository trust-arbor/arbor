defmodule Arbor.Actions.Coding.ContractChange.Shell do
  @moduledoc """
  Imperative shell for contract_change validation.

  Resolves an authorized workspace lease, freezes the candidate committable tree,
  diffs immutable base/candidate blob manifests, admits only recognized contract
  surfaces, and runs two owner-owned Mix children under the validation resource
  owner. Compile and xref are source-compatibility evidence; census is CONTRACT_RULES
  admission. Binding council owns semantic compatibility.
  """

  alias Arbor.Actions.Coding.BlobManifest
  alias Arbor.Actions.Coding.ContractChange.Core
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Mix, as: MixAction

  @full_commit_oid_re ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/
  @mix_env %{"MIX_ENV" => "test"}

  @doc "Execute contract_change validation against a leased workspace."
  @spec run(Core.input(), map()) :: {:ok, map()} | {:error, term()}
  def run(input, context) when is_map(input) and is_map(context) do
    try do
      do_run(input, context, stage_deadline(Map.get(input, :stage_timeout)))
    catch
      {:execution_error, reason} -> {:error, reason}
    end
  end

  def run(_input, _context), do: {:error, :invalid_contract_change_input}

  @doc false
  @spec run_mix_children(String.t(), [String.t()], pos_integer(), pos_integer(), map()) ::
          {:ok, map()} | {:error, term()}
  def run_mix_children(worktree_path, test_paths, timeout, stage_timeout, resource)
      when is_binary(worktree_path) and is_list(test_paths) and is_integer(timeout) and
             is_integer(stage_timeout) and is_map(resource) do
    try do
      with {:ok, test_args} <- Core.test_argv(test_paths) do
        run_checks(
          worktree_path,
          test_paths,
          test_args,
          timeout,
          stage_deadline(stage_timeout),
          resource
        )
      end
    catch
      {:execution_error, reason} -> {:error, reason}
    end
  end

  defp do_run(input, context, validation_deadline) do
    with {:ok, lease} <- resolve_lease(input.workspace_id, context),
         {:ok, worktree_path, base_commit} <- lease_paths(lease),
         {:ok, freeze} <- MixAction.committable_app_mix_inventory(worktree_path),
         :ok <- invoke_after_candidate_freeze_hook(worktree_path, freeze),
         {:ok, base_manifest} <- load_base_blob_manifest(worktree_path, base_commit),
         {:ok, changed_files} <-
           BlobManifest.diff_blob_manifests(base_manifest, Map.fetch!(freeze, :blob_manifest)),
         {:ok, base_paths} <- BlobManifest.paths(base_manifest),
         {:ok, freeze_paths} <- BlobManifest.paths(Map.fetch!(freeze, :blob_manifest)),
         {:ok, admitted?} <-
           Core.admit_contract_surface(changed_files, base_paths, freeze_paths) do
      before_binding = %{head: freeze.head, tree_oid: freeze.tree_oid}

      with {:ok, checks, test_paths} <-
             maybe_run_validation(
               admitted?,
               input,
               context,
               worktree_path,
               changed_files,
               freeze_paths,
               validation_deadline
             ),
           {:ok, after_binding} <- MixAction.committable_tree_binding(worktree_path),
           :ok <- assert_validation_tree_stable(before_binding, after_binding) do
        evidence =
          Core.show(%{
            changed_files: changed_files,
            test_paths: test_paths,
            checks: checks,
            base_commit: base_commit
          })
          |> Map.put(:validated_tree_oid, before_binding.tree_oid)
          |> Map.put(:validated_head, before_binding.head)

        with {:ok, projection} <- Core.feedback_projection(evidence) do
          {:ok, Map.put(evidence, :feedback_json, Jason.encode!(projection))}
        end
      end
    end
  end

  defp maybe_run_validation(
         false,
         _input,
         _context,
         _worktree_path,
         _changed_files,
         _freeze_paths,
         _validation_deadline
       ) do
    skipped = Core.skipped_check("contract_surface_missing")
    {:ok, %{preflight: skipped, test: skipped}, []}
  end

  defp maybe_run_validation(
         true,
         input,
         context,
         worktree_path,
         changed_files,
         freeze_paths,
         validation_deadline
       ) do
    with {:ok, test_paths} <- Core.select_contract_tests(changed_files, freeze_paths),
         :ok <- verify_selected_tests(worktree_path, freeze_paths, test_paths),
         {:ok, test_args} <- Core.test_argv(test_paths) do
      resource_fun = with_validation_resource()

      case resource_fun.(
             input.workspace_id,
             context,
             fn resource ->
               run_checks(
                 worktree_path,
                 test_paths,
                 test_args,
                 input.timeout,
                 validation_deadline,
                 resource
               )
             end,
             validation_resource_opts(input.timeout, validation_deadline)
           ) do
        {:ok, checks} ->
          {:ok, checks, test_paths}

        {:error, reason} ->
          case map_resource_result(reason, input.timeout, test_paths) do
            {:ok, checks} -> {:ok, checks, test_paths}
            {:error, _} = error -> error
          end
      end
    end
  end

  defp run_checks(worktree_path, test_paths, test_args, timeout, validation_deadline, resource) do
    preflight_sha = Core.inventory_sha256(Core.preflight_argv())
    tests_sha = Core.inventory_sha256(test_paths)
    preflight_batch = Core.preflight_batch(preflight_sha)
    tests_batch = Core.tests_batch(max(length(test_paths), 1), tests_sha)

    case remaining_ms(timeout, validation_deadline) do
      remaining when remaining <= 0 ->
        case Core.capacity_check(:structural, timeout, %{
               completed: [],
               unstarted: [preflight_batch, tests_batch]
             }) do
          {:ok, check} ->
            {:ok, %{preflight: check, test: Core.skipped_check("validation_capacity_exceeded")}}

          {:error, reason} ->
            throw({:execution_error, {:capacity_handoff_failed, reason}})
        end

      _remaining ->
        preflight =
          run_mix_check(
            worktree_path,
            Core.preflight_argv(),
            timeout,
            resource,
            validation_deadline,
            :preflight,
            %{
              completed: [],
              current: preflight_batch,
              unstarted: [tests_batch],
              per_batch_budget_ms: timeout
            }
          )

        cond do
          preflight["passed"] != true ->
            {:ok,
             %{
               preflight: preflight,
               test: Core.skipped_check(preflight["reason"] || "preflight_failed")
             }}

          true ->
            run_tests_after_preflight(
              worktree_path,
              test_args,
              timeout,
              validation_deadline,
              resource,
              preflight,
              preflight_batch,
              tests_batch
            )
        end
    end
  end

  defp run_tests_after_preflight(
         worktree_path,
         test_args,
         timeout,
         validation_deadline,
         resource,
         preflight,
         preflight_batch,
         tests_batch
       ) do
    case remaining_ms(timeout, validation_deadline) do
      remaining when remaining <= 0 ->
        case Core.capacity_check(:runtime, timeout, %{
               completed: [preflight_batch],
               unstarted: [tests_batch]
             }) do
          {:ok, check} ->
            {:ok, %{preflight: preflight, test: check}}

          {:error, reason} ->
            throw({:execution_error, {:capacity_handoff_failed, reason}})
        end

      _remaining ->
        test =
          run_mix_check(
            worktree_path,
            test_args,
            timeout,
            resource,
            validation_deadline,
            :test,
            %{
              completed: [preflight_batch],
              current: tests_batch,
              unstarted: [],
              per_batch_budget_ms: timeout
            }
          )

        {:ok, %{preflight: preflight, test: test}}
    end
  end

  defp run_mix_check(path, args, timeout, resource, validation_deadline, stage, plan) do
    case remaining_ms(timeout, validation_deadline) do
      remaining when remaining <= 0 ->
        unstarted_capacity_check(plan, :prelaunch)

      remaining ->
        result =
          run_mix(
            path,
            args,
            validation_resource: resource,
            timeout: remaining,
            env: @mix_env,
            resource_profile: :intensive
          )

        case result do
          {:ok, mix_result} ->
            case project_mix_success(mix_result, stage, plan) do
              {:ok, check} ->
                check

              {:error, :invalid_shell_projection} ->
                throw({:execution_error, :invalid_shell_projection})

              {:error, reason} ->
                throw({:execution_error, {:capacity_handoff_failed, reason}})
            end

          {:error, reason} ->
            remaining_after = signed_remaining_ms(timeout, validation_deadline)

            if Core.prelaunch_probe_timeout_capacity?(reason, remaining_after) do
              unstarted_capacity_check(plan, :probe)
            else
              throw({:execution_error, {stage_execution_failed(stage), reason}})
            end
        end
    end
  end

  # The Shell Mix-success predicates are the external shape gate. They must
  # track Core.check_from_projection/4 families (ordinary, containment,
  # capacity) while adding raw stdout/stderr and exit-code constraints Core
  # does not enforce. Non-binary streams must not reach
  # Core.feedback_from_result/1.
  defp project_mix_success(mix_result, stage, plan) do
    with :ok <- admit_mix_success_result(mix_result),
         :ok <- admit_mix_success_streams(mix_result),
         projection = MixAction.project_shell_validation(mix_result),
         :ok <- admit_shell_projection(projection) do
      feedback = Core.feedback_from_result(mix_result)
      Core.check_from_projection(feedback, projection, stage, plan)
    end
  end

  defp admit_mix_success_result(result) when is_map(result) and not is_struct(result), do: :ok
  defp admit_mix_success_result(_result), do: {:error, :invalid_shell_projection}

  defp admit_mix_success_streams(result) do
    if admitted_raw_stream?(result, :stdout) and admitted_raw_stream?(result, :stderr) do
      :ok
    else
      {:error, :invalid_shell_projection}
    end
  end

  defp admitted_raw_stream?(result, key) do
    admitted_raw_stream_field?(result, key) and
      admitted_raw_stream_field?(result, Atom.to_string(key))
  end

  defp admitted_raw_stream_field?(result, key) do
    case Map.fetch(result, key) do
      :error -> true
      {:ok, value} when is_binary(value) or is_nil(value) -> true
      {:ok, _value} -> false
    end
  end

  defp admit_shell_projection(projection) when is_map(projection) and not is_struct(projection) do
    exit_code = map_value(projection, :exit_code)
    reason = map_value(projection, :reason)
    termination = map_value(projection, :termination)
    passed = map_value(projection, :passed) == true

    cond do
      reason == "validation_containment_failure" and not passed and is_map(termination) and
          is_integer(exit_code) ->
        :ok

      reason == "validation_capacity_exceeded" and not passed and
          (is_nil(exit_code) or is_integer(exit_code)) ->
        :ok

      is_nil(reason) and is_nil(termination) and is_integer(exit_code) ->
        :ok

      true ->
        {:error, :invalid_shell_projection}
    end
  end

  defp admit_shell_projection(_projection), do: {:error, :invalid_shell_projection}

  defp unstarted_capacity_check(plan, kind) do
    completed = plan_list(plan, :completed)
    current = plan_value(plan, :current)
    suffix = plan_list(plan, :unstarted)
    timeout = plan_value(plan, :per_batch_budget_ms)

    unstarted =
      case current do
        batch when is_map(batch) -> [batch | suffix]
        _missing -> suffix
      end

    phase =
      case kind do
        :probe -> :runtime
        :prelaunch when completed == [] -> :structural
        :prelaunch -> :runtime
      end

    case Core.capacity_check(phase, timeout, %{
           completed: completed,
           unstarted: unstarted
         }) do
      {:ok, check} ->
        check

      {:error, reason} ->
        throw({:execution_error, {:capacity_handoff_failed, reason}})
    end
  end

  defp plan_list(plan, key), do: List.wrap(plan_value(plan, key) || [])

  defp plan_value(plan, key) when is_atom(key) do
    cond do
      is_map_key(plan, key) -> Map.get(plan, key)
      is_map_key(plan, Atom.to_string(key)) -> Map.get(plan, Atom.to_string(key))
      true -> nil
    end
  end

  defp map_resource_result(reason, timeout, test_paths) do
    if Core.resource_acquisition_deadline?(reason) do
      emit_structural_resource_capacity(timeout, test_paths)
    else
      {:error, reason}
    end
  end

  defp emit_structural_resource_capacity(timeout, test_paths) do
    preflight_batch = Core.preflight_batch(Core.inventory_sha256(Core.preflight_argv()))
    tests_batch = Core.tests_batch(max(length(test_paths), 1), Core.inventory_sha256(test_paths))

    case Core.capacity_check(:structural, timeout, %{
           completed: [],
           unstarted: [preflight_batch, tests_batch]
         }) do
      {:ok, check} ->
        {:ok, %{preflight: check, test: Core.skipped_check("validation_capacity_exceeded")}}

      {:error, reason} ->
        {:error, {:capacity_handoff_failed, reason}}
    end
  end

  defp with_validation_resource do
    Application.get_env(
      :arbor_actions,
      :contract_change_with_validation_resource,
      &MixAction.with_validation_resource/4
    )
  end

  defp stage_execution_failed(:preflight), do: :preflight_execution_failed
  defp stage_execution_failed(:test), do: :test_execution_failed

  defp run_mix(path, args, opts) do
    runner =
      Application.get_env(:arbor_actions, :contract_change_mix_runner, &MixAction.run_mix/3)

    opts = Keyword.put(opts, :resource_profile, :intensive)
    runner.(path, args, opts)
  end

  defp verify_selected_tests(worktree_path, freeze_paths, test_paths) do
    freeze_set = MapSet.new(freeze_paths)

    Enum.reduce_while(test_paths, :ok, fn rel, :ok ->
      cond do
        not MapSet.member?(freeze_set, rel) ->
          {:halt, {:error, {:selected_test_not_in_freeze, rel}}}

        true ->
          case verify_one_test(worktree_path, rel) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp verify_one_test(worktree_path, rel) do
    with {:ok, segments} <- split_rel(rel),
         :ok <- within_worktree?(worktree_path, segments) do
      verify_components(worktree_path, segments, rel)
    end
  end

  defp split_rel(rel) when is_binary(rel) do
    segments = Path.split(rel)

    if Enum.any?(segments, &(&1 in ["", ".", ".."])) do
      {:error, {:invalid_test_path, rel}}
    else
      {:ok, segments}
    end
  end

  defp within_worktree?(worktree_path, segments) do
    root = Path.split(Path.expand(worktree_path))
    abs = Path.split(Path.expand(Path.join([worktree_path | segments])))

    if List.starts_with?(abs, root) do
      :ok
    else
      {:error, :path_escape}
    end
  end

  defp verify_components(worktree_path, segments, rel) do
    segments
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {_seg, index}, :ok ->
      prefix = Enum.take(segments, index + 1)
      abs = Path.join([worktree_path | prefix])
      last? = index == length(segments) - 1

      case File.lstat(abs) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:symlink_rejected, rel}}}

        {:ok, %File.Stat{type: :directory}} when not last? ->
          {:cont, :ok}

        {:ok, %File.Stat{type: :regular}} when last? ->
          {:cont, :ok}

        {:ok, %File.Stat{type: other}} ->
          {:halt, {:error, {:unexpected_test_path_type, rel, other}}}

        {:error, :enoent} ->
          {:halt, {:error, {:missing_selected_test, rel}}}

        {:error, reason} ->
          {:halt, {:error, {:test_path_stat_failed, rel, reason}}}
      end
    end)
  end

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

  defp validate_full_commit_oid(oid) when is_binary(oid) do
    if Regex.match?(@full_commit_oid_re, oid), do: :ok, else: {:error, :invalid_base_commit_oid}
  end

  defp validate_full_commit_oid(_), do: {:error, :invalid_base_commit_oid}

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  defp invoke_after_candidate_freeze_hook(worktree_path, freeze)
       when is_binary(worktree_path) and is_map(freeze) do
    case Application.get_env(:arbor_actions, :contract_change_after_candidate_freeze) do
      nil ->
        :ok

      fun when is_function(fun, 2) ->
        case fun.(worktree_path, freeze) do
          :ok -> :ok
          {:error, reason} -> {:error, {:after_candidate_freeze_hook_failed, reason}}
          other -> {:error, {:after_candidate_freeze_hook_invalid_return, other}}
        end

      other ->
        {:error, {:invalid_after_candidate_freeze_hook, other}}
    end
  end

  defp assert_validation_tree_stable(%{tree_oid: before}, %{tree_oid: after_oid})
       when is_binary(before) and before != "" and before == after_oid,
       do: :ok

  defp assert_validation_tree_stable(_before, _after),
    do: {:error, :validation_tree_mutated}

  defp resolve_lease(workspace_id, context) do
    task_id = Workspace.context_task_id(context)
    principal_id = Workspace.context_principal_id(context)

    cond do
      not is_binary(task_id) or not is_binary(principal_id) ->
        {:error, :invalid_task_principal}

      true ->
        case WorkspaceLeaseRegistry.inspect_lease_by_lineage(
               workspace_id,
               task_id,
               principal_id
             ) do
          {:ok, lease} -> {:ok, lease}
          {:error, :not_found} -> {:error, :workspace_not_found}
          {:error, :not_authorized} -> {:error, :workspace_unauthorized}
          {:error, :invalid_task_principal} -> {:error, :invalid_task_principal}
          {:error, reason} -> {:error, reason}
        end
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

  defp lease_paths(_), do: {:error, :invalid_lease}

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end

  defp stage_deadline(nil), do: nil
  defp stage_deadline(timeout) when is_integer(timeout), do: monotonic_ms() + timeout

  defp remaining_ms(operation_timeout, nil), do: operation_timeout

  defp remaining_ms(operation_timeout, deadline) when is_integer(deadline) do
    remaining = deadline - monotonic_ms()
    if remaining > 0, do: min(operation_timeout, remaining), else: 0
  end

  defp signed_remaining_ms(operation_timeout, nil), do: operation_timeout

  defp signed_remaining_ms(_operation_timeout, deadline) when is_integer(deadline) do
    deadline - monotonic_ms()
  end

  defp validation_resource_opts(timeout, nil), do: [timeout: timeout]

  defp validation_resource_opts(timeout, validation_deadline),
    do: [timeout: timeout, deadline_ms: validation_deadline]

  defp monotonic_ms do
    clock =
      Application.get_env(:arbor_actions, :contract_change_monotonic_ms, fn ->
        System.monotonic_time(:millisecond)
      end)

    clock.()
  end
end
