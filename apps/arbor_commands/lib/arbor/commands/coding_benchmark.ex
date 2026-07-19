defmodule Arbor.Commands.CodingBenchmark do
  @moduledoc """
  Deterministic conformance harness for paired coding executors.

  Manifests are data-only. Adapter and verifier implementations are supplied
  through trusted runtime options as named modules or unary functions; manifest
  data can never select a module, function name, or MFA.

  Each executor receives an independent clone of the same declared Git tree.
  Public `Arbor.Commands.CodingParity` projections provide all comparable
  coding-result semantics. The harness adds objective verification, counters,
  timing, and independently observed Git and artifact evidence.
  """

  alias Arbor.Commands.CodingBenchmark.{
    Adapter,
    ExactTargetTreeVerifier,
    Git,
    LegacyAdapter,
    PipelineAdapter,
    Runtime
  }

  alias Arbor.Commands.CodingParity
  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Coding.{TranscriptDescriptor, WorkspaceReleaseDescriptor}
  alias Arbor.Orchestrator

  @manifest_schema "arbor.coding_benchmark.manifest.v1"
  @report_schema "arbor.coding_benchmark.report.v1"
  @request_schema "arbor.coding_benchmark.adapter_request.v1"
  @executor_paths ["legacy", "pipeline"]
  @production_adapters [LegacyAdapter, PipelineAdapter]
  @exact_target_tree_selector "exact_target_tree"
  @pipeline_artifact_path_keys [
    {"coding_plan_path", :coding_plan_path},
    {"coding_pipeline_path", :coding_pipeline_path},
    {"compile_manifest_path", :compile_manifest_path}
  ]
  @pipeline_provenance_keys ~w(
    coding_plan_path coding_pipeline_path compile_manifest_path compiler_version graph_hash
  )
  @required_pipeline_artifact_keys MapSet.new(@pipeline_provenance_keys)
  @optional_pipeline_artifact_keys MapSet.new(~w(workspace_release acp_transcript))
  @allowed_pipeline_artifact_keys MapSet.union(
                                    @required_pipeline_artifact_keys,
                                    @optional_pipeline_artifact_keys
                                  )
  @artifact_filenames %{
    "coding_pipeline_path" => "coding-pipeline.dot",
    "coding_plan_path" => "coding-plan.json",
    "compile_manifest_path" => "coding-compile-manifest.json"
  }
  @max_dot_bytes 16_777_216
  @max_json_artifact_bytes 8_388_608
  @max_fixture_entries 10_000
  @max_fixture_object_bytes 16_777_216
  @max_fixture_total_bytes 268_435_456
  @max_fixture_listing_bytes 8_388_608
  @max_fixture_symlink_bytes 4_096
  @max_fixtures 100
  @max_repetitions 100
  @max_seed 2_147_483_647
  @max_counter 10_000
  @oid_pattern ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @hash_pattern ~r/\A[0-9a-f]{64}\z/
  @id_pattern ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/
  @acp_agent_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}\z/

  @type json_map :: %{optional(String.t()) => term()}
  @type callback_ref :: module() | (map() -> term())

  @doc "Return the accepted manifest schema identifier."
  @spec manifest_schema() :: String.t()
  def manifest_schema, do: @manifest_schema

  @doc "Return the emitted report schema identifier."
  @spec report_schema() :: String.t()
  def report_schema, do: @report_schema

  @doc "Validate and normalize a closed benchmark manifest."
  @spec validate_manifest(term()) :: {:ok, json_map()} | {:error, json_map()}
  def validate_manifest(manifest) when is_map(manifest) and not is_struct(manifest) do
    with :ok <-
           closed_map(manifest, ~w(schema seed fixtures), ~w(schema seed fixtures), "manifest"),
         :ok <- exact_value(manifest["schema"], @manifest_schema, "manifest.schema"),
         {:ok, seed} <- bounded_integer(manifest["seed"], 0, @max_seed, "manifest.seed"),
         {:ok, fixtures} <- fixtures(manifest["fixtures"]),
         :ok <- unique_fixture_ids(fixtures) do
      {:ok, %{"fixtures" => fixtures, "schema" => @manifest_schema, "seed" => seed}}
    end
  end

  def validate_manifest(_manifest), do: invalid_manifest("manifest", "expected_object")

  @doc """
  Reconstruct a standalone fixture Git repository from OID-verified source objects.

  This is the shared owner primitive used by the benchmark harness and catalog
  materializer. It never uses linked worktrees, object alternates, network
  access, hooks, replace refs, or copied source `.git` configuration.
  """
  @spec reconstruct_fixture_repository(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: :ok | {:error, String.t()}
  def reconstruct_fixture_repository(source, destination, commit_oid, expected_tree, opts \\ [])

  def reconstruct_fixture_repository(source, destination, commit_oid, expected_tree, opts)
      when is_binary(source) and is_binary(destination) and is_binary(commit_oid) and
             is_binary(expected_tree) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 300_000)

    with true <- is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= 3_600_000,
         {:ok, commit_oid} <- oid(commit_oid, "commit_oid"),
         {:ok, expected_tree} <- oid(expected_tree, "base_tree_oid"),
         {:ok, source} <- directory(source, "source"),
         {:ok, destination} <- reconstruct_destination(destination, source) do
      case clone_fixture(source, destination, commit_oid, expected_tree, timeout_ms) do
        :ok -> :ok
        {:error, reason} when is_binary(reason) -> {:error, reason}
        {:error, reason} -> {:error, reason_string(reason)}
      end
    else
      false ->
        {:error, "invalid_reconstruct_request"}

      {:error, %{"reason" => reason}} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason_string(reason)}
    end
  end

  def reconstruct_fixture_repository(_source, _destination, _commit_oid, _expected_tree, _opts),
    do: {:error, "invalid_reconstruct_request"}

  defp reconstruct_destination(destination, source) do
    cond do
      byte_size(destination) > 4_096 or not String.valid?(destination) or
        String.contains?(destination, <<0>>) or Path.type(destination) != :absolute ->
        {:error, "invalid_reconstruct_request"}

      true ->
        parent = Path.dirname(destination)

        with {:ok, real_parent} <- SafePath.resolve_real(parent),
             canonical = Path.join(real_parent, Path.basename(destination)),
             false <- path_within_git_metadata?(canonical, source),
             {:error, :enoent} <- File.lstat(canonical) do
          {:ok, canonical}
        else
          _other -> {:error, "invalid_reconstruct_request"}
        end
    end
  end

  defp path_within_git_metadata?(path, source) do
    case path |> Path.relative_to(source) |> Path.split() do
      [first | _rest] -> String.downcase(first) == ".git"
      [] -> false
    end
  end

  @doc """
  Execute all manifest fixtures against the named legacy and pipeline adapters.

  Required non-dry options:

    * `:adapters` - map or keyword list with `legacy` and `pipeline` callbacks
    * `:verifiers` - map or keyword list keyed by manifest `verifier_id`
      (except the reserved built-in `exact_target_tree` selector)

  Prepared publications that select `exact_target_tree` must supply validated
  `:exact_target_trees` (`fixture_id => target_tree_oid`) from publication
  evidence. That reserved selector always installs the trusted built-in
  verifier; Application config and ordinary runtime verifier registries cannot
  override or spoof it. Target tree OIDs never enter adapter requests or public
  report rows.

  Adapter modules implement `run/1`; unary functions are also accepted. A
  callback receives a trusted request containing the isolated `workdir` and the
  normalized task input. It returns `{:ok, envelope}` or `{:error, reason}`.
  Envelopes have the closed keys `result`, `observations`, `counters`, and
  `worker_ownership`.

  Every run requires trusted `:arbor_commands` Application configuration for
  `:coding_benchmark_workspace_root`, `:coding_benchmark_artifact_root`,
  `:coding_benchmark_execution_timeout_ms`, and
  `:coding_benchmark_cancellation_timeout_ms`. The artifact root must be a
  distinct existing child of the workspace root. Production adapters also
  require the orchestrator repo/worktree roots to admit that workspace and its
  pipeline logs root to equal the configured benchmark artifact root. Optional
  `:coding_benchmark_fixture_setup_timeout_ms` bounds each reconstruction with
  one absolute deadline (default: 300 seconds), independently of worker timeouts.
  """
  @spec run(term(), keyword()) :: {:ok, json_map()} | {:error, json_map()}
  def run(manifest, opts \\ [])

  def run(manifest, opts) when is_list(opts) do
    with {:ok, manifest} <- validate_manifest(manifest),
         {:ok, runtime} <- runtime_options(manifest, opts) do
      if runtime.dry_run? do
        {:ok, dry_report(manifest, runtime)}
      else
        execute_report(manifest, runtime)
      end
    end
  end

  def run(_manifest, _opts), do: runtime_error("options", "expected_keyword_list")

  @doc """
  Validate the closed pipeline artifact descriptor envelope used by strict
  production provenance verification.

  This is the same gate that runs before trusted artifact reads: required
  provenance keys must be present, only the reviewed key set is admitted, and
  any optional `workspace_release` / `acp_transcript` descriptors must satisfy
  their public contracts. Successful validation returns the required provenance
  subset only; optional evidence is never elevated into authority fields.
  """
  @spec validate_pipeline_artifact_descriptors(term()) ::
          {:ok, json_map()} | {:error, :invalid_artifact_descriptors}
  def validate_pipeline_artifact_descriptors(artifacts)
      when is_map(artifacts) and not is_struct(artifacts) do
    validated_provenance_artifacts(artifacts)
  end

  def validate_pipeline_artifact_descriptors(_artifacts),
    do: {:error, :invalid_artifact_descriptors}

  defp fixtures(fixtures) when is_list(fixtures) and fixtures != [] do
    if length(fixtures) <= @max_fixtures do
      fixtures
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {fixture, index}, {:ok, acc} ->
        case fixture(fixture, index) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, normalized} ->
          {:ok, normalized |> Enum.reverse() |> Enum.sort_by(& &1["fixture_id"])}

        error ->
          error
      end
    else
      invalid_manifest("manifest.fixtures", "too_many_items")
    end
  end

  defp fixtures([]), do: invalid_manifest("manifest.fixtures", "empty_list")
  defp fixtures(_fixtures), do: invalid_manifest("manifest.fixtures", "expected_list")

  defp fixture(fixture, index) when is_map(fixture) and not is_struct(fixture) do
    field = "manifest.fixtures[#{index}]"

    with :ok <-
           closed_map(
             fixture,
             ~w(fixture_id fixture_path base_tree_oid input verifier_id),
             ~w(fixture_id fixture_path base_tree_oid input verifier_id),
             field
           ),
         {:ok, fixture_id} <- identifier(fixture["fixture_id"], "#{field}.fixture_id"),
         {:ok, fixture_path} <- relative_path(fixture["fixture_path"], "#{field}.fixture_path"),
         {:ok, base_tree_oid} <- oid(fixture["base_tree_oid"], "#{field}.base_tree_oid"),
         {:ok, input} <- input(fixture["input"], "#{field}.input"),
         {:ok, verifier_id} <- identifier(fixture["verifier_id"], "#{field}.verifier_id") do
      {:ok,
       %{
         "base_tree_oid" => base_tree_oid,
         "fixture_id" => fixture_id,
         "fixture_path" => fixture_path,
         "input" => input,
         "normalized_input_hash" => hash_json(input),
         "verifier_id" => verifier_id
       }}
    end
  end

  defp fixture(_fixture, index),
    do: invalid_manifest("manifest.fixtures[#{index}]", "expected_object")

  defp input(input, field) when is_map(input) and not is_struct(input) do
    with :ok <-
           closed_map(
             input,
             ~w(objective acceptance_criteria),
             ~w(objective acceptance_criteria),
             field
           ),
         {:ok, objective} <- normalized_text(input["objective"], 1, 32_000, "#{field}.objective"),
         {:ok, criteria} <- criteria(input["acceptance_criteria"], "#{field}.acceptance_criteria") do
      {:ok, %{"acceptance_criteria" => criteria, "objective" => objective}}
    end
  end

  defp input(_input, field), do: invalid_manifest(field, "expected_object")

  defp criteria(criteria, field) when is_list(criteria) and length(criteria) <= 100 do
    criteria
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {criterion, index}, {:ok, acc} ->
      case normalized_text(criterion, 1, 4_000, "#{field}[#{index}]") do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp criteria(_criteria, field), do: invalid_manifest(field, "invalid_list")

  defp normalized_text(value, min, max, field) when is_binary(value) do
    normalized = value |> String.replace("\r\n", "\n") |> String.trim()

    if String.valid?(normalized) and byte_size(normalized) in min..max and
         not String.contains?(normalized, <<0>>) do
      {:ok, normalized}
    else
      invalid_manifest(field, "invalid_text")
    end
  end

  defp normalized_text(_value, _min, _max, field),
    do: invalid_manifest(field, "expected_string")

  defp identifier(value, field) when is_binary(value) do
    if Regex.match?(@id_pattern, value),
      do: {:ok, value},
      else: invalid_manifest(field, "invalid_id")
  end

  defp identifier(_value, field), do: invalid_manifest(field, "expected_string")

  defp relative_path(path, field) when is_binary(path) do
    components = Path.split(path)

    cond do
      not String.valid?(path) or String.contains?(path, <<0>>) ->
        invalid_manifest(field, "invalid_path")

      Path.type(path) != :relative ->
        invalid_manifest(field, "absolute_path")

      components == [] or Enum.any?(components, &(&1 in [".", "..", ""])) ->
        invalid_manifest(field, "unsafe_path")

      true ->
        case SafePath.validate(path) do
          :ok -> {:ok, Path.join(components)}
          {:error, _reason} -> invalid_manifest(field, "unsafe_path")
        end
    end
  end

  defp relative_path(_path, field), do: invalid_manifest(field, "expected_string")

  defp oid(value, field) when is_binary(value) do
    normalized = String.downcase(String.trim(value))

    if Regex.match?(@oid_pattern, normalized),
      do: {:ok, normalized},
      else: invalid_manifest(field, "invalid_oid")
  end

  defp oid(_value, field), do: invalid_manifest(field, "expected_oid")

  defp unique_fixture_ids(fixtures) do
    ids = Enum.map(fixtures, & &1["fixture_id"])

    if length(ids) == length(Enum.uniq(ids)),
      do: :ok,
      else: invalid_manifest("manifest.fixtures", "duplicate_fixture_id")
  end

  defp runtime_options(manifest, opts) do
    with {:ok, benchmark} <- benchmark_runtime(),
         {:ok, repetitions} <-
           bounded_runtime_integer(
             Keyword.get(opts, :repetitions, 1),
             1,
             @max_repetitions,
             "repetitions"
           ),
         {:ok, seed} <-
           bounded_runtime_integer(
             Keyword.get(opts, :seed, manifest["seed"]),
             0,
             @max_seed,
             "seed"
           ),
         {:ok, acp_agent} <- acp_agent(Keyword.get(opts, :acp_agent)),
         {:ok, dry_run?} <- boolean_option(Keyword.get(opts, :dry_run, false), "dry_run"),
         {:ok, measure} <- measure_callback(Keyword.get(opts, :measure, &measure/1)),
         :ok <- reject_process_global_selector(Keyword.get(opts, :executor_selector, false)),
         {:ok, workspace_root} <-
           benchmark_workspace_root(
             Keyword.get(opts, :workspace_root, benchmark.workspace_root),
             benchmark
           ),
         {:ok, fixture_root} <-
           directory(Keyword.get(opts, :fixture_root, File.cwd!()), "fixture_root"),
         :ok <-
           fixture_artifact_disjoint(
             benchmark.artifact_root,
             fixture_root,
             manifest["fixtures"]
           ),
         {:ok, adapters} <- adapters(Keyword.get(opts, :adapters), dry_run?),
         :ok <- preflight_adapters(adapters, benchmark, dry_run?),
         {:ok, exact_target_trees} <-
           exact_target_trees(Keyword.get(opts, :exact_target_trees), manifest, dry_run?),
         {:ok, verifiers} <-
           verifiers(
             Keyword.get(opts, :verifiers),
             manifest,
             dry_run?,
             exact_target_trees,
             benchmark.execution_timeout_ms
           ) do
      {:ok,
       %{
         acp_agent: acp_agent,
         adapters: adapters,
         benchmark: benchmark,
         dry_run?: dry_run?,
         exact_target_trees: exact_target_trees,
         fixture_root: fixture_root,
         measure: measure,
         repetitions: repetitions,
         seed: seed,
         verifiers: verifiers,
         workspace_root: workspace_root
       }}
    end
  end

  defp benchmark_runtime do
    case Runtime.load() do
      {:ok, config} ->
        {:ok, config}

      {:error, {:benchmark_setup_error, reason}} ->
        runtime_error("benchmark_setup", reason_string(reason))
    end
  end

  defp benchmark_workspace_root(path, benchmark) do
    case Runtime.ensure_workspace_directory(path, benchmark) do
      {:ok, root} ->
        {:ok, root}

      {:error, {:benchmark_setup_error, reason}} ->
        runtime_error("workspace_root", reason_string(reason))
    end
  end

  defp preflight_adapters(_adapters, _benchmark, true), do: :ok

  defp preflight_adapters(adapters, benchmark, false) do
    if Enum.any?(Map.values(adapters), &(&1 in @production_adapters)) do
      case Runtime.preflight_production(benchmark) do
        :ok ->
          :ok

        {:error, {:benchmark_setup_error, reason}} ->
          runtime_error("production_setup", reason_string(reason))
      end
    else
      :ok
    end
  end

  defp bounded_runtime_integer(value, min, max, _field)
       when is_integer(value) and value >= min and value <= max,
       do: {:ok, value}

  defp bounded_runtime_integer(_value, _min, _max, field),
    do: runtime_error(field, "out_of_bounds")

  defp bounded_integer(value, min, max, _field)
       when is_integer(value) and value >= min and value <= max,
       do: {:ok, value}

  defp bounded_integer(_value, _min, _max, field),
    do: invalid_manifest(field, "out_of_bounds")

  defp acp_agent(nil), do: {:ok, nil}

  defp acp_agent(value) when is_binary(value) do
    if Regex.match?(@acp_agent_pattern, value),
      do: {:ok, value},
      else: runtime_error("acp_agent", "invalid_name")
  end

  defp acp_agent(_value), do: runtime_error("acp_agent", "expected_string")

  defp boolean_option(value, _field) when is_boolean(value), do: {:ok, value}
  defp boolean_option(_value, field), do: runtime_error(field, "expected_boolean")

  defp measure_callback(fun) when is_function(fun, 1), do: {:ok, fun}
  defp measure_callback(_fun), do: runtime_error("measure", "expected_unary_function")

  defp directory(path, field) when is_binary(path) do
    expanded = Path.expand(path)

    with {:ok, real} <- SafePath.resolve_real(expanded),
         true <- File.dir?(real) do
      {:ok, real}
    else
      _other -> runtime_error(field, "directory_not_found")
    end
  end

  defp directory(_path, field), do: runtime_error(field, "expected_path")

  defp adapters(_registry, true), do: {:ok, %{}}

  defp adapters(registry, false) do
    with {:ok, registry} <- callback_registry(registry, "adapters", @executor_paths),
         :ok <- exact_registry_keys(registry, @executor_paths, "adapters") do
      {:ok, registry}
    end
  end

  defp verifiers(_registry, _manifest, true, _exact_target_trees, _timeout_ms), do: {:ok, %{}}

  defp verifiers(registry, manifest, false, exact_target_trees, timeout_ms) do
    required = manifest["fixtures"] |> Enum.map(& &1["verifier_id"]) |> Enum.uniq() |> Enum.sort()
    needs_exact_target_tree? = @exact_target_tree_selector in required
    other_required = Enum.reject(required, &(&1 == @exact_target_tree_selector))

    with :ok <- exact_target_tree_ownership(needs_exact_target_tree?, exact_target_trees),
         {:ok, registry} <- callback_registry(registry, "verifiers", other_required),
         :ok <- reject_reserved_verifier_override(registry),
         registry <-
           install_exact_target_tree_verifier(
             registry,
             needs_exact_target_tree?,
             exact_target_trees,
             timeout_ms
           ),
         :ok <- required_registry_keys(registry, required, "verifiers") do
      {:ok, registry}
    end
  end

  defp exact_target_trees(_value, _manifest, true), do: {:ok, %{}}

  defp exact_target_trees(nil, manifest, false) do
    if exact_target_tree_fixture_ids(manifest) == [] do
      {:ok, %{}}
    else
      runtime_error("exact_target_trees", "missing_for_exact_target_tree")
    end
  end

  defp exact_target_trees(targets, manifest, false) when is_map(targets) do
    required_ids = exact_target_tree_fixture_ids(manifest)

    with :ok <- closed_exact_target_tree_keys(targets, required_ids),
         {:ok, normalized} <- normalize_exact_target_trees(targets, required_ids) do
      {:ok, normalized}
    end
  end

  defp exact_target_trees(_targets, _manifest, false),
    do: runtime_error("exact_target_trees", "expected_object")

  defp exact_target_tree_fixture_ids(manifest) do
    manifest["fixtures"]
    |> Enum.filter(&(&1["verifier_id"] == @exact_target_tree_selector))
    |> Enum.map(& &1["fixture_id"])
    |> Enum.sort()
  end

  defp closed_exact_target_tree_keys(targets, required_ids) do
    keys = Map.keys(targets)

    cond do
      Enum.any?(keys, &(not is_binary(&1))) ->
        runtime_error("exact_target_trees", "invalid_fixture_id")

      Enum.sort(keys) != Enum.sort(required_ids) ->
        runtime_error("exact_target_trees", "fixture_set_mismatch")

      true ->
        :ok
    end
  end

  defp normalize_exact_target_trees(targets, required_ids) do
    Enum.reduce_while(required_ids, {:ok, %{}}, fn fixture_id, {:ok, acc} ->
      case oid(Map.fetch!(targets, fixture_id), "exact_target_trees.#{fixture_id}") do
        {:ok, target_tree_oid} ->
          {:cont, {:ok, Map.put(acc, fixture_id, target_tree_oid)}}

        {:error, %{"reason" => reason}} ->
          {:halt, runtime_error("exact_target_trees.#{fixture_id}", reason)}

        {:error, _reason} ->
          {:halt, runtime_error("exact_target_trees.#{fixture_id}", "invalid_oid")}
      end
    end)
  end

  defp exact_target_tree_ownership(false, targets) when targets == %{}, do: :ok

  defp exact_target_tree_ownership(false, _targets),
    do: runtime_error("exact_target_trees", "unexpected_without_selector")

  defp exact_target_tree_ownership(true, targets) when map_size(targets) > 0, do: :ok

  defp exact_target_tree_ownership(true, _targets),
    do: runtime_error("exact_target_trees", "missing_for_exact_target_tree")

  defp reject_reserved_verifier_override(registry) do
    if Map.has_key?(registry, @exact_target_tree_selector) do
      runtime_error(
        "verifiers.#{@exact_target_tree_selector}",
        "builtin_selector_reserved"
      )
    else
      :ok
    end
  end

  defp install_exact_target_tree_verifier(registry, false, _targets, _timeout_ms), do: registry

  defp install_exact_target_tree_verifier(registry, true, targets, timeout_ms) do
    Map.put(
      registry,
      @exact_target_tree_selector,
      ExactTargetTreeVerifier.build(targets, timeout_ms)
    )
  end

  defp callback_registry(nil, field, required_other) do
    if required_other == [] do
      {:ok, %{}}
    else
      runtime_error(field, "missing_registry")
    end
  end

  defp callback_registry(registry, field, _required_other)
       when is_map(registry) or is_list(registry) do
    entries = if is_map(registry), do: Map.to_list(registry), else: registry

    Enum.reduce_while(entries, {:ok, %{}}, fn
      {key, callback}, {:ok, acc} when is_binary(key) or is_atom(key) ->
        name = if is_atom(key), do: Atom.to_string(key), else: key

        cond do
          Map.has_key?(acc, name) ->
            {:halt, runtime_error(field, "duplicate_name")}

          callback?(callback) ->
            {:cont, {:ok, Map.put(acc, name, callback)}}

          true ->
            {:halt, runtime_error("#{field}.#{name}", "invalid_callback")}
        end

      _entry, _acc ->
        {:halt, runtime_error(field, "invalid_registry")}
    end)
  end

  defp callback_registry(_registry, field, _required_other),
    do: runtime_error(field, "missing_registry")

  defp callback?(callback) when is_function(callback, 1), do: true

  defp callback?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :run, 1)
  end

  defp callback?(_callback), do: false

  defp exact_registry_keys(registry, expected, field) do
    if registry |> Map.keys() |> Enum.sort() == Enum.sort(expected),
      do: :ok,
      else: runtime_error(field, "invalid_names")
  end

  defp required_registry_keys(registry, expected, field) do
    missing = Enum.reject(expected, &Map.has_key?(registry, &1))

    if missing == [],
      do: :ok,
      else: runtime_error(field, "missing_named_verifier:#{Enum.join(missing, ",")}")
  end

  defp reject_process_global_selector(false), do: :ok
  defp reject_process_global_selector(nil), do: :ok

  defp reject_process_global_selector(_selector),
    do: runtime_error("executor_selector", "process_global_mutation_unsupported")

  defp fixture_artifact_disjoint(artifact_root, fixture_root, fixtures) do
    fixture_paths = Enum.map(fixtures, & &1["fixture_path"])

    case Runtime.ensure_artifact_root_disjoint(artifact_root, fixture_root, fixture_paths) do
      :ok ->
        :ok

      {:error, {:benchmark_setup_error, reason}} ->
        runtime_error("artifact_root", reason_string(reason))
    end
  end

  defp execute_report(manifest, runtime) do
    case create_run_root(runtime.workspace_root) do
      {:ok, run_root} ->
        try do
          pairs = pair_specs(manifest, runtime)

          {rows, pair_reports} =
            Enum.reduce(pairs, {[], []}, fn pair, {rows, pair_reports} ->
              {pair_rows, pair_report} = execute_pair(pair, run_root, runtime)
              {rows ++ pair_rows, pair_reports ++ [pair_report]}
            end)

          {:ok, report(manifest, runtime, rows, pair_reports)}
        after
          File.rm_rf(run_root)
        end

      {:error, reason} ->
        runtime_error("workspace_root", reason)
    end
  end

  defp create_run_root(workspace_root) do
    suffix = System.unique_integer([:positive, :monotonic])
    path = Path.join(workspace_root, "arbor-coding-benchmark-#{suffix}")

    case File.mkdir(path) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "create_failed:#{reason}"}
    end
  end

  defp pair_specs(manifest, runtime) do
    for fixture <- manifest["fixtures"], repetition <- 1..runtime.repetitions do
      order = execution_order(runtime.seed, fixture["fixture_id"], repetition)
      %{fixture: fixture, order: order, repetition: repetition}
    end
  end

  defp execution_order(seed, fixture_id, repetition) do
    <<first, _rest::binary>> = :crypto.hash(:sha256, "#{seed}:#{fixture_id}:#{repetition}")
    if rem(first, 2) == 0, do: @executor_paths, else: Enum.reverse(@executor_paths)
  end

  defp execute_pair(pair, run_root, runtime) do
    pair_root =
      Path.join(run_root, "#{pair.fixture["fixture_id"]}-#{pair.repetition}")

    try do
      case prepare_pair(pair.fixture, pair_root, runtime.fixture_root, runtime.benchmark) do
        {:ok, prepared} ->
          executed =
            Enum.map(pair.order, fn executor ->
              execute_adapter(executor, pair, prepared, runtime)
            end)

          rows = Enum.map(executed, & &1.row)
          projections = Map.new(executed, &{&1.executor, &1.projection})
          {rows, pair_report(pair, projections)}

        {:error, reason} ->
          rows = Enum.map(pair.order, &failure_row(&1, pair, "fixture_setup_failed", reason))
          {rows, pair_report(pair, %{})}
      end
    after
      File.rm_rf(pair_root)
    end
  end

  defp prepare_pair(fixture, pair_root, fixture_root, benchmark) do
    timeout_ms = benchmark.fixture_setup_timeout_ms

    with {:ok, source} <- fixture_source(fixture_root, fixture["fixture_path"]),
         {:ok, commit_oid} <-
           git_output(source, ["rev-parse", "--verify", "HEAD^{commit}"], timeout_ms),
         {:ok, source_tree_oid} <-
           git_output(source, ["rev-parse", "--verify", "HEAD^{tree}"], timeout_ms),
         :ok <- matching_tree(source_tree_oid, fixture["base_tree_oid"]),
         :ok <- mkdir(pair_root),
         {:ok, pair_root} <- Runtime.canonical_pair_root(pair_root, benchmark),
         {:ok, workdirs} <-
           clone_pair(source, commit_oid, fixture["base_tree_oid"], pair_root, timeout_ms) do
      {:ok, %{commit_oid: commit_oid, pair_root: pair_root, workdirs: workdirs}}
    end
  end

  defp fixture_source(fixture_root, fixture_path) do
    with {:ok, lexical} <- SafePath.safe_join(fixture_root, fixture_path),
         {:ok, real} <- SafePath.resolve_real(lexical),
         {:ok, ^real} <- SafePath.resolve_within(real, fixture_root),
         true <- File.dir?(real) do
      {:ok, real}
    else
      _other -> {:error, "unsafe_or_missing_fixture"}
    end
  end

  defp matching_tree(actual, expected) do
    if String.downcase(actual) == expected, do: :ok, else: {:error, "base_tree_oid_mismatch"}
  end

  defp mkdir(path) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, reason} -> {:error, "mkdir_failed:#{reason}"}
    end
  end

  defp clone_pair(source, commit_oid, expected_tree, pair_root, timeout_ms) do
    Enum.reduce_while(@executor_paths, {:ok, %{}}, fn executor, {:ok, acc} ->
      destination = Path.join(pair_root, executor)

      case clone_fixture(source, destination, commit_oid, expected_tree, timeout_ms) do
        :ok -> {:cont, {:ok, Map.put(acc, executor, destination)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp clone_fixture(source, destination, commit_oid, expected_tree, timeout_ms) do
    deadline = Git.deadline(timeout_ms)

    with {:ok, entries} <- fixture_tree_entries(source, commit_oid, expected_tree, deadline),
         :ok <- initialize_fixture_repository(destination, commit_oid, deadline),
         :ok <-
           import_fixture_objects(
             source,
             destination,
             commit_oid,
             expected_tree,
             entries,
             deadline
           ),
         :ok <- materialize_fixture_tree(source, destination, entries, deadline),
         :ok <- attach_fixture_commit(destination, commit_oid, deadline),
         {:ok, ^commit_oid} <-
           git_output(destination, ["rev-parse", "--verify", "HEAD^{commit}"], deadline),
         {:ok, actual_tree} <-
           git_output(destination, ["rev-parse", "--verify", "HEAD^{tree}"], deadline),
         :ok <- matching_tree(actual_tree, expected_tree),
         {:ok, ""} <- git_output(destination, ["status", "--porcelain=v1"], deadline) do
      :ok
    else
      {:ok, dirty} when is_binary(dirty) and dirty != "" ->
        {:error, "fixture_repository_not_clean"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      _other ->
        {:error, "fixture_reconstruction_attestation_failed"}
    end
  end

  defp fixture_tree_entries(source, commit_oid, expected_tree, timeout_ms) do
    with {:ok, listing} <-
           Git.run(
             source,
             ["ls-tree", "-r", "-t", "-z", "--full-tree", commit_oid],
             timeout_ms,
             max_output_bytes: @max_fixture_listing_bytes
           ),
         {:ok, entries} <- parse_fixture_tree(listing),
         true <- length(entries) <= @max_fixture_entries,
         true <- Enum.all?(entries, &supported_fixture_entry?/1),
         true <- Enum.all?(entries, &safe_fixture_path?(&1.path)),
         {:ok, ^expected_tree} <-
           git_output(source, ["rev-parse", "--verify", "#{commit_oid}^{tree}"], timeout_ms) do
      {:ok, entries}
    else
      false -> {:error, "unsupported_or_oversized_fixture_tree"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _other -> {:error, "invalid_fixture_tree"}
    end
  end

  defp parse_fixture_tree(listing) do
    listing
    |> :binary.split(<<0>>, [:global])
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
      case Regex.run(~r/\A([0-7]{6}) (blob|tree) ([0-9a-f]{40}|[0-9a-f]{64})\t(.+)\z/s, record) do
        [_, mode, type, oid, path] ->
          {:cont, {:ok, [%{mode: mode, oid: oid, path: path, type: type} | acc]}}

        _other ->
          {:halt, {:error, "invalid_fixture_tree_entry"}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp supported_fixture_entry?(%{type: "tree", mode: "040000"}), do: true

  defp supported_fixture_entry?(%{type: "blob", mode: mode})
       when mode in ["100644", "100755", "120000"],
       do: true

  defp supported_fixture_entry?(_entry), do: false

  defp safe_fixture_path?(path) do
    String.valid?(path) and path != "" and not String.contains?(path, <<0>>) and
      Path.type(path) != :absolute and
      Enum.all?(Path.split(path), fn segment ->
        segment not in ["", ".", ".."] and String.downcase(segment) != ".git"
      end)
  end

  defp initialize_fixture_repository(destination, commit_oid, timeout_ms) do
    template = Path.join(destination, ".empty-git-template")
    object_format = if byte_size(commit_oid) == 64, do: "sha256", else: "sha1"

    with :ok <- mkdir(destination),
         :ok <- mkdir(template),
         {:ok, _output} <-
           Git.run(
             destination,
             [
               "init",
               "--quiet",
               "--initial-branch=benchmark",
               "--object-format=#{object_format}",
               "--template=#{template}",
               "."
             ],
             timeout_ms
           ),
         :ok <- remove_empty_directory(template),
         {:ok, _output} <-
           Git.run(destination, ["config", "--local", "core.hooksPath", "/dev/null"], timeout_ms),
         {:ok, _output} <-
           Git.run(destination, ["config", "--local", "core.filemode", "true"], timeout_ms),
         {:ok, %{type: :directory}} <- File.lstat(Path.join(destination, ".git")) do
      :ok
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _other -> {:error, "fixture_repository_init_failed"}
    end
  end

  defp remove_empty_directory(path) do
    case File.rmdir(path) do
      :ok -> :ok
      {:error, reason} -> {:error, "template_cleanup_failed:#{reason}"}
    end
  end

  defp import_fixture_objects(source, destination, commit_oid, root_tree_oid, entries, timeout_ms) do
    objects =
      [%{oid: commit_oid, type: "commit"}, %{oid: root_tree_oid, type: "tree"}] ++
        Enum.map(entries, &Map.take(&1, [:oid, :type]))

    objects
    |> Enum.uniq_by(&{&1.type, &1.oid})
    |> Enum.reduce_while({:ok, 0}, fn object, {:ok, total} ->
      case import_fixture_object(source, destination, object, total, timeout_ms) do
        {:ok, next_total} -> {:cont, {:ok, next_total}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _total} -> :ok
      error -> error
    end
  end

  defp import_fixture_object(source, destination, %{oid: oid, type: type}, total, timeout_ms) do
    with {:ok, content} <-
           Git.run(source, ["cat-file", type, oid], timeout_ms,
             max_output_bytes: @max_fixture_object_bytes
           ),
         size = byte_size(content),
         true <- size <= @max_fixture_object_bytes and total + size <= @max_fixture_total_bytes,
         :ok <- write_loose_object(destination, type, content, oid) do
      {:ok, total + size}
    else
      false -> {:error, "fixture_object_attestation_failed"}
      {:error, reason} -> {:error, reason}
      _other -> {:error, "fixture_object_import_failed"}
    end
  end

  defp write_loose_object(destination, type, content, expected_oid) do
    object = [type, " ", Integer.to_string(byte_size(content)), <<0>>, content]
    object = IO.iodata_to_binary(object)
    algorithm = if byte_size(expected_oid) == 40, do: :sha, else: :sha256
    actual_oid = :crypto.hash(algorithm, object) |> Base.encode16(case: :lower)

    object_path =
      Path.join([
        destination,
        ".git",
        "objects",
        String.slice(actual_oid, 0, 2),
        String.slice(actual_oid, 2..-1//1)
      ])

    with true <- actual_oid == expected_oid,
         :ok <- File.mkdir_p(Path.dirname(object_path)),
         :ok <- write_exclusive_file(object_path, :zlib.compress(object)) do
      :ok
    else
      false -> {:error, "fixture_object_attestation_failed"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _other -> {:error, "fixture_object_write_failed"}
    end
  end

  defp materialize_fixture_tree(source, destination, entries, timeout_ms) do
    entries
    |> Enum.filter(&(&1.type == "blob"))
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      with {:ok, path} <- SafePath.safe_join(destination, entry.path),
           {:ok, ^path} <- SafePath.resolve_within(path, destination),
           :ok <- ensure_fixture_parent(Path.dirname(path), destination),
           {:ok, content} <-
             Git.run(source, ["cat-file", "blob", entry.oid], timeout_ms,
               max_output_bytes: @max_fixture_object_bytes
             ),
           :ok <- materialize_fixture_entry(path, content, entry.mode, destination) do
        {:cont, :ok}
      else
        {:error, reason} when is_binary(reason) -> {:halt, {:error, reason}}
        _other -> {:halt, {:error, "fixture_materialization_failed"}}
      end
    end)
  end

  defp materialize_fixture_entry(path, content, "120000", destination) do
    with true <- byte_size(content) in 1..@max_fixture_symlink_bytes,
         true <- String.valid?(content) and not String.contains?(content, <<0>>),
         true <- Path.type(content) == :relative,
         resolved = Path.expand(content, Path.dirname(path)),
         {:ok, ^resolved} <- SafePath.resolve_within(resolved, destination),
         false <- path_within_git_metadata?(resolved, destination),
         :ok <- File.ln_s(content, path) do
      :ok
    else
      _other -> {:error, "unsafe_fixture_symlink"}
    end
  end

  defp materialize_fixture_entry(path, content, mode, _destination)
       when mode in ["100644", "100755"] do
    with :ok <- write_exclusive_file(path, content),
         :ok <- File.chmod(path, if(mode == "100755", do: 0o755, else: 0o644)) do
      :ok
    end
  end

  defp ensure_fixture_parent(parent, destination) do
    with {:ok, ^parent} <- SafePath.resolve_within(parent, destination),
         :ok <- File.mkdir_p(parent),
         {:ok, ^parent} <- SafePath.resolve_real(parent),
         {:ok, ^parent} <- SafePath.resolve_within(parent, destination) do
      :ok
    else
      _other -> {:error, "unsafe_fixture_parent"}
    end
  end

  defp write_exclusive_file(path, content) do
    case File.open(path, [:write, :binary, :exclusive], fn io -> IO.binwrite(io, content) end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, "fixture_write_failed:#{reason}"}
      {:error, reason} -> {:error, "fixture_write_failed:#{reason}"}
    end
  end

  defp attach_fixture_commit(destination, commit_oid, timeout_ms) do
    with :ok <- write_shallow_boundary(destination, commit_oid),
         {:ok, _output} <- Git.run(destination, ["read-tree", commit_oid], timeout_ms),
         {:ok, _output} <-
           Git.run(destination, ["update-ref", "refs/heads/benchmark", commit_oid], timeout_ms),
         {:ok, _output} <-
           Git.run(destination, ["symbolic-ref", "HEAD", "refs/heads/benchmark"], timeout_ms) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_shallow_boundary(destination, commit_oid) do
    destination
    |> Path.join(".git/shallow")
    |> write_exclusive_file(commit_oid <> "\n")
  end

  defp execute_adapter(executor, pair, prepared, runtime) do
    fixture = pair.fixture
    workdir = prepared.workdirs[executor]
    input_hash = fixture["normalized_input_hash"]

    request = %{
      "acp_agent" => runtime.acp_agent,
      "base_commit_oid" => prepared.commit_oid,
      "base_tree_oid" => fixture["base_tree_oid"],
      "executor_path" => executor,
      "fixture_id" => fixture["fixture_id"],
      "normalized_input" => fixture["input"],
      "normalized_input_hash" => input_hash,
      "repetition" => pair.repetition,
      "schema" => @request_schema,
      "seed" => runtime.seed,
      "workdir" => workdir
    }

    callback = runtime.adapters[executor]

    case verification_context(callback, request, runtime) do
      {:ok, verification} ->
        measurement = safely(fn -> measure_execution(runtime, executor, callback, request) end)

        execution =
          measured_execution(
            measurement,
            executor,
            pair,
            request,
            runtime,
            verification
          )

        finalize_artifact_lease(execution, measurement, verification, runtime.benchmark)

      {:error, {:benchmark_setup_error, reason}} ->
        execution_failure(executor, pair, "benchmark_setup_failed", reason)
    end
  end

  defp verification_context(callback, request, runtime) do
    with {:ok, scope} <- Adapter.verification_scope(request, runtime.benchmark) do
      if callback in @production_adapters do
        {:ok,
         %{
           artifact_lease: scope.artifact_lease,
           base_commit_oid: request["base_commit_oid"],
           expected_branch: scope.branch_name,
           git_timeout_ms: runtime.benchmark.execution_timeout_ms,
           require_returned_worktree?: true,
           strict_provenance?: request["executor_path"] == "pipeline",
           trusted_artifact_root: scope.artifact_root,
           trusted_worktree_root: scope.worktree_root
         }}
      else
        {:ok,
         %{
           artifact_lease: nil,
           base_commit_oid: request["base_commit_oid"],
           expected_branch: nil,
           git_timeout_ms: runtime.benchmark.execution_timeout_ms,
           require_returned_worktree?: false,
           strict_provenance?: false,
           trusted_artifact_root: scope.workdir,
           trusted_worktree_root: scope.workdir
         }}
      end
    end
  end

  defp measured_execution(
         {:returned, {wall_clock_ms, outcome}},
         executor,
         pair,
         request,
         runtime,
         verification
       )
       when is_integer(wall_clock_ms) and wall_clock_ms >= 0 do
    build_execution(
      executor,
      pair,
      request,
      outcome,
      wall_clock_ms,
      runtime,
      verification
    )
  end

  defp measured_execution(
         {:returned, _invalid},
         executor,
         pair,
         _request,
         _runtime,
         _verification
       ),
       do: execution_failure(executor, pair, "measurement_failed", "invalid_measurement")

  defp measured_execution({:raised, reason}, executor, pair, _request, _runtime, _verification),
    do: execution_failure(executor, pair, "measurement_failed", reason)

  defp measured_execution({:caught, reason}, executor, pair, _request, _runtime, _verification),
    do: execution_failure(executor, pair, "measurement_failed", reason)

  defp finalize_artifact_lease(
         execution,
         measurement,
         %{artifact_lease: lease, trusted_artifact_root: root},
         benchmark
       )
       when is_binary(lease) do
    case Runtime.artifact_lease_state(root, lease, benchmark) do
      :owned -> finalize_owned_artifact_lease(execution, measurement, root, lease, benchmark)
      :foreign -> execution
      :absent -> execution
      state -> finalize_invalid_artifact_lease(execution, measurement, state)
    end
  end

  defp finalize_artifact_lease(execution, _measurement, _verification, _benchmark), do: execution

  defp finalize_invalid_artifact_lease(execution, measurement, state) do
    if artifact_release_allowed?(measurement) do
      artifact_cleanup_failure(execution, "lease_state:#{state}")
    else
      record_artifact_lease_retention(execution, "lease_state:#{state}")
    end
  end

  defp finalize_owned_artifact_lease(execution, measurement, root, lease, benchmark) do
    if artifact_release_allowed?(measurement) do
      case Runtime.release_artifact_root(root, lease, benchmark) do
        :ok -> execution
        {:error, reason} -> artifact_cleanup_failure(execution, reason)
      end
    else
      record_artifact_lease_retention(execution, "unconfirmed_worker_cleanup")
    end
  end

  defp artifact_release_allowed?(
         {:returned,
          {_wall_clock_ms,
           {:timed_out, _timeout_ms,
            %{
              "cancellation" => %{
                "worker_terminated" => true,
                "cleanup_completed" => true
              },
              "cleanup" => %{"resources_cleaned" => true}
            }}}}
       ),
       do: true

  defp artifact_release_allowed?({:returned, {wall_clock_ms, {:returned, adapter_return}}})
       when is_integer(wall_clock_ms) and wall_clock_ms >= 0 do
    structurally_valid_adapter_return?(adapter_return)
  end

  defp artifact_release_allowed?({:returned, {_wall_clock_ms, {:timed_out, _, _}}}), do: false
  defp artifact_release_allowed?(_measurement), do: false

  defp structurally_valid_adapter_return?({:ok, envelope}),
    do: match?({:ok, _normalized}, adapter_envelope(envelope, true))

  defp structurally_valid_adapter_return?({:error, _reason}), do: true

  defp structurally_valid_adapter_return?({:error, _reason, envelope}),
    do: match?({:ok, _normalized}, adapter_envelope(envelope, false))

  defp structurally_valid_adapter_return?(_other), do: false

  defp record_artifact_lease_retention(%{row: row} = execution, reason) do
    terminal_reason = row["terminal_reason"] || "artifact_lease_retained"

    row =
      Map.put(row, "terminal_reason", terminal_reason <> ";artifact_lease_retained:" <> reason)

    %{execution | row: row}
  end

  defp artifact_cleanup_failure(%{row: row} = execution, reason) do
    verification = Map.put(row["artifact_hash_verification"], "status", "failed")

    row =
      row
      |> Map.put("artifact_hash_verification", verification)
      |> Map.put("terminal_reason", "artifact_lease_cleanup_failed:#{reason_string(reason)}")
      |> Map.put("terminal_status", "artifact_cleanup_failed")

    %{execution | projection: nil, row: row}
  end

  defp measure(fun) do
    {microseconds, result} = :timer.tc(fun)
    {div(microseconds + 999, 1_000), result}
  end

  defp measure_execution(runtime, _executor, callback, request) do
    runtime.measure.(fn ->
      invoke_with_timeout(
        callback,
        request,
        runtime.benchmark.execution_timeout_ms,
        runtime.benchmark.cancellation_timeout_ms
      )
    end)
  end

  defp invoke_with_timeout(callback, request, timeout_ms, cancellation_timeout_ms) do
    task = Task.async(fn -> safely(fn -> invoke(callback, request) end) end)

    case Task.yield(task, timeout_ms) do
      {:ok, outcome} ->
        outcome

      {:exit, reason} ->
        {:caught, "exit:#{inspect(reason, limit: 20, printable_limit: 500)}"}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        cancellation = cancel_with_timeout(callback, request, cancellation_timeout_ms)
        {:timed_out, timeout_ms, cancellation}
    end
  end

  defp cancel_with_timeout(callback, request, timeout_ms) do
    task = Task.async(fn -> safely(fn -> invoke_cancel(callback, request) end) end)

    case Task.yield(task, timeout_ms) do
      {:ok, outcome} ->
        cancellation_observations_from_hook(outcome)

      {:exit, reason} ->
        cancellation_hook_failed({:exit, reason})

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        cancellation_hook_observations("cancel_hook_timeout", false, "timeout:#{timeout_ms}")
    end
  end

  defp invoke(callback, request) when is_function(callback, 1), do: callback.(request)
  defp invoke(module, request) when is_atom(module), do: module.run(request)

  defp invoke_cancel(module, request) when is_atom(module) do
    if function_exported?(module, :cancel, 1),
      do: module.cancel(request),
      else: {:error, :cancellation_unsupported}
  end

  defp invoke_cancel(_callback, _request), do: {:error, :cancellation_unsupported}

  defp safely(fun) do
    {:returned, fun.()}
  rescue
    exception -> {:raised, Exception.message(exception)}
  catch
    kind, reason -> {:caught, "#{kind}:#{inspect(reason, limit: 20, printable_limit: 500)}"}
  end

  defp build_execution(
         executor,
         pair,
         request,
         {:returned, returned},
         wall_clock_ms,
         runtime,
         verification
       ) do
    case normalize_adapter_return(returned) do
      {:ok, envelope} ->
        project_execution(
          executor,
          pair,
          request,
          envelope,
          wall_clock_ms,
          runtime,
          verification
        )

      {:error, reason, envelope} ->
        row =
          failure_row(executor, pair, "executor_failed", reason,
            counters: envelope.counters,
            observations: envelope.observations,
            prepared: true,
            wall_clock_ms: wall_clock_ms,
            worker_ownership: envelope.worker_ownership
          )

        %{executor: executor, projection: nil, row: row}
    end
  end

  defp build_execution(
         executor,
         pair,
         _request,
         {:timed_out, timeout_ms, cancellation_observations},
         wall_clock_ms,
         _runtime,
         _verification
       ) do
    row =
      failure_row(executor, pair, "executor_timeout", "execution_timeout:#{timeout_ms}",
        artifact_failed: true,
        objective_failure: "execution_timeout:#{timeout_ms}",
        observations: cancellation_observations,
        prepared: true,
        wall_clock_ms: wall_clock_ms,
        worker_ownership:
          fetch_value(cancellation_observations, "worker_ownership", :worker_ownership, "unknown")
      )

    %{executor: executor, projection: nil, row: row}
  end

  defp build_execution(
         executor,
         pair,
         _request,
         {:raised, reason},
         wall_clock_ms,
         _runtime,
         _verification
       ) do
    row =
      failure_row(executor, pair, "executor_raised", reason,
        prepared: true,
        wall_clock_ms: wall_clock_ms
      )

    %{executor: executor, projection: nil, row: row}
  end

  defp build_execution(
         executor,
         pair,
         _request,
         {:caught, reason},
         wall_clock_ms,
         _runtime,
         _verification
       ) do
    row =
      failure_row(executor, pair, "executor_threw", reason,
        prepared: true,
        wall_clock_ms: wall_clock_ms
      )

    %{executor: executor, projection: nil, row: row}
  end

  defp execution_failure(executor, pair, status, reason) do
    %{
      executor: executor,
      projection: nil,
      row: failure_row(executor, pair, status, reason, prepared: true)
    }
  end

  defp cancellation_observations_from_hook({:returned, :ok}) do
    cancellation_hook_observations("cancel_requested", false, "cancellation_not_confirmed")
  end

  defp cancellation_observations_from_hook({:returned, {:ok, evidence}})
       when is_map(evidence) do
    cancellation_evidence(evidence)
  end

  defp cancellation_observations_from_hook({:returned, {:error, :cancellation_unsupported}}) do
    cancellation_hook_observations("unsupported", false, "cancellation_unsupported")
  end

  defp cancellation_observations_from_hook({:returned, {:error, reason}}) do
    cancellation_hook_failed(reason)
  end

  defp cancellation_observations_from_hook({:returned, other}) do
    cancellation_hook_failed({:invalid_return, other})
  end

  defp cancellation_observations_from_hook({:raised, reason}),
    do: cancellation_hook_failed({:raised, reason})

  defp cancellation_observations_from_hook({:caught, reason}),
    do: cancellation_hook_failed({:caught, reason})

  defp cancellation_evidence(evidence) do
    worker_terminated =
      Map.get(evidence, "worker_terminated", Map.get(evidence, :worker_terminated))

    worker_ownership =
      Map.get(evidence, "worker_ownership", Map.get(evidence, :worker_ownership))

    cleanup = Map.get(evidence, "cleanup", Map.get(evidence, :cleanup))
    resources_cleaned = fetch_value(cleanup, "resources_cleaned", :resources_cleaned, false)

    if worker_terminated == true and resources_cleaned == true and
         worker_ownership in ["owned", "reused", :owned, :reused] do
      worker_ownership =
        if is_atom(worker_ownership), do: Atom.to_string(worker_ownership), else: worker_ownership

      %{
        "cancellation" => %{
          "cancelled" => true,
          "cleanup_completed" => true,
          "reason" => nil,
          "requested" => true,
          "status" => "cancel_confirmed",
          "worker_terminated" => true
        },
        "cleanup" => %{
          "completed" => true,
          "resources_cleaned" => true,
          "status" => "released",
          "workspace_removed" =>
            fetch_value(cleanup, "workspace_removed", :workspace_removed, nil),
          "workspace_retained" =>
            fetch_value(cleanup, "workspace_retained", :workspace_retained, nil)
        },
        "worker_ownership" => worker_ownership
      }
    else
      cancellation_hook_observations("cancel_unconfirmed", false, "invalid_cancellation_evidence")
    end
  end

  defp cancellation_hook_failed(reason) do
    cancellation_hook_observations("cancel_hook_failed", false, reason_string(reason))
  end

  defp cancellation_hook_observations(status, cancelled, reason) do
    %{
      "cancellation" => %{
        "cancelled" => cancelled,
        "cleanup_completed" => nil,
        "reason" => reason,
        "requested" => true,
        "status" => status,
        "worker_terminated" => nil
      },
      "cleanup" => %{
        "completed" => nil,
        "resources_cleaned" => nil,
        "status" => "unverified",
        "workspace_removed" => nil,
        "workspace_retained" => nil
      }
    }
  end

  defp normalize_adapter_return({:ok, envelope}) do
    case adapter_envelope(envelope, true) do
      {:ok, envelope} -> {:ok, envelope}
      {:error, reason} -> {:error, reason, empty_envelope()}
    end
  end

  defp normalize_adapter_return({:error, reason}) do
    {:error, reason_string(reason), empty_envelope()}
  end

  defp normalize_adapter_return({:error, reason, envelope}) do
    case adapter_envelope(envelope, false) do
      {:ok, envelope} -> {:error, reason_string(reason), envelope}
      {:error, envelope_reason} -> {:error, envelope_reason, empty_envelope()}
    end
  end

  defp normalize_adapter_return(_other),
    do: {:error, "invalid_adapter_return", empty_envelope()}

  defp adapter_envelope(envelope, result_required?)
       when is_map(envelope) and not is_struct(envelope) do
    with {:ok, normalized} <- normalize_envelope_keys(envelope),
         :ok <- envelope_keys(normalized, result_required?),
         {:ok, result} <- envelope_result(normalized, result_required?),
         {:ok, observations} <- envelope_observations(normalized),
         {:ok, counters} <- counters(Map.get(normalized, "counters", %{})),
         {:ok, ownership} <- worker_ownership(Map.get(normalized, "worker_ownership", "unknown")) do
      {:ok,
       %{
         counters: counters,
         observations: observations,
         result: result,
         worker_ownership: ownership
       }}
    end
  end

  defp adapter_envelope(_envelope, _result_required?), do: {:error, "invalid_adapter_envelope"}

  defp normalize_envelope_keys(envelope) do
    Enum.reduce_while(envelope, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      name = if is_atom(key), do: Atom.to_string(key), else: key

      cond do
        not is_binary(name) -> {:halt, {:error, "invalid_adapter_envelope_key"}}
        Map.has_key?(acc, name) -> {:halt, {:error, "duplicate_adapter_envelope_key"}}
        true -> {:cont, {:ok, Map.put(acc, name, value)}}
      end
    end)
  end

  defp envelope_keys(envelope, result_required?) do
    allowed = ~w(result observations counters worker_ownership)
    required = if result_required?, do: ~w(result observations), else: []
    keys = Map.keys(envelope)

    cond do
      Enum.any?(keys, &(&1 not in allowed)) ->
        {:error, "unknown_adapter_envelope_key"}

      Enum.any?(required, &(not Map.has_key?(envelope, &1))) ->
        {:error, "missing_adapter_envelope_key"}

      true ->
        :ok
    end
  end

  defp envelope_result(envelope, true) do
    case Map.get(envelope, "result") do
      result when is_map(result) and not is_struct(result) -> {:ok, result}
      _other -> {:error, "invalid_adapter_result"}
    end
  end

  defp envelope_result(envelope, false), do: {:ok, Map.get(envelope, "result")}

  defp envelope_observations(envelope) do
    case Map.get(envelope, "observations", %{}) do
      observations when is_map(observations) and not is_struct(observations) ->
        {:ok, observations}

      _other ->
        {:error, "invalid_adapter_observations"}
    end
  end

  defp counters(counters) when is_map(counters) and not is_struct(counters) do
    validation = fetch_value(counters, "validation_cycles", :validation_cycles, 0)
    rework = fetch_value(counters, "rework_cycles", :rework_cycles, 0)
    allowed = ["validation_cycles", "rework_cycles", :validation_cycles, :rework_cycles]

    if Enum.all?(Map.keys(counters), &(&1 in allowed)) and valid_counter?(validation) and
         valid_counter?(rework) do
      {:ok, %{"rework_cycles" => rework, "validation_cycles" => validation}}
    else
      {:error, "invalid_adapter_counters"}
    end
  end

  defp counters(_counters), do: {:error, "invalid_adapter_counters"}

  defp valid_counter?(value), do: is_integer(value) and value in 0..@max_counter

  defp worker_ownership(value) when is_atom(value), do: worker_ownership(Atom.to_string(value))

  defp worker_ownership(value) when value in ~w(owned reused none unknown), do: {:ok, value}
  defp worker_ownership(_value), do: {:error, "invalid_worker_ownership"}

  defp empty_envelope do
    %{
      counters: %{"rework_cycles" => 0, "validation_cycles" => 0},
      observations: %{},
      result: nil,
      worker_ownership: "unknown"
    }
  end

  defp project_execution(
         executor,
         pair,
         request,
         envelope,
         wall_clock_ms,
         runtime,
         verification
       ) do
    case observed_worktree(envelope.result, request, verification) do
      {:ok, worktree} ->
        project_observed_execution(
          executor,
          pair,
          request,
          envelope,
          wall_clock_ms,
          runtime,
          worktree,
          verification
        )

      {:error, reason} ->
        row =
          failure_row(executor, pair, "worktree_verification_failed", reason,
            artifact_failed: true,
            counters: envelope.counters,
            objective_failure: reason,
            observations: envelope.observations,
            prepared: true,
            wall_clock_ms: wall_clock_ms,
            worker_ownership: envelope.worker_ownership
          )

        %{executor: executor, projection: nil, row: row}
    end
  end

  defp project_observed_execution(
         executor,
         pair,
         request,
         envelope,
         wall_clock_ms,
         runtime,
         worktree,
         verification
       ) do
    observations = observed_tree(envelope.observations, worktree, verification.git_timeout_ms)

    case CodingParity.project(envelope.result, observations) do
      {:ok, projection} ->
        semantic = projection["semantic"]
        status = semantic["terminal_status"]

        verifier =
          objective_verification(
            status,
            request,
            envelope.result,
            pair.fixture,
            runtime,
            worktree
          )

        artifact_verification =
          artifact_verification(
            executor,
            request,
            envelope.result,
            projection,
            worktree,
            verification
          )

        case final_worktree_attestation(status, envelope.result, worktree, verification) do
          :ok ->
            row = %{
              "approval_observations" => approval_observations(semantic["approval"]),
              "artifact_hash_verification" => artifact_verification,
              "base_tree_oid" => pair.fixture["base_tree_oid"],
              "cancellation_observations" =>
                cancellation_observations(
                  semantic["cancellation"],
                  semantic["cleanup"],
                  envelope.worker_ownership
                ),
              "changed_paths" => semantic["changed_files"],
              "counters" => envelope.counters,
              "executor_path" => executor,
              "fixture_id" => pair.fixture["fixture_id"],
              "normalized_input_hash" => pair.fixture["normalized_input_hash"],
              "objective_verifier" => verifier,
              "repetition" => pair.repetition,
              "review_outcome" => review_outcome(semantic["review"] || %{}),
              "terminal_reason" => result_reason(envelope.result, status),
              "terminal_status" => status,
              "wall_clock_ms" => valid_wall_clock(wall_clock_ms)
            }

            %{executor: executor, projection: projection, row: row}

          {:error, reason} ->
            row =
              failure_row(executor, pair, "worktree_verification_failed", reason,
                artifact_failed: true,
                counters: envelope.counters,
                objective_failure: reason,
                observations: envelope.observations,
                prepared: true,
                wall_clock_ms: wall_clock_ms,
                worker_ownership: envelope.worker_ownership
              )

            %{executor: executor, projection: nil, row: row}
        end

      {:error, reason} ->
        row =
          failure_row(executor, pair, "invalid_coding_result", reason_string(reason),
            counters: envelope.counters,
            observations: envelope.observations,
            prepared: true,
            wall_clock_ms: wall_clock_ms,
            worker_ownership: envelope.worker_ownership
          )

        %{executor: executor, projection: nil, row: row}
    end
  end

  defp observed_worktree(result, _request, %{require_returned_worktree?: true} = verification) do
    with {:ok, path} <- result_worktree_path(result),
         {:ok, branch} <- result_branch(result),
         true <- branch == verification.expected_branch,
         {:ok, expected_path} <-
           Orchestrator.expected_coding_worktree_path(
             verification.trusted_worktree_root,
             branch
           ),
         {:ok, worktree} <-
           exact_canonical_worktree(
             path,
             verification.trusted_worktree_root,
             expected_path,
             branch,
             verification.git_timeout_ms
           ) do
      {:ok, worktree}
    else
      :missing -> {:error, "missing_returned_worktree"}
      {:error, "missing_returned_branch"} = error -> error
      {:error, "invalid_returned_branch"} = error -> error
      false -> {:error, "returned_branch_mismatch"}
      {:error, :invalid_coding_worktree_input} -> {:error, "invalid_expected_worktree"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp observed_worktree(result, request, verification) do
    case result_worktree_path(result) do
      {:ok, path} ->
        canonical_worktree(path, verification.trusted_worktree_root, verification.git_timeout_ms)

      :missing when not verification.require_returned_worktree? ->
        canonical_worktree(
          request["workdir"],
          verification.trusted_worktree_root,
          verification.git_timeout_ms
        )

      :missing ->
        {:error, "missing_returned_worktree"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp result_worktree_path(result) do
    case fetch_value(result, "payload", :payload, nil) do
      payload when is_map(payload) ->
        cond do
          Map.has_key?(payload, "worktree_path") -> worktree_path(payload["worktree_path"])
          Map.has_key?(payload, :worktree_path) -> worktree_path(payload[:worktree_path])
          true -> :missing
        end

      _other ->
        :missing
    end
  end

  defp worktree_path(path) when is_binary(path) do
    if String.valid?(path) and String.trim(path) != "" and not String.contains?(path, <<0>>),
      do: {:ok, path},
      else: {:error, "invalid_returned_worktree"}
  end

  defp worktree_path(_path), do: {:error, "invalid_returned_worktree"}

  defp result_branch(result) do
    case fetch_value(result, "payload", :payload, nil) do
      payload when is_map(payload) ->
        payload
        |> fetch_value("branch", :branch, nil)
        |> returned_branch()

      _other ->
        {:error, "missing_returned_branch"}
    end
  end

  defp returned_branch(nil), do: {:error, "missing_returned_branch"}

  defp returned_branch(branch) when is_binary(branch) do
    if String.valid?(branch) and String.trim(branch) != "" and
         not String.contains?(branch, <<0>>),
       do: {:ok, branch},
       else: {:error, "invalid_returned_branch"}
  end

  defp returned_branch(_branch), do: {:error, "invalid_returned_branch"}

  defp canonical_worktree(path, trusted_root, timeout_ms) do
    with {:ok, root} <- SafePath.resolve_real(trusted_root),
         true <- File.dir?(root),
         {:ok, lexical} <- SafePath.resolve_within(path, root),
         {:ok, real} <- SafePath.resolve_real(lexical),
         {:ok, ^real} <- SafePath.resolve_within(real, root),
         true <- File.dir?(real),
         {:ok, ^real} <- git_output(real, ["rev-parse", "--show-toplevel"], timeout_ms) do
      {:ok, real}
    else
      _other -> {:error, "unsafe_or_missing_returned_worktree"}
    end
  end

  defp exact_canonical_worktree(path, trusted_root, expected_path, expected_branch, timeout_ms) do
    with {:ok, root} <- SafePath.resolve_real(trusted_root),
         true <- File.dir?(root),
         {:ok, ^expected_path} <- SafePath.resolve_within(expected_path, root),
         {:ok, %{type: :directory}} <- File.lstat(expected_path),
         {:ok, ^expected_path} <- SafePath.resolve_real(expected_path),
         {:ok, ^expected_path} <- SafePath.resolve_within(path, root),
         {:ok, ^expected_path} <-
           git_output(expected_path, ["rev-parse", "--show-toplevel"], timeout_ms),
         {:ok, ^expected_branch} <-
           git_output(expected_path, ["symbolic-ref", "--quiet", "--short", "HEAD"], timeout_ms) do
      {:ok, expected_path}
    else
      _other -> {:error, "unexpected_returned_worktree"}
    end
  end

  defp final_worktree_attestation(status, _result, _worktree, _verification)
       when status not in ~w(change_committed pr_created),
       do: :ok

  defp final_worktree_attestation(_status, _result, _worktree, %{
         require_returned_worktree?: false
       }),
       do: :ok

  defp final_worktree_attestation(_status, result, worktree, verification) do
    with {:ok, path} <- result_worktree_path(result),
         {:ok, branch} <- result_branch(result),
         true <- branch == verification.expected_branch,
         {:ok, expected_path} <-
           Orchestrator.expected_coding_worktree_path(verification.trusted_worktree_root, branch),
         {:ok, ^worktree} <-
           exact_canonical_worktree(
             path,
             verification.trusted_worktree_root,
             expected_path,
             branch,
             verification.git_timeout_ms
           ),
         {:ok, expected_commit} <- result_commit(result),
         {:ok, ^expected_commit} <-
           git_output(
             worktree,
             ["rev-parse", "--verify", "HEAD^{commit}"],
             verification.git_timeout_ms
           ),
         :ok <-
           git_ok(
             worktree,
             ["merge-base", "--is-ancestor", verification.base_commit_oid, expected_commit],
             verification.git_timeout_ms
           ),
         {:ok, ""} <-
           git_output(
             worktree,
             ["status", "--porcelain=v1", "--untracked-files=all"],
             verification.git_timeout_ms
           ),
         {:ok, []} <- all_untracked_paths(worktree, verification.git_timeout_ms) do
      :ok
    else
      _other -> {:error, "final_branch_or_commit_attestation_failed"}
    end
  end

  defp result_commit(result) do
    result
    |> fetch_value("payload", :payload, %{})
    |> fetch_value("commit", :commit, nil)
    |> case do
      commit when is_binary(commit) ->
        commit = String.downcase(commit)

        if Regex.match?(@oid_pattern, commit),
          do: {:ok, commit},
          else: {:error, :invalid_returned_commit}

      _other ->
        {:error, :invalid_returned_commit}
    end
  end

  defp observed_tree(observations, worktree, timeout_ms) do
    has_tree? =
      Map.has_key?(observations, "tree_oid") or Map.has_key?(observations, :tree_oid)

    case {has_tree?, git_output(worktree, ["rev-parse", "--verify", "HEAD^{tree}"], timeout_ms)} do
      {false, {:ok, tree_oid}} -> Map.put(observations, "tree_oid", tree_oid)
      _other -> observations
    end
  end

  defp objective_verification(status, _request, _result, _fixture, _runtime, _worktree)
       when status in ~w(cancelled declined) do
    objective_result("not_run", "terminal_status:#{status}")
  end

  defp objective_verification(_status, request, result, fixture, runtime, worktree) do
    verifier = runtime.verifiers[fixture["verifier_id"]]

    verifier_request = %{
      "executor_path" => request["executor_path"],
      "fixture_id" => fixture["fixture_id"],
      "normalized_input" => fixture["input"],
      "result" => result,
      "workdir" => worktree
    }

    case invoke_with_timeout(
           verifier,
           verifier_request,
           runtime.benchmark.execution_timeout_ms,
           runtime.benchmark.cancellation_timeout_ms
         ) do
      {:returned, :ok} ->
        objective_result("passed", nil)

      {:returned, {:ok, _details}} ->
        objective_result("passed", nil)

      {:returned, {:error, reason}} ->
        objective_result("failed", reason_string(reason))

      {:returned, other} ->
        objective_result("failed", "invalid_verifier_return:#{reason_string(other)}")

      {:raised, reason} ->
        objective_result("failed", "verifier_raised:#{reason}")

      {:caught, reason} ->
        objective_result("failed", "verifier_threw:#{reason}")

      {:timed_out, timeout_ms, _cancellation} ->
        objective_result("failed", "verifier_timeout:#{timeout_ms}")
    end
  end

  defp objective_result(status, reason), do: %{"reason" => reason, "status" => status}

  defp artifact_verification(executor, request, result, projection, workdir, verification) do
    semantic = projection["semantic"]
    quality = projection["artifact_quality"]

    timeout_ms = verification.git_timeout_ms
    actual_tree = git_output(workdir, ["rev-parse", "--verify", "HEAD^{tree}"], timeout_ms)

    actual_base_tree =
      git_output(
        workdir,
        [
          "rev-parse",
          "--verify",
          "#{request["base_commit_oid"]}^{tree}"
        ],
        timeout_ms
      )

    actual_paths = changed_paths(workdir, request["base_commit_oid"], timeout_ms)
    expected_tree = semantic["tree_oid"]
    expected_paths = semantic["changed_files"]
    expected_base_tree = request["base_tree_oid"]

    base_verified = match?({:ok, ^expected_base_tree}, actual_base_tree)
    tree_verified = match?({:ok, ^expected_tree}, actual_tree)
    paths_verified = match?({:ok, ^expected_paths}, actual_paths)
    input_verified = hash_json(request["normalized_input"]) == request["normalized_input_hash"]
    graph_hash_verified = graph_hash_verified(executor, result, verification)

    status =
      if base_verified and tree_verified and paths_verified and input_verified and
           artifact_expectations_met?(executor, quality, graph_hash_verified) do
        "passed"
      else
        "failed"
      end

    %{
      "artifact_presence" => artifact_presence(quality),
      "base_tree_verified" => base_verified,
      "changed_paths_verified" => paths_verified,
      "graph_hash_verified" => graph_hash_verified,
      "normalized_input_hash_verified" => input_verified,
      "result_tree_verified" => tree_verified,
      "status" => status
    }
  end

  defp artifact_expectations_met?("legacy", _quality, nil), do: true

  defp artifact_expectations_met?("pipeline", quality, true) do
    Enum.all?(~w(digest dot manifest plan), &Map.get(quality, &1, false))
  end

  defp artifact_expectations_met?(_executor, _quality, _hash), do: false

  defp graph_hash_verified("legacy", _result, _verification), do: nil

  defp graph_hash_verified("pipeline", result, %{strict_provenance?: true} = verification) do
    production_provenance_verified(result, verification.trusted_artifact_root)
  end

  defp graph_hash_verified("pipeline", result, verification) do
    scripted_graph_hash_verified(result, verification.trusted_artifact_root)
  end

  defp scripted_graph_hash_verified(result, workdir) do
    with {:ok, artifacts} <- result_artifacts(result),
         :ok <- contained_artifact_paths(artifacts, workdir),
         hash when is_binary(hash) <- fetch_value(artifacts, "graph_hash", :graph_hash, nil),
         true <- Regex.match?(@hash_pattern, String.downcase(hash)),
         path when is_binary(path) <-
           fetch_value(artifacts, "coding_pipeline_path", :coding_pipeline_path, nil),
         {:ok, content} <- read_trusted_artifact(path, workdir, @max_dot_bytes) do
      sha256(content) == String.downcase(hash)
    else
      _other -> false
    end
  end

  defp production_provenance_verified(result, trusted_root) do
    with {:ok, artifacts} <- result_artifacts(result),
         {:ok, provenance} <- validated_provenance_artifacts(artifacts),
         {:ok, paths} <- exact_provenance_paths(provenance, trusted_root),
         {:ok, dot} <-
           read_trusted_artifact(paths["coding_pipeline_path"], trusted_root, @max_dot_bytes),
         {:ok, plan_json} <-
           read_trusted_artifact(
             paths["coding_plan_path"],
             trusted_root,
             @max_json_artifact_bytes
           ),
         {:ok, manifest_json} <-
           read_trusted_artifact(
             paths["compile_manifest_path"],
             trusted_root,
             @max_json_artifact_bytes
           ),
         {:ok, plan_map} <- decode_json_object(plan_json),
         {:ok, manifest} <- decode_json_object(manifest_json),
         {:ok, identity} <- Orchestrator.verify_coding_provenance(plan_map, dot, manifest),
         true <-
           fetch_value(provenance, "graph_hash", :graph_hash, nil) == identity["graph_hash"],
         true <-
           fetch_value(provenance, "compiler_version", :compiler_version, nil) ==
             identity["compiler_version"],
         {:ok, ^paths} <- exact_provenance_paths(provenance, trusted_root) do
      true
    else
      _other -> false
    end
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp validated_provenance_artifacts(artifacts) do
    with {:ok, keys} <- artifact_descriptor_keys(artifacts),
         true <- MapSet.subset?(@required_pipeline_artifact_keys, keys),
         true <- MapSet.subset?(keys, @allowed_pipeline_artifact_keys),
         :ok <- validate_optional_artifact_descriptors(artifacts) do
      provenance =
        Map.new(@pipeline_provenance_keys, fn key ->
          {:ok, value} = artifact_descriptor_value(artifacts, key)
          {key, value}
        end)

      {:ok, provenance}
    else
      _other -> {:error, :invalid_artifact_descriptors}
    end
  end

  defp validate_optional_artifact_descriptors(artifacts) do
    Enum.reduce_while(@optional_pipeline_artifact_keys, :ok, fn key, :ok ->
      case artifact_descriptor_value(artifacts, key) do
        :error ->
          {:cont, :ok}

        {:ok, descriptor} ->
          if valid_optional_artifact_descriptor?(key, descriptor),
            do: {:cont, :ok},
            else: {:halt, {:error, :invalid_optional_artifact_descriptor}}
      end
    end)
  end

  defp valid_optional_artifact_descriptor?("workspace_release", descriptor),
    do: WorkspaceReleaseDescriptor.valid?(descriptor)

  defp valid_optional_artifact_descriptor?("acp_transcript", descriptor),
    do: TranscriptDescriptor.valid?(descriptor)

  defp exact_provenance_paths(artifacts, trusted_root) do
    with {:ok, %{type: :directory}} <- File.lstat(trusted_root),
         {:ok, ^trusted_root} <- SafePath.resolve_real(trusted_root),
         :ok <- exact_artifact_descriptor_keys(artifacts) do
      Enum.reduce_while(@artifact_filenames, {:ok, %{}}, fn {key, filename}, {:ok, acc} ->
        atom_key = artifact_atom_key(key)
        path = fetch_value(artifacts, key, atom_key, nil)
        expected = Path.join(trusted_root, filename)

        with true <- is_binary(path),
             {:ok, ^expected} <- SafePath.resolve_within(path, trusted_root),
             {:ok, %{type: :regular}} <- File.lstat(expected),
             {:ok, real} <- contained_existing_file(path, trusted_root),
             true <- real == expected do
          {:cont, {:ok, Map.put(acc, key, real)}}
        else
          _other -> {:halt, {:error, :unexpected_provenance_path}}
        end
      end)
    else
      _other -> {:error, :invalid_provenance_root}
    end
  end

  defp exact_artifact_descriptor_keys(artifacts) do
    allowed = @required_pipeline_artifact_keys

    case artifact_descriptor_keys(artifacts) do
      {:ok, ^allowed} -> :ok
      _other -> {:error, :invalid_artifact_descriptor_keys}
    end
  end

  defp artifact_descriptor_keys(artifacts) do
    Enum.reduce_while(artifacts, {:ok, MapSet.new()}, fn {key, _value}, {:ok, acc} ->
      name = if is_atom(key), do: Atom.to_string(key), else: key

      cond do
        not is_binary(name) -> {:halt, {:error, :invalid_artifact_descriptor_key}}
        MapSet.member?(acc, name) -> {:halt, {:error, :duplicate_artifact_descriptor_key}}
        true -> {:cont, {:ok, MapSet.put(acc, name)}}
      end
    end)
  end

  defp artifact_descriptor_value(artifacts, key) do
    case Map.fetch(artifacts, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(artifacts, artifact_atom_key(key))
    end
  end

  defp artifact_atom_key("coding_plan_path"), do: :coding_plan_path
  defp artifact_atom_key("coding_pipeline_path"), do: :coding_pipeline_path
  defp artifact_atom_key("compile_manifest_path"), do: :compile_manifest_path
  defp artifact_atom_key("compiler_version"), do: :compiler_version
  defp artifact_atom_key("graph_hash"), do: :graph_hash
  defp artifact_atom_key("workspace_release"), do: :workspace_release
  defp artifact_atom_key("acp_transcript"), do: :acp_transcript

  defp read_trusted_artifact(path, trusted_root, max_bytes) do
    with {:ok, expected} <- trusted_artifact_identity(path, trusted_root),
         true <- expected.size > 0 and expected.size <= max_bytes do
      read_open_artifact(path, trusted_root, expected)
    else
      _other -> {:error, :invalid_artifact_file}
    end
  end

  defp read_open_artifact(path, trusted_root, expected) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          with {:ok, info_before} <- :file.read_file_info(io, time: :posix),
               {:ok, handle_before} <-
                 regular_artifact_identity(File.Stat.from_record(info_before)),
               true <- same_artifact_identity?(handle_before, expected),
               :ok <- emit_artifact_opened(path),
               {:ok, content} <- read_exact_artifact(io, expected.size, path, 1),
               :ok <- eof_probe(io),
               {:ok, info_between} <- :file.read_file_info(io, time: :posix),
               {:ok, handle_between} <-
                 regular_artifact_identity(File.Stat.from_record(info_between)),
               true <- same_artifact_identity?(handle_between, expected),
               {:ok, 0} <- :file.position(io, :bof),
               {:ok, repeated} <- read_exact_artifact(io, expected.size, path, 2),
               true <- repeated == content,
               :ok <- eof_probe(io),
               {:ok, info_after} <- :file.read_file_info(io, time: :posix),
               {:ok, handle_after} <- regular_artifact_identity(File.Stat.from_record(info_after)),
               true <- same_artifact_identity?(handle_after, expected),
               {:ok, path_after} <- trusted_artifact_identity(path, trusted_root),
               true <- same_artifact_identity?(path_after, expected) do
            {:ok, content}
          else
            _other -> {:error, :invalid_artifact_file}
          end
        after
          :file.close(io)
        end

      {:error, _reason} ->
        {:error, :invalid_artifact_file}
    end
  end

  defp read_exact_artifact(io, size, path, pass),
    do: read_exact_artifact(io, size, path, pass, 0, [])

  defp read_exact_artifact(_io, 0, _path, _pass, _offset, chunks),
    do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_exact_artifact(io, remaining, path, pass, offset, chunks) when remaining > 0 do
    chunk_size = min(remaining, 65_536)

    case :file.read(io, chunk_size) do
      {:ok, chunk} when byte_size(chunk) == chunk_size ->
        emit_artifact_chunk_read(path, pass, offset, chunk_size)

        read_exact_artifact(io, remaining - chunk_size, path, pass, offset + chunk_size, [
          chunk | chunks
        ])

      _other ->
        {:error, :short_read}
    end
  end

  defp emit_artifact_chunk_read(path, pass, offset, bytes) do
    :telemetry.execute(
      [:arbor, :commands, :coding_benchmark, :artifact_chunk_read],
      %{bytes: bytes},
      %{offset: offset, pass: pass, path: path}
    )

    :ok
  end

  defp eof_probe(io) do
    case :file.read(io, 1) do
      :eof -> :ok
      {:ok, <<>>} -> :ok
      _other -> {:error, :file_changed}
    end
  end

  defp emit_artifact_opened(path) do
    :telemetry.execute(
      [:arbor, :commands, :coding_benchmark, :artifact_opened],
      %{count: 1},
      %{path: path}
    )

    :ok
  end

  defp decode_json_object(content) do
    case Jason.decode(content) do
      {:ok, object} when is_map(object) and not is_struct(object) -> {:ok, object}
      _other -> {:error, :invalid_json_object}
    end
  end

  defp contained_artifact_paths(artifacts, workdir) do
    Enum.reduce_while(@pipeline_artifact_path_keys, :ok, fn {key, atom_key}, :ok ->
      case fetch_value(artifacts, key, atom_key, nil) do
        path when is_binary(path) ->
          case contained_existing_file(path, workdir) do
            {:ok, _real} -> {:cont, :ok}
            {:error, _reason} -> {:halt, {:error, :unsafe_artifact_path}}
          end

        _other ->
          {:halt, {:error, :missing_artifact_path}}
      end
    end)
  end

  defp result_artifacts(result) do
    with payload when is_map(payload) <- fetch_value(result, "payload", :payload, nil),
         artifacts when is_map(artifacts) <- fetch_value(payload, "artifacts", :artifacts, nil) do
      {:ok, artifacts}
    else
      _other -> {:error, :missing_artifacts}
    end
  end

  defp contained_existing_file(path, workdir) do
    with {:ok, lexical} <- SafePath.resolve_within(path, workdir),
         {:ok, real} <- SafePath.resolve_real(lexical),
         {:ok, ^real} <- SafePath.resolve_within(real, workdir),
         true <- File.regular?(real) do
      {:ok, real}
    else
      _other -> {:error, :unsafe_artifact_path}
    end
  end

  defp trusted_artifact_file(path, trusted_root) do
    with {:ok, %{type: :directory}} <- File.lstat(trusted_root),
         {:ok, ^trusted_root} <- SafePath.resolve_real(trusted_root),
         {:ok, lexical} <- SafePath.resolve_within(path, trusted_root),
         {:ok, %{type: :regular} = stat} <- File.lstat(lexical),
         {:ok, real} <- SafePath.resolve_real(lexical),
         true <- real == lexical,
         {:ok, ^real} <- SafePath.resolve_within(real, trusted_root) do
      {:ok, stat}
    else
      _other -> {:error, :unsafe_artifact_path}
    end
  end

  defp trusted_artifact_identity(path, trusted_root) do
    with {:ok, stat} <- trusted_artifact_file(path, trusted_root),
         {:ok, identity} <- regular_artifact_identity(stat) do
      {:ok, identity}
    end
  end

  defp regular_artifact_identity(%File.Stat{type: :regular} = stat)
       when is_integer(stat.inode) and stat.inode > 0 and is_integer(stat.major_device) and
              is_integer(stat.minor_device) and is_integer(stat.size) and stat.size >= 0 do
    {:ok,
     %{
       inode: stat.inode,
       major_device: stat.major_device,
       minor_device: stat.minor_device,
       size: stat.size,
       type: stat.type
     }}
  end

  defp regular_artifact_identity(_stat), do: {:error, :unsafe_artifact_path}

  defp same_artifact_identity?(left, right) do
    left.type == right.type and left.inode == right.inode and
      left.major_device == right.major_device and left.minor_device == right.minor_device and
      left.size == right.size
  end

  defp changed_paths(workdir, base_commit_oid, timeout_ms) do
    with {:ok, tracked} <-
           git_binary(
             workdir,
             [
               "diff",
               "--name-only",
               "-z",
               "--no-renames",
               base_commit_oid,
               "--"
             ],
             timeout_ms
           ),
         {:ok, tracked_paths} <- nul_paths(tracked),
         {:ok, untracked_paths} <- all_untracked_paths(workdir, timeout_ms) do
      {:ok, (tracked_paths ++ untracked_paths) |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp all_untracked_paths(workdir, timeout_ms) do
    with {:ok, ordinary} <-
           git_binary(workdir, ["ls-files", "--others", "-z", "--"], timeout_ms),
         {:ok, ignored} <-
           git_binary(
             workdir,
             ["ls-files", "--others", "--ignored", "--exclude-standard", "-z", "--"],
             timeout_ms
           ),
         {:ok, paths} <- nul_paths(ordinary <> ignored) do
      {:ok, paths |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp nul_paths(binary) when is_binary(binary) do
    paths = :binary.split(binary, <<0>>, [:global]) |> Enum.reject(&(&1 == ""))

    if Enum.all?(paths, &(String.valid?(&1) and not String.contains?(&1, <<0>>))),
      do: {:ok, paths},
      else: {:error, "invalid_git_path"}
  end

  defp approval_observations(observation) do
    fixed_fields(observation || %{}, ~w(status requested required resumed count))
  end

  defp cancellation_observations(cancellation, cleanup, ownership) do
    cancellation
    |> Kernel.||(%{})
    |> fixed_fields(~w(status requested cancelled worker_terminated cleanup_completed))
    |> Map.put(
      "cleanup",
      fixed_fields(
        cleanup || %{},
        ~w(status completed resources_cleaned workspace_removed workspace_retained)
      )
    )
    |> Map.put("worker_ownership", ownership)
  end

  defp review_outcome(review) do
    fixed_fields(
      review,
      ~w(recommendation tier_decision human_required security_veto blast_radius)
    )
  end

  defp artifact_presence(quality),
    do: fixed_fields(quality || %{}, ~w(digest dot manifest plan), false)

  defp fixed_fields(map, fields, default \\ nil) do
    Map.new(fields, &{&1, Map.get(map, &1, default)})
  end

  defp result_reason(_result, status)
       when status in ~w(change_committed no_changes pr_created),
       do: nil

  defp result_reason(result, _status) do
    payload = fetch_value(result, "payload", :payload, %{})

    sources = [
      fetch_value(payload, "report", :report, %{}),
      payload,
      fetch_value(result, "raw", :raw, %{}),
      result
    ]

    Enum.find_value(sources, fn source ->
      value =
        fetch_value(source, "reason", :reason, nil) || fetch_value(source, "error", :error, nil)

      if is_nil(value), do: nil, else: reason_string(value)
    end)
  end

  defp failure_row(executor, pair, status, reason, opts \\ []) do
    ownership = Keyword.get(opts, :worker_ownership, "unknown")
    observations = Keyword.get(opts, :observations, %{})
    approval = fetch_value(observations, "approval", :approval, %{})
    cancellation = fetch_value(observations, "cancellation", :cancellation, %{})
    cleanup = fetch_value(observations, "cleanup", :cleanup, %{})

    artifact_verification =
      opts
      |> Keyword.get(:prepared, false)
      |> empty_artifact_verification()
      |> maybe_fail_artifact_verification(Keyword.get(opts, :artifact_failed, false))

    objective_verification =
      case Keyword.get(opts, :objective_failure) do
        nil -> objective_result("not_run", status)
        objective_reason -> objective_result("failed", reason_string(objective_reason))
      end

    %{
      "approval_observations" => approval_observations(approval),
      "artifact_hash_verification" => artifact_verification,
      "base_tree_oid" => pair.fixture["base_tree_oid"],
      "cancellation_observations" => cancellation_observations(cancellation, cleanup, ownership),
      "changed_paths" => [],
      "counters" =>
        Keyword.get(opts, :counters, %{"rework_cycles" => 0, "validation_cycles" => 0}),
      "executor_path" => executor,
      "fixture_id" => pair.fixture["fixture_id"],
      "normalized_input_hash" => pair.fixture["normalized_input_hash"],
      "objective_verifier" => objective_verification,
      "repetition" => pair.repetition,
      "review_outcome" => review_outcome(%{}),
      "terminal_reason" => reason_string(reason),
      "terminal_status" => status,
      "wall_clock_ms" => valid_wall_clock(Keyword.get(opts, :wall_clock_ms, 0))
    }
  end

  defp empty_artifact_verification(prepared?) do
    %{
      "artifact_presence" => artifact_presence(%{}),
      "base_tree_verified" => if(prepared?, do: true, else: nil),
      "changed_paths_verified" => nil,
      "graph_hash_verified" => nil,
      "normalized_input_hash_verified" => if(prepared?, do: true, else: nil),
      "result_tree_verified" => nil,
      "status" => "not_run"
    }
  end

  defp maybe_fail_artifact_verification(verification, true) do
    Map.merge(verification, %{
      "base_tree_verified" => false,
      "changed_paths_verified" => false,
      "result_tree_verified" => false,
      "status" => "failed"
    })
  end

  defp maybe_fail_artifact_verification(verification, false), do: verification

  defp valid_wall_clock(value) when is_integer(value) and value >= 0, do: value
  defp valid_wall_clock(_value), do: 0

  defp pair_report(pair, projections) do
    comparison =
      case {Map.get(projections, "legacy"), Map.get(projections, "pipeline")} do
        {left, right} when is_map(left) and is_map(right) ->
          case CodingParity.compare(left, right) do
            {:ok, result} ->
              %{
                "differences" => result["differences"],
                "equivalent" => result["equivalent?"],
                "reason" => nil,
                "status" => if(result["equivalent?"], do: "equivalent", else: "different")
              }

            {:error, reason} ->
              unavailable_comparison(reason_string(reason))
          end

        _other ->
          unavailable_comparison("missing_projection")
      end

    %{
      "comparison" => comparison,
      "execution_order" => pair.order,
      "fixture_id" => pair.fixture["fixture_id"],
      "repetition" => pair.repetition
    }
  end

  defp unavailable_comparison(reason) do
    %{"differences" => [], "equivalent" => nil, "reason" => reason, "status" => "unavailable"}
  end

  defp dry_report(manifest, runtime) do
    pairs = pair_specs(manifest, runtime)

    {rows, pair_reports} =
      Enum.reduce(pairs, {[], []}, fn pair, {rows, reports} ->
        pair_rows =
          Enum.map(pair.order, fn executor ->
            failure_row(executor, pair, "dry_run", "execution_skipped")
          end)

        {rows ++ pair_rows, reports ++ [pair_report(pair, %{})]}
      end)

    report(manifest, runtime, rows, pair_reports)
  end

  defp report(manifest, runtime, rows, pairs) do
    statuses = Enum.frequencies_by(pairs, & &1["comparison"]["status"])

    %{
      "manifest_hash" => hash_json(manifest),
      "pairs" => pairs,
      "repetitions" => runtime.repetitions,
      "rows" => rows,
      "schema" => @report_schema,
      "seed" => runtime.seed,
      "summary" => %{
        "different_pairs" => Map.get(statuses, "different", 0),
        "equivalent_pairs" => Map.get(statuses, "equivalent", 0),
        "pair_count" => length(pairs),
        "row_count" => length(rows),
        "unavailable_pairs" => Map.get(statuses, "unavailable", 0)
      }
    }
  end

  defp git_ok(workdir, args, timeout_ms) do
    case git_binary(workdir, args, timeout_ms) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_output(workdir, args, timeout_ms) do
    case git_binary(workdir, args, timeout_ms) do
      {:ok, output} -> {:ok, String.trim(output)}
      error -> error
    end
  end

  defp git_binary(workdir, args, timeout_ms) do
    Git.run(workdir, args, timeout_ms)
  end

  defp fetch_value(map, string, atom, default) when is_map(map) do
    case Map.fetch(map, string) do
      {:ok, value} -> value
      :error -> Map.get(map, atom, default)
    end
  end

  defp fetch_value(_map, _string, _atom, default), do: default

  defp reason_string(nil), do: "unspecified"

  defp reason_string(value) when is_binary(value) do
    if String.valid?(value) do
      String.slice(value, 0, 1_000)
    else
      bytes = binary_part(value, 0, min(byte_size(value), 500))
      "invalid_utf8:#{Base.encode16(bytes, case: :lower)}"
    end
  end

  defp reason_string(value) when is_atom(value), do: Atom.to_string(value)

  defp reason_string(value) do
    inspect(value, limit: 30, printable_limit: 1_000, width: 120)
  end

  defp closed_map(map, allowed, required, field) do
    keys = Map.keys(map)

    cond do
      Enum.any?(keys, &(not is_binary(&1))) ->
        invalid_manifest(field, "non_string_key")

      Enum.any?(keys, &(&1 not in allowed)) ->
        invalid_manifest(field, "unknown_field")

      Enum.any?(required, &(not Map.has_key?(map, &1))) ->
        invalid_manifest(field, "missing_field")

      true ->
        :ok
    end
  end

  defp exact_value(value, value, _field), do: :ok
  defp exact_value(_actual, _expected, field), do: invalid_manifest(field, "unsupported_schema")

  defp invalid_manifest(field, reason) do
    {:error,
     %{
       "error" => "invalid_coding_benchmark_manifest",
       "field" => field,
       "reason" => reason
     }}
  end

  defp runtime_error(field, reason) do
    {:error,
     %{
       "error" => "invalid_coding_benchmark_runtime",
       "field" => field,
       "reason" => reason
     }}
  end

  defp hash_json(value), do: value |> canonical_json() |> IO.iodata_to_binary() |> sha256()

  defp sha256(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  defp canonical_json(nil), do: "null"
  defp canonical_json(true), do: "true"
  defp canonical_json(false), do: "false"
  defp canonical_json(value) when is_binary(value), do: Jason.encode_to_iodata!(value)
  defp canonical_json(value) when is_integer(value), do: Integer.to_string(value)
  defp canonical_json(value) when is_float(value), do: Jason.encode_to_iodata!(value)

  defp canonical_json(value) when is_list(value) do
    ["[", value |> Enum.map(&canonical_json/1) |> Enum.intersperse(","), "]"]
  end

  defp canonical_json(value) when is_map(value) and not is_struct(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, item} -> [Jason.encode_to_iodata!(key), ":", canonical_json(item)] end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end
end
