defmodule Arbor.Actions.Coding.CrossApp.Core do
  @moduledoc """
  Pure input, dependency-selection, and evidence logic for cross-app validation.

  The imperative shell supplies changed files and parsed app metadata. This module
  decides the affected-app closure and formats JSON-clean validation evidence
  without filesystem, process, clock, or registry operations.
  """

  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @default_timeout 300_000
  @minimum_timeout 1_000
  # cross_app uses Shell :intensive resource_profile for every contained Mix
  # stage, so per-operation timeout derives from the intensive spawn-capable
  # ceiling (not the standard 600_000 ms default).
  @maximum_timeout (case Arbor.Shell.spawn_capable_max_timeout_ms(:intensive) do
                      {:ok, ms} when is_integer(ms) and ms > 0 ->
                        ms

                      other ->
                        raise CompileError,
                          description:
                            "cross_app maximum_timeout requires a positive Shell intensive spawn-capable ceiling; got #{inspect(other)}"
                    end)
  # Aggregate sequential test-stage ceiling is distinct from the intensive
  # per-process Shell bound. Reviewed cross_app max is 4_200_000 ms (70 min)
  # so sequential bounded multi-file intensive children can complete a full
  # inventory without widening Shell ceilings (live task_19076 exhausted 40
  # min on batch 7 of 40 under the prior one-file runtime cap after four
  # healthy children alone took ~2_007 s). Effective stage budget is still
  # min(this, plan wall_clock) at compile time.
  @default_test_stage_timeout 300_000
  @maximum_test_stage_timeout 4_200_000
  @allowed_param_keys [:workspace_id, :timeout, :test_stage_timeout]
  @allowed_param_string_keys Enum.map(@allowed_param_keys, &Atom.to_string/1)

  @max_changed_files 2_000
  @max_apps 256
  @max_identifier_bytes 64
  @max_test_paths 256
  # Expanded per-file list after directory expansion (tracked + untracked).
  @max_expanded_test_files 2_000
  # Combined raw Git inventory entries under selected test dirs before suffix
  # filtering / dedup / lstat (ignored/generated paths still consume this bound).
  @max_git_inventory_entries 8_000
  # Closed Mix argv batch limits after exact-file normalization/lstat. Each
  # invocation prepends `["test", "--"]`. Path slots are the minimum of:
  #   * Shell's public non-bypassable argv ceiling minus fixed args
  #   * a reviewed runtime batch cap (at most 20 exact test files per child)
  # so multi-file suites amortize container startup without exhausting the
  # intensive per-process wall clock, while still preserving the complete
  # exact inventory across sequential batches. The sum of each path's UTF-8
  # bytes plus one separator byte must also stay under the byte ceiling. A
  # single normalized path (max 1024 bytes) always fits both bounds.
  @test_batch_fixed_args 2
  @max_test_batch_runtime_files 20
  @max_test_batch_argv_files Arbor.Shell.spawn_capable_max_command_args() - @test_batch_fixed_args
  @max_test_batch_files min(@max_test_batch_runtime_files, @max_test_batch_argv_files)
  @max_test_batch_arg_bytes 65_536
  @max_output_list 2_000
  # Process/stream excerpts and aggregate evidence are fixed-size by *bytes*.
  @max_output_excerpt_bytes 2_000
  @max_aggregate_excerpt_bytes 2_000
  @excerpt_omission_marker "\n...[omitted]...\n"
  # U+FFFD replacement character in UTF-8.
  @utf8_replacement <<0xEF, 0xBF, 0xBD>>
  # Max incomplete UTF-8 sequence length is 3 trailing/leading bytes. Windows
  # take this extra raw allowance so repair can complete a cut multi-byte char
  # without scanning the rest of the stream.
  @utf8_boundary_allowance 3
  # Failure-aware excerpt: small head/tail windows preserve ExUnit seed and
  # final summary; the bulk of the byte budget centers on the first stable
  # diagnostic anchor so the resumed worker sees the actual assertion rather
  # than rerunning the suite. Diagnostic detection only chooses which bytes
  # to preserve; exit code remains the sole pass/fail authority.
  @excerpt_head_share 8
  @excerpt_anchor_lookback 64
  # Byte-level anchors that recognize ExUnit's first numbered failure block,
  # Mix compilation-error banners, and uncaught Mix/BEAM exception headings
  # without parsing prose as pass/fail authority. Erlang's :re runs PCRE in
  # byte mode on raw binaries, so invalid UTF-8 in the stream does not raise.
  @diagnostic_anchor_pattern ~r/  [0-9]+\) [^\n]+\([A-Z][A-Za-z0-9_.]*\)|== Compilation error|\*\* \([A-Z][A-Za-z0-9_.]*\)/

  @root_wide_exact MapSet.new([
                     "mix.exs",
                     "mix.lock",
                     ".formatter.exs",
                     ".tool-versions"
                   ])

  @typedoc "Normalized, side-effect-free action input."
  @type input :: %{
          workspace_id: String.t(),
          timeout: pos_integer(),
          test_stage_timeout: pos_integer()
        }

  @typedoc "One umbrella app's static dependency metadata."
  @type app_def :: %{
          dir: String.t(),
          app: String.t(),
          deps: [String.t()]
        }

  @typedoc "Dependency graph keyed by app directory/name."
  @type graph :: %{
          apps: [String.t()],
          # app => upstream in-umbrella deps it depends on
          depends_on: %{optional(String.t()) => [String.t()]},
          # app => downstream apps that depend on it
          depended_by: %{optional(String.t()) => [String.t()]}
        }

  @typedoc "Selection result for changed files against a graph."
  @type selection :: %{
          changed_files: [String.t()],
          changed_apps: [String.t()],
          affected_apps: [String.t()],
          test_paths: [String.t()],
          root_wide: boolean()
        }

  @typedoc "One deterministic argv-safe batch of exact `*_test.exs` paths."
  @type test_batch :: %{
          label: String.t(),
          paths: [String.t()],
          index: pos_integer(),
          total: pos_integer(),
          count: pos_integer(),
          inventory_sha256: String.t()
        }

  @typedoc "One completed (or budget-exhausted) batch test invocation record."
  @type app_test_result :: %{
          path: String.t(),
          passed: boolean(),
          timed_out: boolean(),
          exit_code: integer() | nil,
          reason: String.t() | nil,
          stdout_excerpt: String.t(),
          stderr_excerpt: String.t(),
          stdout_truncated: boolean(),
          stderr_truncated: boolean(),
          stdout_sha256: String.t(),
          stderr_sha256: String.t()
        }

  @typedoc "Pure decision for the next sequential batch Mix invocation."
  @type test_step ::
          :complete
          | {:run, test_batch(), pos_integer(), [test_batch()]}
          | {:timeout, test_batch(), [test_batch()]}
          | {:error, term()}

  @typedoc "Bounded evidence for a validation capacity handoff."
  @type capacity_handoff :: %{required(String.t()) => term()}

  @doc "Construct and validate the action's deliberately narrow input surface."
  @spec new(map()) :: {:ok, input()} | {:error, atom()}
  def new(params) when is_map(params) do
    with :ok <- validate_param_keys(params),
         {:ok, workspace_id} <- validate_workspace_id(param(params, :workspace_id)),
         {:ok, timeout} <- validate_timeout(param(params, :timeout)),
         {:ok, test_stage_timeout} <-
           validate_test_stage_timeout(param(params, :test_stage_timeout)) do
      {:ok,
       %{
         workspace_id: workspace_id,
         timeout: timeout,
         test_stage_timeout: test_stage_timeout
       }}
    end
  end

  def new(_params), do: {:error, :invalid_parameters}

  @doc "Build a dependency graph from pure app definitions. Fails closed on ambiguity."
  @spec build_graph([app_def()]) :: {:ok, graph()} | {:error, term()}
  def build_graph(app_defs) when is_list(app_defs) do
    with :ok <- validate_app_def_count(app_defs),
         :ok <- validate_app_defs(app_defs) do
      apps = app_defs |> Enum.map(& &1.dir) |> Enum.sort()
      app_set = MapSet.new(apps)

      depends_on =
        Map.new(app_defs, fn %{dir: dir, deps: deps} ->
          {dir, deps |> Enum.uniq() |> Enum.sort()}
        end)

      with :ok <- validate_dep_targets(depends_on, app_set) do
        depended_by =
          Enum.reduce(depends_on, %{}, fn {app, deps}, acc ->
            Enum.reduce(deps, acc, fn dep, acc2 ->
              Map.update(acc2, dep, [app], fn existing -> [app | existing] end)
            end)
          end)
          |> Map.new(fn {k, v} -> {k, v |> Enum.uniq() |> Enum.sort()} end)

        {:ok,
         %{
           apps: apps,
           depends_on: depends_on,
           depended_by: depended_by
         }}
      end
    end
  end

  def build_graph(_), do: {:error, :invalid_app_defs}

  @doc """
  Select changed and affected apps from changed files and a dependency graph.

  Directly changed apps plus every downstream in-umbrella dependent. Root
  build-impact files select all apps. Unrelated docs do not widen selection.
  """
  @spec select([String.t()], graph()) :: {:ok, selection()} | {:error, term()}
  def select(changed_files, graph) when is_list(changed_files) and is_map(graph) do
    with {:ok, files} <- normalize_changed_files(changed_files),
         {:ok, changed_apps, root_wide} <- classify_files(files, graph) do
      affected_apps =
        if root_wide do
          graph.apps
        else
          downstream_closure(changed_apps, graph.depended_by)
        end

      test_paths =
        affected_apps
        |> Enum.map(&("apps/" <> &1 <> "/test"))
        |> Enum.take(@max_test_paths)

      {:ok,
       %{
         changed_files: Enum.take(files, @max_output_list),
         changed_apps: changed_apps,
         affected_apps: affected_apps,
         test_paths: test_paths,
         root_wide: root_wide
       }}
    end
  end

  def select(_, _), do: {:error, :invalid_selection_input}

  @doc "Assemble bounded JSON-clean evidence from selection and check results."
  @spec show(map()) :: map()
  def show(%{
        selection: selection,
        checks: checks,
        base_commit: base_commit
      })
      when is_map(selection) and is_map(checks) do
    compile = Map.get(checks, :compile) || Map.get(checks, "compile") || %{}
    xref = Map.get(checks, :xref) || Map.get(checks, "xref") || %{}
    test_compile = Map.get(checks, :test_compile) || Map.get(checks, "test_compile") || %{}
    test = Map.get(checks, :test) || Map.get(checks, "test") || %{}

    compile_passed = Map.get(compile, :passed) || Map.get(compile, "passed") || false
    xref_passed = Map.get(xref, :passed) || Map.get(xref, "passed") || false

    test_compile_passed =
      Map.get(test_compile, :passed) || Map.get(test_compile, "passed") || false

    test_passed = Map.get(test, :passed) || Map.get(test, "passed") || false

    passed = compile_passed and xref_passed and test_compile_passed and test_passed
    reason = overall_reason(passed, compile, xref, test_compile, test)

    %{
      passed: passed,
      reason: reason,
      base_commit: base_commit,
      changed_files: selection.changed_files,
      changed_apps: selection.changed_apps,
      affected_apps: selection.affected_apps,
      test_paths: selection.test_paths,
      root_wide: selection.root_wide,
      compile: normalize_check(compile),
      xref: normalize_check(xref),
      test_compile: normalize_check(test_compile),
      test: normalize_check(test)
    }
  end

  @doc false
  def default_timeout, do: @default_timeout

  @doc false
  def maximum_timeout, do: @maximum_timeout

  @doc false
  def default_test_stage_timeout, do: @default_test_stage_timeout

  @doc false
  def maximum_test_stage_timeout, do: @maximum_test_stage_timeout

  @doc false
  def max_expanded_test_files, do: @max_expanded_test_files

  @doc false
  def max_git_inventory_entries, do: @max_git_inventory_entries

  @doc false
  def max_test_batch_files, do: @max_test_batch_files

  @doc false
  def max_test_batch_runtime_files, do: @max_test_batch_runtime_files

  @doc false
  def max_test_batch_argv_files, do: @max_test_batch_argv_files

  @doc false
  def max_test_batch_arg_bytes, do: @max_test_batch_arg_bytes

  @doc false
  def root_wide_path?(path) when is_binary(path) do
    cond do
      MapSet.member?(@root_wide_exact, path) -> true
      String.starts_with?(path, "config/") -> true
      true -> false
    end
  end

  def root_wide_path?(_), do: false

  @doc false
  def app_dir_from_path(path) when is_binary(path) do
    case Path.split(path) do
      ["apps", app | _rest] when app != "" ->
        if valid_identifier?(app), do: {:ok, app}, else: {:error, {:invalid_app_dir, app}}

      _ ->
        :not_app_path
    end
  end

  def app_dir_from_path(_), do: :not_app_path

  @doc "Build a skipped-check map (domain failure cascade)."
  @spec skipped_check(String.t()) :: map()
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

  @doc "Build a completed-check map from Mix feedback plus optional status."
  @spec completed_check(map(), keyword()) :: map()
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

  @doc "No-op passed check when there is nothing to run (e.g. zero test paths)."
  @spec empty_pass_check(String.t()) :: map()
  def empty_pass_check(reason) when is_binary(reason) do
    %{
      "status" => "skipped",
      "passed" => true,
      "exit_code" => 0,
      "reason" => reason,
      "stdout_excerpt" => "",
      "stderr_excerpt" => "",
      "stdout_truncated" => false,
      "stderr_truncated" => false,
      "stdout_sha256" => sha256(""),
      "stderr_sha256" => sha256("")
    }
  end

  @doc """
  Build JSON-clean Mix feedback from a raw process result map.

  Process streams are treated as arbitrary bytes: SHA-256 hashes the raw binary,
  excerpts are UTF-8-safe for Jason, and excerpt length is bounded by *bytes*
  without splitting multi-byte codepoints. For a nonzero exit, the excerpt is
  failure-aware: a small head window, the first stable diagnostic anchor
  centered in the bulk of the budget, and a small tail window — so a multi-KB
  ExUnit stream no longer drops every failure block between head and tail.
  """
  @spec feedback_from_result(map()) :: map()
  def feedback_from_result(result) when is_map(result) do
    stdout = raw_stream(result, :stdout)
    stderr = raw_stream(result, :stderr)
    exit_code = Map.get(result, :exit_code) || Map.get(result, "exit_code")

    # Exit code is the sole pass/fail authority. For nonzero exits, prefer the
    # failure-aware excerpt so the worker sees the diagnostic; otherwise use
    # the established head/tail window. The two paths share UTF-8 repair and
    # the byte ceiling, and the failure-aware path falls back to head/tail
    # when no stable anchor is present.
    {stdout_excerpt, stdout_truncated} =
      if exit_code == 0,
        do: bound_output_excerpt(stdout),
        else: bound_failure_aware_excerpt(stdout)

    {stderr_excerpt, stderr_truncated} =
      if exit_code == 0,
        do: bound_output_excerpt(stderr),
        else: bound_failure_aware_excerpt(stderr)

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
  True only for exact runner/result timeout markers.

  Never inspects stdout/stderr/reason text for words like "timeout".
  """
  @spec runner_timed_out?(term()) :: boolean()
  def runner_timed_out?(result) when is_map(result) do
    Map.get(result, :timed_out) == true or Map.get(result, "timed_out") == true
  end

  def runner_timed_out?(_), do: false

  @doc """
  Stage-level timeout after a child returns: runner marker **or** shared budget
  fully consumed (`remaining_ms_after <= 0`), including the final child.
  """
  @spec child_timed_out?(boolean(), integer()) :: boolean()
  def child_timed_out?(runner_timed_out?, remaining_ms_after)
      when is_boolean(runner_timed_out?) and is_integer(remaining_ms_after) do
    runner_timed_out? or remaining_ms_after <= 0
  end

  @doc """
  Pure next-step decision for sequential batch tests under dual budgets.

  `remaining_ms` is the aggregate test-stage budget remaining. Each child is
  capped by `min(operation_timeout_ms, remaining_ms)` so no Mix process may
  exceed the intensive Shell spawn-capable ceiling even when aggregate budget remains.

  Returns:
  - `:complete` when no batches remain
  - `{:run, batch, budget_ms, rest}` when budget remains
  - `{:timeout, batch, rest}` when budget is exhausted with batches left
  - `{:error, reason}` when arguments are malformed (fail closed; never skip)
  """
  @spec next_test_step(term(), term(), term()) :: test_step()
  def next_test_step(_remaining_ms, [], operation_timeout_ms)
      when is_integer(operation_timeout_ms) and operation_timeout_ms > 0 do
    :complete
  end

  def next_test_step(remaining_ms, [batch | rest], operation_timeout_ms)
      when is_integer(remaining_ms) and remaining_ms <= 0 and is_map(batch) and is_list(rest) and
             is_integer(operation_timeout_ms) and operation_timeout_ms > 0 do
    if valid_remaining_batches?([batch | rest]) do
      {:timeout, batch, rest}
    else
      invalid_test_step_input(remaining_ms, [batch | rest], operation_timeout_ms)
    end
  end

  def next_test_step(remaining_ms, [batch | rest], operation_timeout_ms)
      when is_integer(remaining_ms) and remaining_ms > 0 and is_map(batch) and is_list(rest) and
             is_integer(operation_timeout_ms) and operation_timeout_ms > 0 do
    if valid_remaining_batches?([batch | rest]) do
      {:run, batch, min(operation_timeout_ms, remaining_ms), rest}
    else
      invalid_test_step_input(remaining_ms, [batch | rest], operation_timeout_ms)
    end
  end

  def next_test_step(remaining_ms, batches, operation_timeout_ms) do
    invalid_test_step_input(remaining_ms, batches, operation_timeout_ms)
  end

  @doc """
  Conservative admission check for the complete reviewed batch plan.

  Every admitted batch receives up to the operation ceiling. If that complete
  worst-case plan cannot fit the aggregate stage budget, the caller must hand
  off before launching a child rather than knowingly starting a partial plan.
  """
  @spec admit_test_batches([test_batch()], pos_integer(), pos_integer()) ::
          :ok | {:capacity_exceeded, map()} | {:error, term()}
  def admit_test_batches(batches, available_ms, operation_timeout_ms)
      when is_list(batches) and is_integer(available_ms) and
             is_integer(operation_timeout_ms) and operation_timeout_ms > 0 do
    required_ms = length(batches) * operation_timeout_ms

    cond do
      batches == [] ->
        :ok

      not valid_remaining_batches?(batches) ->
        {:error, :invalid_test_batch_plan}

      required_ms <= available_ms ->
        :ok

      true ->
        case capacity_handoff(
               :structural,
               available_ms,
               operation_timeout_ms,
               required_ms,
               [],
               batches
             ) do
          {:ok, check} -> {:capacity_exceeded, check}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def admit_test_batches(_batches, _available_ms, _operation_timeout_ms),
    do: {:error, :invalid_test_batch_plan}

  @doc """
  Build the bounded, JSON-clean handoff check for an unstarted batch suffix.

  Batch paths are already admitted and normalized by partition_test_batches/1.
  The descriptor therefore binds the exact ordered suffix while retaining only
  deterministic labels, counts, and digests. Retained workspace and authorized
  inventory can reconstruct filenames; terminal evidence never carries them.
  """
  @spec capacity_handoff(
          :structural | :runtime,
          integer(),
          pos_integer(),
          pos_integer(),
          [test_batch()],
          [test_batch()]
        ) :: {:ok, map()} | {:error, term()}
  def capacity_handoff(
        phase,
        available_ms,
        per_batch_budget_ms,
        required_ms,
        completed_batches,
        unstarted_batches
      )
      when phase in [:structural, :runtime] and is_integer(available_ms) and
             is_integer(per_batch_budget_ms) and per_batch_budget_ms > 0 and
             is_integer(required_ms) and required_ms > 0 and is_list(completed_batches) and
             is_list(unstarted_batches) do
    with :ok <- validate_capacity_batches(completed_batches, unstarted_batches),
         all_batches <- completed_batches ++ unstarted_batches,
         completed_files <- Enum.sum(Enum.map(completed_batches, & &1.count)),
         unstarted_files <- Enum.sum(Enum.map(unstarted_batches, & &1.count)),
         compact_batches <- Enum.map(unstarted_batches, &capacity_batch/1),
         {:ok, ordered_plan_sha256} <-
           ValidationCapacityHandoff.ordered_plan_digest(compact_batches),
         {:ok, handoff} <-
           ValidationCapacityHandoff.new(%{
             "schema_version" => ValidationCapacityHandoff.schema_version(),
             "phase" => Atom.to_string(phase),
             "available_budget_ms" => max(available_ms, 0),
             "per_batch_budget_ms" => per_batch_budget_ms,
             "required_budget_ms" => required_ms,
             "completed_batch_count" => length(completed_batches),
             "completed_file_count" => completed_files,
             "unstarted_batch_count" => length(unstarted_batches),
             "unstarted_file_count" => unstarted_files,
             "total_batch_count" => length(all_batches),
             "total_file_count" => completed_files + unstarted_files,
             "ordered_plan_sha256" => ordered_plan_sha256,
             "unstarted_batches" => compact_batches
           }) do
      check =
        completed_check(
          %{"passed" => false, "exit_code" => nil},
          reason: "validation_capacity_exceeded"
        )
        |> Map.put("capacity_handoff", ValidationCapacityHandoff.to_map(handoff))

      {:ok, check}
    else
      {:error, _reason} = error -> error
    end
  end

  def capacity_handoff(
        _phase,
        _available_ms,
        _per_batch_budget_ms,
        _required_ms,
        _completed_batches,
        _unstarted_batches
      ),
      do: {:error, :invalid_capacity_handoff}

  defp capacity_batch(batch) do
    %{
      "index" => Map.get(batch, :index),
      "total" => Map.get(batch, :total),
      "count" => Map.get(batch, :count),
      "label" => Map.get(batch, :label),
      "inventory_sha256" => Map.get(batch, :inventory_sha256)
    }
  end

  defp validate_capacity_batches(completed_batches, unstarted_batches)
       when is_list(completed_batches) and is_list(unstarted_batches) and unstarted_batches != [] do
    all_batches = completed_batches ++ unstarted_batches

    if Enum.all?(all_batches, &is_map/1) and valid_remaining_batches?(all_batches),
      do: :ok,
      else: {:error, :invalid_capacity_batch_plan}
  end

  defp validate_capacity_batches(_completed_batches, _unstarted_batches),
    do: {:error, :invalid_capacity_batch_plan}

  defp invalid_test_step_input(remaining_ms, batches, operation_timeout_ms) do
    {:error,
     {:invalid_test_step_input,
      %{
        remaining_ms: remaining_ms,
        batches_shape: batches_shape(batches),
        operation_timeout_ms: operation_timeout_ms
      }}}
  end

  defp batches_shape(batches) when is_list(batches), do: {:list, length(batches)}
  defp batches_shape(batches), do: {:not_list, batches}

  # Fail closed: never trust caller-supplied label/digest/path metadata.
  # Recompute inventory bounds, SHA-256, deterministic label, and require the
  # remaining list to be a coherent ordered suffix of a partition.
  defp valid_remaining_batches?(batches) when is_list(batches) and batches != [] do
    Enum.all?(batches, &valid_test_batch?/1) and coherent_remaining_batch_indices?(batches) and
      exact_remaining_partition?(batches)
  end

  defp valid_remaining_batches?(_), do: false

  defp valid_test_batch?(%{
         label: label,
         paths: paths,
         index: index,
         total: total,
         count: count,
         inventory_sha256: inventory_sha256
       })
       when is_binary(label) and is_list(paths) and is_integer(index) and is_integer(total) and
              is_integer(count) and is_binary(inventory_sha256) do
    with :ok <- validate_batch_member_paths(paths),
         true <- index > 0 and total > 0 and index <= total,
         true <- count == length(paths),
         expected <- build_test_batch(paths, index, total) do
      label == expected.label and inventory_sha256 == expected.inventory_sha256 and
        count == expected.count and paths == expected.paths and index == expected.index and
        total == expected.total
    else
      _ -> false
    end
  end

  defp valid_test_batch?(_), do: false

  defp coherent_remaining_batch_indices?([%{index: first, total: total} | _] = batches)
       when is_integer(first) and is_integer(total) and first > 0 and total > 0 do
    n = length(batches)

    Enum.with_index(batches, 0)
    |> Enum.all?(fn {batch, offset} ->
      is_map(batch) and batch.index == first + offset and batch.total == total
    end) and first + n - 1 == total
  end

  defp coherent_remaining_batch_indices?(_), do: false

  defp exact_remaining_partition?(batches) do
    paths = Enum.flat_map(batches, & &1.paths)

    with :ok <- validate_batch_source_files(paths),
         {:ok, expected_paths} <- pack_test_batches(paths) do
      expected_paths == Enum.map(batches, & &1.paths)
    else
      _ -> false
    end
  end

  defp validate_batch_member_paths(paths) when is_list(paths) and paths != [] do
    count = length(paths)

    cond do
      count > @max_test_batch_files ->
        :error

      true ->
        Enum.reduce_while(paths, {:ok, nil, 0}, fn path, {:ok, prev, bytes} ->
          case normalize_test_file_path(path) do
            {:ok, ^path} ->
              cost = path_arg_bytes(path)

              cond do
                is_binary(prev) and path <= prev ->
                  {:halt, :error}

                cost > @max_test_batch_arg_bytes ->
                  {:halt, :error}

                bytes + cost > @max_test_batch_arg_bytes ->
                  {:halt, :error}

                true ->
                  {:cont, {:ok, path, bytes + cost}}
              end

            _ ->
              {:halt, :error}
          end
        end)
        |> case do
          {:ok, _prev, _bytes} -> :ok
          :error -> :error
        end
    end
  end

  defp validate_batch_member_paths(_), do: :error

  @doc """
  Deterministically partition verified, normalized `*_test.exs` paths into
  argv-safe Mix batches.

  Input must already be the post-normalization inventory: strictly sorted,
  unique, and every path must re-normalize to itself. Partitioning is greedy
  left-to-right under the closed runtime file-count cap (at most 20 exact
  files per child), Shell argv-count ceiling, argument-byte ceiling, and
  app test root boundary (a batch never mixes files from different
  `apps/<app>/test` roots). Every path appears in exactly one non-empty
  batch, including a final partial batch; labels bind inventory count and
  SHA-256 over the exact ordered batch paths. Slow/integration-tagged files
  are never excluded — they remain in the exact inventory and are only split
  across sequential children.
  """
  @spec partition_test_batches(term()) :: {:ok, [test_batch()]} | {:error, term()}
  def partition_test_batches([]), do: {:ok, []}

  def partition_test_batches(files) when is_list(files) do
    with :ok <- validate_batch_source_files(files),
         {:ok, packed} <- pack_test_batches(files) do
      total = length(packed)

      batches =
        packed
        |> Enum.with_index(1)
        |> Enum.map(fn {paths, index} -> build_test_batch(paths, index, total) end)

      {:ok, batches}
    end
  end

  def partition_test_batches(_), do: {:error, :invalid_test_batch_input}

  defp validate_batch_source_files(files) do
    if length(files) > @max_expanded_test_files do
      {:error, :too_many_test_files}
    else
      Enum.reduce_while(files, {:ok, nil}, fn path, {:ok, prev} ->
        case normalize_test_file_path(path) do
          {:ok, ^path} ->
            cond do
              is_binary(prev) and path <= prev ->
                {:halt, {:error, :unsorted_or_duplicate_test_files}}

              path_arg_bytes(path) > @max_test_batch_arg_bytes ->
                # Defensive: normalized paths are ≤1024 bytes and always fit.
                {:halt, {:error, {:test_file_path_exceeds_batch_bytes, path}}}

              true ->
                {:cont, {:ok, path}}
            end

          {:ok, _other} ->
            {:halt, {:error, {:non_normalized_test_file, path}}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp pack_test_batches(files) do
    {batches, current, _count, _bytes, _current_root} =
      Enum.reduce(files, {[], [], 0, 0, nil}, fn path, {batches, current, count, bytes, root} ->
        cost = path_arg_bytes(path)
        path_root = app_test_root(path)

        cond do
          current == [] ->
            {batches, [path], 1, cost, path_root}

          path_root != root ->
            {[Enum.reverse(current) | batches], [path], 1, cost, path_root}

          count + 1 > @max_test_batch_files or bytes + cost > @max_test_batch_arg_bytes ->
            {[Enum.reverse(current) | batches], [path], 1, cost, path_root}

          true ->
            {batches, [path | current], count + 1, bytes + cost, root}
        end
      end)

    final =
      if current == [] do
        Enum.reverse(batches)
      else
        Enum.reverse([Enum.reverse(current) | batches])
      end

    if final == [] or Enum.any?(final, &(&1 == [])) do
      {:error, :empty_test_batch}
    else
      {:ok, final}
    end
  end

  # Extract the canonical app test root (apps/<app>/test) from a normalized
  # *_test.exs path. All validated batch paths match this shape.
  defp app_test_root(path) when is_binary(path) do
    case Path.split(path) do
      ["apps", app, "test" | _rest] -> "apps/#{app}/test"
      _ -> nil
    end
  end

  defp build_test_batch(paths, index, total)
       when is_list(paths) and paths != [] and is_integer(index) and is_integer(total) do
    count = length(paths)
    inventory_sha256 = inventory_sha256(paths)
    label = batch_label(index, total, count, inventory_sha256)

    %{
      label: label,
      paths: paths,
      index: index,
      total: total,
      count: count,
      inventory_sha256: inventory_sha256
    }
  end

  defp inventory_sha256(paths) when is_list(paths) do
    # Paths reject NUL during normalization; join with NUL for exact inventory.
    material = Enum.join(paths, <<0>>)
    sha256(material)
  end

  defp batch_label(index, total, count, inventory_sha256) do
    "batch-#{index}-of-#{total}-n#{count}-#{inventory_sha256}"
  end

  defp path_arg_bytes(path) when is_binary(path), do: byte_size(path) + 1

  @doc """
  Normalize and bound an expanded list of relative `*_test.exs` file paths.

  Pure path grammar only — the shell must already reject symlinks via lstat.
  Fails closed on empty components, escapes, absolute paths, non-test suffixes,
  oversized inventories, and overlong path bytes.
  """
  @spec normalize_expanded_test_files([String.t()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def normalize_expanded_test_files(files) when is_list(files) do
    if length(files) > @max_expanded_test_files do
      {:error, :too_many_test_files}
    else
      Enum.reduce_while(files, {:ok, []}, fn path, {:ok, acc} ->
        case normalize_test_file_path(path) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, collected} ->
          {:ok, collected |> Enum.reverse() |> Enum.uniq() |> Enum.sort()}

        {:error, _} = error ->
          error
      end
    end
  end

  def normalize_expanded_test_files(_), do: {:error, :invalid_test_file_list}

  @doc false
  def normalize_test_file_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" ->
        {:error, :empty_test_file_path}

      not String.valid?(trimmed) ->
        {:error, :invalid_test_file_path}

      String.contains?(trimmed, <<0>>) ->
        {:error, :invalid_test_file_path}

      String.starts_with?(trimmed, "/") ->
        {:error, :absolute_test_file_path}

      String.contains?(trimmed, "\\") ->
        {:error, :invalid_test_file_path}

      String.contains?(trimmed, "..") ->
        {:error, :path_escape}

      byte_size(trimmed) > 1_024 ->
        {:error, :test_file_path_too_long}

      not String.ends_with?(trimmed, "_test.exs") ->
        {:error, {:not_test_file, trimmed}}

      true ->
        case Path.split(trimmed) do
          ["apps", app, "test" | rest] when app != "" and rest != [] ->
            cond do
              not valid_identifier?(app) ->
                {:error, {:invalid_app_dir, app}}

              Enum.any?(rest, &(&1 == "" or &1 == "." or &1 == "..")) ->
                {:error, :invalid_test_file_path}

              true ->
                {:ok, Path.join(["apps", app, "test" | rest])}
            end

          _ ->
            {:error, {:not_app_test_path, trimmed}}
        end
    end
  end

  def normalize_test_file_path(_), do: {:error, :invalid_test_file_path}

  @doc """
  Classify one Mix process result for a single inventory-bound batch label.

  Deadline/process wall-clock work stays in the shell; this only maps feedback
  into a pure batch record. Timed-out processes are failures with
  `tests_timed_out`; non-zero exits use the stable `tests_failed` reason.
  Timeout classification is driven solely by the `timed_out` option (exact
  shape from the shell), never by substring matching on output text.

  `label` is the deterministic batch inventory label (count + SHA-256), never an
  unbounded concatenation of file paths.
  """
  @spec classify_app_test_result(String.t(), map(), keyword()) :: app_test_result()
  def classify_app_test_result(label, feedback, opts \\ [])
      when is_binary(label) and is_map(feedback) and is_list(opts) do
    timed_out = Keyword.get(opts, :timed_out, false) == true
    exit_code = Map.get(feedback, "exit_code") || Map.get(feedback, :exit_code)
    raw_passed = Map.get(feedback, "passed") || Map.get(feedback, :passed) || false
    passed = raw_passed == true and not timed_out and exit_code == 0

    reason =
      cond do
        passed -> nil
        timed_out -> "tests_timed_out"
        true -> "tests_failed"
      end

    stdout_excerpt =
      json_safe_utf8(
        Map.get(feedback, "stdout_excerpt") || Map.get(feedback, :stdout_excerpt) || ""
      )

    stderr_excerpt =
      json_safe_utf8(
        Map.get(feedback, "stderr_excerpt") || Map.get(feedback, :stderr_excerpt) || ""
      )

    %{
      path: label,
      passed: passed,
      timed_out: timed_out,
      exit_code: exit_code,
      reason: reason,
      stdout_excerpt: stdout_excerpt,
      stderr_excerpt: stderr_excerpt,
      stdout_truncated:
        Map.get(feedback, "stdout_truncated") || Map.get(feedback, :stdout_truncated) || false,
      stderr_truncated:
        Map.get(feedback, "stderr_truncated") || Map.get(feedback, :stderr_truncated) || false,
      stdout_sha256:
        Map.get(feedback, "stdout_sha256") || Map.get(feedback, :stdout_sha256) || sha256(""),
      stderr_sha256:
        Map.get(feedback, "stderr_sha256") || Map.get(feedback, :stderr_sha256) || sha256("")
    }
  end

  @doc """
  Deterministic record for a batch that was not started because the shared
  test-stage budget was already exhausted.
  """
  @spec budget_exhausted_result(String.t()) :: app_test_result()
  def budget_exhausted_result(label) when is_binary(label) do
    message = "test stage budget exhausted before " <> label

    %{
      path: label,
      passed: false,
      timed_out: true,
      exit_code: nil,
      reason: "tests_timed_out",
      stdout_excerpt: message,
      stderr_excerpt: "",
      stdout_truncated: false,
      stderr_truncated: false,
      stdout_sha256: sha256(message),
      stderr_sha256: sha256("")
    }
  end

  @doc """
  Aggregate ordered batch test results into the existing JSON-clean check shape.

  Excerpts are batch-label-labeled and re-bounded to a fixed *byte* size
  independent of batch count. Aggregate hashes are derived from each batch label
  plus that process's stdout/stderr hashes so completed invocations remain
  covered without retaining unbounded process output. Prior successful children
  stay in the aggregate when a later child fails or times out.
  """
  @spec aggregate_test_check([app_test_result()]) :: map()
  def aggregate_test_check([]), do: empty_pass_check("no_existing_test_dirs")

  def aggregate_test_check(app_results) when is_list(app_results) do
    all_passed = Enum.all?(app_results, &(&1.passed == true))

    reason =
      cond do
        all_passed -> nil
        Enum.any?(app_results, &(&1.timed_out == true)) -> "tests_timed_out"
        true -> "tests_failed"
      end

    exit_code =
      cond do
        all_passed ->
          0

        true ->
          app_results
          |> Enum.find(&(&1.passed != true))
          |> case do
            %{exit_code: code} -> code
            _ -> nil
          end
      end

    {stdout_excerpt, stdout_agg_truncated} =
      bound_aggregate_excerpt(app_results, :stdout_excerpt)

    {stderr_excerpt, stderr_agg_truncated} =
      bound_aggregate_excerpt(app_results, :stderr_excerpt)

    stdout_truncated =
      stdout_agg_truncated or Enum.any?(app_results, &(&1.stdout_truncated == true))

    stderr_truncated =
      stderr_agg_truncated or Enum.any?(app_results, &(&1.stderr_truncated == true))

    completed_check(
      %{
        "passed" => all_passed,
        "exit_code" => exit_code,
        "stdout_excerpt" => stdout_excerpt,
        "stderr_excerpt" => stderr_excerpt,
        "stdout_truncated" => stdout_truncated,
        "stderr_truncated" => stderr_truncated,
        "stdout_sha256" => aggregate_stream_hash(app_results, :stdout_sha256),
        "stderr_sha256" => aggregate_stream_hash(app_results, :stderr_sha256)
      },
      reason: reason
    )
  end

  @doc false
  def max_aggregate_excerpt, do: @max_aggregate_excerpt_bytes

  @doc false
  def max_output_excerpt_bytes, do: @max_output_excerpt_bytes

  @doc false
  def bound_output_excerpt(raw) when is_binary(raw) do
    # Never sanitize or enumerate the full raw stream just to build a ~2 KB
    # excerpt. Hashing (caller) covers the complete already-bounded raw bytes;
    # excerpts only repair bounded head/tail windows (+ UTF-8 boundary allowance).
    size = byte_size(raw)

    if size <= @max_output_excerpt_bytes do
      {replace_invalid_utf8(raw), false}
    else
      marker = @excerpt_omission_marker
      available = @max_output_excerpt_bytes - byte_size(marker)
      head_budget = div(available, 2)
      tail_budget = available - head_budget

      head = repair_raw_window_prefix(raw, head_budget)
      tail = repair_raw_window_suffix(raw, tail_budget)
      {head <> marker <> tail, true}
    end
  end

  def bound_output_excerpt(_), do: {"", false}

  # Failure-aware excerpt: small head + anchor-centered middle + small tail.
  # Falls back to head/tail when no stable diagnostic anchor exists. The
  # anchor is recognized from byte-level structure (ExUnit numbered failure
  # block, Mix compilation banner, uncaught exception heading) — never from
  # localized prose, which can mislead success/failure classification.
  defp bound_failure_aware_excerpt(raw) when is_binary(raw) do
    size = byte_size(raw)

    if size <= @max_output_excerpt_bytes do
      {replace_invalid_utf8(raw), false}
    else
      case find_first_diagnostic_anchor(raw) do
        {:ok, anchor_start} ->
          bound_failure_aware_excerpt(raw, anchor_start)

        :none ->
          bound_output_excerpt(raw)
      end
    end
  end

  defp bound_failure_aware_excerpt(_), do: {"", false}

  defp bound_failure_aware_excerpt(raw, anchor_start)
       when is_binary(raw) and is_integer(anchor_start) and anchor_start >= 0 do
    size = byte_size(raw)

    if size <= @max_output_excerpt_bytes do
      {replace_invalid_utf8(raw), false}
    else
      {build_failure_centered_excerpt(raw, size, min(anchor_start, size)), true}
    end
  end

  defp find_first_diagnostic_anchor(raw) when is_binary(raw) do
    case Regex.run(@diagnostic_anchor_pattern, raw, return: :index) do
      [{offset, _} | _] -> {:ok, offset}
      _ -> :none
    end
  end

  # Build the three-window excerpt around the first diagnostic anchor. The
  # head/tail budgets each take 1/share of the post-marker content budget so
  # ExUnit seed/concurrency and the final summary survive; the middle covers
  # the anchor with a small lookback for preceding context. Provisioning two
  # markers up front keeps the assembled excerpt under the byte ceiling no
  # matter where the anchor lands.
  defp build_failure_centered_excerpt(raw, size, anchor_start) do
    marker = @excerpt_omission_marker
    marker_bytes = byte_size(marker)
    content_budget = @max_output_excerpt_bytes - 2 * marker_bytes

    head_budget = div(content_budget, @excerpt_head_share)
    tail_budget = div(content_budget, @excerpt_head_share)
    middle_budget = content_budget - head_budget - tail_budget

    lookback = min(@excerpt_anchor_lookback, div(middle_budget, @excerpt_head_share))
    raw_middle_start = max(0, anchor_start - lookback)
    middle_end = min(size, raw_middle_start + middle_budget)

    # If the middle hit the stream end, slide its start backward to consume
    # the remaining budget rather than leaving it unused.
    middle_start =
      if middle_end - raw_middle_start < middle_budget and raw_middle_start > 0 do
        max(0, middle_end - middle_budget)
      else
        raw_middle_start
      end

    head_end = min(head_budget, middle_start)
    tail_start = max(middle_end, size - tail_budget)

    head_text =
      if head_end > 0,
        do: repair_raw_window_prefix(raw, head_end),
        else: nil

    middle_text = repair_raw_window_middle(raw, middle_start, middle_end - middle_start)

    tail_text =
      if tail_start < size,
        do: repair_raw_window_middle(raw, tail_start, size - tail_start),
        else: nil

    # Emit a marker only where there is a real gap between non-empty segments,
    # so contiguous windows do not advertise false omissions.
    head_gap? = head_text != nil and middle_start > head_end
    tail_gap? = tail_text != nil and tail_start > middle_end

    parts = []
    parts = if head_text != nil, do: [head_text | parts], else: parts
    parts = if head_gap?, do: [marker | parts], else: parts
    parts = [middle_text | parts]
    parts = if tail_gap?, do: [marker | parts], else: parts
    parts = if tail_text != nil, do: [tail_text | parts], else: parts

    parts
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  @doc false
  def json_safe_utf8(data) when is_binary(data), do: replace_invalid_utf8(data)
  def json_safe_utf8(_), do: ""

  defp bound_aggregate_excerpt(app_results, field) do
    chunks =
      app_results
      |> Enum.map(fn result ->
        body = json_safe_utf8(Map.get(result, field) || "")
        path = json_safe_utf8(result.path)
        "[" <> path <> "]\n" <> body
      end)

    text = Enum.join(chunks, "\n")

    # When any child failed, use the failure-aware excerpt so a failed
    # child's diagnostic survives even when successful siblings fill the head
    # and tail windows. Anchor selection is constrained to the first failed
    # child: diagnostic-looking fixture/log text from a successful child must
    # not displace the actual failure. Per-app bodies are already bounded.
    case first_failed_aggregate_anchor(app_results, chunks, field) do
      {:ok, anchor_start} -> bound_failure_aware_excerpt(text, anchor_start)
      :none -> bound_output_excerpt(text)
    end
  end

  defp first_failed_aggregate_anchor(app_results, chunks, field) do
    app_results
    |> Enum.zip(chunks)
    |> Enum.reduce_while({0, nil}, fn {result, chunk}, {offset, fallback} ->
      chunk_start = offset + if(offset == 0, do: 0, else: 1)
      next_offset = chunk_start + byte_size(chunk)

      if result.passed != true do
        body = json_safe_utf8(Map.get(result, field) || "")
        label_bytes = byte_size(chunk) - byte_size(body)

        case find_first_diagnostic_anchor(body) do
          {:ok, body_anchor} ->
            {:halt, {:found, chunk_start + label_bytes + body_anchor}}

          :none ->
            {:cont, {next_offset, fallback || chunk_start}}
        end
      else
        {:cont, {next_offset, fallback}}
      end
    end)
    |> case do
      {:found, anchor_start} -> {:ok, anchor_start}
      {_offset, nil} -> :none
      {_offset, fallback} -> {:ok, fallback}
    end
  end

  defp aggregate_stream_hash(app_results, field) do
    material =
      app_results
      |> Enum.map(fn result ->
        hash = Map.get(result, field) || sha256("")
        result.path <> "\n" <> hash
      end)
      |> Enum.join("\n")

    sha256(material)
  end

  defp raw_stream(result, key) when is_atom(key) do
    case Map.fetch(result, key) do
      {:ok, value} when is_binary(value) ->
        value

      {:ok, nil} ->
        ""

      {:ok, _} ->
        ""

      :error ->
        case Map.fetch(result, Atom.to_string(key)) do
          {:ok, value} when is_binary(value) -> value
          _ -> ""
        end
    end
  end

  # Linear iodata repair: each invalid/incomplete byte becomes U+FFFD once.
  # Used only on already-bounded windows (or streams that already fit the
  # excerpt budget), never as a full-stream pre-pass for large process output.
  defp replace_invalid_utf8(data) when is_binary(data) do
    data
    |> replace_invalid_utf8_iodata([])
    |> IO.iodata_to_binary()
  end

  defp replace_invalid_utf8_iodata(<<>>, acc), do: Enum.reverse(acc)

  defp replace_invalid_utf8_iodata(data, acc) do
    case :unicode.characters_to_binary(data, :utf8, :utf8) do
      result when is_binary(result) ->
        Enum.reverse([result | acc])

      {:error, good, <<_bad, next::binary>>} when is_binary(good) ->
        replace_invalid_utf8_iodata(next, prepend_replacement(good, acc))

      {:error, good, _rest} when is_binary(good) ->
        Enum.reverse(prepend_replacement(good, acc))

      {:incomplete, good, _rest} when is_binary(good) ->
        Enum.reverse(prepend_replacement(good, acc))

      _other ->
        Enum.reverse([@utf8_replacement | acc])
    end
  end

  defp prepend_replacement(<<>>, acc), do: [@utf8_replacement | acc]
  defp prepend_replacement(good, acc), do: [@utf8_replacement, good | acc]

  defp repair_raw_window_prefix(raw, budget)
       when is_binary(raw) and is_integer(budget) and budget <= 0 do
    ""
  end

  defp repair_raw_window_prefix(raw, budget) when is_binary(raw) and is_integer(budget) do
    size = byte_size(raw)
    take = min(size, budget + @utf8_boundary_allowance)

    raw
    |> binary_part(0, take)
    |> replace_invalid_utf8()
    |> take_utf8_prefix_bytes(budget)
  end

  defp repair_raw_window_suffix(raw, budget)
       when is_binary(raw) and is_integer(budget) and budget <= 0 do
    ""
  end

  defp repair_raw_window_suffix(raw, budget) when is_binary(raw) and is_integer(budget) do
    size = byte_size(raw)
    take = min(size, budget + @utf8_boundary_allowance)

    raw
    |> binary_part(size - take, take)
    |> replace_invalid_utf8()
    |> take_utf8_suffix_bytes(budget)
  end

  # Repair an arbitrary interior window: used by the failure-aware excerpt's
  # middle/tail segments. A partial char at the start boundary becomes a
  # single U+FFFD; the suffix is then trimmed to the budget on a UTF-8
  # boundary so the segment is always valid UTF-8 and never exceeds budget.
  defp repair_raw_window_middle(raw, start_offset, length_budget)
       when is_binary(raw) and is_integer(start_offset) and start_offset >= 0 and
              is_integer(length_budget) and length_budget > 0 do
    size = byte_size(raw)
    start = min(start_offset, size)
    available = size - start

    if available <= 0 do
      ""
    else
      take = min(available, length_budget + @utf8_boundary_allowance)

      raw
      |> binary_part(start, take)
      |> replace_invalid_utf8()
      |> take_utf8_prefix_bytes(length_budget)
    end
  end

  defp repair_raw_window_middle(_raw, _start_offset, _length_budget), do: ""

  defp take_utf8_prefix_bytes(text, max_bytes)
       when is_binary(text) and is_integer(max_bytes) and max_bytes <= 0 do
    ""
  end

  defp take_utf8_prefix_bytes(text, max_bytes)
       when is_binary(text) and is_integer(max_bytes) and byte_size(text) <= max_bytes do
    text
  end

  defp take_utf8_prefix_bytes(text, max_bytes) when is_binary(text) and is_integer(max_bytes) do
    # Input is already repaired/valid UTF-8 of a bounded window. Drop at most
    # a few trailing bytes so we do not split a multi-byte codepoint.
    text
    |> binary_part(0, max_bytes)
    |> trim_incomplete_utf8_suffix()
  end

  defp take_utf8_suffix_bytes(text, max_bytes)
       when is_binary(text) and is_integer(max_bytes) and max_bytes <= 0 do
    ""
  end

  defp take_utf8_suffix_bytes(text, max_bytes)
       when is_binary(text) and is_integer(max_bytes) and byte_size(text) <= max_bytes do
    text
  end

  defp take_utf8_suffix_bytes(text, max_bytes) when is_binary(text) and is_integer(max_bytes) do
    # Input is already repaired/valid UTF-8 of a bounded window. Align the
    # start index forward by at most 3 bytes so the suffix is complete UTF-8.
    size = byte_size(text)
    start = align_utf8_start(text, size - max_bytes, 0)
    binary_part(text, start, size - start)
  end

  defp trim_incomplete_utf8_suffix(<<>>), do: <<>>

  defp trim_incomplete_utf8_suffix(bin) when is_binary(bin) do
    if String.valid?(bin) do
      bin
    else
      size = byte_size(bin)

      if size <= 1 do
        <<>>
      else
        trim_incomplete_utf8_suffix(binary_part(bin, 0, size - 1))
      end
    end
  end

  defp align_utf8_start(_text, start, _n) when start <= 0, do: 0

  defp align_utf8_start(_text, start, n) when n > @utf8_boundary_allowance do
    # Should not happen for valid UTF-8; fail soft to empty-aligned start.
    start
  end

  defp align_utf8_start(text, start, n) do
    size = byte_size(text)
    part = binary_part(text, start, size - start)

    if String.valid?(part) do
      start
    else
      align_utf8_start(text, start + 1, n + 1)
    end
  end

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

  defp validate_timeout(timeout) when is_binary(timeout) do
    case Integer.parse(timeout) do
      {parsed, ""} ->
        if Integer.to_string(parsed) == timeout,
          do: validate_timeout(parsed),
          else: {:error, :invalid_timeout}

      _other ->
        {:error, :invalid_timeout}
    end
  end

  defp validate_timeout(_timeout), do: {:error, :invalid_timeout}

  defp validate_test_stage_timeout(nil), do: {:ok, @default_test_stage_timeout}

  defp validate_test_stage_timeout(timeout)
       when is_integer(timeout) and timeout >= @minimum_timeout and
              timeout <= @maximum_test_stage_timeout,
       do: {:ok, timeout}

  defp validate_test_stage_timeout(timeout) when is_binary(timeout) do
    case Integer.parse(timeout) do
      {parsed, ""} ->
        if Integer.to_string(parsed) == timeout,
          do: validate_test_stage_timeout(parsed),
          else: {:error, :invalid_test_stage_timeout}

      _other ->
        {:error, :invalid_test_stage_timeout}
    end
  end

  defp validate_test_stage_timeout(_timeout), do: {:error, :invalid_test_stage_timeout}

  defp validate_app_def_count(app_defs) do
    if length(app_defs) <= @max_apps, do: :ok, else: {:error, :too_many_apps}
  end

  defp validate_app_defs(app_defs) do
    dirs = Enum.map(app_defs, & &1.dir)
    apps = Enum.map(app_defs, & &1.app)

    cond do
      Enum.any?(app_defs, fn def ->
        not is_binary(def.dir) or not is_binary(def.app) or not is_list(def.deps)
      end) ->
        {:error, :malformed_app_def}

      Enum.any?(app_defs, fn def -> def.dir != def.app end) ->
        {:error, :app_dir_name_mismatch}

      Enum.any?(dirs, &(not valid_identifier?(&1))) ->
        {:error, :invalid_app_identifier}

      Enum.any?(apps, &(not valid_identifier?(&1))) ->
        {:error, :invalid_app_identifier}

      Enum.any?(app_defs, fn def -> Enum.any?(def.deps, &(not valid_identifier?(&1))) end) ->
        {:error, :invalid_dep_identifier}

      length(Enum.uniq(dirs)) != length(dirs) ->
        {:error, :duplicate_app_dir}

      length(Enum.uniq(apps)) != length(apps) ->
        {:error, :duplicate_app_name}

      true ->
        :ok
    end
  end

  defp validate_dep_targets(depends_on, app_set) do
    unknown =
      depends_on
      |> Enum.flat_map(fn {from, deps} ->
        Enum.reject(deps, &MapSet.member?(app_set, &1))
        |> Enum.map(&{from, &1})
      end)

    if unknown == [] do
      :ok
    else
      {:error, {:unknown_in_umbrella_dep, Enum.sort(unknown)}}
    end
  end

  defp normalize_changed_files(files) do
    if length(files) > @max_changed_files do
      {:error, :too_many_changed_files}
    else
      normalized =
        files
        |> Enum.map(&normalize_path/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      if Enum.any?(normalized, &(byte_size(&1) > 1_024)) do
        {:error, :changed_file_path_too_long}
      else
        {:ok, normalized}
      end
    end
  end

  defp normalize_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" -> nil
      String.contains?(trimmed, <<0>>) -> nil
      String.starts_with?(trimmed, "/") -> nil
      String.contains?(trimmed, "..") -> nil
      true -> trimmed
    end
  end

  defp normalize_path(_), do: nil

  defp classify_files(files, graph) do
    app_set = MapSet.new(graph.apps)

    Enum.reduce_while(files, {:ok, MapSet.new(), false}, fn path, {:ok, apps, root_wide} ->
      cond do
        root_wide_path?(path) ->
          {:cont, {:ok, apps, true}}

        true ->
          case app_dir_from_path(path) do
            {:ok, app} ->
              if MapSet.member?(app_set, app) do
                {:cont, {:ok, MapSet.put(apps, app), root_wide}}
              else
                # Changed path under apps/<unknown>/ — fail closed unless the
                # path is merely an untracked junk file outside known apps.
                # Known-app directories are the only authority for selection.
                {:halt, {:error, {:changed_unknown_app, app}}}
              end

            :not_app_path ->
              # docs, scripts, etc. — do not widen
              {:cont, {:ok, apps, root_wide}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, apps, root_wide} ->
        {:ok, apps |> MapSet.to_list() |> Enum.sort(), root_wide}

      {:error, _} = error ->
        error
    end
  end

  defp downstream_closure(seeds, depended_by) do
    seeds = MapSet.new(seeds)

    expand = fn
      expand_fun, frontier, seen ->
        next =
          frontier
          |> Enum.flat_map(fn app -> Map.get(depended_by, app, []) end)
          |> Enum.reject(&MapSet.member?(seen, &1))

        if next == [] do
          seen
        else
          next_set = MapSet.new(next)
          expand_fun.(expand_fun, next, MapSet.union(seen, next_set))
        end
    end

    seeds
    |> then(fn s -> expand.(expand, MapSet.to_list(s), s) end)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp valid_identifier?(name)
       when is_binary(name) and name != "" and byte_size(name) <= @max_identifier_bytes do
    String.match?(name, ~r/^[a-z][a-z0-9_]*$/)
  end

  defp valid_identifier?(_), do: false

  defp overall_reason(true, _compile, _xref, _test_compile, _test), do: "cross_app_validated"

  defp overall_reason(false, compile, xref, test_compile, test) do
    cond do
      check_failed?(compile) -> check_reason(compile, "compile_failed")
      check_failed?(xref) -> check_reason(xref, "xref_failed")
      check_failed?(test_compile) -> check_reason(test_compile, "test_compile_failed")
      check_failed?(test) -> check_reason(test, "tests_failed")
      true -> "validation_failed"
    end
  end

  defp check_failed?(check) do
    passed = Map.get(check, :passed) || Map.get(check, "passed")
    passed != true
  end

  defp check_reason(check, default) do
    Map.get(check, :reason) || Map.get(check, "reason") || default
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

    case Map.get(check, :capacity_handoff) || Map.get(check, "capacity_handoff") do
      handoff when is_map(handoff) -> Map.put(normalized, "capacity_handoff", handoff)
      _ -> normalized
    end
  end

  defp normalize_check(_), do: skipped_check("missing_check")

  defp to_string_value(value) when is_binary(value), do: value
  defp to_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_value(value), do: inspect(value)

  defp param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, Atom.to_string(key))
    end
  end

  defp sha256(output) when is_binary(output) do
    :crypto.hash(:sha256, output) |> Base.encode16(case: :lower)
  end
end
