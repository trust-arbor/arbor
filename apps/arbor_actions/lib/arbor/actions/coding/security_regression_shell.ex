defmodule Arbor.Actions.Coding.SecurityRegression.Shell do
  @moduledoc """
  Imperative resource shell for two-revision security-regression validation.

  It stages candidate test bytes once, runs an isolated candidate suite, asks
  the monitored workspace registry for an exact-base detached snapshot, overlays
  only the staged tests, and runs the same suite again. All domain verdicts are
  delegated to `SecurityRegression.Core`.
  """

  alias Arbor.Actions.Coding.SecurityRegression.Core
  alias Arbor.Actions.Coding.SecurityRegression.Formatter
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Mix, as: MixAction
  alias Arbor.Common.SafePath

  @maximum_source_bytes 1_048_576
  @maximum_total_source_bytes 4_194_304
  @maximum_artifact_bytes 65_536

  @type source :: %{
          path: String.t(),
          bytes: binary(),
          sha256: String.t(),
          identity: map()
        }

  @doc "Execute the compound validation and release all monitored resources before returning."
  @spec run(Core.input(), map()) :: {:ok, map()} | {:error, term()}
  def run(input, context) when is_map(input) and is_map(context) do
    caller = caller_context(context)

    with {:ok, claim} <-
           WorkspaceLeaseRegistry.claim_review_attestation(input.review_attestation_id, caller) do
      resource = claim.resource
      material = claim.material

      execution_input =
        Map.merge(input, %{
          workspace_id: material.workspace_id,
          test_paths: Enum.map(material.selected_tests, & &1.path),
          material: material
        })

      result =
        with {:ok, evidence} <- guarded_execute(resource, execution_input, caller),
             {:ok, finalized_material} <-
               WorkspaceLeaseRegistry.finalize_review_attestation(
                 input.review_attestation_id,
                 caller
               ) do
          {:ok,
           bind_attestation_evidence(
             evidence,
             finalized_material,
             claim.council_decision_digest
           )}
        end

      cleanup = WorkspaceLeaseRegistry.release_validation_resource(resource.resource_id, caller)

      case {result, cleanup} do
        {{:ok, evidence}, {:ok, _released}} ->
          feedback_json = Jason.encode!(evidence)
          {:ok, Map.put(evidence, :feedback_json, feedback_json)}

        {{:error, reason}, {:ok, _released}} ->
          {:error, reason}

        {_result, {:error, _reason}} ->
          {:error, :validation_resource_cleanup_failed}
      end
    end
  end

  def run(_input, _context), do: {:error, :invalid_security_regression_input}

  defp guarded_execute(resource, input, caller) do
    try do
      execute(resource, input, caller)
    rescue
      _error -> {:error, :security_regression_execution_failed}
    catch
      _kind, _reason -> {:error, :security_regression_execution_failed}
    end
  end

  defp execute(resource, input, caller) do
    with {:ok, sources} <- stage_sources(resource, input.test_paths),
         :ok <- verify_attested_sources(sources, input.material.selected_tests),
         {:ok, candidate_fingerprint} <-
           workspace_fingerprint(resource.candidate_path, resource.root_path, "candidate"),
         {:ok, candidate, stable_fingerprint} <-
           run_candidate(resource, input, sources, candidate_fingerprint),
         {:ok, base} <- run_base_if_needed(resource, input, sources, candidate, caller) do
      {:ok,
       Core.show(%{
         base_commit: resource.base_commit,
         candidate_fingerprint: stable_fingerprint,
         sources: sources,
         candidate: candidate,
         base: base
       })
       |> Map.put(:evidence_type, "reviewed_regression_evidence")}
    end
  end

  defp bind_attestation_evidence(evidence, material, council_decision_digest) do
    Map.merge(evidence, %{
      attested_base_commit: material.base_commit,
      attested_candidate_commit: material.candidate_commit,
      attested_candidate_tree_oid: material.candidate_tree_oid,
      attested_diff_sha256: material.diff_sha256,
      attested_selected_tests: material.selected_tests,
      review_attestation_digest: material.canonical_digest,
      council_decision_digest: council_decision_digest
    })
  end

  defp run_candidate(resource, input, sources, candidate_fingerprint) do
    case validate_test_helpers(resource.candidate_path, input.test_paths) do
      :ok ->
        with :ok <- verify_sources(resource.candidate_path, sources),
             :ok <-
               write_runner(
                 revision_runner_path(resource, :candidate),
                 formatter_module_name(resource.resource_id)
               ) do
          leg =
            run_leg(
              resource.candidate_path,
              resource.candidate_build_path,
              resource.candidate_result_path,
              revision_runner_path(resource, :candidate),
              input,
              resource
            )

          with :ok <- verify_sources(resource.candidate_path, sources),
               {:ok, after_fingerprint} <-
                 workspace_fingerprint(
                   resource.candidate_path,
                   resource.root_path,
                   "candidate"
                 ) do
            stable_leg =
              if after_fingerprint == candidate_fingerprint do
                leg
              else
                %{leg | status: :source_changed}
              end

            {:ok, stable_leg, candidate_fingerprint}
          else
            {:error, :candidate_source_changed} ->
              {:ok, %{leg | status: :source_changed}, candidate_fingerprint}

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:error, :candidate_source_changed} ->
            {:ok, Core.incomplete_leg(:source_changed), candidate_fingerprint}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :helper_missing} ->
        {:ok, Core.incomplete_leg(:helper_missing), candidate_fingerprint}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_base_if_needed(resource, input, sources, candidate, caller) do
    case Core.candidate_gate(candidate) do
      :ok -> run_base(resource, input, sources, caller)
      {:error, _reason} -> {:ok, Core.not_run_leg()}
    end
  end

  defp run_base(resource, input, sources, caller) do
    case WorkspaceLeaseRegistry.create_validation_snapshot(resource.resource_id, caller) do
      {:ok, snapshot} ->
        with :ok <- verify_exact_head(snapshot.base_worktree_path, snapshot.base_commit),
             :ok <- overlay_sources(snapshot.base_worktree_path, sources),
             {:ok, before_fingerprint} <-
               workspace_fingerprint(snapshot.base_worktree_path, snapshot.root_path, "base") do
          run_base_suite(snapshot, input, before_fingerprint)
        else
          {:error, :overlay_failed} ->
            {:ok, Core.incomplete_leg(:overlay_failed)}

          {:error, reason} when reason in [:base_commit_changed, :fingerprint_failed] ->
            {:ok, Core.incomplete_leg(:snapshot_failed)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _reason} ->
        {:ok, Core.incomplete_leg(:snapshot_failed)}
    end
  end

  defp run_base_suite(snapshot, input, before_fingerprint) do
    case validate_test_helpers(snapshot.base_worktree_path, input.test_paths) do
      :ok ->
        with :ok <-
               write_runner(
                 revision_runner_path(snapshot, :base),
                 formatter_module_name(snapshot.resource_id)
               ) do
          leg =
            run_leg(
              snapshot.base_worktree_path,
              snapshot.base_build_path,
              snapshot.base_result_path,
              revision_runner_path(snapshot, :base),
              input,
              snapshot
            )

          with :ok <- verify_exact_head(snapshot.base_worktree_path, snapshot.base_commit),
               {:ok, after_fingerprint} <-
                 workspace_fingerprint(snapshot.base_worktree_path, snapshot.root_path, "base") do
            if after_fingerprint == before_fingerprint do
              {:ok, leg}
            else
              {:ok, Core.incomplete_leg(:snapshot_failed, Map.get(leg, :diagnostic, %{}))}
            end
          else
            {:error, _reason} ->
              {:ok, Core.incomplete_leg(:snapshot_failed, Map.get(leg, :diagnostic, %{}))}
          end
        end

      {:error, :helper_missing} ->
        {:ok, Core.incomplete_leg(:helper_missing)}

      {:error, _reason} ->
        {:ok, Core.incomplete_leg(:helper_missing)}
    end
  end

  defp run_leg(root, build_path, result_path, runner_path, input, resource) do
    _ = File.rm(result_path)

    # Owner-issued host paths only. Shell rewrites runner/result to fixed guest
    # paths after exact projection verification (Level A harness evidence).
    args = ["run", "--no-start", runner_path, "--", result_path | input.test_paths]
    revision = if root == resource.candidate_path, do: :candidate, else: :base

    # Module-owned contained env always wins over any path-bearing keys. Pass
    # MIX_ENV only on the safe surface; private HOME/TMP/build/deps come from
    # the validation resource.
    opts = [
      timeout: input.timeout,
      validation_resource: resource,
      validation_revision: revision,
      env: %{"MIX_ENV" => "test"}
    ]

    # build_path / deps paths are derived from the resource revision — do not
    # accept the local variables as caller env authority.
    _ = {build_path, dependency_path_for(root, resource)}

    case run_mix(root, args, opts) do
      {:ok, result} ->
        diagnostic = diagnostic(result, resource)

        case read_artifact(result_path) do
          {:ok, counts} ->
            Core.completed_leg(result.exit_code, result.timed_out, counts, diagnostic)

          {:error, :invalid_result_artifact} ->
            Core.incomplete_leg(
              :artifact_invalid,
              diagnostic,
              result.exit_code,
              result.timed_out
            )

          {:error, _reason} ->
            Core.incomplete_leg(
              :suite_incomplete,
              diagnostic,
              result.exit_code,
              result.timed_out
            )
        end

      {:error, reason} ->
        Core.incomplete_leg(:execution_failed, diagnostic_for_error(reason, resource))
    end
  end

  # Production default is MixAction.run_mix/3. Tests may install a hermetic
  # :security_regression_mix_runner that still enforces contained env + tree
  # binding without resolving the host Mix wrapper from BEAM ancestry.
  defp run_mix(path, args, opts) do
    runner =
      Application.get_env(
        :arbor_actions,
        :security_regression_mix_runner,
        &MixAction.run_mix/3
      )

    runner.(path, args, opts)
  end

  # Candidate and base receive independent pre-candidate dependency snapshots.
  # The base leg must never consume a tree candidate code could have mutated.
  # Path-bearing Mix env is module-owned in Arbor.Actions.Mix; this helper is
  # retained only for diagnostic pairing with local path variables.
  defp dependency_path_for(root, resource) do
    if root == resource.candidate_path,
      do: resource.candidate_deps_path,
      else: resource.base_deps_path
  end

  defp revision_runner_path(resource, :candidate) do
    Map.get(resource, :candidate_runner_path) || Map.get(resource, :runner_path) ||
      resource.runner_path
  end

  defp revision_runner_path(resource, :base) do
    Map.get(resource, :base_runner_path) ||
      Path.join([
        Map.get(resource, :base_runner_dir_path) ||
          Path.join(Map.get(resource, :base_runtime_path) || resource.root_path, "runner"),
        "runner.exs"
      ])
  end

  defp stage_sources(resource, test_paths) do
    with :ok <- require_real_directory(resource.candidate_path),
         :ok <- create_private_directory(resource.stage_path) do
      Enum.reduce_while(test_paths, {:ok, [], 0}, fn test_path, {:ok, sources, total} ->
        case read_test_source(resource.candidate_path, test_path) do
          {:ok, bytes, identity} ->
            next_total = total + byte_size(bytes)

            if next_total > @maximum_total_source_bytes do
              {:halt, {:error, :test_sources_too_large}}
            else
              source = %{
                path: test_path,
                bytes: bytes,
                sha256: sha256(bytes),
                identity: identity
              }

              case write_staged_source(resource.stage_path, source) do
                :ok -> {:cont, {:ok, [source | sources], next_total}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, sources, _total} -> {:ok, Enum.reverse(sources)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp read_test_source(root, relative_path) do
    with {:ok, path, before} <- require_regular_path(root, relative_path),
         true <- before.size <= @maximum_source_bytes,
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= @maximum_source_bytes,
         {:ok, _same_path, after_stat} <- require_regular_path(root, relative_path),
         true <- file_identity(before) == file_identity(after_stat),
         true <- byte_size(bytes) == after_stat.size do
      {:ok, bytes, file_identity(after_stat)}
    else
      {:error, :path_symlink} -> {:error, :test_path_symlink}
      {:error, _reason} -> {:error, :invalid_test_source}
      false -> {:error, :test_source_changed}
    end
  end

  defp verify_sources(root, sources) do
    Enum.reduce_while(sources, :ok, fn source, :ok ->
      case read_test_source(root, source.path) do
        {:ok, bytes, identity} when bytes == source.bytes and identity == source.identity ->
          {:cont, :ok}

        _other ->
          {:halt, {:error, :candidate_source_changed}}
      end
    end)
  end

  defp verify_attested_sources(sources, selected_tests) do
    actual = Enum.map(sources, &Map.take(&1, [:path, :sha256]))

    expected =
      Enum.map(selected_tests, fn test ->
        %{path: test.path, sha256: test.blob_sha256}
      end)

    if actual == expected, do: :ok, else: {:error, :attested_test_source_changed}
  end

  defp write_staged_source(stage_root, source) do
    with {:ok, path} <- SafePath.safe_join(stage_root, source.path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, :ok} <-
           File.open(path, [:write, :binary, :exclusive], fn io ->
             IO.binwrite(io, source.bytes)
           end),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      _other -> {:error, :source_staging_failed}
    end
  end

  defp overlay_sources(root, sources) do
    Enum.reduce_while(sources, :ok, fn source, :ok ->
      case overlay_source(root, source) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :overlay_failed}}
      end
    end)
  end

  defp overlay_source(root, source) do
    with {:ok, path} <- SafePath.safe_join(root, source.path),
         :ok <- create_overlay_parents(root, Path.dirname(source.path)),
         :ok <- reject_symlink_or_directory(path),
         :ok <- atomic_write(path, source.bytes, 0o600),
         {:ok, written} <- File.read(path),
         true <- written == source.bytes do
      :ok
    else
      _other -> {:error, :overlay_failed}
    end
  end

  defp create_overlay_parents(_root, "."), do: :ok

  defp create_overlay_parents(root, relative_parent) do
    relative_parent
    |> Path.split()
    |> Enum.reduce_while(root, fn component, current ->
      next = Path.join(current, component)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :directory}} ->
          {:cont, next}

        {:error, :enoent} ->
          case File.mkdir(next) do
            :ok -> {:cont, next}
            _other -> {:halt, {:error, :overlay_parent_failed}}
          end

        _other ->
          {:halt, {:error, :overlay_parent_invalid}}
      end
    end)
    |> case do
      path when is_binary(path) -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_symlink_or_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      _other -> {:error, :invalid_overlay_target}
    end
  end

  defp validate_test_helpers(root, test_paths) do
    with :ok <- require_real_directory(root),
         {:ok, project_roots} <- project_roots_for_tests(root, test_paths) do
      Enum.reduce_while(project_roots, :ok, fn project_root, :ok ->
        helper =
          if project_root == "." do
            "test/test_helper.exs"
          else
            Path.join([project_root, "test", "test_helper.exs"])
          end

        case require_regular_path(root, helper) do
          {:ok, _path, _stat} -> {:cont, :ok}
          _other -> {:halt, {:error, :helper_missing}}
        end
      end)
    else
      _other -> {:error, :helper_missing}
    end
  end

  defp project_roots_for_tests(root, test_paths) do
    Enum.reduce_while(test_paths, {:ok, []}, fn test_path, {:ok, roots} ->
      case nearest_project_root(root, Path.dirname(test_path)) do
        {:ok, project_root} -> {:cont, {:ok, [project_root | roots]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, roots} -> {:ok, roots |> Enum.uniq() |> Enum.sort()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp nearest_project_root(root, relative_dir) do
    relative_dir
    |> ancestor_paths()
    |> Enum.find_value(fn ancestor ->
      mix_file = if ancestor == ".", do: "mix.exs", else: Path.join(ancestor, "mix.exs")

      case require_regular_path(root, mix_file) do
        {:ok, _path, _stat} -> {:ok, ancestor}
        _other -> nil
      end
    end)
    |> case do
      nil -> {:error, :project_root_missing}
      result -> result
    end
  end

  defp ancestor_paths("."), do: ["."]

  defp ancestor_paths(path) do
    parent = Path.dirname(path)
    [path | if(parent == path, do: ["."], else: ancestor_paths(parent))]
  end

  defp require_regular_path(root, relative_path) do
    with {:ok, path} <- SafePath.safe_join(root, relative_path),
         :ok <- require_components(root, relative_path, :regular),
         {:ok, %File.Stat{type: :regular} = stat} <- File.lstat(path),
         {:ok, real_root} <- SafePath.resolve_real(root),
         {:ok, real_path} <- SafePath.resolve_real(path),
         true <- real_path == Path.join(real_root, relative_path) do
      {:ok, path, stat}
    else
      {:error, :path_symlink} -> {:error, :path_symlink}
      _other -> {:error, :invalid_regular_path}
    end
  end

  defp require_components(root, relative_path, leaf_type) do
    parts = Path.split(relative_path)
    last_index = length(parts) - 1

    parts
    |> Enum.with_index()
    |> Enum.reduce_while(root, fn {component, index}, current ->
      path = Path.join(current, component)
      expected = if index == last_index, do: leaf_type, else: :directory

      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :path_symlink}}
        {:ok, %File.Stat{type: ^expected}} -> {:cont, path}
        _other -> {:halt, {:error, :invalid_path_component}}
      end
    end)
    |> case do
      path when is_binary(path) -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_real_directory(path) do
    expanded = Path.expand(path)

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(expanded),
         {:ok, _real_path} <- SafePath.resolve_real(expanded) do
      :ok
    else
      _other -> {:error, :invalid_workspace_path}
    end
  end

  defp create_private_directory(path) do
    case File.mkdir(path) do
      :ok -> File.chmod(path, 0o700)
      _other -> {:error, :resource_directory_create_failed}
    end
  end

  defp workspace_fingerprint(root, resource_root, label) do
    index_path = Path.join(resource_root, "#{label}-fingerprint.index")
    env = [{"GIT_INDEX_FILE", index_path}]

    try do
      with {:ok, head} <- git(root, ["rev-parse", "HEAD"], env),
           {:ok, _output} <- git(root, ["read-tree", "HEAD"], env),
           {:ok, _output} <- git(root, ["add", "-A", "--", "."], env),
           {:ok, tree} <- git(root, ["write-tree"], env) do
        fingerprint = sha256("arbor-candidate-v1\0#{String.trim(head)}\0#{String.trim(tree)}")
        {:ok, fingerprint}
      else
        _other -> {:error, :fingerprint_failed}
      end
    after
      _ = File.rm(index_path)
      _ = File.rm(index_path <> ".lock")
    end
  end

  defp verify_exact_head(path, expected_commit) do
    case git(path, ["rev-parse", "HEAD"], []) do
      {:ok, output} when is_binary(output) ->
        if String.trim(output) == expected_commit,
          do: :ok,
          else: {:error, :base_commit_changed}

      _other ->
        {:error, :base_commit_changed}
    end
  end

  defp git(path, args, env) do
    opts = [stderr_to_stdout: true]
    opts = if env == [], do: opts, else: Keyword.put(opts, :env, env)

    case System.cmd("git", ["-C", path | args], opts) do
      {output, 0} -> {:ok, output}
      {_output, _code} -> {:error, :git_failed}
    end
  rescue
    _error -> {:error, :git_failed}
  end

  defp write_runner(path, module_name) do
    with {:ok, source} <- Formatter.runner_source(module_name),
         :ok <- atomic_write(path, source, 0o600) do
      :ok
    else
      _other -> {:error, :formatter_setup_failed}
    end
  end

  defp atomic_write(path, bytes, mode) do
    temporary = path <> ".tmp"
    _ = File.rm(temporary)

    with :ok <- File.write(temporary, bytes, [:binary, :exclusive]),
         :ok <- File.chmod(temporary, mode),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      _other ->
        _ = File.rm(temporary)
        {:error, :atomic_write_failed}
    end
  end

  defp read_artifact(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @maximum_artifact_bytes <-
           File.lstat(path),
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) == size,
         {:ok, artifact} <- safe_binary_to_term(bytes),
         {:ok, counts} <- Core.validate_artifact(artifact) do
      {:ok, counts}
    else
      {:error, :invalid_result_artifact} -> {:error, :invalid_result_artifact}
      _other -> {:error, :result_artifact_missing}
    end
  end

  defp safe_binary_to_term(bytes) do
    {:ok, :erlang.binary_to_term(bytes, [:safe])}
  rescue
    _error -> {:error, :invalid_result_artifact}
  end

  defp diagnostic(result, resource) do
    output = (result.stdout || "") <> (result.stderr || "")
    normalized = normalize_diagnostic(output, resource)

    %{
      "exit_code" => result.exit_code,
      "timed_out" => result.timed_out == true,
      "output_bytes" => byte_size(normalized),
      "output_sha256" => sha256(normalized)
    }
  end

  defp diagnostic_for_error(reason, resource) do
    normalized = normalize_diagnostic(inspect(reason), resource)

    %{
      "exit_code" => nil,
      "timed_out" => false,
      "output_bytes" => byte_size(normalized),
      "output_sha256" => sha256(normalized)
    }
  end

  defp normalize_diagnostic(output, resource) when is_binary(output) do
    [
      {resource.candidate_path, "<candidate>"},
      {resource.base_worktree_path, "<base>"},
      {resource.root_path, "<resource>"},
      {resource.repo_path, "<repo>"}
    ]
    |> Enum.sort_by(fn {path, _replacement} -> -byte_size(path) end)
    |> Enum.reduce(output, fn {path, replacement}, acc ->
      :binary.replace(acc, path, replacement, [:global])
    end)
  end

  defp file_identity(stat) do
    Map.take(Map.from_struct(stat), [
      :type,
      :size,
      :inode,
      :major_device,
      :minor_device,
      :mtime,
      :ctime
    ])
  end

  defp formatter_module_name(resource_id) do
    suffix =
      :crypto.hash(:sha256, resource_id)
      |> Base.encode16(case: :upper)
      |> binary_part(0, 32)

    "ArborSecurityRegressionFormatter.M" <> suffix
  end

  defp caller_context(context) do
    %{
      task_id: Workspace.context_task_id(context),
      principal_id: Workspace.context_principal_id(context)
    }
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end
end
