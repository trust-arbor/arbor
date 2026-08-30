defmodule Arbor.Actions.Coding.CrossApp.Core do
  @moduledoc """
  Pure input, dependency-selection, and evidence logic for cross-app validation.

  The imperative shell supplies changed files and parsed app metadata. This module
  decides the affected-app closure and formats JSON-clean validation evidence
  without filesystem, process, clock, or registry operations.

  Multi-path test batches use deterministic timeout refinement. This module owns
  the pure `test_execution` state, every refinement decision, and the bounded
  JSON-clean frontier that ProgressCore may persist across graph windows. The
  shell only interprets the resulting effects. Full-budget multi-file timeouts
  always split; residual only decides whether the next step runs or capacities.

  Test-stage admission is residual-budget based: a Mix-launchable child timeout
  `min(operation_timeout, remaining)` strictly above the injected Mix postflight
  tree-binding reserve starts the first exact batch under one shared deadline.
  Residual or per-operation ceiling at or below that reserve is logical capacity,
  not executable test budget. Per-batch intensive ceilings are never multiplied
  as a predicted total duration. Capacity handoffs emit schema-v3 evidence with
  `available_budget_ms == 0` only, including an optional aggregate-deadline
  interrupted batch descriptor.
  """

  alias Arbor.Actions.Coding.BlobManifest
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
  # Whole-validation stage hard max: exactly three pre-test intensive children
  # (compile, xref, MIX_ENV=test compile) plus the aggregate test-stage ceiling.
  # Canonical owner of this product — do not restate the numeric result outside
  # this module / the Arbor.Actions facade.
  @pretest_intensive_children 3
  @maximum_stage_timeout @pretest_intensive_children * @maximum_timeout +
                           @maximum_test_stage_timeout
  @allowed_param_keys [:workspace_id, :timeout, :stage_timeout, :test_stage_timeout]
  @allowed_param_string_keys Enum.map(@allowed_param_keys, &Atom.to_string/1)
  @configuration_digest_domain "arbor.actions.coding.cross_app.continuation.configuration"
  @configuration_digest_schema_version 1

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
  # invocation prepends `["test", "--no-deps-check", "--"]`. Path slots are
  # the minimum of:
  #   * Shell's public non-bypassable argv ceiling minus fixed args
  #   * a reviewed runtime batch cap (at most 20 exact test files per child)
  # so multi-file suites amortize container startup without exhausting the
  # intensive per-process wall clock, while still preserving the complete
  # exact inventory across sequential batches. A process timeout on a multi-file
  # batch is refined deterministically with ordered_binary_split_v1 under the
  # same absolute aggregate deadline; ordinary failures and singleton timeouts
  # remain terminal. The sum of each path's UTF-8 bytes plus one separator byte
  # must also stay under the byte ceiling. A single normalized path (max 1024
  # bytes) always fits both bounds.
  @test_batch_fixed_args 3
  @max_test_batch_runtime_files 20
  @max_test_batch_argv_files Arbor.Shell.spawn_capable_max_command_args() - @test_batch_fixed_args
  @max_test_batch_files min(@max_test_batch_runtime_files, @max_test_batch_argv_files)
  # "root" plus bit_length(max_files - 1): the split tree's worst-case depth.
  @max_refinement_position_bytes byte_size("root") +
                                   length(Integer.digits(@max_test_batch_files - 1, 2))
  @refinement_position_regex ~r/\Aroot([LR])*\z/
  @refinement_frontier_schema_version 1
  @max_refinement_json_bytes 4_096
  @refinement_frontier_keys Enum.sort(~w(
    accepted_file_count
    accepted_positions
    original_count
    original_index
    original_inventory_sha256
    pending_file_count
    pending_positions
    refined_child_count
    schema_version
    strategy
  ))
  @refinement_forbidden_keys MapSet.new(
                               ~w(authority authorization capability credential fence_token secret token)
                             )
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
          stage_timeout: pos_integer() | nil,
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

  @typedoc "Bounded topology delta between base and candidate graphs."
  @type topology_change :: %{
          changed?: boolean(),
          added_apps: [String.t()],
          removed_apps: [String.t()],
          edge_changed_apps: [String.t()]
        }

  @typedoc "Selection result for changed files against a graph."
  @type selection :: %{
          changed_files: [String.t()],
          changed_apps: [String.t()],
          affected_apps: [String.t()],
          test_paths: [String.t()],
          root_wide: boolean(),
          topology_change: topology_change()
        }

  @type execution_app_order :: %{
          direct: [String.t()],
          downstream: [String.t()],
          ordered: [String.t()]
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

  @typedoc """
  Bounded evidence for a deterministically refined original batch.

  `attempted_outputs_sha256` binds the ordered attempted-record projection:
  original and attempt labels, sequence, file count, inventory digest, timeout
  flag, exit code, and stdout/stderr digests.
  """
  @type refinement_metadata :: %{
          strategy: String.t(),
          attempt_count: pos_integer(),
          refined_child_count: pos_integer(),
          attempted_outputs_sha256: String.t()
        }

  @typedoc "One completed (or budget-exhausted) batch test invocation record."
  @type app_test_result :: %{
          required(:path) => String.t(),
          required(:passed) => boolean(),
          required(:timed_out) => boolean(),
          required(:exit_code) => integer() | nil,
          required(:reason) => String.t() | nil,
          required(:stdout_excerpt) => String.t(),
          required(:stderr_excerpt) => String.t(),
          required(:stdout_truncated) => boolean(),
          required(:stderr_truncated) => boolean(),
          required(:stdout_sha256) => String.t(),
          required(:stderr_sha256) => String.t(),
          optional(:refinement) => refinement_metadata()
        }

  @typedoc "Pure decision for the next sequential batch Mix invocation."
  @type test_step ::
          :complete
          | {:run, test_batch(), pos_integer(), [test_batch()]}
          | {:timeout, test_batch(), [test_batch()]}
          | {:error, term()}

  @typedoc "One bounded root or refined process attempt."
  @type test_attempt :: %{
          label: String.t(),
          paths: [String.t()],
          count: pos_integer(),
          inventory_sha256: String.t(),
          position: String.t(),
          original_index: pos_integer()
        }

  @typedoc "One bounded output record retained while refining an original batch."
  @type test_attempt_record :: %{
          original_label: String.t(),
          attempt_label: String.t(),
          sequence: pos_integer(),
          count: pos_integer(),
          inventory_sha256: String.t(),
          timed_out: boolean(),
          exit_code: integer() | nil,
          stdout_excerpt: String.t(),
          stderr_excerpt: String.t(),
          stdout_truncated: boolean(),
          stderr_truncated: boolean(),
          stdout_sha256: String.t(),
          stderr_sha256: String.t()
        }

  @typedoc """
  Complete pure state for deterministic timeout refinement.

  `original_batches` is immutable. `completed_originals`, `current_original`,
  and `original_suffix` are its exact ordered partition. `work_queue` contains
  only runtime attempt descriptors for the current original; Shell may read
  `operation_timeout` but all state transitions and validation stay in Core.
  `accepted_positions` is the exact ordered cut of accepted nodes. `prior_frontier`
  is the admitted compact cut rehydrated in this process, or nil.
  `attempt_records` are Mix observations from this process only.
  """
  @type test_execution :: %{
          original_batches: [test_batch()],
          completed_originals: [test_batch()],
          current_original: test_batch() | nil,
          original_suffix: [test_batch()],
          work_queue: [test_attempt()],
          accepted_paths: [String.t()],
          accepted_positions: [String.t()],
          original_results: [app_test_result()],
          attempt_records: [test_attempt_record()],
          current_started: boolean(),
          refined?: boolean(),
          refined_child_count: non_neg_integer(),
          total_attempt_count: non_neg_integer(),
          operation_timeout: pos_integer(),
          postflight_reserve_ms: non_neg_integer(),
          prior_frontier: map() | nil
        }

  @typedoc "Bounded evidence for a validation capacity handoff."
  @type capacity_handoff :: %{required(String.t()) => term()}

  @doc false
  @spec normalize_app_id(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize_app_id(app_id) when is_binary(app_id) do
    if valid_identifier?(app_id), do: {:ok, app_id}, else: {:error, :invalid_app_identifier}
  end

  def normalize_app_id(_), do: {:error, :invalid_app_identifier}

  @doc false
  @spec normalize_app_ids(term()) :: {:ok, [String.t()]} | {:error, term()}
  def normalize_app_ids(app_ids) do
    with {:ok, normalized} <- collect_normalized_app_ids(app_ids) do
      {:ok, Enum.sort(normalized)}
    end
  end

  @doc false
  @spec normalize_ordered_app_ids(term()) :: {:ok, [String.t()]} | {:error, term()}
  def normalize_ordered_app_ids(app_ids), do: collect_normalized_app_ids(app_ids)

  @doc false
  @spec canonical_test_dir_for_app(term()) :: {:ok, String.t()} | {:error, term()}
  def canonical_test_dir_for_app(app_id) do
    with {:ok, normalized} <- normalize_app_id(app_id) do
      {:ok, "apps/#{normalized}/test"}
    end
  end

  @doc false
  @spec app_id_from_test_dir(term()) :: {:ok, String.t()} | {:error, term()}
  def app_id_from_test_dir(path) when is_binary(path) do
    case Path.split(path) do
      ["apps", app, "test"] ->
        case normalize_app_id(app) do
          {:ok, normalized} -> {:ok, normalized}
          {:error, _reason} -> {:error, {:invalid_test_dir, path}}
        end

      _ ->
        {:error, {:invalid_test_dir, path}}
    end
  end

  def app_id_from_test_dir(_), do: {:error, :invalid_test_dir}

  @doc false
  def max_apps, do: @max_apps

  defp collect_normalized_app_ids(app_ids) do
    collect_normalized_app_ids(app_ids, @max_apps, MapSet.new(), [])
  end

  defp collect_normalized_app_ids([], _remaining, _seen, acc),
    do: {:ok, Enum.reverse(acc)}

  defp collect_normalized_app_ids([_app_id | _rest], 0, _seen, _acc),
    do: {:error, :invalid_app_order_input}

  defp collect_normalized_app_ids([app_id | rest], remaining, seen, acc) do
    with {:ok, normalized} <- normalize_app_id(app_id),
         false <- MapSet.member?(seen, normalized) do
      collect_normalized_app_ids(
        rest,
        remaining - 1,
        MapSet.put(seen, normalized),
        [normalized | acc]
      )
    else
      _ -> {:error, :invalid_app_order_input}
    end
  end

  defp collect_normalized_app_ids(_improper, _remaining, _seen, _acc),
    do: {:error, :invalid_app_order_input}

  @doc "Construct and validate the action's deliberately narrow input surface."
  @spec new(map()) :: {:ok, input()} | {:error, atom()}
  def new(params) when is_map(params) do
    with :ok <- validate_param_keys(params),
         {:ok, workspace_id} <- validate_workspace_id(param(params, :workspace_id)),
         {:ok, timeout} <- validate_timeout(param(params, :timeout)),
         {:ok, stage_timeout} <- validate_stage_timeout(param(params, :stage_timeout)),
         {:ok, test_stage_timeout} <-
           validate_test_stage_timeout(param(params, :test_stage_timeout)) do
      {:ok,
       %{
         workspace_id: workspace_id,
         timeout: timeout,
         stage_timeout: stage_timeout,
         test_stage_timeout: test_stage_timeout
       }}
    end
  end

  def new(_params), do: {:error, :invalid_parameters}

  @doc """
  Canonical configuration identity for the three normalized CrossApp budgets.

  `workspace_id` is deliberately excluded. The digest is over the values
  admitted by `new/1`, so aliases, defaults, and decimal string inputs cannot
  create distinct identities for the same effective configuration.
  """
  @spec configuration_digest(map()) :: {:ok, String.t()} | {:error, atom()}
  def configuration_digest(params) when is_map(params) do
    with {:ok, input} <- new(params),
         {:ok, digest} <-
           Arbor.Actions.Coding.CrossApp.EvidenceCore.digest(%{
             "domain" => @configuration_digest_domain,
             "schema_version" => @configuration_digest_schema_version,
             "stage_timeout" => input.stage_timeout,
             "test_stage_timeout" => input.test_stage_timeout,
             "timeout" => input.timeout
           }) do
      {:ok, digest}
    end
  end

  def configuration_digest(_params), do: {:error, :invalid_parameters}

  @doc "Project a complete path-bearing Core batch plan to its canonical compact form."
  @spec compact_batch_plan(term()) :: {:ok, [map()]} | {:error, term()}
  def compact_batch_plan([]), do: {:ok, []}

  def compact_batch_plan(batches) when is_list(batches) do
    if valid_remaining_batches?(batches) and hd(batches).index == 1 do
      {:ok, Enum.map(batches, &compact_batch/1)}
    else
      {:error, :invalid_test_batch_plan}
    end
  rescue
    _ -> {:error, :invalid_test_batch_plan}
  end

  def compact_batch_plan(_batches), do: {:error, :invalid_test_batch_plan}

  @doc "Construct the canonical passed receipt for one admitted full original batch."
  @spec passed_batch_receipt(term()) :: {:ok, map()} | {:error, term()}
  def passed_batch_receipt(batch) when is_map(batch) do
    if valid_test_batch?(batch),
      do: {:ok, Map.put(compact_batch(batch), "outcome", "passed")},
      else: {:error, :invalid_test_batch}
  end

  def passed_batch_receipt(_batch), do: {:error, :invalid_test_batch}

  defp compact_batch(batch) do
    %{
      "index" => batch.index,
      "total" => batch.total,
      "count" => batch.count,
      "label" => batch.label,
      "inventory_sha256" => batch.inventory_sha256
    }
  end

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
  Attaches a zero topology_change for a stable selection shape.
  """
  @spec select([String.t()], graph()) :: {:ok, selection()} | {:error, term()}
  def select(changed_files, graph) when is_list(changed_files) and is_map(graph) do
    with {:ok, files} <- normalize_changed_files(changed_files),
         {:ok, known} <- known_apps_from_graph(graph),
         {:ok, changed_apps, root_wide} <- classify_files(files, known) do
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
         root_wide: root_wide,
         topology_change: empty_topology_change()
       }}
    end
  end

  def select(_, _), do: {:error, :invalid_selection_input}

  @doc """
  Compare two dependency graphs for structural umbrella topology changes.

  Topology differs when the app set differs (add/remove/merge) or when any
  shared app's in-umbrella `depends_on` edge set changes.
  """
  @spec compare_topology(graph(), graph()) :: {:ok, topology_change()} | {:error, term()}
  def compare_topology(base_graph, candidate_graph)
      when is_map(base_graph) and is_map(candidate_graph) do
    with {:ok, base_apps} <- graph_apps(base_graph),
         {:ok, cand_apps} <- graph_apps(candidate_graph),
         {:ok, base_deps} <- graph_depends_on(base_graph),
         {:ok, cand_deps} <- graph_depends_on(candidate_graph) do
      base_set = MapSet.new(base_apps)
      cand_set = MapSet.new(cand_apps)

      added_apps =
        cand_set
        |> MapSet.difference(base_set)
        |> MapSet.to_list()
        |> Enum.sort()

      removed_apps =
        base_set
        |> MapSet.difference(cand_set)
        |> MapSet.to_list()
        |> Enum.sort()

      edge_changed_apps =
        base_set
        |> MapSet.intersection(cand_set)
        |> MapSet.to_list()
        |> Enum.filter(fn app ->
          Map.get(base_deps, app, []) != Map.get(cand_deps, app, [])
        end)
        |> Enum.sort()

      changed? = added_apps != [] or removed_apps != [] or edge_changed_apps != []

      {:ok,
       %{
         changed?: changed?,
         added_apps: Enum.take(added_apps, @max_apps),
         removed_apps: Enum.take(removed_apps, @max_apps),
         edge_changed_apps: Enum.take(edge_changed_apps, @max_apps)
       }}
    end
  end

  def compare_topology(_, _), do: {:error, :invalid_topology_input}

  @typedoc "One path/mode/blob entry from an immutable revision snapshot."
  @type blob_manifest_entry :: %{
          path: String.t(),
          mode: String.t(),
          oid: String.t()
        }

  @doc """
  Derive changed relative paths from two immutable path/mode/blob manifests.

  An entry is changed when present on only one side or when mode/oid differ.
  Paths are sorted and bounded; the full manifests are never returned.
  """
  @spec diff_blob_manifests(term(), term()) :: {:ok, [String.t()]} | {:error, term()}
  def diff_blob_manifests(base_manifest, candidate_manifest),
    do: BlobManifest.diff_blob_manifests(base_manifest, candidate_manifest)

  @doc false
  def max_changed_files, do: @max_changed_files

  @doc """
  Select validation scope against base and candidate dependency graphs.

  Path classification uses the union of both app sets so deleted-app paths are
  not `changed_unknown_app`. Topology deltas force full candidate validation;
  unchanged topology retains focused downstream closure on the candidate graph.
  Test paths are always candidate apps only.
  """
  @spec select_revisions([String.t()], graph(), graph()) ::
          {:ok, selection()} | {:error, term()}
  def select_revisions(changed_files, base_graph, candidate_graph)
      when is_list(changed_files) and is_map(base_graph) and is_map(candidate_graph) do
    with {:ok, files} <- normalize_changed_files(changed_files),
         {:ok, topology} <- compare_topology(base_graph, candidate_graph),
         {:ok, base_apps} <- graph_apps(base_graph),
         {:ok, cand_apps} <- graph_apps(candidate_graph),
         known <- MapSet.union(MapSet.new(base_apps), MapSet.new(cand_apps)),
         {:ok, changed_apps_raw, root_wide} <- classify_files(files, known) do
      cand_set = MapSet.new(cand_apps)

      path_changed_candidate =
        changed_apps_raw
        |> Enum.filter(&MapSet.member?(cand_set, &1))
        |> Enum.sort()

      affected_apps =
        cond do
          topology.changed? ->
            cand_apps

          root_wide ->
            cand_apps

          true ->
            downstream_closure(path_changed_candidate, candidate_graph.depended_by)
        end

      test_paths =
        affected_apps
        |> Enum.map(&("apps/" <> &1 <> "/test"))
        |> Enum.take(@max_test_paths)

      {:ok,
       %{
         changed_files: Enum.take(files, @max_output_list),
         changed_apps: path_changed_candidate,
         affected_apps: affected_apps,
         test_paths: test_paths,
         root_wide: root_wide,
         topology_change: topology
       }}
    end
  end

  def select_revisions(_, _, _), do: {:error, :invalid_selection_input}

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

    evidence = %{
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

    case topology_change_evidence(selection) do
      nil -> evidence
      topology -> Map.put(evidence, :topology_change, topology)
    end
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
  def maximum_stage_timeout, do: @maximum_stage_timeout

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
  def max_refinement_json_bytes, do: @max_refinement_json_bytes

  @doc false
  def refinement_frontier_schema_version, do: @refinement_frontier_schema_version

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
  True when Mix can spawn a child that honors postflight reserve.

  Mix receives `min(operation_timeout, remaining)` as the outer child timeout and
  requires that value strictly greater than its owned postflight tree-binding
  reserve. Aggregate residual above the reserve is not enough when the
  per-operation ceiling is at or below the reserve. CrossApp must not subtract
  the reserve from launched timeouts; this predicate is only the logical launch
  floor.
  """
  @spec residual_allows_mix_launch?(term(), term(), term()) :: boolean()
  def residual_allows_mix_launch?(remaining_ms, operation_timeout_ms, postflight_reserve_ms)
      when is_integer(remaining_ms) and is_integer(operation_timeout_ms) and
             operation_timeout_ms > 0 and is_integer(postflight_reserve_ms) and
             postflight_reserve_ms >= 0 do
    min(operation_timeout_ms, remaining_ms) > postflight_reserve_ms
  end

  def residual_allows_mix_launch?(
        _remaining_ms,
        _operation_timeout_ms,
        _postflight_reserve_ms
      ),
      do: false

  @doc """
  True only for aggregate-deadline interruption of a launched child.

  Requires trusted runner timeout evidence, a launched budget strictly below the
  intensive operation ceiling, and residual that cannot honor the injected Mix
  postflight reserve. Equal ceilings remain an ordinary child timeout.
  """
  @spec aggregate_deadline_interrupted?(
          boolean(),
          integer(),
          pos_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: boolean()
  def aggregate_deadline_interrupted?(
        runner_timed_out?,
        remaining_after,
        budget_ms,
        operation_timeout,
        postflight_reserve_ms \\ 0
      )

  def aggregate_deadline_interrupted?(
        runner_timed_out?,
        remaining_after,
        budget_ms,
        operation_timeout,
        postflight_reserve_ms
      )
      when is_boolean(runner_timed_out?) and is_integer(remaining_after) and
             is_integer(budget_ms) and budget_ms > 0 and is_integer(operation_timeout) and
             operation_timeout > 0 and is_integer(postflight_reserve_ms) and
             postflight_reserve_ms >= 0 do
    runner_timed_out? == true and budget_ms < operation_timeout and
      not residual_allows_mix_launch?(
        remaining_after,
        operation_timeout,
        postflight_reserve_ms
      )
  end

  def aggregate_deadline_interrupted?(
        _runner,
        _remaining,
        _budget,
        _operation,
        _postflight_reserve_ms
      ),
      do: false

  @doc """
  True only for a closed prelaunch validation-runtime probe timeout after the
  shared aggregate deadline is already exhausted.

  The Mix child never launched. Positive residual, every other probe error,
  and launched-child results remain validation failures. Never inspects
  stdout/stderr/reason text for the word timeout.
  """
  @spec prelaunch_probe_timeout_capacity?(term(), integer()) :: boolean()
  def prelaunch_probe_timeout_capacity?(:probe_timeout, remaining_ms_after)
      when is_integer(remaining_ms_after) and remaining_ms_after <= 0,
      do: true

  def prelaunch_probe_timeout_capacity?(":probe_timeout", remaining_ms_after)
      when is_integer(remaining_ms_after) and remaining_ms_after <= 0,
      do: true

  def prelaunch_probe_timeout_capacity?(_reason, _remaining_ms_after), do: false

  defp prelaunch_capacity_reason?(:probe_timeout), do: true
  defp prelaunch_capacity_reason?(":probe_timeout"), do: true
  defp prelaunch_capacity_reason?(:operation_deadline_exceeded), do: true
  defp prelaunch_capacity_reason?(":operation_deadline_exceeded"), do: true
  defp prelaunch_capacity_reason?(_reason), do: false

  defp prelaunch_residual_capacity?(
         reason,
         remaining_after,
         operation_timeout_ms,
         postflight_reserve_ms
       )
       when is_integer(remaining_after) and is_integer(operation_timeout_ms) and
              operation_timeout_ms > 0 and is_integer(postflight_reserve_ms) and
              postflight_reserve_ms >= 0 do
    prelaunch_capacity_reason?(reason) and
      not residual_allows_mix_launch?(
        remaining_after,
        operation_timeout_ms,
        postflight_reserve_ms
      )
  end

  defp prelaunch_residual_capacity?(
         _reason,
         _remaining_after,
         _operation_timeout_ms,
         _postflight_reserve_ms
       ),
       do: false

  @doc """
  Construct bounded pure state for sequential test execution with timeout refinement.

  The supplied batches remain the immutable capacity-handoff plan. Refined
  attempts are runtime-only descriptors and can never replace plan entries.
  """
  @spec new_test_execution([test_batch()], pos_integer(), non_neg_integer()) ::
          {:ok, test_execution()} | {:error, term()}
  def new_test_execution(batches, operation_timeout, postflight_reserve_ms \\ 0)

  def new_test_execution([], operation_timeout, postflight_reserve_ms)
      when is_integer(operation_timeout) and operation_timeout > 0 and
             is_integer(postflight_reserve_ms) and postflight_reserve_ms >= 0 do
    {:ok, empty_test_execution(operation_timeout, postflight_reserve_ms)}
  end

  def new_test_execution(batches, operation_timeout, postflight_reserve_ms)
      when is_list(batches) and is_integer(operation_timeout) and operation_timeout > 0 and
             is_integer(postflight_reserve_ms) and postflight_reserve_ms >= 0 do
    if valid_remaining_batches?(batches) do
      [current | suffix] = batches

      {:ok,
       empty_test_execution(operation_timeout, postflight_reserve_ms)
       |> Map.merge(%{
         original_batches: batches,
         current_original: current,
         original_suffix: suffix,
         work_queue: [root_attempt(current)]
       })}
    else
      {:error, :invalid_test_batch_plan}
    end
  end

  def new_test_execution(_batches, _operation_timeout, _postflight_reserve_ms),
    do: {:error, :invalid_test_batch_plan}

  @doc """
  Project a bounded, non-accepting ordered_binary_split_v1 cut from live state.

  Returns nil when there is no current original, the current original is
  unrefined, or the work queue is still the unsplit root. Never includes Mix
  observations.
  """
  @spec compact_refinement_frontier(term()) :: {:ok, map() | nil} | {:error, term()}
  def compact_refinement_frontier(state) when is_map(state) do
    with :ok <- validate_test_execution(state) do
      cond do
        is_nil(state.current_original) ->
          {:ok, nil}

        not state.refined? ->
          {:ok, nil}

        state.work_queue == [root_attempt(state.current_original)] and
            state.accepted_paths == [] ->
          {:ok, nil}

        true ->
          encode_live_frontier(state)
      end
    end
  end

  def compact_refinement_frontier(_state), do: {:error, :invalid_refinement_state}

  @doc """
  Admit a compact refinement frontier against a path-free original batch.

  Count-only left-first simulation enforces no overlap, no gaps, and a
  reachable cut of the unique split tree. Mix observations are forbidden.
  """
  @spec admit_refinement_frontier(term(), term()) :: {:ok, map()} | {:error, atom()}
  def admit_refinement_frontier(frontier, compact_original) do
    with {:ok, compact} <- normalize_compact_original(compact_original),
         {:ok, parsed} <- parse_frontier_shape(frontier),
         :ok <- match_frontier_original(parsed, compact),
         {:ok, splits} <-
           simulate_frontier_cut(
             parsed["original_count"],
             parsed["accepted_positions"],
             parsed["pending_positions"]
           ),
         :ok <- match_frontier_geometry(parsed, splits) do
      {:ok, build_frontier(parsed)}
    end
  rescue
    _ -> {:error, :malformed_state}
  catch
    _, _ -> {:error, :malformed_state}
  end

  @doc """
  Rehydrate live execution to an admitted compact frontier.

  `nil` is identity only for an unrefined execution. A map reconstructs
  accepted paths and the pending work queue from the original path list and
  sets `prior_frontier`. Does not invent Mix attempt records.
  """
  @spec resume_test_execution(term(), term()) :: {:ok, test_execution()} | {:error, atom()}
  def resume_test_execution(state, nil) when is_map(state) do
    with :ok <- validate_test_execution(state),
         {:ok, nil} <- compact_refinement_frontier(state),
         true <- is_nil(state.prior_frontier) do
      {:ok, state}
    else
      _ -> {:error, :invalid_refinement_state}
    end
  end

  def resume_test_execution(state, frontier) when is_map(state) do
    with :ok <- validate_test_execution(state),
         true <- is_nil(state.prior_frontier),
         %{} = current <- state.current_original,
         {:ok, admitted} <- admit_refinement_frontier(frontier, compact_batch(current)),
         {:ok, accepted_paths, pending} <- reconstruct_frontier_attempts(current, admitted) do
      resumed = %{
        state
        | work_queue: pending,
          accepted_paths: accepted_paths,
          accepted_positions: admitted["accepted_positions"],
          attempt_records: [],
          current_started: true,
          refined?: true,
          refined_child_count: admitted["refined_child_count"],
          prior_frontier: admitted
      }

      with :ok <- validate_test_execution(resumed) do
        {:ok, resumed}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_refinement_state}
    end
  end

  def resume_test_execution(_state, _frontier), do: {:error, :invalid_refinement_state}

  @doc """
  Decide the next process effect under the caller-supplied shared-deadline residual.

  Capacity effects always contain original batches only.
  """
  @spec next_test_execution_step(test_execution(), integer()) ::
          {:run, test_attempt(), pos_integer()}
          | {:complete, map()}
          | {:capacity, [test_batch()], test_batch() | nil, [test_batch()]}
          | {:error, term()}
  def next_test_execution_step(state, remaining_ms)
      when is_map(state) and is_integer(remaining_ms) do
    with :ok <- validate_test_execution(state) do
      case state.current_original do
        nil ->
          {:complete, aggregate_test_check(state.original_results)}

        current ->
          if residual_allows_mix_launch?(
               remaining_ms,
               state.operation_timeout,
               state.postflight_reserve_ms
             ) do
            case state.work_queue do
              [attempt | _] ->
                {:run, attempt, min(state.operation_timeout, remaining_ms)}

              _ ->
                {:error, :invalid_refinement_state}
            end
          else
            if state.current_started do
              {:capacity, state.completed_originals, current, state.original_suffix}
            else
              {:capacity, state.completed_originals, nil, [current | state.original_suffix]}
            end
          end
      end
    end
  end

  def next_test_execution_step(_state, _remaining_ms), do: {:error, :invalid_refinement_state}

  @doc """
  Purely reduce one launched process result into the next refinement state/effect.

  Non-timeout failures win over deadline exhaustion. A clipped aggregate-deadline
  timeout leaves the attempt pending. A singleton full-budget timeout is
  candidate-actionable. Multi-file full-budget timeouts always split; residual
  only decides whether the next step runs or capacities.
  """
  @spec record_test_execution_attempt(
          test_execution(),
          test_attempt(),
          map(),
          boolean(),
          pos_integer(),
          integer()
        ) ::
          {:continue, test_execution()}
          | {:terminal, map()}
          | {:capacity, [test_batch()], test_batch(), [test_batch()]}
          | {:error, term()}
  def record_test_execution_attempt(
        state,
        attempt,
        feedback,
        runner_timeout,
        launched_budget,
        remaining_after
      )
      when is_map(state) and is_map(attempt) and is_map(feedback) and
             is_boolean(runner_timeout) and is_integer(launched_budget) and
             launched_budget > 0 and is_integer(remaining_after) do
    with :ok <- validate_test_execution(state),
         [expected | rest] <- state.work_queue,
         true <- attempt == expected do
      record = attempt_record(state, attempt, feedback, runner_timeout)

      state = %{
        state
        | current_started: true,
          attempt_records: state.attempt_records ++ [record],
          total_attempt_count: state.total_attempt_count + 1
      }

      passed = feedback_value(feedback, :passed) == true
      reserve = state.postflight_reserve_ms

      cond do
        not runner_timeout and not passed ->
          result = original_result(state, feedback, false, false)
          {:terminal, aggregate_test_check(state.original_results ++ [result])}

        aggregate_deadline_interrupted?(
          runner_timeout,
          remaining_after,
          launched_budget,
          state.operation_timeout,
          reserve
        ) ->
          {:capacity, state.completed_originals, state.current_original, state.original_suffix}

        runner_timeout and attempt.count == 1 ->
          result = original_result(state, feedback, false, true)
          {:terminal, aggregate_test_check(state.original_results ++ [result])}

        runner_timeout ->
          with {:ok, left, right} <- split_attempt(state.current_original, attempt) do
            {:continue,
             %{
               state
               | work_queue: [left, right | rest],
                 refined?: true,
                 refined_child_count: state.refined_child_count + 2
             }}
          end

        passed ->
          accept_passing_attempt(state, attempt, rest, feedback, remaining_after)

        true ->
          {:error, :invalid_refinement_state}
      end
    else
      _ -> {:error, :invalid_refinement_state}
    end
  end

  def record_test_execution_attempt(
        _state,
        _attempt,
        _feedback,
        _runner_timeout,
        _launched_budget,
        _remaining_after
      ),
      do: {:error, :invalid_refinement_state}

  @doc """
  Classify a process that failed before launch.

  A closed Mix/prelaunch capacity token with residual that cannot honor the
  injected postflight reserve interrupts the immutable original during
  refinement and leaves that original unstarted before a root launch.
  Ordinary prelaunch errors stay execution failures.
  """
  @spec record_test_execution_prelaunch_error(test_execution(), term(), integer()) ::
          {:capacity, [test_batch()], test_batch() | nil, [test_batch()]}
          | {:execution_error, term()}
          | {:error, term()}
  def record_test_execution_prelaunch_error(state, reason, remaining_after)
      when is_map(state) and is_integer(remaining_after) do
    with :ok <- validate_test_execution(state) do
      if prelaunch_residual_capacity?(
           reason,
           remaining_after,
           state.operation_timeout,
           state.postflight_reserve_ms
         ) do
        if state.current_started do
          {:capacity, state.completed_originals, state.current_original, state.original_suffix}
        else
          {:capacity, state.completed_originals, nil,
           [state.current_original | state.original_suffix]}
        end
      else
        [attempt | _] = state.work_queue
        {:execution_error, {:test_execution_failed, attempt.label, reason}}
      end
    end
  end

  def record_test_execution_prelaunch_error(_state, _reason, _remaining_after),
    do: {:error, :invalid_refinement_state}

  defp empty_test_execution(operation_timeout, postflight_reserve_ms) do
    %{
      original_batches: [],
      completed_originals: [],
      current_original: nil,
      original_suffix: [],
      work_queue: [],
      accepted_paths: [],
      accepted_positions: [],
      original_results: [],
      attempt_records: [],
      current_started: false,
      refined?: false,
      refined_child_count: 0,
      total_attempt_count: 0,
      operation_timeout: operation_timeout,
      postflight_reserve_ms: postflight_reserve_ms,
      prior_frontier: nil
    }
  end

  defp accept_passing_attempt(state, attempt, rest, feedback, _remaining_after) do
    accepted_paths = state.accepted_paths ++ attempt.paths
    accepted_positions = state.accepted_positions ++ [attempt.position]

    state = %{
      state
      | accepted_paths: accepted_paths,
        accepted_positions: accepted_positions,
        work_queue: rest
    }

    cond do
      rest != [] ->
        {:continue, state}

      accepted_paths != state.current_original.paths ->
        {:error, :invalid_refinement_state}

      true ->
        result = original_result(state, feedback, true, false)
        {:continue, advance_original(state, result)}
    end
  end

  defp advance_original(state, result) do
    completed = state.completed_originals ++ [state.current_original]
    results = state.original_results ++ [result]

    case state.original_suffix do
      [next | suffix] ->
        %{
          state
          | completed_originals: completed,
            current_original: next,
            original_suffix: suffix,
            work_queue: [root_attempt(next)],
            accepted_paths: [],
            accepted_positions: [],
            original_results: results,
            attempt_records: [],
            current_started: false,
            refined?: false,
            refined_child_count: 0,
            prior_frontier: nil
        }

      [] ->
        %{
          state
          | completed_originals: completed,
            current_original: nil,
            original_suffix: [],
            work_queue: [],
            accepted_paths: [],
            accepted_positions: [],
            original_results: results,
            attempt_records: [],
            current_started: false,
            refined?: false,
            refined_child_count: 0,
            prior_frontier: nil
        }
    end
  end

  defp root_attempt(batch) do
    %{
      label: batch.label,
      paths: batch.paths,
      count: batch.count,
      inventory_sha256: batch.inventory_sha256,
      position: "root",
      original_index: batch.index
    }
  end

  defp split_attempt(original, attempt) do
    split_at = div(attempt.count + 1, 2)
    {left_paths, right_paths} = Enum.split(attempt.paths, split_at)

    if left_paths != [] and right_paths != [] and length(left_paths) < attempt.count and
         length(right_paths) < attempt.count do
      {:ok, refined_attempt(original, attempt.position <> "L", left_paths),
       refined_attempt(original, attempt.position <> "R", right_paths)}
    else
      {:error, :invalid_refinement_state}
    end
  end

  defp refined_attempt(original, position, paths) do
    count = length(paths)
    digest = inventory_sha256(paths)

    %{
      label: "#{original.label}:refine-#{position}-n#{count}-#{digest}",
      paths: paths,
      count: count,
      inventory_sha256: digest,
      position: position,
      original_index: original.index
    }
  end

  defp attempt_record(state, attempt, feedback, runner_timeout) do
    %{
      original_label: state.current_original.label,
      attempt_label: attempt.label,
      sequence: length(state.attempt_records) + 1,
      count: attempt.count,
      inventory_sha256: attempt.inventory_sha256,
      timed_out: runner_timeout,
      exit_code: feedback_value(feedback, :exit_code),
      stdout_excerpt: feedback_value(feedback, :stdout_excerpt) || "",
      stderr_excerpt: feedback_value(feedback, :stderr_excerpt) || "",
      stdout_truncated: feedback_value(feedback, :stdout_truncated) == true,
      stderr_truncated: feedback_value(feedback, :stderr_truncated) == true,
      stdout_sha256: feedback_value(feedback, :stdout_sha256) || sha256(""),
      stderr_sha256: feedback_value(feedback, :stderr_sha256) || sha256("")
    }
  end

  defp original_result(%{refined?: false} = state, final_feedback, _passed, timed_out) do
    classify_app_test_result(state.current_original.label, final_feedback, timed_out: timed_out)
  end

  defp original_result(state, final_feedback, passed, timed_out) do
    records = state.attempt_records
    attempt_digest = attempt_records_digest(records)
    marker = refinement_marker(state, records, attempt_digest)

    stdout =
      records
      |> Enum.map_join("\n", fn record ->
        "[#{record.attempt_label}]\n#{json_safe_utf8(record.stdout_excerpt)}"
      end)
      |> prepend_marker(marker)
      |> bound_output_excerpt()

    stderr =
      records
      |> Enum.map_join("\n", fn record ->
        "[#{record.attempt_label}]\n#{json_safe_utf8(record.stderr_excerpt)}"
      end)
      |> bound_output_excerpt()

    {stdout_excerpt, stdout_aggregate_truncated} = stdout
    {stderr_excerpt, stderr_aggregate_truncated} = stderr

    %{
      path: state.current_original.label,
      passed: passed,
      timed_out: timed_out,
      exit_code: feedback_value(final_feedback, :exit_code),
      reason:
        if(passed, do: nil, else: if(timed_out, do: "tests_timed_out", else: "tests_failed")),
      stdout_excerpt: stdout_excerpt,
      stderr_excerpt: stderr_excerpt,
      stdout_truncated: stdout_aggregate_truncated or Enum.any?(records, & &1.stdout_truncated),
      stderr_truncated: stderr_aggregate_truncated or Enum.any?(records, & &1.stderr_truncated),
      stdout_sha256: attempt_stream_digest(records, :stdout_sha256),
      stderr_sha256: attempt_stream_digest(records, :stderr_sha256),
      refinement: refinement_metadata(state, records, attempt_digest)
    }
  end

  defp refinement_marker(%{prior_frontier: prior} = state, records, attempt_digest)
       when is_map(prior) do
    {:ok, prior_digest} = Arbor.Actions.Coding.CrossApp.EvidenceCore.digest(prior)

    "[cross_app_refinement strategy=ordered_binary_split_v1 original=#{state.current_original.label} window_attempts=#{length(records)} refined_children=#{state.refined_child_count} resumed=1 prior_sha256=#{prior_digest} attempted_outputs_sha256=#{attempt_digest}]"
  end

  defp refinement_marker(state, records, attempt_digest) do
    "[cross_app_refinement strategy=ordered_binary_split_v1 original=#{state.current_original.label} attempts=#{length(records)} refined_children=#{state.refined_child_count} attempted_outputs_sha256=#{attempt_digest}]"
  end

  defp refinement_metadata(%{prior_frontier: prior} = state, records, attempt_digest)
       when is_map(prior) do
    %{
      strategy: "ordered_binary_split_v1",
      attempt_count: length(records),
      refined_child_count: state.refined_child_count,
      attempted_outputs_sha256: attempt_digest,
      resumed: true,
      prior: prior
    }
  end

  defp refinement_metadata(state, records, attempt_digest) do
    %{
      strategy: "ordered_binary_split_v1",
      attempt_count: length(records),
      refined_child_count: state.refined_child_count,
      attempted_outputs_sha256: attempt_digest
    }
  end

  defp prepend_marker(text, ""), do: text
  defp prepend_marker("", marker), do: marker
  defp prepend_marker(text, marker), do: marker <> "\n" <> text

  defp attempt_records_digest(records) do
    records
    |> Enum.map(fn record ->
      [
        record.original_label,
        record.attempt_label,
        record.sequence,
        record.count,
        record.inventory_sha256,
        record.timed_out,
        record.exit_code,
        record.stdout_sha256,
        record.stderr_sha256
      ]
    end)
    |> Jason.encode!()
    |> then(&sha256("cross_app_refinement_attempts_v1\0" <> &1))
  end

  defp attempt_stream_digest(records, field) do
    records
    |> Enum.map(fn record -> [record.attempt_label, Map.fetch!(record, field)] end)
    |> Jason.encode!()
    |> then(&sha256("cross_app_refinement_stream_v1\0" <> Atom.to_string(field) <> "\0" <> &1))
  end

  defp feedback_value(feedback, key) do
    Map.get(feedback, key) || Map.get(feedback, Atom.to_string(key))
  end

  defp validate_test_execution(state) when is_map(state) do
    try do
      do_validate_test_execution(state)
    rescue
      _ -> {:error, :invalid_refinement_state}
    catch
      _, _ -> {:error, :invalid_refinement_state}
    end
  end

  defp validate_test_execution(_state), do: {:error, :invalid_refinement_state}

  defp do_validate_test_execution(state) do
    required = [
      :original_batches,
      :completed_originals,
      :current_original,
      :original_suffix,
      :work_queue,
      :accepted_paths,
      :accepted_positions,
      :original_results,
      :attempt_records,
      :current_started,
      :refined?,
      :refined_child_count,
      :total_attempt_count,
      :operation_timeout,
      :postflight_reserve_ms,
      :prior_frontier
    ]

    cond do
      Enum.any?(required, &(not Map.has_key?(state, &1))) ->
        {:error, :invalid_refinement_state}

      not is_integer(state.operation_timeout) or state.operation_timeout <= 0 ->
        {:error, :invalid_refinement_state}

      not is_integer(state.postflight_reserve_ms) or state.postflight_reserve_ms < 0 ->
        {:error, :invalid_refinement_state}

      not is_list(state.original_batches) or not is_list(state.completed_originals) or
        not is_list(state.original_suffix) or not is_list(state.work_queue) or
        not is_list(state.accepted_paths) or not is_list(state.accepted_positions) or
        not is_list(state.original_results) or not is_list(state.attempt_records) ->
        {:error, :invalid_refinement_state}

      not is_boolean(state.current_started) or not is_boolean(state.refined?) or
        not is_integer(state.refined_child_count) or state.refined_child_count < 0 or
        not is_integer(state.total_attempt_count) or state.total_attempt_count < 0 ->
        {:error, :invalid_refinement_state}

      state.original_batches == [] ->
        validate_empty_test_execution(state)

      not valid_remaining_batches?(state.original_batches) ->
        {:error, :invalid_refinement_state}

      true ->
        validate_active_test_execution(state)
    end
  end

  defp validate_empty_test_execution(state) do
    if state.completed_originals == [] and is_nil(state.current_original) and
         state.original_suffix == [] and state.work_queue == [] and
         state.accepted_paths == [] and state.accepted_positions == [] and
         state.original_results == [] and
         state.attempt_records == [] and state.current_started == false and
         state.refined? == false and state.refined_child_count == 0 and
         state.total_attempt_count == 0 and is_nil(state.prior_frontier) do
      :ok
    else
      {:error, :invalid_refinement_state}
    end
  end

  defp validate_active_test_execution(state) do
    remaining =
      if is_nil(state.current_original),
        do: [],
        else: [state.current_original | state.original_suffix]

    with true <- state.completed_originals ++ remaining == state.original_batches,
         {:ok, completed_attempt_count} <-
           validate_execution_results(state.completed_originals, state.original_results) do
      validate_active_test_execution_fields(state, completed_attempt_count)
    else
      _ -> {:error, :invalid_refinement_state}
    end
  end

  defp validate_active_test_execution_fields(
         %{current_original: nil} = state,
         completed_attempt_count
       ) do
    if state.work_queue == [] and state.original_suffix == [] and state.accepted_paths == [] and
         state.accepted_positions == [] and
         state.attempt_records == [] and state.current_started == false and
         state.refined? == false and state.refined_child_count == 0 and
         is_nil(state.prior_frontier) and
         length(state.completed_originals) == length(state.original_batches) and
         state.total_attempt_count == completed_attempt_count do
      :ok
    else
      {:error, :invalid_refinement_state}
    end
  end

  defp validate_active_test_execution_fields(state, completed_attempt_count) do
    current = state.current_original
    current_count = Map.get(current, :count)
    valid_queue? = Enum.all?(state.work_queue, &valid_attempt?(&1, current))
    max_refined_children = if is_integer(current_count), do: 2 * (current_count - 1), else: -1

    canonical_refined_children =
      canonical_refined_child_count(length(state.attempt_records) + length(state.work_queue))

    cond do
      not is_integer(current_count) or current_count <= 0 ->
        {:error, :invalid_refinement_state}

      state.work_queue == [] or not valid_queue? ->
        {:error, :invalid_refinement_state}

      length(state.attempt_records) > 2 * current_count - 1 ->
        {:error, :invalid_refinement_state}

      not valid_attempt_records?(state.attempt_records, current) ->
        {:error, :invalid_refinement_state}

      state.total_attempt_count != completed_attempt_count + length(state.attempt_records) ->
        {:error, :invalid_refinement_state}

      state.accepted_paths ++ queue_paths(state.work_queue) != Map.get(current, :paths) ->
        {:error, :invalid_refinement_state}

      is_map(state.prior_frontier) ->
        validate_resumed_test_execution_fields(state, current, max_refined_children)

      not is_nil(state.prior_frontier) ->
        {:error, :invalid_refinement_state}

      state.current_started != state.refined? ->
        {:error, :invalid_refinement_state}

      state.current_started != (state.attempt_records != []) ->
        {:error, :invalid_refinement_state}

      state.refined? and
          (state.refined_child_count < 2 or
             rem(state.refined_child_count, 2) != 0 or
             state.refined_child_count != canonical_refined_children or
             state.refined_child_count > max_refined_children) ->
        {:error, :invalid_refinement_state}

      not state.refined? and
          (state.refined_child_count != 0 or state.accepted_paths != [] or
             state.accepted_positions != [] or
             state.work_queue != [root_attempt(current)]) ->
        {:error, :invalid_refinement_state}

      state.refined? and not valid_refined_origin_record?(state.attempt_records, current) ->
        {:error, :invalid_refinement_state}

      state.refined? ->
        validate_live_cut(state, current)

      true ->
        :ok
    end
  end

  defp validate_resumed_test_execution_fields(state, current, max_refined_children) do
    prior = state.prior_frontier
    window_splits = window_split_count(state.attempt_records)
    expected_children = prior["refined_child_count"] + 2 * window_splits

    with {:ok, _admitted} <- admit_refinement_frontier(prior, compact_batch(current)),
         true <- state.current_started == true,
         true <- state.refined? == true,
         true <- is_integer(state.refined_child_count),
         true <- rem(state.refined_child_count, 2) == 0,
         true <- state.refined_child_count == expected_children,
         true <- state.refined_child_count >= prior["refined_child_count"],
         true <- state.refined_child_count <= max_refined_children,
         :ok <- validate_live_cut(state, current) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_refinement_state}
    end
  end

  defp validate_live_cut(state, current) do
    pending = Enum.map(state.work_queue, & &1.position)

    with true <- is_list(state.accepted_positions),
         {:ok, accepted_positions, pending_positions, splits} <- replay_live_cut(state),
         true <- accepted_positions == state.accepted_positions,
         true <- pending_positions == pending,
         true <- 2 * splits == state.refined_child_count,
         {:ok, expected_accepted} <- collect_position_paths(current, accepted_positions),
         true <- expected_accepted == state.accepted_paths do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_refinement_state}
    end
  end

  defp window_split_count(records) when is_list(records) do
    Enum.count(records, fn record ->
      is_map(record) and record.timed_out == true and is_integer(record.count) and
        record.count > 1
    end)
  end

  defp queue_paths(queue), do: Enum.flat_map(queue, &Map.fetch!(&1, :paths))

  defp valid_attempt?(attempt, original)
       when is_map(attempt) and is_map(original) do
    with {:ok, label} <- Map.fetch(attempt, :label),
         {:ok, paths} <- Map.fetch(attempt, :paths),
         {:ok, count} <- Map.fetch(attempt, :count),
         {:ok, digest} <- Map.fetch(attempt, :inventory_sha256),
         {:ok, position} <- Map.fetch(attempt, :position),
         {:ok, original_index} <- Map.fetch(attempt, :original_index),
         {:ok, expected_original_index} <- Map.fetch(original, :index),
         {:ok, original_label} <- Map.fetch(original, :label),
         true <-
           is_binary(position) and byte_size(position) <= @max_refinement_position_bytes and
             Regex.match?(@refinement_position_regex, position),
         true <- is_list(paths) and paths != [],
         :ok <- validate_batch_member_paths(paths),
         true <- count == length(paths),
         true <- digest == inventory_sha256(paths),
         true <- original_index == expected_original_index do
      expected_label =
        if position == "root" do
          original_label
        else
          refined_attempt(original, position, paths).label
        end

      label == expected_label
    else
      _ -> false
    end
  end

  defp valid_attempt?(_attempt, _original), do: false

  defp validate_execution_results(completed, results)
       when is_list(completed) and is_list(results) and length(completed) == length(results) do
    Enum.zip(completed, results)
    |> Enum.reduce_while({:ok, 0}, fn {batch, result}, {:ok, count} ->
      case completed_result_attempt_count(batch, result) do
        {:ok, attempts} -> {:cont, {:ok, count + attempts}}
        :error -> {:halt, {:error, :invalid_refinement_state}}
      end
    end)
  end

  defp validate_execution_results(_completed, _results),
    do: {:error, :invalid_refinement_state}

  defp completed_result_attempt_count(batch, result) when is_map(batch) and is_map(result) do
    valid_base? =
      Map.get(result, :path) == Map.get(batch, :label) and Map.get(result, :passed) == true and
        Map.get(result, :timed_out) == false and Map.get(result, :exit_code) == 0 and
        is_nil(Map.get(result, :reason)) and
        bounded_attempt_excerpt?(Map.get(result, :stdout_excerpt)) and
        bounded_attempt_excerpt?(Map.get(result, :stderr_excerpt)) and
        is_boolean(Map.get(result, :stdout_truncated)) and
        is_boolean(Map.get(result, :stderr_truncated)) and
        valid_sha256?(Map.get(result, :stdout_sha256)) and
        valid_sha256?(Map.get(result, :stderr_sha256))

    case {valid_base?, Map.get(result, :refinement)} do
      {true, nil} ->
        {:ok, 1}

      {true, refinement} when is_map(refinement) ->
        if Map.get(refinement, :resumed) == true do
          completed_resumed_attempt_count(batch, refinement)
        else
          max_attempts = 2 * Map.get(batch, :count, 0) - 1
          max_refined_children = 2 * (Map.get(batch, :count, 0) - 1)
          attempts = Map.get(refinement, :attempt_count)
          children = Map.get(refinement, :refined_child_count)

          if Map.get(refinement, :strategy) == "ordered_binary_split_v1" and
               is_integer(attempts) and attempts >= 3 and attempts <= max_attempts and
               is_integer(children) and children == canonical_refined_child_count(attempts) and
               rem(children, 2) == 0 and
               children <= max_refined_children and
               valid_sha256?(Map.get(refinement, :attempted_outputs_sha256)) do
            {:ok, attempts}
          else
            :error
          end
        end

      _ ->
        :error
    end
  end

  defp completed_result_attempt_count(_batch, _result), do: :error

  defp completed_resumed_attempt_count(batch, refinement) do
    attempts = Map.get(refinement, :attempt_count)
    children = Map.get(refinement, :refined_child_count)
    prior = Map.get(refinement, :prior)
    max_refined_children = 2 * (Map.get(batch, :count, 0) - 1)

    with true <- Map.get(refinement, :strategy) == "ordered_binary_split_v1",
         true <- is_integer(attempts) and attempts >= 1,
         true <- is_integer(children) and rem(children, 2) == 0,
         true <- children <= max_refined_children,
         true <- valid_sha256?(Map.get(refinement, :attempted_outputs_sha256)),
         {:ok, admitted} <- admit_refinement_frontier(prior, compact_batch(batch)),
         true <- children >= admitted["refined_child_count"] do
      {:ok, attempts}
    else
      _ -> :error
    end
  end

  # The root is not a refined child, so its materialized tree has node_count - 1 children.
  defp canonical_refined_child_count(materialized_node_count), do: materialized_node_count - 1

  defp valid_refined_origin_record?([record | _], original) do
    Map.get(record, :attempt_label) == Map.get(original, :label) and
      Map.get(record, :count) == Map.get(original, :count) and
      Map.get(record, :inventory_sha256) == Map.get(original, :inventory_sha256) and
      Map.get(record, :timed_out) == true
  end

  defp valid_refined_origin_record?(_records, _original), do: false

  defp valid_attempt_records?(records, original) when is_list(records) and is_map(original) do
    Enum.with_index(records, 1)
    |> Enum.all?(fn {record, sequence} ->
      is_map(record) and record.original_label == original.label and
        is_binary(record.attempt_label) and byte_size(record.attempt_label) <= 512 and
        record.sequence == sequence and is_integer(record.count) and record.count > 0 and
        record.count <= original.count and valid_sha256?(record.inventory_sha256) and
        is_boolean(record.timed_out) and
        (is_nil(record.exit_code) or is_integer(record.exit_code)) and
        bounded_attempt_excerpt?(record.stdout_excerpt) and
        bounded_attempt_excerpt?(record.stderr_excerpt) and
        is_boolean(record.stdout_truncated) and is_boolean(record.stderr_truncated) and
        valid_sha256?(record.stdout_sha256) and valid_sha256?(record.stderr_sha256)
    end)
  rescue
    _ -> false
  end

  defp valid_attempt_records?(_records, _original), do: false

  defp bounded_attempt_excerpt?(value),
    do:
      is_binary(value) and byte_size(value) <= @max_output_excerpt_bytes and String.valid?(value)

  defp valid_sha256?(value),
    do: is_binary(value) and byte_size(value) == 64 and String.match?(value, ~r/\A[0-9a-f]{64}\z/)

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
  @spec next_test_step(term(), term(), term(), term()) :: test_step()
  def next_test_step(remaining_ms, batches, operation_timeout_ms, postflight_reserve_ms \\ 0)

  def next_test_step(_remaining_ms, [], operation_timeout_ms, postflight_reserve_ms)
      when is_integer(operation_timeout_ms) and operation_timeout_ms > 0 and
             is_integer(postflight_reserve_ms) and postflight_reserve_ms >= 0 do
    :complete
  end

  def next_test_step(remaining_ms, [batch | rest], operation_timeout_ms, postflight_reserve_ms)
      when is_integer(remaining_ms) and is_map(batch) and is_list(rest) and
             is_integer(operation_timeout_ms) and operation_timeout_ms > 0 and
             is_integer(postflight_reserve_ms) and postflight_reserve_ms >= 0 do
    if valid_remaining_batches?([batch | rest]) do
      if residual_allows_mix_launch?(
           remaining_ms,
           operation_timeout_ms,
           postflight_reserve_ms
         ) do
        {:run, batch, min(operation_timeout_ms, remaining_ms), rest}
      else
        {:timeout, batch, rest}
      end
    else
      invalid_test_step_input(remaining_ms, [batch | rest], operation_timeout_ms)
    end
  end

  def next_test_step(remaining_ms, batches, operation_timeout_ms, _postflight_reserve_ms) do
    invalid_test_step_input(remaining_ms, batches, operation_timeout_ms)
  end

  @doc """
  Residual-budget admission for the complete reviewed batch plan.

  Batches run sequentially under one shared aggregate deadline. Each child is
  capped by `min(operation_timeout_ms, remaining_ms)`. Admission therefore
  checks whether that Mix outer timeout can honor postflight reserve — never
  whether `batch_count * per-batch ceiling` fits the aggregate as a predicted
  total.
  """
  @spec admit_test_batches([test_batch()], integer(), pos_integer(), non_neg_integer()) ::
          :ok | {:capacity_exceeded, map()} | {:error, term()}
  def admit_test_batches(
        batches,
        available_ms,
        operation_timeout_ms,
        postflight_reserve_ms \\ 0
      )

  def admit_test_batches(batches, available_ms, operation_timeout_ms, postflight_reserve_ms)
      when is_list(batches) and is_integer(available_ms) and
             is_integer(operation_timeout_ms) and operation_timeout_ms > 0 and
             is_integer(postflight_reserve_ms) and postflight_reserve_ms >= 0 do
    cond do
      batches == [] ->
        :ok

      not valid_remaining_batches?(batches) ->
        {:error, :invalid_test_batch_plan}

      residual_allows_mix_launch?(
        available_ms,
        operation_timeout_ms,
        postflight_reserve_ms
      ) ->
        :ok

      true ->
        # Residual cannot honor Mix postflight reserve before the first child.
        case capacity_handoff(:structural, 0, operation_timeout_ms, [], nil, batches) do
          {:ok, check} -> {:capacity_exceeded, check}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def admit_test_batches(_batches, _available_ms, _operation_timeout_ms, _postflight_reserve_ms),
    do: {:error, :invalid_test_batch_plan}

  @doc """
  Build the bounded, JSON-clean handoff check for residual capacity evidence.

  Residual available budget on a handoff is always 0: any Mix-launchable
  remainder is executable via `next_test_step/4`. Batch paths are already admitted and
  normalized by partition_test_batches/1. Schema v3 binds either an unstarted
  suffix (`interrupted_batch` null) or one aggregate-deadline interrupted batch
  plus optional unstarted suffix — path-free labels, counts, and digests only.
  """
  @spec capacity_handoff(
          :structural | :runtime,
          integer(),
          pos_integer(),
          [test_batch()],
          test_batch() | nil,
          [test_batch()]
        ) :: {:ok, map()} | {:error, term()}
  def capacity_handoff(
        phase,
        available_ms,
        per_batch_budget_ms,
        completed_batches,
        interrupted_batch,
        unstarted_batches
      )
      when phase in [:structural, :runtime] and is_integer(available_ms) and
             is_integer(per_batch_budget_ms) and per_batch_budget_ms > 0 and
             is_list(completed_batches) and is_list(unstarted_batches) and
             (is_nil(interrupted_batch) or is_map(interrupted_batch)) do
    cond do
      available_ms > 0 ->
        # Positive residual must execute, not hand off.
        {:error, :invalid_capacity_handoff}

      true ->
        with :ok <-
               validate_capacity_batches(
                 completed_batches,
                 interrupted_batch,
                 unstarted_batches
               ),
             all_batches <-
               capacity_all_batches(completed_batches, interrupted_batch, unstarted_batches),
             completed_files <- Enum.sum(Enum.map(completed_batches, & &1.count)),
             interrupted_files <- interrupted_file_count(interrupted_batch),
             unstarted_files <- Enum.sum(Enum.map(unstarted_batches, & &1.count)),
             compact_interrupted <- compact_interrupted(interrupted_batch),
             compact_unstarted <- Enum.map(unstarted_batches, &capacity_batch/1),
             digest_subject <-
               if(compact_interrupted,
                 do: [compact_interrupted | compact_unstarted],
                 else: compact_unstarted
               ),
             {:ok, ordered_plan_sha256} <-
               ValidationCapacityHandoff.ordered_plan_digest(digest_subject),
             {:ok, handoff} <-
               ValidationCapacityHandoff.new(%{
                 "schema_version" => ValidationCapacityHandoff.schema_version(),
                 "phase" => Atom.to_string(phase),
                 # Exhausted residual is always normalized to 0 (never negative).
                 "available_budget_ms" => 0,
                 "per_batch_budget_ms" => per_batch_budget_ms,
                 "completed_batch_count" => length(completed_batches),
                 "completed_file_count" => completed_files,
                 "unstarted_batch_count" => length(unstarted_batches),
                 "unstarted_file_count" => unstarted_files,
                 "total_batch_count" => length(all_batches),
                 "total_file_count" => completed_files + interrupted_files + unstarted_files,
                 "ordered_plan_sha256" => ordered_plan_sha256,
                 "interrupted_batch" => compact_interrupted,
                 "unstarted_batches" => compact_unstarted
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
  end

  def capacity_handoff(
        _phase,
        _available_ms,
        _per_batch_budget_ms,
        _completed_batches,
        _interrupted_batch,
        _unstarted_batches
      ),
      do: {:error, :invalid_capacity_handoff}

  # Compatibility shim for call sites that still pass the pre-v3 arity
  # (completed + unstarted only => interrupted null).
  @doc false
  def capacity_handoff(
        phase,
        available_ms,
        per_batch_budget_ms,
        completed_batches,
        unstarted_batches
      )
      when is_list(unstarted_batches) do
    capacity_handoff(
      phase,
      available_ms,
      per_batch_budget_ms,
      completed_batches,
      nil,
      unstarted_batches
    )
  end

  defp capacity_batch(batch) do
    %{
      "index" => Map.get(batch, :index),
      "total" => Map.get(batch, :total),
      "count" => Map.get(batch, :count),
      "label" => Map.get(batch, :label),
      "inventory_sha256" => Map.get(batch, :inventory_sha256)
    }
  end

  defp compact_interrupted(nil), do: nil
  defp compact_interrupted(batch), do: capacity_batch(batch)

  defp interrupted_file_count(nil), do: 0
  defp interrupted_file_count(batch), do: Map.get(batch, :count) || Map.get(batch, "count") || 0

  defp capacity_all_batches(completed, nil, unstarted), do: completed ++ unstarted

  defp capacity_all_batches(completed, interrupted, unstarted),
    do: completed ++ [interrupted | unstarted]

  defp validate_capacity_batches(completed_batches, nil, unstarted_batches)
       when is_list(completed_batches) and is_list(unstarted_batches) and unstarted_batches != [] do
    all_batches = completed_batches ++ unstarted_batches

    if Enum.all?(all_batches, &is_map/1) and valid_remaining_batches?(all_batches),
      do: :ok,
      else: {:error, :invalid_capacity_batch_plan}
  end

  defp validate_capacity_batches(completed_batches, interrupted, unstarted_batches)
       when is_map(interrupted) and is_list(completed_batches) and is_list(unstarted_batches) do
    all_batches = completed_batches ++ [interrupted | unstarted_batches]

    if Enum.all?(all_batches, &is_map/1) and valid_remaining_batches?(all_batches),
      do: :ok,
      else: {:error, :invalid_capacity_batch_plan}
  end

  defp validate_capacity_batches(_completed_batches, _interrupted, _unstarted_batches),
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
        Enum.reduce_while(paths, {:ok, nil, nil, 0}, fn path, {:ok, prev_app, prev_path, bytes} ->
          case normalize_test_file_path(path) do
            {:ok, ^path} ->
              path_root = app_test_root(path)
              cost = path_arg_bytes(path)

              cond do
                is_nil(path_root) ->
                  {:halt, :error}

                is_binary(prev_app) and path_root != prev_app ->
                  {:halt, :error}

                is_binary(prev_path) and path <= prev_path ->
                  {:halt, :error}

                cost > @max_test_batch_arg_bytes ->
                  {:halt, :error}

                bytes + cost > @max_test_batch_arg_bytes ->
                  {:halt, :error}

                true ->
                  {:cont, {:ok, path_root, path, bytes + cost}}
              end

            _ ->
              {:halt, :error}
          end
        end)
        |> case do
          {:ok, _prev_app, _prev_path, _bytes} -> :ok
          :error -> :error
        end
    end
  end

  defp validate_batch_member_paths(_), do: :error

  @doc """
  Deterministically partition verified, normalized `*_test.exs` paths into
  argv-safe Mix batches.

  Input must already be the post-normalization inventory: unique, grouped
  contiguously by app, strictly sorted within each app, and every path must
  re-normalize to itself. Partitioning is greedy left-to-right under the closed
  runtime file-count cap (at most 20 exact files per child), Shell argv-count
  ceiling, argument-byte ceiling, and app test root boundary (a batch never
  mixes files from different `apps/<app>/test` roots). Every path appears in
  exactly one non-empty batch, including a final partial batch; labels bind
  inventory count and SHA-256 over the exact ordered batch paths.
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

  @doc """
  Deterministically partition verified, normalized `*_test.exs` paths into
  argv-safe Mix batches using an explicit app execution order contract.

  `ordered_apps` is a canonical direct-first app ordering: changed apps first,
  then downstream apps. Paths are first normalized and deduped as before, then
  reordered so each listed app's entire deterministic per-app suffix appears in
  execution order before downstream app files.
  """
  @spec partition_test_batches([String.t()], [String.t()]) ::
          {:ok, [test_batch()]} | {:error, term()}
  def partition_test_batches([], ordered_apps) do
    with {:ok, _normalized_apps} <- normalize_ordered_app_ids(ordered_apps) do
      {:ok, []}
    end
  end

  def partition_test_batches(files, ordered_apps) when is_list(ordered_apps) do
    with {:ok, ordered_files} <- normalize_expanded_test_files(files, ordered_apps),
         {:ok, packed} <- pack_test_batches(ordered_files) do
      total = length(packed)

      batches =
        packed
        |> Enum.with_index(1)
        |> Enum.map(fn {paths, index} -> build_test_batch(paths, index, total) end)

      {:ok, batches}
    end
  end

  def partition_test_batches(_files, _ordered_apps), do: {:error, :invalid_test_batch_input}

  @doc """
  Build the direct-first execution-app order from selection metadata.

  `changed_apps` and `affected_apps` are fully validated sets; this helper is a
  pure deterministic projection that preserves the unchanged downstream inventory.
  """
  @spec execution_app_order([String.t()], [String.t()]) ::
          {:ok, execution_app_order()} | {:error, term()}
  def execution_app_order(changed_apps, affected_apps)
      when is_list(changed_apps) and is_list(affected_apps) do
    with {:ok, changed} <- normalize_app_ids(changed_apps),
         {:ok, affected} <- normalize_app_ids(affected_apps),
         :ok <- validate_changed_subset(changed, affected) do
      direct = changed
      direct_set = MapSet.new(direct)
      downstream = Enum.reject(affected, &MapSet.member?(direct_set, &1))
      ordered = direct ++ downstream

      {:ok,
       %{
         direct: direct,
         downstream: downstream,
         ordered: ordered
       }}
    end
  end

  def execution_app_order(_changed_apps, _affected_apps), do: {:error, :invalid_app_order_input}

  defp validate_changed_subset(changed_apps, affected_apps)
       when is_list(changed_apps) and is_list(affected_apps) do
    affected_set = MapSet.new(affected_apps)

    if Enum.all?(changed_apps, &MapSet.member?(affected_set, &1)) do
      :ok
    else
      {:error, :invalid_app_order_input}
    end
  end

  defp validate_batch_source_files(files) do
    validate_batch_source_files(
      files,
      @max_expanded_test_files,
      nil,
      nil,
      MapSet.new(),
      MapSet.new()
    )
  end

  defp validate_batch_source_files(
         [],
         _remaining,
         _prev_app,
         _prev_path,
         _seen_paths,
         _seen_apps
       ),
       do: :ok

  defp validate_batch_source_files(
         [_path | _rest],
         0,
         _prev_app,
         _prev_path,
         _seen_paths,
         _seen_apps
       ),
       do: {:error, :too_many_test_files}

  defp validate_batch_source_files(
         [path | rest],
         remaining,
         prev_app,
         prev_path,
         seen_paths,
         seen_apps
       ) do
    case normalize_test_file_path(path) do
      {:ok, ^path} ->
        app = test_file_app(path)

        cond do
          is_nil(app) ->
            {:error, {:invalid_test_file_path, path}}

          MapSet.member?(seen_paths, path) ->
            {:error, :unsorted_or_duplicate_test_files}

          path_arg_bytes(path) > @max_test_batch_arg_bytes ->
            {:error, {:test_file_path_exceeds_batch_bytes, path}}

          app == prev_app and is_binary(prev_path) and path <= prev_path ->
            {:error, :unsorted_or_duplicate_test_files}

          app != prev_app and MapSet.member?(seen_apps, app) ->
            {:error, :invalid_app_batching}

          true ->
            validate_batch_source_files(
              rest,
              remaining - 1,
              app,
              path,
              MapSet.put(seen_paths, path),
              MapSet.put(seen_apps, app)
            )
        end

      {:ok, _other} ->
        {:error, {:non_normalized_test_file, path}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_batch_source_files(
         _improper,
         _remaining,
         _prev_app,
         _prev_path,
         _seen_paths,
         _seen_apps
       ),
       do: {:error, :invalid_test_file_list}

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

  defp test_file_app(path) when is_binary(path) do
    case Path.split(path) do
      ["apps", app, "test" | _rest] when app != "" -> app
      _ -> nil
    end
  end

  defp reorder_normalized_test_files(paths, ordered_apps) do
    order_lookup =
      ordered_apps
      |> Enum.with_index()
      |> Enum.into(%{}, fn {app, index} -> {app, index} end)

    Enum.sort_by(paths, fn path ->
      {Map.fetch!(order_lookup, test_file_app(path)), path}
    end)
  end

  @doc """
  Normalize and bound an expanded list of relative `*_test.exs` file paths.

  Pure path grammar only — the shell must already reject symlinks via lstat.
  Fails closed on empty components, escapes, absolute paths, non-test suffixes,
  oversized inventories, and overlong path bytes.
  """
  @spec normalize_expanded_test_files(term()) ::
          {:ok, [String.t()]} | {:error, term()}
  def normalize_expanded_test_files(files) do
    collect_normalized_test_files(files, @max_expanded_test_files, MapSet.new(), [])
  end

  @doc """
  Same validation as `normalize_expanded_test_files/1`, then deterministic
  reordering into a direct-first per-app execution plan.

  Existing per-app validation and global uniqueness semantics remain unchanged.
  """
  @spec normalize_expanded_test_files(term(), term()) ::
          {:ok, [String.t()]} | {:error, term()}
  def normalize_expanded_test_files(files, ordered_apps) do
    with {:ok, normalized_apps} <- normalize_ordered_app_ids(ordered_apps),
         {:ok, normalized} <- normalize_expanded_test_files(files),
         :ok <- validate_test_file_apps(normalized, normalized_apps) do
      {:ok, reorder_normalized_test_files(normalized, normalized_apps)}
    end
  end

  defp collect_normalized_test_files([], _remaining, _seen, acc) do
    {:ok, acc |> Enum.reverse() |> Enum.sort()}
  end

  defp collect_normalized_test_files([_path | _rest], 0, _seen, _acc),
    do: {:error, :too_many_test_files}

  defp collect_normalized_test_files([path | rest], remaining, seen, acc) do
    case normalize_test_file_path(path) do
      {:ok, normalized} ->
        if MapSet.member?(seen, normalized) do
          collect_normalized_test_files(rest, remaining - 1, seen, acc)
        else
          collect_normalized_test_files(
            rest,
            remaining - 1,
            MapSet.put(seen, normalized),
            [normalized | acc]
          )
        end

      {:error, _} = error ->
        error
    end
  end

  defp collect_normalized_test_files(_improper, _remaining, _seen, _acc),
    do: {:error, :invalid_test_file_list}

  defp validate_test_file_apps(paths, ordered_apps) do
    allowed = MapSet.new(ordered_apps)

    case Enum.find(paths, &(not MapSet.member?(allowed, test_file_app(&1)))) do
      nil -> :ok
      path -> {:error, {:test_file_outside_app_order, path}}
    end
  end

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

    {raw_stdout_excerpt, stdout_agg_truncated} =
      bound_aggregate_excerpt(app_results, :stdout_excerpt)

    {stderr_excerpt, stderr_agg_truncated} =
      bound_aggregate_excerpt(app_results, :stderr_excerpt)

    {stdout_excerpt, refinement_truncated} =
      case refinement_aggregate_summary(app_results) do
        nil -> {raw_stdout_excerpt, false}
        summary -> bound_output_excerpt(summary <> "\n" <> raw_stdout_excerpt)
      end

    stdout_truncated =
      stdout_agg_truncated or refinement_truncated or
        Enum.any?(app_results, &(&1.stdout_truncated == true))

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

  defp refinement_aggregate_summary(app_results) do
    refinements =
      app_results
      |> Enum.map(&Map.get(&1, :refinement))
      |> Enum.reject(&is_nil/1)

    case refinements do
      [] ->
        nil

      _ ->
        attempted_outputs_sha256 =
          refinements
          |> Enum.map(fn refinement ->
            [
              refinement.strategy,
              refinement.attempt_count,
              refinement.refined_child_count,
              refinement.attempted_outputs_sha256
            ]
          end)
          |> Jason.encode!()
          |> then(&sha256("cross_app_refinement_summary_v1\0" <> &1))

        attempts = Enum.sum(Enum.map(refinements, & &1.attempt_count))
        children = Enum.sum(Enum.map(refinements, & &1.refined_child_count))

        "[cross_app_refinement_summary strategy=ordered_binary_split_v1 refined_originals=#{length(refinements)} attempts=#{attempts} refined_children=#{children} attempted_outputs_sha256=#{attempted_outputs_sha256}]"
    end
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

  defp validate_stage_timeout(nil), do: {:ok, nil}

  defp validate_stage_timeout(timeout)
       when is_integer(timeout) and timeout >= @minimum_timeout and
              timeout <= @maximum_stage_timeout,
       do: {:ok, timeout}

  defp validate_stage_timeout(timeout) when is_binary(timeout) do
    case Integer.parse(timeout) do
      {parsed, ""} ->
        if Integer.to_string(parsed) == timeout,
          do: validate_stage_timeout(parsed),
          else: {:error, :invalid_stage_timeout}

      _other ->
        {:error, :invalid_stage_timeout}
    end
  end

  defp validate_stage_timeout(_timeout), do: {:error, :invalid_stage_timeout}

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

  defp empty_topology_change do
    %{
      changed?: false,
      added_apps: [],
      removed_apps: [],
      edge_changed_apps: []
    }
  end

  defp known_apps_from_graph(graph) when is_map(graph) do
    case graph_apps(graph) do
      {:ok, apps} -> {:ok, MapSet.new(apps)}
      {:error, _} = error -> error
    end
  end

  defp graph_apps(%{apps: apps}) when is_list(apps), do: {:ok, apps}
  defp graph_apps(%{"apps" => apps}) when is_list(apps), do: {:ok, apps}
  defp graph_apps(_), do: {:error, :invalid_topology_input}

  defp graph_depends_on(%{depends_on: deps}) when is_map(deps), do: {:ok, deps}
  defp graph_depends_on(%{"depends_on" => deps}) when is_map(deps), do: {:ok, deps}
  defp graph_depends_on(_), do: {:error, :invalid_topology_input}

  defp topology_change_evidence(selection) when is_map(selection) do
    case Map.get(selection, :topology_change) || Map.get(selection, "topology_change") do
      %{changed?: changed?, added_apps: added, removed_apps: removed, edge_changed_apps: edges}
      when is_boolean(changed?) and is_list(added) and is_list(removed) and is_list(edges) ->
        %{
          "changed" => changed?,
          "added_apps" => Enum.take(added, @max_apps),
          "removed_apps" => Enum.take(removed, @max_apps),
          "edge_changed_apps" => Enum.take(edges, @max_apps)
        }

      %{
        "changed" => changed?,
        "added_apps" => added,
        "removed_apps" => removed,
        "edge_changed_apps" => edges
      }
      when is_boolean(changed?) and is_list(added) and is_list(removed) and is_list(edges) ->
        %{
          "changed" => changed?,
          "added_apps" => Enum.take(added, @max_apps),
          "removed_apps" => Enum.take(removed, @max_apps),
          "edge_changed_apps" => Enum.take(edges, @max_apps)
        }

      _ ->
        nil
    end
  end

  defp classify_files(files, known_apps) do
    known_set =
      cond do
        is_struct(known_apps, MapSet) -> known_apps
        is_list(known_apps) -> MapSet.new(known_apps)
        is_map(known_apps) and is_list(Map.get(known_apps, :apps)) -> MapSet.new(known_apps.apps)
        true -> nil
      end

    if is_nil(known_set) do
      {:error, :invalid_selection_input}
    else
      Enum.reduce_while(files, {:ok, MapSet.new(), false}, fn path, {:ok, apps, root_wide} ->
        cond do
          root_wide_path?(path) ->
            {:cont, {:ok, apps, true}}

          true ->
            case app_dir_from_path(path) do
              {:ok, app} ->
                if MapSet.member?(known_set, app) do
                  {:cont, {:ok, MapSet.put(apps, app), root_wide}}
                else
                  # Changed path under apps/<unknown>/ — fail closed when the
                  # name is absent from the known revision-union app set.
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

  defp encode_live_frontier(state) do
    original = state.current_original
    accepted_positions = state.accepted_positions
    pending_positions = Enum.map(state.work_queue, & &1.position)

    with {:ok, replayed_accepted, replayed_pending, splits} <- replay_live_cut(state),
         true <- replayed_accepted == accepted_positions,
         true <- replayed_pending == pending_positions,
         {:ok, accepted_paths} <- collect_position_paths(original, accepted_positions),
         true <- accepted_paths == state.accepted_paths,
         parsed <- %{
           "schema_version" => @refinement_frontier_schema_version,
           "strategy" => "ordered_binary_split_v1",
           "original_index" => original.index,
           "original_count" => original.count,
           "original_inventory_sha256" => original.inventory_sha256,
           "accepted_positions" => accepted_positions,
           "pending_positions" => pending_positions,
           "accepted_file_count" => length(state.accepted_paths),
           "pending_file_count" => pending_file_count(state.work_queue),
           "refined_child_count" => state.refined_child_count
         },
         :ok <- match(parsed["refined_child_count"], 2 * splits, :invalid_refinement_state),
         {:ok, admitted} <- admit_refinement_frontier(parsed, compact_batch(original)) do
      {:ok, admitted}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_refinement_state}
    end
  end

  defp pending_file_count(queue) do
    Enum.reduce(queue, 0, fn attempt, acc -> acc + attempt.count end)
  end

  defp replay_live_cut(state) do
    original = state.current_original

    with {:ok, accepted, pending, splits} <-
           replay_initial_cut(original, state.prior_frontier) do
      replay_attempt_records(state.attempt_records, original, accepted, pending, splits)
    end
  end

  defp replay_initial_cut(original, nil) do
    {:ok, [], [root_attempt(original)], 0}
  end

  defp replay_initial_cut(original, prior) when is_map(prior) do
    with {:ok, admitted} <- admit_refinement_frontier(prior, compact_batch(original)),
         {:ok, _accepted_paths, pending} <- reconstruct_frontier_attempts(original, admitted) do
      {:ok, admitted["accepted_positions"], pending, div(admitted["refined_child_count"], 2)}
    end
  end

  defp replay_initial_cut(_original, _prior), do: {:error, :invalid_refinement_state}

  defp replay_attempt_records(records, original, accepted, pending, splits)
       when is_list(records) do
    records
    |> Enum.reduce_while({:ok, {accepted, pending, splits}}, fn record,
                                                                {:ok, {accepted, pending, splits}} ->
      replay_one_record(record, original, accepted, pending, splits)
    end)
    |> case do
      {:ok, {accepted, pending, splits}} ->
        {:ok, accepted, Enum.map(pending, & &1.position), splits}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replay_one_record(record, original, accepted, [head | rest], splits) do
    cond do
      not record_matches_attempt?(record, head) ->
        {:halt, {:error, :invalid_refinement_state}}

      record.timed_out == true and head.count > 1 ->
        case split_attempt(original, head) do
          {:ok, left, right} ->
            {:cont, {:ok, {accepted, [left, right | rest], splits + 1}}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end

      record.timed_out == false ->
        {:cont, {:ok, {accepted ++ [head.position], rest, splits}}}

      true ->
        {:halt, {:error, :invalid_refinement_state}}
    end
  end

  defp replay_one_record(_record, _original, _accepted, _pending, _splits),
    do: {:halt, {:error, :invalid_refinement_state}}

  defp record_matches_attempt?(record, attempt) when is_map(record) and is_map(attempt) do
    record.attempt_label == attempt.label and record.count == attempt.count and
      record.inventory_sha256 == attempt.inventory_sha256
  end

  defp record_matches_attempt?(_record, _attempt), do: false

  defp reconstruct_frontier_attempts(original, frontier) do
    with {:ok, _splits} <-
           simulate_frontier_cut(
             original.count,
             frontier["accepted_positions"],
             frontier["pending_positions"]
           ),
         {:ok, accepted_paths} <-
           collect_position_paths(original, frontier["accepted_positions"]),
         {:ok, pending} <-
           collect_pending_attempts(original, frontier["pending_positions"]) do
      {:ok, accepted_paths, pending}
    end
  end

  defp collect_position_paths(original, positions) do
    positions
    |> Enum.reduce_while({:ok, []}, fn position, {:ok, acc} ->
      case position_paths(original, position) do
        {:ok, paths} -> {:cont, {:ok, acc ++ paths}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp collect_pending_attempts(original, positions) do
    positions
    |> Enum.reduce_while({:ok, []}, fn position, {:ok, acc} ->
      case position_paths(original, position) do
        {:ok, paths} -> {:cont, {:ok, acc ++ [refined_attempt(original, position, paths)]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp position_paths(original, position) do
    case position_range(original.count, position) do
      {:ok, {start, len}} -> {:ok, Enum.slice(original.paths, start, len)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_frontier_shape(frontier) do
    with :ok <- require_frontier_object(frontier),
         :ok <- reject_frontier_forbidden(frontier),
         :ok <- require_exact_frontier_keys(frontier),
         :ok <-
           match(
             frontier["schema_version"],
             @refinement_frontier_schema_version,
             :malformed_state
           ),
         :ok <- match(frontier["strategy"], "ordered_binary_split_v1", :malformed_state),
         {:ok, original_index} <- parse_positive_int(frontier["original_index"]),
         {:ok, original_count} <- parse_frontier_count(frontier["original_count"]),
         {:ok, inventory} <- parse_frontier_hex(frontier["original_inventory_sha256"]),
         {:ok, accepted_positions} <-
           parse_position_list(frontier["accepted_positions"], @max_test_batch_files - 1),
         {:ok, pending_positions} <-
           parse_pending_positions(frontier["pending_positions"]),
         :ok <-
           require_unique_positions(accepted_positions ++ pending_positions),
         {:ok, accepted_file_count} <- parse_nonneg_int(frontier["accepted_file_count"]),
         {:ok, pending_file_count} <- parse_positive_int(frontier["pending_file_count"]),
         {:ok, refined_child_count} <- parse_even_pos_int(frontier["refined_child_count"]),
         :ok <-
           bound_frontier_json(frontier),
         true <- length(accepted_positions) + length(pending_positions) <= @max_test_batch_files,
         true <- accepted_file_count + pending_file_count == original_count,
         true <- refined_child_count <= 2 * (original_count - 1) do
      {:ok,
       %{
         "schema_version" => @refinement_frontier_schema_version,
         "strategy" => "ordered_binary_split_v1",
         "original_index" => original_index,
         "original_count" => original_count,
         "original_inventory_sha256" => inventory,
         "accepted_positions" => accepted_positions,
         "pending_positions" => pending_positions,
         "accepted_file_count" => accepted_file_count,
         "pending_file_count" => pending_file_count,
         "refined_child_count" => refined_child_count
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed_state}
    end
  end

  defp match_frontier_original(parsed, compact) do
    with :ok <- match(parsed["original_index"], compact["index"], :plan_drift),
         :ok <- match(parsed["original_count"], compact["count"], :plan_drift),
         :ok <-
           match(parsed["original_inventory_sha256"], compact["inventory_sha256"], :plan_drift) do
      :ok
    end
  end

  defp match_frontier_geometry(parsed, splits) do
    with {:ok, accepted_files} <-
           sum_position_files(parsed["original_count"], parsed["accepted_positions"]),
         {:ok, pending_files} <-
           sum_position_files(parsed["original_count"], parsed["pending_positions"]),
         :ok <- match(parsed["accepted_file_count"], accepted_files, :invalid_refinement_state),
         :ok <- match(parsed["pending_file_count"], pending_files, :invalid_refinement_state),
         :ok <- match(parsed["refined_child_count"], 2 * splits, :invalid_refinement_state) do
      :ok
    end
  end

  defp simulate_frontier_cut(count, accepted, pending)
       when is_integer(count) and count >= 2 and is_list(accepted) and is_list(pending) do
    simulate_frontier_cut([{"root", 0, count}], accepted, pending, 0)
  end

  defp simulate_frontier_cut(_count, _accepted, _pending),
    do: {:error, :invalid_refinement_state}

  defp simulate_frontier_cut(queue, accepted, pending, splits) do
    queue_positions = Enum.map(queue, fn {pos, _start, _len} -> pos end)

    cond do
      accepted == [] and queue_positions == pending ->
        {:ok, splits}

      queue == [] ->
        {:error, :invalid_refinement_state}

      true ->
        [{pos, start, len} | rest] = queue
        next_accepted = List.first(accepted)

        cond do
          next_accepted == pos ->
            if position_prefix_of_any?(pos, Enum.drop(accepted, 1) ++ pending) do
              {:error, :invalid_refinement_state}
            else
              simulate_frontier_cut(rest, Enum.drop(accepted, 1), pending, splits)
            end

          position_prefix_of_any?(pos, accepted ++ pending) and len >= 2 ->
            split_at = div(len + 1, 2)
            right_len = len - split_at

            if split_at >= 1 and right_len >= 1 do
              left = {pos <> "L", start, split_at}
              right = {pos <> "R", start + split_at, right_len}
              simulate_frontier_cut([left, right | rest], accepted, pending, splits + 1)
            else
              {:error, :invalid_refinement_state}
            end

          true ->
            {:error, :invalid_refinement_state}
        end
    end
  end

  defp position_prefix_of_any?(pos, positions) when is_binary(pos) and is_list(positions) do
    Enum.any?(positions, fn other ->
      is_binary(other) and other != pos and String.starts_with?(other, pos)
    end)
  end

  defp position_range(count, "root") when is_integer(count) and count > 0, do: {:ok, {0, count}}

  defp position_range(count, position) when is_binary(position) do
    parent = String.slice(position, 0, byte_size(position) - 1)
    side = String.last(position)

    with {:ok, {start, len}} <- position_range(count, parent),
         true <- len >= 2,
         split_at = div(len + 1, 2),
         right_len = len - split_at,
         true <- split_at >= 1 and right_len >= 1 do
      case side do
        "L" -> {:ok, {start, split_at}}
        "R" -> {:ok, {start + split_at, right_len}}
        _ -> {:error, :invalid_refinement_state}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_refinement_state}
    end
  end

  defp position_range(_count, _position), do: {:error, :invalid_refinement_state}

  defp sum_position_files(count, positions) do
    positions
    |> Enum.reduce_while({:ok, 0}, fn position, {:ok, acc} ->
      case position_range(count, position) do
        {:ok, {_start, len}} -> {:cont, {:ok, acc + len}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_position_list(list, max_len) when is_list(list) and is_integer(max_len) do
    if length(list) <= max_len and Enum.all?(list, &valid_frontier_position?/1) do
      {:ok, list}
    else
      {:error, :invalid_refinement_state}
    end
  end

  defp parse_position_list(_list, _max_len), do: {:error, :malformed_state}

  defp parse_pending_positions(list) when is_list(list) and list != [] do
    parse_position_list(list, @max_test_batch_files)
  end

  defp parse_pending_positions(_list), do: {:error, :invalid_refinement_state}

  defp valid_frontier_position?(position) when is_binary(position) do
    byte_size(position) <= @max_refinement_position_bytes and
      Regex.match?(@refinement_position_regex, position)
  end

  defp valid_frontier_position?(_position), do: false

  defp require_unique_positions(positions) do
    if length(Enum.uniq(positions)) == length(positions) do
      :ok
    else
      {:error, :invalid_refinement_state}
    end
  end

  defp parse_frontier_count(value)
       when is_integer(value) and not is_boolean(value) and value >= 2 and
              value <= @max_test_batch_files,
       do: {:ok, value}

  defp parse_frontier_count(_value), do: {:error, :malformed_state}

  defp parse_positive_int(value)
       when is_integer(value) and not is_boolean(value) and value > 0,
       do: {:ok, value}

  defp parse_positive_int(_value), do: {:error, :malformed_state}

  defp parse_nonneg_int(value)
       when is_integer(value) and not is_boolean(value) and value >= 0,
       do: {:ok, value}

  defp parse_nonneg_int(_value), do: {:error, :malformed_state}

  defp parse_even_pos_int(value)
       when is_integer(value) and not is_boolean(value) and value >= 2 and rem(value, 2) == 0,
       do: {:ok, value}

  defp parse_even_pos_int(_value), do: {:error, :malformed_state}

  defp parse_frontier_hex(value) when is_binary(value) do
    if String.match?(value, ~r/\A[0-9a-f]{64}\z/),
      do: {:ok, value},
      else: {:error, :malformed_state}
  end

  defp parse_frontier_hex(_value), do: {:error, :malformed_state}

  defp normalize_compact_original(batch) when is_map(batch) and not is_struct(batch) do
    cond do
      Map.has_key?(batch, :index) ->
        {:ok, compact_batch(batch)}

      Map.has_key?(batch, "index") ->
        {:ok,
         %{
           "index" => batch["index"],
           "total" => batch["total"],
           "count" => batch["count"],
           "label" => batch["label"],
           "inventory_sha256" => batch["inventory_sha256"]
         }}

      true ->
        {:error, :malformed_state}
    end
  end

  defp normalize_compact_original(_batch), do: {:error, :malformed_state}

  defp build_frontier(parsed) do
    %{
      "schema_version" => parsed["schema_version"],
      "strategy" => parsed["strategy"],
      "original_index" => parsed["original_index"],
      "original_count" => parsed["original_count"],
      "original_inventory_sha256" => parsed["original_inventory_sha256"],
      "accepted_positions" => parsed["accepted_positions"],
      "pending_positions" => parsed["pending_positions"],
      "accepted_file_count" => parsed["accepted_file_count"],
      "pending_file_count" => parsed["pending_file_count"],
      "refined_child_count" => parsed["refined_child_count"]
    }
  end

  defp require_frontier_object(value) when is_map(value) and not is_struct(value) do
    if frontier_json_value?(value), do: :ok, else: {:error, :malformed_state}
  end

  defp require_frontier_object(_value), do: {:error, :malformed_state}

  defp require_exact_frontier_keys(map) do
    if Enum.sort(Map.keys(map)) == @refinement_frontier_keys,
      do: :ok,
      else: {:error, :malformed_state}
  end

  defp reject_frontier_forbidden(value) do
    if contains_frontier_forbidden?(value),
      do: {:error, :malformed_state},
      else: :ok
  end

  defp contains_frontier_forbidden?(value) when is_map(value) and not is_struct(value) do
    Enum.any?(value, fn {key, nested} ->
      (is_binary(key) and MapSet.member?(@refinement_forbidden_keys, key)) or
        not is_binary(key) or contains_frontier_forbidden?(nested)
    end)
  end

  defp contains_frontier_forbidden?(value) when is_list(value),
    do: Enum.any?(value, &contains_frontier_forbidden?/1)

  defp contains_frontier_forbidden?(_value), do: false

  defp frontier_json_value?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> String.valid?(key) and frontier_json_value?(nested)
      _ -> false
    end)
  end

  defp frontier_json_value?(value) when is_list(value) do
    proper_frontier_list?(value) and Enum.all?(value, &frontier_json_value?/1)
  end

  defp frontier_json_value?(value) when is_binary(value), do: String.valid?(value)

  defp frontier_json_value?(value)
       when is_integer(value) or is_boolean(value) or is_nil(value),
       do: true

  defp frontier_json_value?(_value), do: false

  defp proper_frontier_list?([]), do: true
  defp proper_frontier_list?([_head | tail]), do: proper_frontier_list?(tail)
  defp proper_frontier_list?(_tail), do: false

  defp bound_frontier_json(value) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= @max_refinement_json_bytes -> :ok
      {:ok, _encoded} -> {:error, :oversized_state}
      {:error, _reason} -> {:error, :malformed_state}
    end
  end

  defp match(left, right, _error) when left === right, do: :ok
  defp match(_left, _right, error), do: {:error, error}

  defp sha256(output) when is_binary(output) do
    :crypto.hash(:sha256, output) |> Base.encode16(case: :lower)
  end
end
