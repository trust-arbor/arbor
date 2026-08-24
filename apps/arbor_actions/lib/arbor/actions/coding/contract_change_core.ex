defmodule Arbor.Actions.Coding.ContractChange.Core do
  @moduledoc """
  Pure input, applicability, test selection, and evidence for contract_change.

  Compile and xref are source-compatibility evidence only. Binding council
  review owns semantic / consumer API compatibility. This module never imports
  CrossApp policy.
  """

  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @default_timeout 300_000
  @minimum_timeout 1_000
  @maximum_timeout (case Arbor.Shell.spawn_capable_max_timeout_ms(:intensive) do
                      {:ok, ms} when is_integer(ms) and ms > 0 ->
                        ms

                      other ->
                        raise CompileError,
                          description:
                            "contract_change maximum_timeout requires a positive Shell intensive spawn-capable ceiling; got #{inspect(other)}"
                    end)
  @default_stage_timeout 600_000
  @maximum_stage_timeout 2 * @maximum_timeout
  @allowed_param_keys [:workspace_id, :timeout, :stage_timeout]
  @allowed_param_string_keys Enum.map(@allowed_param_keys, &Atom.to_string/1)
  @max_path_bytes 1_024
  @max_identifier_bytes 64
  @max_contract_tests 256
  @max_changed_files 2_000
  @max_output_excerpt_bytes 2_000
  @max_feedback_reason_bytes 64
  @feedback_check_statuses ["completed", "skipped"]
  @oid_re ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/
  @sha256_re ~r/\A[0-9a-f]{64}\z/
  @excerpt_omission_marker "\n...[omitted]...\n"
  @utf8_replacement <<0xEF, 0xBF, 0xBD>>
  @test_argv_prefix ["test", "--warnings-as-errors", "--"]
  @preflight_argv [
    "do",
    "compile",
    "--warnings-as-errors,",
    "xref",
    "graph,",
    "arbor.contracts.census",
    "--fail-on-violation"
  ]
  @max_test_argv_files Arbor.Shell.spawn_capable_max_command_args() - length(@test_argv_prefix)
  @max_test_arg_bytes 65_536
  @app_id_re ~r/^[a-z][a-z0-9_]*$/
  @retired_apps MapSet.new(["arbor_contracts"])

  @type input :: %{
          workspace_id: String.t(),
          timeout: pos_integer(),
          stage_timeout: pos_integer()
        }

  @type check :: %{required(String.t()) => term()}

  @doc false
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout

  @doc false
  @spec maximum_timeout() :: pos_integer()
  def maximum_timeout, do: @maximum_timeout

  @doc false
  @spec default_stage_timeout() :: pos_integer()
  def default_stage_timeout, do: @default_stage_timeout

  @doc false
  @spec maximum_stage_timeout() :: pos_integer()
  def maximum_stage_timeout, do: @maximum_stage_timeout

  @doc false
  @spec max_changed_files() :: pos_integer()
  def max_changed_files, do: @max_changed_files

  @doc false
  @spec max_contract_tests() :: pos_integer()
  def max_contract_tests, do: @max_contract_tests

  @doc false
  @spec preflight_argv() :: [String.t()]
  def preflight_argv, do: @preflight_argv

  @doc false
  @spec test_argv_prefix() :: [String.t()]
  def test_argv_prefix, do: @test_argv_prefix

  @doc "Construct and validate the action's deliberately narrow input surface."
  @spec new(map()) :: {:ok, input()} | {:error, atom()}
  def new(params) when is_map(params) do
    with :ok <- validate_param_keys(params),
         {:ok, workspace_id} <- validate_workspace_id(param(params, :workspace_id)),
         {:ok, timeout} <- validate_timeout(param(params, :timeout)),
         {:ok, stage_timeout} <- validate_stage_timeout(param(params, :stage_timeout)) do
      {:ok,
       %{
         workspace_id: workspace_id,
         timeout: timeout,
         stage_timeout: stage_timeout
       }}
    end
  end

  def new(_params), do: {:error, :invalid_parameters}

  @doc """
  True when immutable changed_files contain at least one recognized contract surface.

  Coordinated consumer edits may accompany a surface. Arbitrary non-contract
  work is not admitted. Invalid paths never count as a surface. App-owned
  contract paths count only when `apps/<app>/mix.exs` exists in the union of
  the immutable base and candidate path inventories.
  """
  @spec admit_contract_surface(term(), term(), term()) :: {:ok, boolean()} | {:error, term()}
  def admit_contract_surface(changed_files, base_paths, candidate_paths)
      when is_list(changed_files) and is_list(base_paths) and is_list(candidate_paths) do
    with {:ok, files} <- normalize_changed_files(changed_files) do
      app_roots =
        MapSet.union(app_roots_from_paths(base_paths), app_roots_from_paths(candidate_paths))

      {:ok, Enum.any?(files, &recognized_contract_surface?(&1, app_roots))}
    end
  end

  def admit_contract_surface(_, _, _), do: {:error, :invalid_changed_files}

  @doc "Select exact freeze-only contract tests. Never accepts candidate-supplied commands."
  @spec select_contract_tests(term(), term()) :: {:ok, [String.t()]} | {:error, term()}
  def select_contract_tests(changed_files, candidate_paths)
      when is_list(changed_files) and is_list(candidate_paths) do
    with {:ok, changed} <- normalize_changed_files(changed_files),
         {:ok, freeze_paths} <- normalize_freeze_paths(candidate_paths) do
      freeze_set = MapSet.new(freeze_paths)
      suite = kernel_suite(freeze_paths)

      if suite == [] do
        {:error, :contract_suite_missing}
      else
        extra =
          changed
          |> Enum.flat_map(&additional_tests(&1, freeze_set))
          |> Enum.concat(suite)
          |> Enum.uniq()
          |> Enum.sort()

        cond do
          length(extra) > @max_contract_tests ->
            {:error, :too_many_contract_tests}

          true ->
            {:ok, extra}
        end
      end
    end
  end

  def select_contract_tests(_, _), do: {:error, :invalid_test_selection}

  @doc "Owner-owned Mix test argv for an exact inventory, or fail closed."
  @spec test_argv([String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def test_argv(paths) when is_list(paths) do
    with {:ok, normalized} <- normalize_test_files(paths) do
      args = @test_argv_prefix ++ normalized
      path_bytes = Enum.reduce(normalized, 0, fn path, acc -> acc + byte_size(path) + 1 end)

      cond do
        length(normalized) > @max_test_argv_files ->
          {:error, :contract_test_inventory_unrunnable}

        path_bytes > @max_test_arg_bytes ->
          {:error, :contract_test_inventory_unrunnable}

        true ->
          {:ok, args}
      end
    end
  end

  def test_argv(_), do: {:error, :contract_test_inventory_unrunnable}

  @doc "Assemble bounded JSON-clean evidence from checks and freeze metadata."
  @spec show(map()) :: map()
  def show(%{
        changed_files: changed_files,
        test_paths: test_paths,
        checks: checks,
        base_commit: base_commit
      })
      when is_list(changed_files) and is_list(test_paths) and is_map(checks) and
             is_binary(base_commit) do
    preflight = normalize_check(Map.get(checks, :preflight) || Map.get(checks, "preflight"))
    test = normalize_check(Map.get(checks, :test) || Map.get(checks, "test"))
    passed = preflight["passed"] == true and test["passed"] == true
    reason = overall_reason(passed, preflight, test)

    %{
      passed: passed,
      reason: reason,
      base_commit: base_commit,
      changed_files: changed_files,
      test_paths: test_paths,
      preflight: preflight,
      test: test
    }
  end

  @doc """
  Project bounded rework feedback from contract_change evidence.

  Omits full path inventories. Reconstructs each stage check from a closed key
  set and re-bounds excerpts to the existing excerpt limit. Unknown extras,
  including termination and capacity_handoff, are omitted; structured evidence
  retains them. Oversized reason or base_commit fail closed. Bound by
  construction. Do not encode JSON here.
  """
  @spec feedback_projection(map()) :: {:ok, map()} | {:error, :invalid_feedback_projection}
  def feedback_projection(evidence) when is_map(evidence) do
    with {:ok, inventories} <-
           admit_transport_inventories(
             evidence_field(evidence, :changed_files),
             evidence_field(evidence, :test_paths)
           ),
         passed when is_boolean(passed) <- evidence_field(evidence, :passed),
         {:ok, reason} <- bound_feedback_reason(evidence_field(evidence, :reason)),
         {:ok, base_commit} <- bound_feedback_oid(evidence_field(evidence, :base_commit)),
         {:ok, preflight} <- project_feedback_check(evidence_field(evidence, :preflight)),
         {:ok, test} <- project_feedback_check(evidence_field(evidence, :test)) do
      {:ok,
       %{
         passed: passed,
         reason: reason,
         base_commit: base_commit,
         preflight: preflight,
         test: test,
         changed_files_count: length(inventories.changed_files),
         test_paths_count: length(inventories.test_paths),
         changed_files_sha256: inventory_sha256(inventories.changed_files),
         test_paths_sha256: inventory_sha256(inventories.test_paths)
       }}
    else
      _other -> {:error, :invalid_feedback_projection}
    end
  end

  def feedback_projection(_evidence), do: {:error, :invalid_feedback_projection}

  @doc "Skipped domain-failure check."
  @spec skipped_check(String.t()) :: check()
  def skipped_check(reason) when is_binary(reason) do
    %{
      "status" => "skipped",
      "passed" => false,
      "exit_code" => nil,
      "reason" => reason,
      "stdout_excerpt" => "",
      "stderr_excerpt" => "",
      "stdout_truncated" => false,
      "stderr_truncated" => false,
      "stdout_sha256" => sha256(""),
      "stderr_sha256" => sha256("")
    }
  end

  @doc "Completed check from Mix feedback."
  @spec completed_check(map(), keyword()) :: check()
  def completed_check(feedback, opts \\ []) when is_map(feedback) do
    passed = Map.get(feedback, "passed") || Map.get(feedback, :passed) || false
    exit_code = Map.get(feedback, "exit_code") || Map.get(feedback, :exit_code)

    %{
      "status" => Keyword.get(opts, :status, "completed"),
      "passed" => passed == true,
      "exit_code" => exit_code,
      "reason" => Keyword.get(opts, :reason),
      "stdout_excerpt" =>
        json_safe_utf8(
          Map.get(feedback, "stdout_excerpt") || Map.get(feedback, :stdout_excerpt) || ""
        ),
      "stderr_excerpt" =>
        json_safe_utf8(
          Map.get(feedback, "stderr_excerpt") || Map.get(feedback, :stderr_excerpt) || ""
        ),
      "stdout_truncated" =>
        Map.get(feedback, "stdout_truncated") || Map.get(feedback, :stdout_truncated) || false,
      "stderr_truncated" =>
        Map.get(feedback, "stderr_truncated") || Map.get(feedback, :stderr_truncated) || false,
      "stdout_sha256" =>
        Map.get(feedback, "stdout_sha256") || Map.get(feedback, :stdout_sha256) || sha256(""),
      "stderr_sha256" =>
        Map.get(feedback, "stderr_sha256") || Map.get(feedback, :stderr_sha256) || sha256("")
    }
  end

  @doc "JSON-clean Mix feedback from a raw process result."
  @spec feedback_from_result(map()) :: map()
  def feedback_from_result(result) when is_map(result) do
    stdout = raw_stream(result, :stdout)
    stderr = raw_stream(result, :stderr)
    exit_code = Map.get(result, :exit_code) || Map.get(result, "exit_code")
    {stdout_excerpt, stdout_truncated} = bound_output_excerpt(stdout)
    {stderr_excerpt, stderr_truncated} = bound_output_excerpt(stderr)

    %{
      "exit_code" => exit_code,
      "passed" => exit_code == 0,
      "stdout_excerpt" => stdout_excerpt,
      "stderr_excerpt" => stderr_excerpt,
      "stdout_truncated" => stdout_truncated,
      "stderr_truncated" => stderr_truncated,
      "stdout_sha256" => sha256(stdout),
      "stderr_sha256" => sha256(stderr)
    }
  end

  @doc """
  True only for a closed prelaunch Apple Container probe timeout after the
  shared aggregate deadline is already exhausted.

  The Mix child never launched. Positive residual, every other probe error,
  nested tuples, and substring decoys remain action errors.
  """
  @spec prelaunch_probe_timeout_capacity?(term(), integer()) :: boolean()
  def prelaunch_probe_timeout_capacity?(:probe_timeout, remaining_ms_after)
      when is_integer(remaining_ms_after) and remaining_ms_after <= 0,
      do: true

  def prelaunch_probe_timeout_capacity?(":probe_timeout", remaining_ms_after)
      when is_integer(remaining_ms_after) and remaining_ms_after <= 0,
      do: true

  def prelaunch_probe_timeout_capacity?(_reason, _remaining_ms_after), do: false

  @doc """
  True only for the exact resource-acquisition deadline atom.

  Nested tuples and the Mix-child string form stay action errors.
  """
  @spec resource_acquisition_deadline?(term()) :: boolean()
  def resource_acquisition_deadline?(:operation_deadline_exceeded), do: true
  def resource_acquisition_deadline?(_reason), do: false

  @doc """
  Reconcile ContractChange transport inventories without truncating.

  Empty `test_paths` is valid (surface-missing evidence). Over-bound or
  invalid paths fail closed.
  """
  @spec admit_transport_inventories(term(), term()) ::
          {:ok, %{changed_files: [String.t()], test_paths: [String.t()]}} | {:error, term()}
  def admit_transport_inventories(changed_files, test_paths)
      when is_list(changed_files) and is_list(test_paths) do
    with {:ok, files} <- normalize_changed_files(changed_files),
         {:ok, tests} <- normalize_test_files(test_paths) do
      {:ok, %{changed_files: files, test_paths: tests}}
    end
  end

  def admit_transport_inventories(_changed_files, _test_paths),
    do: {:error, :invalid_contract_inventory}

  @doc """
  Project a Mix.project_shell_validation/1 result into a contract_change check.

  Consumes the shared Mix projection as data. Does not re-read Shell flags.
  Containment keeps Mix's five-key envelope. Capacity ignores Mix's four-key
  envelope and attaches schema-v3 interrupted-stage evidence.
  """
  @spec check_from_projection(map(), map(), :preflight | :test, map()) ::
          {:ok, check()} | {:error, term()}
  def check_from_projection(feedback, projection, stage, plan)
      when is_map(feedback) and is_map(projection) and stage in [:preflight, :test] and
             is_map(plan) do
    passed = projection_field(projection, :passed) == true
    reason = projection_field(projection, :reason)
    termination = projection_field(projection, :termination)
    feedback = Map.put(feedback, "passed", passed)

    cond do
      reason == "validation_containment_failure" and not passed and is_map(termination) ->
        check =
          Map.put(
            completed_check(feedback, reason: "validation_containment_failure"),
            "termination",
            termination
          )

        {:ok, check}

      reason == "validation_capacity_exceeded" and not passed ->
        attach_interrupted_capacity(feedback, plan)

      is_nil(reason) and is_nil(termination) ->
        ordinary_check(feedback, passed, stage)

      true ->
        {:error, :invalid_shell_projection}
    end
  end

  def check_from_projection(_, _, _, _), do: {:error, :invalid_shell_projection}

  @doc "Capacity check when remaining stage budget cannot start the next child."
  @spec capacity_check(:structural | :runtime, pos_integer(), map()) ::
          {:ok, check()} | {:error, term()}
  def capacity_check(phase, per_batch_budget_ms, plan)
      when phase in [:structural, :runtime] and is_integer(per_batch_budget_ms) and
             per_batch_budget_ms > 0 and is_map(plan) do
    completed = plan_list(plan, :completed)
    unstarted = plan_list(plan, :unstarted)
    interrupted = plan_value(plan, :interrupted)

    with :ok <- validate_capacity_plan(phase, completed, interrupted, unstarted),
         compact_interrupted <- compact_interrupted(interrupted),
         compact_unstarted <- Enum.map(unstarted, &capacity_batch/1),
         digest_subject <-
           if(compact_interrupted,
             do: [compact_interrupted | compact_unstarted],
             else: compact_unstarted
           ),
         {:ok, digest} <- ValidationCapacityHandoff.ordered_plan_digest(digest_subject),
         completed_files <- Enum.sum(Enum.map(completed, & &1.count)),
         interrupted_files <- interrupted_file_count(interrupted),
         unstarted_files <- Enum.sum(Enum.map(unstarted, & &1.count)),
         total_batches <-
           length(completed) + interrupted_batch_count(interrupted) + length(unstarted),
         {:ok, handoff} <-
           ValidationCapacityHandoff.new(%{
             "schema_version" => ValidationCapacityHandoff.schema_version(),
             "phase" => Atom.to_string(phase),
             "available_budget_ms" => 0,
             "per_batch_budget_ms" => per_batch_budget_ms,
             "completed_batch_count" => length(completed),
             "completed_file_count" => completed_files,
             "unstarted_batch_count" => length(unstarted),
             "unstarted_file_count" => unstarted_files,
             "total_batch_count" => total_batches,
             "total_file_count" => completed_files + interrupted_files + unstarted_files,
             "ordered_plan_sha256" => digest,
             "interrupted_batch" => compact_interrupted,
             "unstarted_batches" => compact_unstarted
           }) do
      check =
        Map.put(
          completed_check(%{"passed" => false, "exit_code" => nil},
            reason: "validation_capacity_exceeded"
          ),
          "capacity_handoff",
          ValidationCapacityHandoff.to_map(handoff)
        )

      {:ok, check}
    else
      {:error, _} = error -> error
    end
  end

  def capacity_check(_, _, _), do: {:error, :invalid_capacity_handoff}

  @doc false
  @spec preflight_batch(String.t()) :: map()
  def preflight_batch(inventory_sha256) when is_binary(inventory_sha256) do
    compact_batch(1, 2, 1, inventory_sha256)
  end

  @doc false
  @spec tests_batch(pos_integer(), String.t()) :: map()
  def tests_batch(count, inventory_sha256)
      when is_integer(count) and count > 0 and is_binary(inventory_sha256) do
    compact_batch(2, 2, count, inventory_sha256)
  end

  @doc false
  @spec inventory_sha256([String.t()]) :: String.t()
  def inventory_sha256(parts) when is_list(parts) do
    parts
    |> Enum.join("\n")
    |> sha256()
  end

  defp attach_interrupted_capacity(feedback, plan) do
    current = plan_value(plan, :current)
    timeout = plan_value(plan, :per_batch_budget_ms)

    with true <- is_map(current),
         true <- is_integer(timeout) and timeout > 0,
         {:ok, capacity} <-
           capacity_check(:runtime, timeout, %{
             completed: plan_list(plan, :completed),
             interrupted: current,
             unstarted: plan_list(plan, :unstarted)
           }) do
      check =
        Map.put(
          completed_check(feedback, reason: "validation_capacity_exceeded"),
          "capacity_handoff",
          capacity["capacity_handoff"]
        )

      {:ok, check}
    else
      {:error, _} = error -> error
      _other -> {:error, :invalid_capacity_handoff}
    end
  end

  defp ordinary_check(feedback, true, _stage), do: {:ok, completed_check(feedback)}

  defp ordinary_check(feedback, false, :preflight),
    do: {:ok, completed_check(feedback, reason: "preflight_failed")}

  defp ordinary_check(feedback, false, :test),
    do: {:ok, completed_check(feedback, reason: "tests_failed")}

  defp projection_field(projection, key) when is_atom(key) do
    cond do
      is_map_key(projection, key) -> Map.get(projection, key)
      is_map_key(projection, Atom.to_string(key)) -> Map.get(projection, Atom.to_string(key))
      true -> nil
    end
  end

  defp plan_list(plan, key) do
    List.wrap(plan_value(plan, key) || [])
  end

  defp plan_value(plan, key) when is_atom(key) do
    cond do
      is_map_key(plan, key) -> Map.get(plan, key)
      is_map_key(plan, Atom.to_string(key)) -> Map.get(plan, Atom.to_string(key))
      true -> nil
    end
  end

  defp validate_capacity_plan(phase, completed, nil, unstarted)
       when phase in [:structural, :runtime] and is_list(completed) and is_list(unstarted) and
              unstarted != [] do
    if Enum.all?(completed ++ unstarted, &valid_capacity_batch?/1) do
      :ok
    else
      {:error, :invalid_capacity_handoff}
    end
  end

  defp validate_capacity_plan(:runtime, completed, interrupted, unstarted)
       when is_list(completed) and is_map(interrupted) and is_list(unstarted) do
    if valid_capacity_batch?(interrupted) and
         Enum.all?(completed ++ unstarted, &valid_capacity_batch?/1) do
      :ok
    else
      {:error, :invalid_capacity_handoff}
    end
  end

  defp validate_capacity_plan(_, _, _, _), do: {:error, :invalid_capacity_handoff}

  defp compact_interrupted(nil), do: nil
  defp compact_interrupted(batch) when is_map(batch), do: capacity_batch(batch)

  defp interrupted_file_count(nil), do: 0
  defp interrupted_file_count(%{count: count}) when is_integer(count), do: count

  defp interrupted_batch_count(nil), do: 0
  defp interrupted_batch_count(_batch), do: 1

  defp valid_capacity_batch?(%{index: i, total: t, count: c, label: l, inventory_sha256: sha})
       when is_integer(i) and is_integer(t) and is_integer(c) and c > 0 and is_binary(l) and
              is_binary(sha),
       do: l == canonical_batch_label(i, t, c, sha)

  defp valid_capacity_batch?(_), do: false

  defp compact_batch(index, total, count, inventory_sha256) do
    %{
      index: index,
      total: total,
      count: count,
      label: canonical_batch_label(index, total, count, inventory_sha256),
      inventory_sha256: inventory_sha256
    }
  end

  defp canonical_batch_label(index, total, count, inventory_sha256),
    do: "batch-#{index}-of-#{total}-n#{count}-#{inventory_sha256}"

  defp capacity_batch(batch) do
    %{
      "index" => batch.index,
      "total" => batch.total,
      "count" => batch.count,
      "label" => batch.label,
      "inventory_sha256" => batch.inventory_sha256
    }
  end

  defp recognized_contract_surface?(path, app_roots) when is_binary(path) do
    case split_repo_path(path) do
      {:ok, ["apps", "arbor_kernel", "lib", "arbor", "contracts.ex"]} ->
        true

      {:ok, ["apps", "arbor_kernel", "lib", "arbor", "contracts" | rest]} when rest != [] ->
        true

      {:ok, ["docs", "arbor", "CONTRACT_RULES.md"]} ->
        true

      {:ok, ["apps", "arbor_kernel", "lib", "mix", "tasks", "arbor.contracts.census.ex"]} ->
        true

      {:ok, ["apps", "arbor_kernel", "lib", "arbor", "contracts_census.ex"]} ->
        true

      {:ok, ["apps", app, "lib" | rest]} ->
        app_owned_lib_contracts?(app, rest, app_roots)

      {:ok, _other} ->
        false

      :error ->
        false
    end
  end

  defp recognized_contract_surface?(_, _), do: false

  defp app_owned_lib_contracts?(app, rest, app_roots) when is_list(rest) do
    valid_app_id?(app) and MapSet.member?(app_roots, app) and contracts_descendant?(rest)
  end

  defp app_roots_from_paths(paths) when is_list(paths) do
    Enum.reduce(paths, MapSet.new(), fn path, acc ->
      case split_repo_path(path) do
        {:ok, ["apps", app, "mix.exs"]} ->
          if valid_app_id?(app), do: MapSet.put(acc, app), else: acc

        _other ->
          acc
      end
    end)
  end

  defp contracts_descendant?(segments) when is_list(segments) do
    case Enum.split_while(segments, &(&1 != "contracts")) do
      {_before, ["contracts" | rest]} when rest != [] -> true
      _ -> false
    end
  end

  defp kernel_suite(freeze_paths) do
    freeze_paths
    |> Enum.filter(&kernel_contract_test?/1)
    |> Enum.sort()
  end

  defp kernel_contract_test?(path) do
    case split_repo_path(path) do
      {:ok, ["apps", "arbor_kernel", "test", "arbor", "contracts" | rest]} ->
        rest != [] and test_file_name?(List.last(rest))

      _ ->
        false
    end
  end

  defp additional_tests(changed_path, freeze_set) do
    mapped =
      case map_lib_contract_to_test(changed_path) do
        {:ok, test_path} -> if MapSet.member?(freeze_set, test_path), do: [test_path], else: []
        :error -> []
      end

    changed_tests =
      if MapSet.member?(freeze_set, changed_path) and app_owned_contract_test?(changed_path) do
        [changed_path]
      else
        []
      end

    mapped ++ changed_tests
  end

  defp app_owned_contract_test?(path) do
    case split_repo_path(path) do
      {:ok, ["apps", app, "test" | rest]} ->
        valid_app_id?(app) and contracts_descendant?(rest) and
          test_file_name?(List.last(rest))

      _ ->
        false
    end
  end

  defp map_lib_contract_to_test(path) do
    case split_repo_path(path) do
      {:ok, ["apps", app, "lib" | rest]} ->
        if valid_app_id?(app) and contracts_descendant?(rest) do
          case List.pop_at(rest, -1) do
            {file, dir} when is_binary(file) ->
              if String.ends_with?(file, ".ex") do
                stem = binary_part(file, 0, byte_size(file) - 3)
                {:ok, Path.join(["apps", app, "test" | dir] ++ [stem <> "_test.exs"])}
              else
                :error
              end

            _ ->
              :error
          end
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp test_file_name?(name) when is_binary(name), do: String.ends_with?(name, "_test.exs")
  defp test_file_name?(_), do: false

  defp valid_app_id?(app) when is_binary(app) do
    not MapSet.member?(@retired_apps, app) and valid_identifier?(app)
  end

  defp valid_app_id?(_), do: false

  defp valid_identifier?(name)
       when is_binary(name) and name != "" and byte_size(name) <= @max_identifier_bytes do
    String.match?(name, @app_id_re)
  end

  defp valid_identifier?(_), do: false

  defp normalize_changed_files(files) do
    collect_repo_paths(files, @max_changed_files)
  end

  defp normalize_freeze_paths(files) do
    collect_repo_paths(files, Arbor.Actions.Coding.BlobManifest.max_entries())
  end

  defp normalize_test_files(files) do
    collect_repo_paths(files, @max_contract_tests, &test_file_name?(List.last(elem(&1, 1))))
  end

  defp collect_repo_paths(files, max) do
    collect_repo_paths(files, max, fn _ -> true end)
  end

  defp collect_repo_paths(files, max, pred) when is_list(files) and is_function(pred, 1) do
    Enum.reduce_while(files, {:ok, [], MapSet.new(), 0}, fn file, {:ok, acc, seen, count} ->
      cond do
        count >= max ->
          {:halt, {:error, :too_many_paths}}

        true ->
          case split_repo_path(file) do
            {:ok, segments} ->
              if pred.({file, segments}) do
                if MapSet.member?(seen, file) do
                  {:cont, {:ok, acc, seen, count}}
                else
                  {:cont, {:ok, [file | acc], MapSet.put(seen, file), count + 1}}
                end
              else
                {:halt, {:error, {:invalid_repo_path, file}}}
              end

            :error ->
              {:halt, {:error, {:invalid_repo_path, file}}}
          end
      end
    end)
    |> case do
      {:ok, acc, _seen, _count} -> {:ok, Enum.sort(acc)}
      {:error, _} = error -> error
    end
  end

  defp collect_repo_paths(_, _, _), do: {:error, :invalid_paths}

  defp split_repo_path(path) when is_binary(path) do
    cond do
      path == "" ->
        :error

      not String.valid?(path) ->
        :error

      byte_size(path) > @max_path_bytes ->
        :error

      String.contains?(path, <<0>>) ->
        :error

      String.contains?(path, "\\") ->
        :error

      String.starts_with?(path, "/") ->
        :error

      String.trim(path) != path ->
        :error

      true ->
        segments = String.split(path, "/")

        if segments == [] or Enum.any?(segments, &invalid_repo_segment?/1) do
          :error
        else
          {:ok, segments}
        end
    end
  end

  defp split_repo_path(_), do: :error

  defp invalid_repo_segment?(segment) when is_binary(segment) do
    segment in ["", ".", ".."] or String.trim(segment) != segment
  end

  defp invalid_repo_segment?(_), do: true

  defp overall_reason(true, _preflight, _test), do: "contract_change_validated"

  defp overall_reason(false, preflight, test) do
    cond do
      preflight["passed"] != true -> preflight["reason"] || "preflight_failed"
      test["passed"] != true -> test["reason"] || "tests_failed"
      true -> "validation_failed"
    end
  end

  defp normalize_check(check) when is_map(check) do
    normalized = %{
      "status" =>
        to_string_value(Map.get(check, :status) || Map.get(check, "status") || "unknown"),
      "passed" => Map.get(check, :passed) || Map.get(check, "passed") || false,
      "exit_code" => Map.get(check, :exit_code) || Map.get(check, "exit_code"),
      "reason" => Map.get(check, :reason) || Map.get(check, "reason"),
      "stdout_excerpt" =>
        json_safe_utf8(Map.get(check, :stdout_excerpt) || Map.get(check, "stdout_excerpt") || ""),
      "stderr_excerpt" =>
        json_safe_utf8(Map.get(check, :stderr_excerpt) || Map.get(check, "stderr_excerpt") || ""),
      "stdout_truncated" =>
        Map.get(check, :stdout_truncated) || Map.get(check, "stdout_truncated") || false,
      "stderr_truncated" =>
        Map.get(check, :stderr_truncated) || Map.get(check, "stderr_truncated") || false,
      "stdout_sha256" =>
        Map.get(check, :stdout_sha256) || Map.get(check, "stdout_sha256") || sha256(""),
      "stderr_sha256" =>
        Map.get(check, :stderr_sha256) || Map.get(check, "stderr_sha256") || sha256("")
    }

    normalized =
      case Map.get(check, :capacity_handoff) || Map.get(check, "capacity_handoff") do
        handoff when is_map(handoff) -> Map.put(normalized, "capacity_handoff", handoff)
        _ -> normalized
      end

    case Map.get(check, :termination) || Map.get(check, "termination") do
      termination when is_map(termination) -> Map.put(normalized, "termination", termination)
      _ -> normalized
    end
  end

  defp normalize_check(_), do: skipped_check("missing_check")

  defp to_string_value(value) when is_binary(value), do: value
  defp to_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_value(value), do: inspect(value)

  defp validate_param_keys(params) do
    valid? =
      Enum.all?(Map.keys(params), fn key ->
        key in @allowed_param_keys or key in @allowed_param_string_keys
      end)

    if valid?, do: :ok, else: {:error, :unsupported_parameter}
  end

  defp validate_workspace_id(value)
       when is_binary(value) and value != "" and byte_size(value) <= 256 do
    if String.valid?(value) and not String.contains?(value, <<0>>) do
      {:ok, value}
    else
      {:error, :invalid_workspace_id}
    end
  end

  defp validate_workspace_id(_value), do: {:error, :invalid_workspace_id}

  defp validate_timeout(nil), do: {:ok, @default_timeout}

  defp validate_timeout(timeout)
       when is_integer(timeout) and timeout >= @minimum_timeout and timeout <= @maximum_timeout,
       do: {:ok, timeout}

  defp validate_timeout(_timeout), do: {:error, :invalid_timeout}

  defp validate_stage_timeout(nil), do: {:ok, @default_stage_timeout}

  defp validate_stage_timeout(timeout)
       when is_integer(timeout) and timeout >= @minimum_timeout and
              timeout <= @maximum_stage_timeout,
       do: {:ok, timeout}

  defp validate_stage_timeout(_timeout), do: {:error, :invalid_stage_timeout}

  defp param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, Atom.to_string(key))
    end
  end

  defp evidence_field(evidence, key) when is_atom(key) do
    cond do
      is_map_key(evidence, key) -> Map.get(evidence, key)
      is_map_key(evidence, Atom.to_string(key)) -> Map.get(evidence, Atom.to_string(key))
      true -> nil
    end
  end

  defp project_feedback_check(check) when is_map(check) and not is_struct(check) do
    stdout_raw = feedback_excerpt_raw(check, :stdout_excerpt)
    stderr_raw = feedback_excerpt_raw(check, :stderr_excerpt)

    with {:ok, status} <- bound_feedback_status(evidence_field(check, :status)),
         passed when is_boolean(passed) <- evidence_field(check, :passed),
         {:ok, exit_code} <- bound_feedback_exit_code(evidence_field(check, :exit_code)),
         {:ok, reason} <- bound_optional_reason(evidence_field(check, :reason)),
         true <- is_binary(stdout_raw),
         true <- is_binary(stderr_raw),
         {:ok, stdout_truncated} <- bound_truncated_flag(check, :stdout_truncated),
         {:ok, stderr_truncated} <- bound_truncated_flag(check, :stderr_truncated),
         {:ok, stdout_sha} <- bound_feedback_sha256(evidence_field(check, :stdout_sha256)),
         {:ok, stderr_sha} <- bound_feedback_sha256(evidence_field(check, :stderr_sha256)) do
      {stdout_excerpt, stdout_cut} = bound_output_excerpt(stdout_raw)
      {stderr_excerpt, stderr_cut} = bound_output_excerpt(stderr_raw)

      {:ok,
       %{
         "status" => status,
         "passed" => passed,
         "exit_code" => exit_code,
         "reason" => reason,
         "stdout_excerpt" => stdout_excerpt,
         "stderr_excerpt" => stderr_excerpt,
         "stdout_truncated" => stdout_truncated or stdout_cut,
         "stderr_truncated" => stderr_truncated or stderr_cut,
         "stdout_sha256" => stdout_sha,
         "stderr_sha256" => stderr_sha
       }}
    else
      _other -> :error
    end
  end

  defp project_feedback_check(_check), do: :error

  defp feedback_excerpt_raw(check, key) do
    case evidence_field(check, key) do
      nil -> ""
      value -> value
    end
  end

  defp bound_feedback_reason(reason)
       when is_binary(reason) and reason != "" and
              byte_size(reason) <= @max_feedback_reason_bytes do
    if String.valid?(reason) and not String.contains?(reason, <<0>>),
      do: {:ok, reason},
      else: :error
  end

  defp bound_feedback_reason(_reason), do: :error

  defp bound_optional_reason(nil), do: {:ok, nil}

  defp bound_optional_reason(reason)
       when is_binary(reason) and byte_size(reason) <= @max_feedback_reason_bytes do
    if String.valid?(reason) and not String.contains?(reason, <<0>>),
      do: {:ok, reason},
      else: :error
  end

  defp bound_optional_reason(_reason), do: :error

  defp bound_feedback_oid(oid) when is_binary(oid) and byte_size(oid) in [40, 64] do
    if Regex.match?(@oid_re, oid), do: {:ok, oid}, else: :error
  end

  defp bound_feedback_oid(_oid), do: :error

  defp bound_feedback_status(status) when status in @feedback_check_statuses, do: {:ok, status}
  defp bound_feedback_status(:completed), do: {:ok, "completed"}
  defp bound_feedback_status(:skipped), do: {:ok, "skipped"}
  defp bound_feedback_status(_status), do: :error

  defp bound_feedback_exit_code(nil), do: {:ok, nil}

  defp bound_feedback_exit_code(code)
       when is_integer(code) and code >= 0 and code <= 255,
       do: {:ok, code}

  defp bound_feedback_exit_code(_code), do: :error

  defp bound_truncated_flag(check, key) do
    case evidence_field(check, key) do
      nil -> {:ok, false}
      value when is_boolean(value) -> {:ok, value}
      _other -> :error
    end
  end

  defp bound_feedback_sha256(value) do
    if valid_feedback_sha256?(value), do: {:ok, value}, else: :error
  end

  defp valid_feedback_sha256?(value) when is_binary(value) and byte_size(value) == 64 do
    Regex.match?(@sha256_re, value)
  end

  defp valid_feedback_sha256?(_value), do: false

  defp raw_stream(result, key) do
    Map.get(result, key) || Map.get(result, Atom.to_string(key)) || ""
  end

  defp bound_output_excerpt(raw) when is_binary(raw) do
    size = byte_size(raw)

    if size <= @max_output_excerpt_bytes do
      {json_safe_utf8(raw), false}
    else
      marker = @excerpt_omission_marker
      available = @max_output_excerpt_bytes - byte_size(marker)
      head_budget = div(available, 2)
      tail_budget = available - head_budget
      head = json_safe_utf8(binary_part(raw, 0, min(head_budget, size)))
      tail_start = max(size - tail_budget, 0)
      tail = json_safe_utf8(binary_part(raw, tail_start, size - tail_start))
      {head <> marker <> tail, true}
    end
  end

  defp bound_output_excerpt(_), do: {"", false}

  defp json_safe_utf8(data) when is_binary(data) do
    if String.valid?(data), do: data, else: replace_invalid_utf8(data)
  end

  defp json_safe_utf8(_), do: ""

  defp replace_invalid_utf8(data) when is_binary(data) do
    case :unicode.characters_to_binary(data, :utf8, :utf8) do
      result when is_binary(result) ->
        result

      {:error, good, rest} when is_binary(good) and is_binary(rest) and rest != <<>> ->
        good <>
          @utf8_replacement <> replace_invalid_utf8(binary_part(rest, 1, byte_size(rest) - 1))

      {:error, good, _rest} when is_binary(good) ->
        good <> @utf8_replacement

      {:incomplete, good, _rest} when is_binary(good) ->
        good <> @utf8_replacement

      _other ->
        @utf8_replacement
    end
  end

  defp sha256(output) when is_binary(output) do
    :crypto.hash(:sha256, output) |> Base.encode16(case: :lower)
  end
end
