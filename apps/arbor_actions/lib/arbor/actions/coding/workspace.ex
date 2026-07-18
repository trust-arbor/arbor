defmodule Arbor.Actions.Coding.Workspace do
  @moduledoc """
  Schema-bounded coding workspace lease actions.

  These actions encapsulate git worktree lifecycle for coding agents without
  exposing PIDs or rich process handles. Lease authority is the invoking owner
  process. Cross-process resume requires both non-empty `task_id` and the same
  non-empty principal/agent id -- opaque workspace ids alone are never enough.

  | Action | Canonical URI |
  |--------|---------------|
  | `Acquire` | `arbor://action/coding/workspace/acquire` |
  | `Inspect` | `arbor://action/coding/workspace/inspect` |
  | `RecoverySummary` | `arbor://action/coding/workspace/recovery_summary` |
  | `Release` | `arbor://action/coding/workspace/release` |
  | `CommittedChange` | `arbor://action/coding/workspace/committed_change` |
  """

  # -- Shared worktree lifecycle (pure helpers + git side effects) ---

  alias Arbor.Actions.Git
  alias Arbor.Actions.Coding.Workspace.DeltaRanges
  alias Arbor.Actions.Mix, as: MixAction
  alias Arbor.Common.SafePath

  @detached_identity_capture_attempts 5

  @fingerprint_max_manifest_bytes 16 * 1024 * 1024
  @fingerprint_max_path_bytes 4 * 1024 * 1024
  @fingerprint_max_paths 20_000
  @fingerprint_max_content_bytes 256 * 1024 * 1024
  @fingerprint_chunk_bytes 64 * 1024

  @doc false
  def resolve_repo_root(path) when is_binary(path) do
    expanded = Path.expand(path)

    case git(expanded, ["rev-parse", "--show-toplevel"]) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, "repo_path is not a git repository: #{reason}"}
    end
  end

  def resolve_repo_root(_), do: {:error, "repo_path must be a string"}

  @doc false
  @spec canonical_path_or_expanded(String.t()) :: String.t()
  def canonical_path_or_expanded(path) when is_binary(path) do
    expanded = Path.expand(path)

    case SafePath.resolve_real(expanded) do
      {:ok, canonical} -> canonical
      {:error, _} -> canonical_missing_tail(expanded)
    end
  end

  defp canonical_missing_tail(expanded) do
    ancestor = nearest_existing_ancestor(expanded)

    case SafePath.resolve_real(ancestor) do
      {:ok, canonical_ancestor} ->
        case Path.relative_to(expanded, ancestor) do
          "." -> canonical_ancestor
          suffix -> Path.join(canonical_ancestor, suffix)
        end

      {:error, _} ->
        expanded
    end
  end

  defp nearest_existing_ancestor(path) do
    if match?({:ok, _}, File.lstat(path)) do
      path
    else
      parent = Path.dirname(path)

      if parent == path do
        path
      else
        nearest_existing_ancestor(parent)
      end
    end
  end

  @doc false
  def resolve_branch_name(params) do
    params
    |> get_param(:branch_name)
    |> case do
      nil -> generated_branch_name(get_param(params, :task))
      "" -> generated_branch_name(get_param(params, :task))
      branch -> {:ok, branch}
    end
    |> validate_branch_name()
  end

  @doc false
  def worktree_dir_name(branch_name) when is_binary(branch_name) do
    slug =
      branch_name
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 48)
      |> case do
        "" -> "change"
        value -> value
      end

    hash =
      branch_name
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "arbor-coding-agent-#{slug}-#{hash}"
  end

  @doc false
  # Create or reuse a worktree for `branch_name`.
  # Returns `{:ok, path, ownership, base_commit}` where ownership is
  # `:owned` (this invocation added the path) or `:reused` (pre-existing path
  # or branch already checked out elsewhere).
  #
  # Atomicity: if this invocation creates an owned worktree and a later
  # reset/clean step fails, the owned path and git worktree registration are
  # removed only through the captured filesystem and Git-registration identity.
  def create_worktree(repo_root, branch_name, params) do
    base_dir =
      params
      |> get_param(:worktree_base_dir)
      |> case do
        nil -> System.tmp_dir!()
        path -> Path.expand(path)
      end

    case File.mkdir_p(base_dir) do
      :ok ->
        base_ref = get_param(params, :base_ref) || "HEAD"
        worktree_path = Path.join(base_dir, worktree_dir_name(branch_name))

        require_reused? = get_param(params, :require_reused) == true

        with {:ok, base_commit} <- rev_parse(repo_root, base_ref),
             {:ok, path, ownership, reset?} <-
               ensure_worktree(
                 repo_root,
                 branch_name,
                 worktree_path,
                 base_commit,
                 require_reused?
               ),
             {:ok, owned_identity} <-
               capture_owned_removal_identity(repo_root, path, branch_name, ownership),
             :ok <-
               finalize_created_worktree(
                 repo_root,
                 path,
                 ownership,
                 base_commit,
                 reset?,
                 owned_identity
               ) do
          {:ok, path, ownership, base_commit}
        end

      {:error, reason} ->
        {:error, "failed to create worktree base dir #{base_dir}: #{inspect(reason)}"}
    end
  end

  @doc false
  @spec preflight_worktree_ownership(String.t(), String.t(), keyword() | map()) ::
          :reused | :may_own
  def preflight_worktree_ownership(repo_root, branch_name, params)
      when is_binary(repo_root) and is_binary(branch_name) do
    base_dir =
      params
      |> get_param(:worktree_base_dir)
      |> case do
        nil -> System.tmp_dir!()
        path -> Path.expand(path)
      end

    worktree_path = Path.join(base_dir, worktree_dir_name(branch_name))

    cond do
      File.dir?(worktree_path) -> :reused
      is_binary(worktree_for_branch(repo_root, branch_name)) -> :reused
      true -> :may_own
    end
  rescue
    _error -> :may_own
  catch
    _kind, _reason -> :may_own
  end

  def preflight_worktree_ownership(_repo_root, _branch_name, _params), do: :may_own

  @doc false
  @spec worktree_lstat_identity(String.t()) :: {:ok, map()} | {:error, term()}
  def worktree_lstat_identity(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok, Map.take(Map.from_struct(stat), [:type, :major_device, :minor_device, :inode])}

      {:ok, _stat} ->
        {:error, :worktree_not_directory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def worktree_lstat_identity(_path), do: {:error, :invalid_worktree_path}

  @doc false
  @spec create_detached_worktree(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def create_detached_worktree(repo_root, worktree_path, commit)
      when is_binary(repo_root) and is_binary(worktree_path) and is_binary(commit) do
    case create_detached_worktree_with_identity(repo_root, worktree_path, commit) do
      {:ok, %{path: path}} -> {:ok, path}
      {:error, _reason} = error -> error
    end
  end

  def create_detached_worktree(_repo_root, _worktree_path, _commit),
    do: {:error, :invalid_detached_snapshot}

  @doc false
  @spec create_detached_worktree_with_identity(String.t(), String.t(), String.t()) ::
          {:ok, %{path: String.t(), removal_identity: map()}} | {:error, term()}
  def create_detached_worktree_with_identity(repo_root, worktree_path, commit)
      when is_binary(repo_root) and is_binary(worktree_path) and is_binary(commit) do
    with :ok <- require_exact_commit_hash(commit),
         :ok <- require_absent_path(worktree_path) do
      case add_detached_worktree(repo_root, worktree_path, commit) do
        {:ok, _output} ->
          finish_added_detached_worktree(repo_root, worktree_path, commit)

        {:error, reason} ->
          recover_failed_detached_add(repo_root, worktree_path, reason)
      end
    else
      {:error, _reason} = error -> error
    end
  rescue
    _error -> {:error, :detached_snapshot_create_failed}
  catch
    :exit, _reason -> {:error, :detached_snapshot_create_failed}
  end

  def create_detached_worktree_with_identity(_repo_root, _worktree_path, _commit),
    do: {:error, :invalid_detached_snapshot}

  defp finish_added_detached_worktree(repo_root, worktree_path, commit) do
    case capture_detached_identity_with_retry(repo_root, worktree_path) do
      {:ok, removal_identity} ->
        run_detached_snapshot_identity_test_hook(worktree_path, removal_identity)
        finalize_detached_worktree(repo_root, worktree_path, commit, removal_identity)

      {:error, reason} ->
        retain_unidentified_detached_snapshot(
          repo_root,
          worktree_path,
          :detached_snapshot_create_failed,
          reason
        )
    end
  end

  defp recover_failed_detached_add(repo_root, worktree_path, create_reason) do
    case capture_detached_identity_with_retry(repo_root, worktree_path) do
      {:ok, removal_identity} ->
        run_detached_snapshot_identity_test_hook(worktree_path, removal_identity)
        detached_snapshot_failure(repo_root, worktree_path, removal_identity, create_reason)

      {:error, identity_reason} ->
        retain_unidentified_detached_snapshot(
          repo_root,
          worktree_path,
          create_reason,
          identity_reason
        )
    end
  end

  defp retain_unidentified_detached_snapshot(
         repo_root,
         worktree_path,
         create_reason,
         identity_reason
       ) do
    case detached_worktree_absent?(repo_root, worktree_path) do
      {:ok, :absent} ->
        {:error, create_reason}

      {:ok, :present} ->
        {:error,
         {:detached_snapshot_cleanup_identity_unavailable, create_reason, identity_reason}}

      {:error, absence_reason} ->
        {:error,
         {:detached_snapshot_cleanup_identity_unavailable, create_reason,
          {identity_reason, absence_reason}}}
    end
  end

  defp capture_detached_identity_with_retry(
         repo_root,
         worktree_path,
         attempts_left \\ @detached_identity_capture_attempts
       )

  defp capture_detached_identity_with_retry(_repo_root, _worktree_path, 0),
    do: {:error, :detached_snapshot_identity_unavailable}

  defp capture_detached_identity_with_retry(repo_root, worktree_path, attempts_left) do
    result =
      case Process.get({__MODULE__, :test_force_detached_identity_capture_failure}) do
        true -> {:error, :forced_identity_capture_failure}
        _other -> capture_worktree_removal_identity(repo_root, worktree_path)
      end

    case result do
      {:ok, identity} ->
        {:ok, identity}

      {:error, _reason} when attempts_left > 1 ->
        Process.sleep(1)
        capture_detached_identity_with_retry(repo_root, worktree_path, attempts_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_detached_snapshot_identity_test_hook(worktree_path, removal_identity) do
    case Process.delete({__MODULE__, :test_after_detached_snapshot_identity}) do
      callback when is_function(callback, 2) -> callback.(worktree_path, removal_identity)
      _other -> :ok
    end
  end

  @doc false
  @spec remove_detached_worktree(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_detached_worktree(repo_root, worktree_path)
      when is_binary(repo_root) and is_binary(worktree_path) do
    case detached_worktree_absent?(repo_root, worktree_path) do
      {:ok, :absent} -> :ok
      {:ok, :present} -> {:error, :detached_snapshot_cleanup_identity_required}
      {:error, reason} -> {:error, {:detached_snapshot_cleanup_failed, reason}}
    end
  rescue
    _error -> {:error, :detached_snapshot_cleanup_failed}
  catch
    :exit, _reason -> {:error, :detached_snapshot_cleanup_failed}
  end

  def remove_detached_worktree(_repo_root, _worktree_path),
    do: {:error, :invalid_detached_snapshot}

  @doc false
  @spec remove_detached_worktree(String.t(), String.t(), map() | nil) ::
          :ok | {:error, term()}
  def remove_detached_worktree(repo_root, worktree_path, removal_identity)
      when is_binary(repo_root) and is_binary(worktree_path) do
    do_remove_detached_worktree(repo_root, worktree_path, removal_identity, nil)
  rescue
    _error -> {:error, :detached_snapshot_cleanup_failed}
  catch
    :exit, _reason -> {:error, :detached_snapshot_cleanup_failed}
  end

  def remove_detached_worktree(_repo_root, _worktree_path, _removal_identity),
    do: {:error, :invalid_detached_snapshot}

  @doc false
  @spec remove_detached_worktree(String.t(), String.t(), map() | nil, keyword()) ::
          :ok | {:error, term()}
  def remove_detached_worktree(repo_root, worktree_path, removal_identity, opts)
      when is_binary(repo_root) and is_binary(worktree_path) and is_list(opts) do
    with {:ok, deadline_ms} <- detached_cleanup_deadline(opts) do
      do_remove_detached_worktree(repo_root, worktree_path, removal_identity, deadline_ms)
    end
  rescue
    _error -> {:error, :detached_snapshot_cleanup_failed}
  catch
    :exit, _reason -> {:error, :detached_snapshot_cleanup_failed}
  end

  def remove_detached_worktree(_repo_root, _worktree_path, _removal_identity, _opts),
    do: {:error, :invalid_detached_snapshot}

  defp do_remove_detached_worktree(repo_root, worktree_path, removal_identity, deadline_ms) do
    case File.lstat(worktree_path) do
      {:error, :enoent} ->
        confirm_detached_worktree_absent(repo_root, worktree_path, deadline_ms)

      {:ok, _stat} when is_map(removal_identity) ->
        remove_present_detached_worktree(
          repo_root,
          worktree_path,
          removal_identity,
          deadline_ms
        )

      {:ok, _stat} ->
        {:error, :detached_snapshot_cleanup_identity_required}

      {:error, reason} ->
        {:error, {:detached_snapshot_cleanup_failed, reason}}
    end
  end

  defp add_detached_worktree(repo_root, worktree_path, commit) do
    result =
      System.cmd(
        "git",
        ["-C", repo_root, "worktree", "add", "--detach", worktree_path, commit],
        stderr_to_stdout: true
      )

    case {result, Process.delete({__MODULE__, :test_force_detached_add_failure})} do
      {{_output, 0}, true} -> {:error, :detached_snapshot_create_failed}
      {{_output, 0}, _other} -> {:ok, worktree_path}
      {{_output, _code}, _other} -> {:error, :detached_snapshot_create_failed}
    end
  end

  defp finalize_detached_worktree(repo_root, worktree_path, commit, removal_identity) do
    with %{worktree_registration: %{detached: true}} <- removal_identity,
         {:ok, actual_commit} <- git(worktree_path, ["rev-parse", "HEAD"]) do
      if String.trim(actual_commit) == commit do
        {:ok, %{path: worktree_path, removal_identity: removal_identity}}
      else
        detached_snapshot_failure(
          repo_root,
          worktree_path,
          removal_identity,
          :detached_snapshot_commit_mismatch
        )
      end
    else
      %{worktree_registration: _registration} ->
        detached_snapshot_failure(
          repo_root,
          worktree_path,
          removal_identity,
          :detached_snapshot_registration_mismatch
        )

      {:error, reason} ->
        detached_snapshot_failure(repo_root, worktree_path, removal_identity, reason)
    end
  end

  defp detached_snapshot_failure(repo_root, worktree_path, removal_identity, reason) do
    case remove_detached_worktree(repo_root, worktree_path, removal_identity) do
      :ok ->
        {:error, reason}

      {:error, cleanup_reason} ->
        {:error, {:detached_snapshot_cleanup_retained, reason, cleanup_reason, removal_identity}}
    end
  end

  defp remove_present_detached_worktree(
         repo_root,
         worktree_path,
         removal_identity,
         deadline_ms
       ) do
    with :ok <-
           remove_bound_worktree_with_deadline(
             repo_root,
             worktree_path,
             removal_identity,
             deadline_ms
           ),
         {:ok, :absent} <- detached_worktree_absent?(repo_root, worktree_path, deadline_ms) do
      :ok
    else
      {:ok, :present} -> {:error, :detached_snapshot_cleanup_failed}
      {:error, reason} -> {:error, {:detached_snapshot_cleanup_failed, reason}}
    end
  end

  defp confirm_detached_worktree_absent(repo_root, worktree_path, deadline_ms) do
    case detached_worktree_absent?(repo_root, worktree_path, deadline_ms) do
      {:ok, :absent} -> :ok
      {:ok, :present} -> {:error, {:detached_snapshot_cleanup_failed, :registration_present}}
      {:error, reason} -> {:error, {:detached_snapshot_cleanup_failed, reason}}
    end
  end

  defp detached_worktree_absent?(repo_root, worktree_path) do
    detached_worktree_absent?(repo_root, worktree_path, nil)
  end

  defp detached_worktree_absent?(repo_root, worktree_path, deadline_ms) do
    with {:error, :enoent} <- File.lstat(worktree_path),
         {:ok, registration} <-
           worktree_registration_with_deadline(repo_root, worktree_path, deadline_ms) do
      if is_map(registration), do: {:ok, :present}, else: {:ok, :absent}
    else
      {:ok, _stat} -> {:ok, :present}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_bound_worktree_with_deadline(repo_root, worktree_path, identity, nil) do
    Git.remove_worktree(repo_root, worktree_path, identity)
  end

  defp remove_bound_worktree_with_deadline(repo_root, worktree_path, identity, deadline_ms) do
    with {:ok, timeout_ms} <- remaining_detached_cleanup_timeout(deadline_ms) do
      Git.remove_worktree(repo_root, worktree_path, identity, timeout_ms)
    end
  end

  defp worktree_registration_with_deadline(repo_root, worktree_path, nil) do
    Git.worktree_registration(repo_root, worktree_path)
  end

  defp worktree_registration_with_deadline(repo_root, worktree_path, deadline_ms) do
    with {:ok, timeout_ms} <- remaining_detached_cleanup_timeout(deadline_ms) do
      Git.worktree_registration(repo_root, worktree_path, timeout_ms)
    end
  end

  defp detached_cleanup_deadline(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) == [:timeout_ms] do
      case Keyword.fetch!(opts, :timeout_ms) do
        timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= 30_000 ->
          {:ok, System.monotonic_time(:millisecond) + timeout_ms}

        _other ->
          {:error, :invalid_detached_cleanup_timeout}
      end
    else
      {:error, :invalid_detached_cleanup_options}
    end
  end

  defp remaining_detached_cleanup_timeout(deadline_ms) when is_integer(deadline_ms) do
    remaining = deadline_ms - System.monotonic_time(:millisecond)

    if remaining > 0,
      do: {:ok, min(remaining, 30_000)},
      else: {:error, :detached_cleanup_deadline_exceeded}
  end

  @doc false
  @spec capture_worktree_removal_identity(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def capture_worktree_removal_identity(repo_root, worktree_path)
      when is_binary(repo_root) and is_binary(worktree_path) do
    with {:ok, lstat_identity} <- worktree_lstat_identity(worktree_path),
         {:ok, registration} when is_map(registration) <-
           Git.worktree_registration(repo_root, worktree_path) do
      {:ok,
       %{
         lstat_identity: lstat_identity,
         worktree_registration: registration
       }}
    else
      {:ok, nil} -> {:error, :worktree_not_registered}
      {:error, reason} -> {:error, reason}
    end
  end

  def capture_worktree_removal_identity(_repo_root, _worktree_path),
    do: {:error, :invalid_worktree_path}

  @doc false
  def context_task_id(context) when is_map(context) do
    map_value(context, :task_id) ||
      map_value(context, "session.task_id") ||
      map_value(context, :session_task_id)
  end

  def context_task_id(_), do: nil

  @doc false
  # Prefer the trusted AuthContext principal (production ActionsExecutor shape),
  # then fall back to canonical session/agent/principal keys.
  def context_principal_id(context) when is_map(context) do
    case auth_context_principal_id(context) do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        map_value(context, :"session.agent_id") ||
          map_value(context, :agent_id) ||
          map_value(context, :principal_id) ||
          map_value(context, "principal_id")
    end
  end

  def context_principal_id(_), do: nil

  @doc false
  @spec inspect_worktree(String.t() | nil, String.t() | nil, keyword() | map()) :: map()
  def inspect_worktree(worktree_path, base_commit, opts \\ []) do
    baseline = inspect_baseline_fingerprint(opts)
    exists = is_binary(worktree_path) and worktree_path != "" and File.dir?(worktree_path)

    if exists do
      dirty = worktree_dirty?(worktree_path)
      head_commit = head_commit(worktree_path)
      fingerprint_result = worktree_fingerprint(worktree_path, head_commit)

      {fingerprint, fingerprint_valid, fingerprint_error} =
        case fingerprint_result do
          {:ok, value} -> {value, true, nil}
          {:error, reason} -> {nil, false, fingerprint_error(reason)}
        end

      {committable_tree_oid, tree_binding_valid, tree_binding_error} =
        case MixAction.committable_tree_binding(worktree_path) do
          {:ok, %{tree_oid: oid}} when is_binary(oid) and oid != "" ->
            {oid, true, nil}

          {:ok, _} ->
            {nil, false, "committable_tree_binding_missing_oid"}

          {:error, reason} ->
            {nil, false, inspect(reason)}
        end

      changed_from_base =
        dirty or
          (is_binary(head_commit) and is_binary(base_commit) and base_commit != "" and
             head_commit != base_commit)

      %{
        exists: true,
        dirty: dirty,
        head_commit: head_commit,
        changed_from_base: changed_from_base,
        fingerprint: fingerprint,
        fingerprint_valid: fingerprint_valid,
        fingerprint_error: fingerprint_error,
        committable_tree_oid: committable_tree_oid,
        tree_binding_valid: tree_binding_valid,
        tree_binding_error: tree_binding_error,
        turn_progressed: turn_progressed?(fingerprint, baseline)
      }
    else
      fingerprint = missing_worktree_fingerprint()

      %{
        exists: false,
        dirty: false,
        head_commit: nil,
        changed_from_base: false,
        fingerprint: fingerprint,
        fingerprint_valid: true,
        fingerprint_error: nil,
        committable_tree_oid: nil,
        tree_binding_valid: false,
        tree_binding_error: "missing_worktree",
        turn_progressed: turn_progressed?(fingerprint, baseline)
      }
    end
  end

  @doc false
  # Bounded, deterministic owner-observed workspace identity for turn-progress
  # detection. The fixed digest covers HEAD, every staged index entry, and the
  # content/metadata of every unstaged or untracked path. No diff or file body
  # crosses the action/Engine boundary.
  @spec worktree_fingerprint(String.t() | term(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def worktree_fingerprint(worktree_path, head_commit \\ nil)

  def worktree_fingerprint(worktree_path, head_commit) when is_binary(worktree_path) do
    with {:ok, canonical_root} <- SafePath.resolve_real(worktree_path),
         {:ok, before} <- fingerprint_manifest(canonical_root, head_commit),
         {:ok, hash, content_bytes} <- hash_fingerprint_manifest(canonical_root, before),
         true <- content_bytes <= @fingerprint_max_content_bytes,
         {:ok, after_manifest} <- fingerprint_manifest(canonical_root, nil),
         true <- stable_fingerprint_manifest?(before, after_manifest) do
      digest = hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
      {:ok, "sha256:" <> digest}
    else
      false -> {:error, :workspace_fingerprint_changed}
      {:error, _reason} = error -> error
      _ -> {:error, :workspace_fingerprint_failed}
    end
  end

  def worktree_fingerprint(_worktree_path, _head_commit),
    do: {:error, :workspace_fingerprint_invalid_path}

  defp fingerprint_manifest(root, supplied_head) do
    with {:ok, head} <- fingerprint_head(root, supplied_head),
         {:ok, index} <- git(root, ["ls-files", "--stage", "-z"]),
         :ok <- require_bounded_binary(index, @fingerprint_max_manifest_bytes),
         {:ok, unstaged} <-
           git(root, [
             "diff",
             "--no-ext-diff",
             "--no-textconv",
             "--ignore-submodules=none",
             "--name-only",
             "-z",
             "HEAD",
             "--"
           ]),
         {:ok, untracked} <-
           git(root, ["ls-files", "--others", "--exclude-standard", "-z"]),
         :ok <- require_bounded_binary(unstaged, @fingerprint_max_path_bytes),
         :ok <- require_bounded_binary(untracked, @fingerprint_max_path_bytes),
         {:ok, paths} <- fingerprint_paths(unstaged, untracked) do
      {:ok, %{head: head, index: index, paths: paths}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :workspace_fingerprint_manifest_failed}
    end
  end

  defp fingerprint_head(_root, supplied) when is_binary(supplied) and supplied != "",
    do: {:ok, supplied}

  defp fingerprint_head(root, _supplied) do
    case git(root, ["rev-parse", "HEAD"]) do
      {:ok, output} ->
        head = String.trim(output)
        if head == "", do: {:error, :workspace_fingerprint_head_missing}, else: {:ok, head}

      {:error, _reason} ->
        {:error, :workspace_fingerprint_head_failed}
    end
  end

  defp require_bounded_binary(value, max_bytes)
       when is_binary(value) and byte_size(value) <= max_bytes,
       do: :ok

  defp require_bounded_binary(_value, _max_bytes),
    do: {:error, :workspace_fingerprint_manifest_too_large}

  defp fingerprint_paths(unstaged, untracked) do
    paths =
      [unstaged, untracked]
      |> Enum.flat_map(&:binary.split(&1, <<0>>, [:global]))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    cond do
      length(paths) > @fingerprint_max_paths ->
        {:error, :workspace_fingerprint_too_many_paths}

      Enum.all?(paths, &safe_fingerprint_relative_path?/1) ->
        {:ok, paths}

      true ->
        {:error, :workspace_fingerprint_unsafe_path}
    end
  end

  defp safe_fingerprint_relative_path?(path) when is_binary(path) and path != "" do
    String.valid?(path) and not String.starts_with?(path, "/") and
      path
      |> :binary.split("/", [:global])
      |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  defp safe_fingerprint_relative_path?(_), do: false

  defp hash_fingerprint_manifest(root, manifest) do
    hash = :crypto.hash_init(:sha256)

    hash =
      hash
      |> hash_fingerprint_field("arbor-coding-ws-fp-v2")
      |> hash_fingerprint_field(manifest.head)
      |> hash_fingerprint_field(manifest.index)

    Enum.reduce_while(manifest.paths, {:ok, hash, 0}, fn path, {:ok, acc, bytes} ->
      case hash_fingerprint_path(root, path, acc, bytes) do
        {:ok, next_hash, next_bytes} -> {:cont, {:ok, next_hash, next_bytes}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp hash_fingerprint_path(root, relative_path, hash, content_bytes) do
    full_path = Path.join(root, relative_path)
    hash = hash_fingerprint_field(hash, relative_path)

    case File.lstat(full_path, time: :posix) do
      {:error, :enoent} ->
        {:ok, hash_fingerprint_field(hash, "missing"), content_bytes}

      {:ok, %File.Stat{type: :regular} = before} ->
        hash_regular_fingerprint_path(root, full_path, before, hash, content_bytes)

      {:ok, %File.Stat{type: :symlink} = before} ->
        with {:ok, target} <- File.read_link(full_path),
             true <- byte_size(target) <= @fingerprint_max_path_bytes,
             {:ok, after_stat} <- File.lstat(full_path, time: :posix),
             true <- same_fingerprint_stat?(before, after_stat) do
          hash =
            hash
            |> hash_fingerprint_field("symlink")
            |> hash_fingerprint_field(Integer.to_string(before.mode))
            |> hash_fingerprint_field(target)

          {:ok, hash, content_bytes}
        else
          _ -> {:error, :workspace_fingerprint_source_changed}
        end

      {:ok, %File.Stat{type: :directory} = before} ->
        with {:ok, submodule_head} <- git(full_path, ["rev-parse", "HEAD"]),
             {:ok, after_stat} <- File.lstat(full_path, time: :posix),
             true <- same_fingerprint_stat?(before, after_stat) do
          hash =
            hash
            |> hash_fingerprint_field("directory")
            |> hash_fingerprint_field(Integer.to_string(before.mode))
            |> hash_fingerprint_field(String.trim(submodule_head))

          {:ok, hash, content_bytes}
        else
          _ -> {:error, :workspace_fingerprint_unsupported_directory}
        end

      {:ok, _other} ->
        {:error, :workspace_fingerprint_unsupported_file_type}

      {:error, _reason} ->
        {:error, :workspace_fingerprint_lstat_failed}
    end
  end

  defp hash_regular_fingerprint_path(root, path, before, hash, content_bytes) do
    hash =
      hash
      |> hash_fingerprint_field("regular")
      |> hash_fingerprint_field(Integer.to_string(before.mode))
      |> hash_fingerprint_field(Integer.to_string(before.size))

    with {:ok, canonical_path} <- SafePath.resolve_real(path),
         true <- within_fingerprint_root?(canonical_path, root),
         true <- content_bytes + before.size <= @fingerprint_max_content_bytes,
         {:ok, hash, read_bytes} <- hash_fingerprint_file(canonical_path, hash, content_bytes),
         true <- read_bytes - content_bytes == before.size,
         {:ok, after_stat} <- File.lstat(path, time: :posix),
         true <- same_fingerprint_stat?(before, after_stat) do
      {:ok, hash, read_bytes}
    else
      false -> {:error, :workspace_fingerprint_content_too_large}
      {:error, _reason} = error -> error
      _ -> {:error, :workspace_fingerprint_source_changed}
    end
  end

  defp hash_fingerprint_file(path, hash, content_bytes) do
    case File.open(path, [:read, :binary], fn io ->
           hash_fingerprint_stream(io, hash, content_bytes)
         end) do
      {:ok, {:ok, next_hash, next_bytes}} -> {:ok, next_hash, next_bytes}
      {:ok, {:error, _reason} = error} -> error
      {:error, _reason} -> {:error, :workspace_fingerprint_read_failed}
    end
  rescue
    _ -> {:error, :workspace_fingerprint_read_failed}
  end

  defp hash_fingerprint_stream(io, hash, content_bytes) do
    case IO.binread(io, @fingerprint_chunk_bytes) do
      :eof ->
        {:ok, hash, content_bytes}

      {:error, _reason} ->
        {:error, :workspace_fingerprint_read_failed}

      chunk when is_binary(chunk) ->
        next_bytes = content_bytes + byte_size(chunk)

        if next_bytes <= @fingerprint_max_content_bytes do
          hash_fingerprint_stream(io, :crypto.hash_update(hash, chunk), next_bytes)
        else
          {:error, :workspace_fingerprint_content_too_large}
        end
    end
  end

  defp hash_fingerprint_field(hash, value) when is_binary(value) do
    :crypto.hash_update(hash, <<byte_size(value)::unsigned-big-64, value::binary>>)
  end

  defp within_fingerprint_root?(path, root),
    do: path == root or String.starts_with?(path, root <> "/")

  defp same_fingerprint_stat?(left, right) do
    fingerprint_stat_identity(left) == fingerprint_stat_identity(right)
  end

  defp fingerprint_stat_identity(%File.Stat{} = stat) do
    Map.take(Map.from_struct(stat), [
      :type,
      :major_device,
      :minor_device,
      :inode,
      :mode,
      :size,
      :mtime,
      :ctime
    ])
  end

  defp stable_fingerprint_manifest?(before, after_manifest) do
    before.head == after_manifest.head and before.index == after_manifest.index and
      before.paths == after_manifest.paths
  end

  defp fingerprint_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp fingerprint_error(_reason), do: "workspace_fingerprint_failed"

  defp missing_worktree_fingerprint, do: "sha256:missing-worktree"

  defp inspect_baseline_fingerprint(opts) when is_list(opts) do
    case Keyword.get(opts, :baseline_fingerprint) do
      fp when is_binary(fp) -> String.trim(fp)
      _ -> nil
    end
  end

  defp inspect_baseline_fingerprint(opts) when is_map(opts) do
    case map_value(opts, :baseline_fingerprint) do
      fp when is_binary(fp) -> String.trim(fp)
      _ -> nil
    end
  end

  defp inspect_baseline_fingerprint(_), do: nil

  defp turn_progressed?(_fingerprint, baseline)
       when not is_binary(baseline) or baseline == "",
       do: true

  defp turn_progressed?(fingerprint, baseline) when is_binary(fingerprint),
    do: fingerprint != baseline

  defp turn_progressed?(_fingerprint, _baseline), do: false

  @doc false
  def json_clean?(value) do
    case value do
      %{} = map when not is_struct(map) ->
        Enum.all?(map, fn {k, v} ->
          (is_atom(k) or is_binary(k)) and json_clean?(v)
        end)

      list when is_list(list) ->
        Enum.all?(list, &json_clean?/1)

      value when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) ->
        true

      _ ->
        false
    end
  end

  @doc """
  Materialize the cumulative committed change for a leased worktree.

  Review input is the range from the lease `base_commit` to the current HEAD
  (not a single arbitrary commit). The worktree must be clean. When `commit`
  is supplied it must equal the current HEAD exactly; ancestors, other
  branches, and revision expressions are rejected before any git read.
  """
  @spec materialize_committed_change(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def materialize_committed_change(worktree_path, base_commit, requested_commit \\ nil)

  def materialize_committed_change(worktree_path, base_commit, requested_commit)
      when is_binary(worktree_path) and worktree_path != "" do
    inspection = inspect_worktree(worktree_path, base_commit)

    with :ok <- require_existing_worktree(inspection),
         :ok <- require_clean_worktree(inspection),
         {:ok, head_commit} <- require_head_commit(inspection),
         {:ok, head_commit} <- ensure_commit_is_exact_head(requested_commit, head_commit),
         {:ok, base_ref} <- require_base_commit(base_commit),
         {:ok, diff} <- committed_diff(worktree_path, base_ref, head_commit),
         {:ok, files} <- committed_files(worktree_path, base_ref, head_commit) do
      {:ok,
       %{
         commit_hash: head_commit,
         base_ref: base_ref,
         diff: diff,
         files: files
       }}
    end
  end

  def materialize_committed_change(_, _, _), do: {:error, :invalid_committed_change_args}

  @doc false
  @spec materialize_committed_change_with_delta(
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t()
        ) :: {:ok, map()} | {:error, term()}
  def materialize_committed_change_with_delta(
        worktree_path,
        repo_path,
        base_commit,
        requested_commit,
        prior_commit
      )
      when is_binary(worktree_path) and is_binary(repo_path) and is_binary(prior_commit) do
    with :ok <- require_exact_prior_commit(prior_commit),
         {:ok, change} <-
           materialize_committed_change(worktree_path, base_commit, requested_commit),
         :ok <- require_prior_commit(repo_path, worktree_path, prior_commit),
         :ok <- require_distinct_prior_commit(prior_commit, change.commit_hash),
         :ok <- require_prior_ancestor(repo_path, worktree_path, prior_commit, change.commit_hash),
         {:ok, delta_diff} <-
           committed_delta_diff(repo_path, worktree_path, prior_commit, change.commit_hash),
         {:ok, delta_files} <-
           committed_delta_files(repo_path, worktree_path, prior_commit, change.commit_hash),
         {:ok, delta_ranges} <- DeltaRanges.parse(delta_diff),
         :ok <- require_delta_range_files(delta_ranges, delta_files),
         :ok <- verify_materialized_head(worktree_path, change.commit_hash) do
      {:ok,
       Map.merge(change, %{
         prior_candidate_commit: prior_commit,
         delta_diff: delta_diff,
         delta_files: delta_files,
         delta_ranges: delta_ranges
       })}
    end
  end

  def materialize_committed_change_with_delta(_, _, _, _, _),
    do: {:error, :invalid_committed_change_args}

  @doc false
  @spec materialize_security_regression_material(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def materialize_security_regression_material(
        worktree_path,
        workspace_id,
        base_commit,
        test_paths
      )
      when is_binary(worktree_path) and is_binary(workspace_id) and is_binary(base_commit) and
             is_list(test_paths) do
    with {:ok, change} <- materialize_committed_change(worktree_path, base_commit),
         :ok <- validate_selected_test_paths(test_paths),
         {:ok, tree_oid} <- git_oid(worktree_path, "#{change.commit_hash}^{tree}"),
         {:ok, selected_tests} <- git_test_blobs(worktree_path, change.commit_hash, test_paths),
         :ok <- verify_materialized_head(worktree_path, change.commit_hash),
         {:ok, material} <-
           Arbor.Actions.Coding.SecurityRegression.Attestation.new(%{
             workspace_id: workspace_id,
             base_commit: base_commit,
             candidate_commit: change.commit_hash,
             candidate_tree_oid: tree_oid,
             diff_sha256: sha256(change.diff),
             selected_tests: selected_tests,
             validation_profile: "security_regression"
           }),
         :ok <- verify_materialized_head(worktree_path, change.commit_hash) do
      {:ok, Map.put(material, :diff, change.diff)}
    end
  end

  def materialize_security_regression_material(_, _, _, _),
    do: {:error, :invalid_security_regression_material_args}

  @doc false
  @spec committed_diff(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def committed_diff(worktree_path, base_commit, head_commit)
      when is_binary(worktree_path) and is_binary(base_commit) and is_binary(head_commit) do
    case git(worktree_path, [
           "diff",
           "--find-renames",
           "--no-ext-diff",
           "#{base_commit}..#{head_commit}"
         ]) do
      {:ok, diff} when diff != "" -> {:ok, diff}
      {:ok, _empty} -> {:error, :empty_commit_diff}
      {:error, reason} -> {:error, {:diff_failed, reason}}
    end
  end

  def committed_diff(_, _, _), do: {:error, :invalid_committed_change_args}

  @doc false
  @spec committed_files(String.t(), String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def committed_files(worktree_path, base_commit, head_commit)
      when is_binary(worktree_path) and is_binary(base_commit) and is_binary(head_commit) do
    case git(worktree_path, [
           "diff",
           "--name-only",
           "--find-renames",
           "#{base_commit}..#{head_commit}"
         ]) do
      {:ok, output} ->
        files =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        if files == [], do: {:error, :empty_commit_file_list}, else: {:ok, files}

      {:error, reason} ->
        {:error, {:files_failed, reason}}
    end
  end

  def committed_files(_, _, _), do: {:error, :invalid_committed_change_args}

  defp require_existing_worktree(%{exists: true}), do: :ok
  defp require_existing_worktree(_), do: {:error, :worktree_missing}

  defp require_clean_worktree(%{dirty: true}), do: {:error, :dirty_workspace}
  defp require_clean_worktree(_), do: :ok

  defp require_head_commit(%{head_commit: head}) when is_binary(head) and head != "",
    do: {:ok, head}

  defp require_head_commit(_), do: {:error, :missing_commit_hash}

  defp require_base_commit(base) when is_binary(base) and base != "", do: {:ok, base}
  defp require_base_commit(_), do: {:error, :missing_base_commit}

  defp require_exact_prior_commit(prior_commit) when is_binary(prior_commit) do
    if Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, prior_commit),
      do: :ok,
      else: {:error, :invalid_prior_commit}
  end

  defp require_exact_prior_commit(_), do: {:error, :missing_prior_commit}

  defp require_prior_commit(repo_path, worktree_path, prior_commit) do
    case lease_git(repo_path, worktree_path, ["rev-parse", "--verify", "#{prior_commit}^{commit}"]) do
      {:ok, output} when is_binary(output) ->
        if String.trim(output) == prior_commit,
          do: :ok,
          else: {:error, :prior_commit_missing}

      _other ->
        {:error, :prior_commit_missing}
    end
  end

  defp require_distinct_prior_commit(prior_commit, candidate_commit) do
    if prior_commit == candidate_commit,
      do: {:error, :prior_commit_equal_candidate},
      else: :ok
  end

  defp require_prior_ancestor(repo_path, worktree_path, prior_commit, candidate_commit) do
    case lease_git_result(repo_path, worktree_path, [
           "merge-base",
           "--is-ancestor",
           prior_commit,
           candidate_commit
         ]) do
      {:ok, %{exit_code: 0}} -> :ok
      _other -> {:error, :prior_commit_not_ancestor}
    end
  end

  defp committed_delta_diff(repo_path, worktree_path, prior_commit, candidate_commit) do
    case lease_git(repo_path, worktree_path, [
           "diff",
           "--find-renames",
           "--no-ext-diff",
           "--no-textconv",
           "#{prior_commit}..#{candidate_commit}"
         ]) do
      {:ok, diff} when diff != "" -> {:ok, diff}
      {:ok, _empty} -> {:error, :empty_delta_diff}
      {:error, _reason} -> {:error, :delta_diff_failed}
    end
  end

  defp committed_delta_files(repo_path, worktree_path, prior_commit, candidate_commit) do
    case lease_git(repo_path, worktree_path, [
           "diff",
           "--name-only",
           "-z",
           "--find-renames",
           "#{prior_commit}..#{candidate_commit}"
         ]) do
      {:ok, output} -> parse_delta_files(output)
      {:error, _reason} -> {:error, :delta_files_failed}
    end
  end

  defp parse_delta_files(output) when is_binary(output) do
    files = String.split(output, <<0>>, trim: true)

    with true <- files != [],
         true <- files == Enum.sort(files),
         true <- files == Enum.uniq(files),
         true <- Enum.all?(files, &valid_delta_file?/1) do
      {:ok, files}
    else
      _other -> {:error, :invalid_delta_files}
    end
  end

  defp parse_delta_files(_), do: {:error, :invalid_delta_files}

  defp valid_delta_file?(path) do
    match?({:ok, _}, Arbor.Actions.Coding.ReviewTree.validate_repo_relative_path(path))
  end

  defp require_delta_range_files(delta_ranges, delta_files) do
    if Enum.all?(Map.keys(delta_ranges), &(&1 in delta_files)),
      do: :ok,
      else: {:error, :delta_ranges_not_in_files}
  end

  defp lease_git(repo_path, worktree_path, args) do
    case lease_git_result(repo_path, worktree_path, args) do
      {:ok, %{exit_code: 0, stdout: output, output_limit_exceeded: false}} -> {:ok, output}
      _other -> {:error, :lease_git_failed}
    end
  end

  defp lease_git_result(repo_path, worktree_path, args) do
    Git.with_storage_authority(repo_path, worktree_path, fn ->
      Git.execute(worktree_path, args)
    end)
  end

  defp validate_selected_test_paths(paths) when is_list(paths) and paths != [] do
    if paths == Enum.sort(paths) and Enum.uniq(paths) == paths and
         Enum.all?(paths, &valid_selected_test_path?/1),
       do: :ok,
       else: {:error, :invalid_selected_test_paths}
  end

  defp validate_selected_test_paths(_), do: {:error, :invalid_selected_test_paths}

  defp valid_selected_test_path?(path) when is_binary(path) do
    path != "" and byte_size(path) <= 512 and String.ends_with?(path, "_test.exs") and
      Path.type(path) != :absolute and path == Path.relative_to(path, ".") and
      not Enum.member?(Path.split(path), "..") and not String.contains?(path, ["\0", "\\"])
  end

  defp valid_selected_test_path?(_), do: false

  defp git_oid(path, revision) do
    case git(path, ["rev-parse", "--verify", revision]) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, {:tree_oid_failed, reason}}
    end
  end

  defp git_test_blobs(worktree_path, candidate_commit, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case git(worktree_path, ["show", "#{candidate_commit}:#{path}"]) do
        {:ok, bytes} ->
          {:cont, {:ok, [%{path: path, blob_sha256: sha256(bytes)} | acc]}}

        {:error, _reason} ->
          {:halt, {:error, :selected_test_not_in_candidate}}
      end
    end)
    |> case do
      {:ok, tests} -> {:ok, Enum.reverse(tests)}
      error -> error
    end
  end

  defp verify_materialized_head(worktree_path, expected_commit) do
    case git(worktree_path, ["rev-parse", "HEAD"]) do
      {:ok, output} when is_binary(output) ->
        if String.trim(output) == expected_commit, do: :ok, else: {:error, :material_head_changed}

      _ ->
        {:error, :material_head_changed}
    end
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp require_exact_commit_hash(commit) do
    if Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, commit) do
      :ok
    else
      {:error, :invalid_base_commit}
    end
  end

  defp require_absent_path(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _other -> {:error, :detached_snapshot_path_exists}
    end
  end

  # Exact HEAD only. Do not rev-parse the request; that would allow reading
  # ancestors or other refs via expressions such as HEAD~1 or branch names.
  defp ensure_commit_is_exact_head(nil, head), do: {:ok, head}
  defp ensure_commit_is_exact_head("", head), do: {:ok, head}

  defp ensure_commit_is_exact_head(requested, head)
       when is_binary(requested) and is_binary(head) do
    if requested == head do
      {:ok, head}
    else
      {:error, :commit_not_head}
    end
  end

  defp ensure_commit_is_exact_head(_, _), do: {:error, :commit_not_head}

  defp generated_branch_name(task) do
    slug =
      task
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 48)
      |> case do
        "" -> "change"
        value -> value
      end

    unique = System.unique_integer([:positive])
    {:ok, "arbor/coding-agent/#{slug}-#{unique}"}
  end

  defp validate_branch_name({:ok, branch}) do
    cond do
      not is_binary(branch) or branch == "" ->
        {:error, "branch_name must be a non-empty string"}

      String.starts_with?(branch, "-") ->
        {:error, "branch_name must not start with '-'"}

      String.contains?(branch, ["..", "@{", "\\"]) ->
        {:error, "branch_name contains a forbidden git ref sequence"}

      String.ends_with?(branch, ["/", "."]) ->
        {:error, "branch_name must not end with '/' or '.'"}

      not Regex.match?(~r/^[A-Za-z0-9._\/-]+$/, branch) ->
        {:error, "branch_name contains unsupported characters"}

      true ->
        {:ok, branch}
    end
  end

  # Ownership is about the *path*, not the branch:
  # - already-present path at our computed location -> :reused
  # - branch already checked out at another worktree -> :reused
  # - pre-existing branch, newly added path -> :owned (branch reuse is fine)
  # - new branch + new path -> :owned
  # `reset?` is independent: reused worktrees / attached branches start clean.
  defp ensure_worktree(repo_root, branch_name, worktree_path, base_commit, require_reused?) do
    cond do
      File.dir?(worktree_path) ->
        with {:ok, path} <- ensure_existing_worktree_branch(worktree_path, branch_name) do
          {:ok, path, :reused, true}
        end

      existing_path = worktree_for_branch(repo_root, branch_name) ->
        {:ok, existing_path, :reused, true}

      branch_exists?(repo_root, branch_name) ->
        if require_reused? do
          {:error, :reused_worktree_vanished}
        else
          with {:ok, path} <- add_existing_branch_worktree(repo_root, branch_name, worktree_path) do
            {:ok, path, :owned, true}
          end
        end

      true ->
        if require_reused? do
          {:error, :reused_worktree_vanished}
        else
          with {:ok, path} <-
                 add_new_branch_worktree(repo_root, branch_name, worktree_path, base_commit) do
            {:ok, path, :owned, false}
          end
        end
    end
  end

  defp ensure_existing_worktree_branch(worktree_path, branch_name) do
    case git(worktree_path, ["branch", "--show-current"]) do
      {:ok, output} ->
        current_branch = String.trim(output)

        if current_branch == branch_name do
          {:ok, worktree_path}
        else
          {:error,
           "existing worktree #{worktree_path} is on #{inspect(current_branch)}, expected #{inspect(branch_name)}"}
        end

      {:error, reason} ->
        {:error, "existing worktree #{worktree_path} is not usable: #{reason}"}
    end
  end

  defp worktree_for_branch(repo_root, branch_name) do
    case Git.worktree_for_branch(repo_root, branch_name) do
      {:ok, path} -> path
      {:error, _reason} -> nil
    end
  end

  defp branch_exists?(repo_root, branch_name) do
    case git(repo_root, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch_name}"]) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp add_existing_branch_worktree(repo_root, branch_name, worktree_path) do
    case System.cmd(
           "git",
           ["-C", repo_root, "worktree", "add", worktree_path, branch_name],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> {:ok, worktree_path}
      {output, _code} -> {:error, "failed to create worktree: #{String.trim(output)}"}
    end
  end

  defp add_new_branch_worktree(repo_root, branch_name, worktree_path, base_commit) do
    case System.cmd(
           "git",
           ["-C", repo_root, "worktree", "add", "-b", branch_name, worktree_path, base_commit],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> {:ok, worktree_path}
      {output, _code} -> {:error, "failed to create worktree: #{String.trim(output)}"}
    end
  end

  # After ensure_worktree, apply reset/clean. If this invocation owns the path
  # and finalization fails, remove path + git registration before returning.
  defp finalize_created_worktree(repo_root, path, ownership, base_commit, reset?, owned_identity) do
    case maybe_reset_reused_worktree(path, base_commit, reset?) do
      :ok ->
        :ok

      {:error, reset_reason} = err ->
        if ownership == :owned and is_map(owned_identity) do
          case remove_owned_worktree(repo_root, path, owned_identity) do
            :ok ->
              err

            {:error, cleanup_reason} ->
              {:error, {:worktree_finalize_cleanup_failed, reset_reason, cleanup_reason}}
          end
        else
          if ownership == :owned do
            {:error, {:worktree_finalize_identity_unavailable, reset_reason}}
          else
            err
          end
        end
    end
  end

  defp capture_owned_removal_identity(_repo_root, _path, _branch_name, :reused),
    do: {:ok, nil}

  defp capture_owned_removal_identity(repo_root, path, branch_name, :owned) do
    with {:ok, removal_identity} <- capture_worktree_removal_identity(repo_root, path),
         %{branch: ^branch_name} <- removal_identity.worktree_registration do
      {:ok, removal_identity}
    else
      %{branch: _other} -> {:error, :worktree_registration_mismatch}
      %{detached: true} -> {:error, :worktree_registration_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp capture_owned_removal_identity(_repo_root, _path, _branch_name, _ownership),
    do: {:error, :invalid_worktree_ownership}

  defp maybe_reset_reused_worktree(_worktree_path, _base_commit, false), do: :ok

  defp maybe_reset_reused_worktree(worktree_path, base_commit, true) do
    with {:ok, _} <- git(worktree_path, ["reset", "--hard", base_commit]),
         {:ok, _} <- git(worktree_path, ["clean", "-fd"]) do
      :ok
    else
      {:error, reason} -> {:error, "failed to reset existing worktree: #{reason}"}
    end
  end

  # Destructive cleanup for owned worktrees created by this invocation only.
  # The caller must provide the identity captured before fallible post-create
  # work; this helper never rebinds authority to the current path.
  @doc false
  @spec remove_owned_worktree(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def remove_owned_worktree(repo_root, worktree_path, identity)
      when is_binary(repo_root) and is_binary(worktree_path) and is_map(identity) do
    Git.remove_worktree(repo_root, worktree_path, identity)
  rescue
    error -> {:error, {:cleanup_raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:cleanup_thrown, kind, reason}}
  end

  defp auth_context_principal_id(context) when is_map(context) do
    case Map.get(context, :auth_context) || Map.get(context, "auth_context") do
      %Arbor.Contracts.Security.AuthContext{principal_id: id}
      when is_binary(id) and id != "" ->
        id

      _ ->
        nil
    end
  end

  defp rev_parse(repo_root, ref) do
    case git(repo_root, ["rev-parse", "--verify", ref]) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, "failed to resolve base_ref #{inspect(ref)}: #{reason}"}
    end
  end

  defp worktree_dirty?(worktree_path) do
    # Command-line policy overrides repository/user config such as
    # status.showUntrackedFiles=no so authoritative workspace inspection never
    # hides useful untracked files.
    case git(worktree_path, ["status", "--porcelain", "--untracked-files=all"]) do
      {:ok, ""} -> false
      {:ok, output} -> String.trim(output) != ""
      {:error, _reason} -> true
    end
  end

  defp head_commit(worktree_path) do
    case git(worktree_path, ["rev-parse", "HEAD"]) do
      {:ok, output} ->
        commit = String.trim(output)
        if commit == "", do: nil, else: commit

      {:error, _reason} ->
        nil
    end
  end

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  defp get_param(map, key) when is_map(map), do: map_value(map, key)

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end

  defp map_value(map, key) when is_map(map) and is_binary(key), do: Map.get(map, key)
  defp map_value(_map, _key), do: nil

  # -- Actions --------------------------------------------------------

  defmodule Acquire do
    @moduledoc """
    Acquire a monitored coding workspace lease (git worktree + branch).

    Resolves the repo root and base commit, validates branch names, chooses a
    deterministic worktree path, reuses/resets an existing matching worktree or
    checked-out branch, and creates a branch/worktree when absent.

    Acquisition is registry-owned: the registry monitors the calling process
    before any git worktree side effect and stores the lease atomically with
    create. Caller-supplied owner PIDs are not authority.

    Returns an opaque JSON-clean `workspace_id` plus path/branch metadata.
    Never returns a PID, monitor, function, or rich struct.
    """

    use Jido.Action,
      name: "coding_workspace_acquire",
      description: "Acquire a monitored coding git worktree lease",
      category: "coding",
      tags: ["coding", "workspace", "worktree", "git", "lease"],
      schema: [
        repo_path: [
          type: :string,
          required: true,
          doc: "Repository root path"
        ],
        base_ref: [
          type: :string,
          doc: "Git ref to branch from (default: HEAD)"
        ],
        branch_name: [
          type: :string,
          doc: "Branch name to create or reuse"
        ],
        worktree_base_dir: [
          type: :string,
          doc: "Directory where the worktree should be created"
        ],
        task: [
          type: :string,
          doc: "Task text used to generate branch_name when omitted"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Coding.Workspace
    alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

    def taint_roles do
      %{
        repo_path: {:control, requires: [:path_traversal]},
        base_ref: {:control, requires: [:command_injection]},
        branch_name: {:control, requires: [:command_injection]},
        worktree_base_dir: {:control, requires: [:path_traversal]},
        task: {:control, requires: [:prompt_injection]}
      }
    end

    def effect_class, do: :local_write

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(%{repo_path: repo_path} = params, context) do
      Actions.emit_started(__MODULE__, %{repo_path: repo_path})
      {task_id, principal_id} = resume_identity(context)

      with {:ok, repo_root} <- Workspace.resolve_repo_root(repo_path),
           {:ok, branch_name} <- Workspace.resolve_branch_name(params),
           {:ok, lease} <-
             WorkspaceLeaseRegistry.acquire(%{
               repo_path: repo_root,
               branch: branch_name,
               base_ref: get_param(params, :base_ref),
               worktree_base_dir: get_param(params, :worktree_base_dir),
               task: get_param(params, :task),
               task_id: task_id,
               principal_id: principal_id
             }) do
        Actions.emit_completed(__MODULE__, %{
          workspace_id: lease.workspace_id,
          ownership: lease.ownership
        })

        {:ok, lease}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    def run(_params, _context), do: {:error, "repo_path is required"}

    defp resume_identity(context) do
      task_id = Workspace.context_task_id(context)
      principal_id = Workspace.context_principal_id(context)

      if nonblank_id?(task_id) and nonblank_id?(principal_id) do
        {task_id, principal_id}
      else
        {nil, nil}
      end
    end

    defp nonblank_id?(id), do: is_binary(id) and String.trim(id) != ""

    defp get_param(map, key) when is_map(map) do
      cond do
        Map.has_key?(map, key) ->
          Map.get(map, key)

        is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
          Map.get(map, Atom.to_string(key))

        true ->
          nil
      end
    end
  end

  defmodule Inspect do
    @moduledoc """
    Inspect an active coding workspace lease when authorized.

    Authority is the live owner process, or matching non-empty `task_id` plus
    the same non-empty principal/agent id. Opaque `workspace_id` alone is not
    sufficient.

    Returns registry metadata plus live workspace inspection: `exists`, `dirty`,
    `head_commit`, `changed_from_base` (dirty OR HEAD differs from the acquired
    `base_commit`), a bounded `fingerprint`, and `turn_progressed` when a
    `baseline_fingerprint` is supplied. PID/ref/function data stay private.
    """

    use Jido.Action,
      name: "coding_workspace_inspect",
      description: "Inspect a coding workspace lease owned by this process or task",
      category: "coding",
      tags: ["coding", "workspace", "worktree", "lease"],
      schema: [
        workspace_id: [
          type: :string,
          required: true,
          doc: "Opaque workspace lease id from acquire"
        ],
        baseline_fingerprint: [
          type: :string,
          required: false,
          doc:
            "Optional pre-turn fingerprint; when present, turn_progressed reports owner-observed progress"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Coding.Workspace
    alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

    def taint_roles do
      %{
        workspace_id: :control,
        baseline_fingerprint: :control
      }
    end

    def effect_class, do: :read

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, context) when is_map(params) do
      workspace_id = map_value(params, :workspace_id)

      if is_binary(workspace_id) and workspace_id != "" do
        Actions.emit_started(__MODULE__, %{workspace_id: workspace_id})

        case WorkspaceLeaseRegistry.inspect_lease(workspace_id, %{
               task_id: Workspace.context_task_id(context),
               principal_id: Workspace.context_principal_id(context)
             }) do
          {:ok, lease} ->
            baseline = map_value(params, :baseline_fingerprint)

            view =
              lease
              |> Map.merge(
                Workspace.inspect_worktree(
                  map_value(lease, :worktree_path),
                  map_value(lease, :base_commit),
                  baseline_fingerprint: baseline
                )
              )

            cond do
              view.exists == true and view.fingerprint_valid != true ->
                Actions.emit_failed(__MODULE__, :workspace_fingerprint_failed)
                {:error, :workspace_fingerprint_failed}

              view.exists == true and view.tree_binding_valid != true ->
                Actions.emit_failed(__MODULE__, :committable_tree_binding_failed)
                {:error, :committable_tree_binding_failed}

              true ->
                Actions.emit_completed(__MODULE__, %{workspace_id: workspace_id})
                {:ok, view}
            end

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, reason}
        end
      else
        {:error, "workspace_id is required"}
      end
    end

    def run(_params, _context), do: {:error, "workspace_id is required"}

    defp map_value(map, key) when is_map(map) and is_atom(key) do
      cond do
        Map.has_key?(map, key) -> Map.get(map, key)
        Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
        true -> nil
      end
    end
  end

  defmodule Release do
    @moduledoc """
    Release a coding workspace lease (idempotent).

    Modes:
    * `retain` - disarm cancellation cleanup and preserve the worktree
    * `remove` - remove only invocation-owned worktrees; reused paths survive

    Authority is the live owner process, or matching non-empty `task_id` plus
    the same non-empty principal/agent id.
    """

    use Jido.Action,
      name: "coding_workspace_release",
      description: "Release a coding workspace lease (retain or remove)",
      category: "coding",
      tags: ["coding", "workspace", "worktree", "lease"],
      schema: [
        workspace_id: [
          type: :string,
          required: true,
          doc: "Opaque workspace lease id from acquire"
        ],
        mode: [
          type: :string,
          default: "retain",
          doc: "Release mode: \"retain\" (default) or \"remove\""
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Coding.Workspace
    alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

    def taint_roles do
      %{
        workspace_id: :control,
        mode: :control
      }
    end

    def effect_class, do: :local_write

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(%{workspace_id: workspace_id} = params, context) when is_binary(workspace_id) do
      mode = Map.get(params, :mode) || Map.get(params, "mode") || "retain"
      Actions.emit_started(__MODULE__, %{workspace_id: workspace_id, mode: mode})

      case WorkspaceLeaseRegistry.release(workspace_id, mode, %{
             task_id: Workspace.context_task_id(context),
             principal_id: Workspace.context_principal_id(context)
           }) do
        {:ok, result} ->
          Actions.emit_completed(__MODULE__, %{
            workspace_id: workspace_id,
            status: result[:status] || result["status"]
          })

          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    def run(_params, _context), do: {:error, "workspace_id is required"}
  end

  defmodule CommittedChange do
    @moduledoc """
    Read the cumulative committed diff and changed-file list for a workspace lease.

    Authority is the live owner process, or matching non-empty `task_id` plus
    the same non-empty principal/agent id. Opaque `workspace_id` alone is not
    sufficient.

    Review material is always the leased range: `base_commit` (recorded at
    acquire) through the current worktree HEAD. Rework that creates multiple
    commits is included. The worktree must be clean before materialization.

    Optional `commit` must equal the current HEAD exactly; non-HEAD values are
    rejected before any git read. Optional `prior_commit` is an exact ancestor
    commit used to add review-cycle delta evidence. Without `prior_commit`, the
    response remains the cumulative JSON-clean `diff`, `files`, `commit_hash`
    (HEAD), and `base_ref` (lease base_commit). Does not mutate the worktree.
    """

    use Jido.Action,
      name: "coding_workspace_committed_change",
      description:
        "Read cumulative committed diff and changed files for a coding workspace lease",
      category: "coding",
      tags: ["coding", "workspace", "worktree", "git", "diff", "lease"],
      schema: [
        workspace_id: [
          type: :string,
          required: true,
          doc: "Opaque workspace lease id from acquire"
        ],
        commit: [
          type: :string,
          doc:
            "Optional exact HEAD commit hash only. Ancestors, other branches, and " <>
              "revision expressions are rejected. Omit to use current HEAD."
        ],
        prior_commit: [
          type: :string,
          doc:
            "Optional exact ancestor commit hash. Adds delta_diff, delta_files, and " <>
              "new-side delta_ranges from this commit to the current HEAD."
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Coding.Workspace
    alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

    def taint_roles do
      %{
        workspace_id: :control,
        commit: {:control, requires: [:command_injection]},
        prior_commit: {:control, requires: [:command_injection]}
      }
    end

    def effect_class, do: :read

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(%{workspace_id: workspace_id} = params, context) when is_binary(workspace_id) do
      Actions.emit_started(__MODULE__, %{workspace_id: workspace_id})

      case WorkspaceLeaseRegistry.inspect_lease(workspace_id, %{
             task_id: Workspace.context_task_id(context),
             principal_id: Workspace.context_principal_id(context)
           }) do
        {:ok, lease} ->
          worktree_path = map_value(lease, :worktree_path)
          repo_path = map_value(lease, :repo_path)
          base_commit = map_value(lease, :base_commit)
          requested_commit = map_value(params, :commit)
          prior_commit = map_value(params, :prior_commit)

          material =
            if is_nil(prior_commit) do
              Workspace.materialize_committed_change(worktree_path, base_commit, requested_commit)
            else
              Workspace.materialize_committed_change_with_delta(
                worktree_path,
                repo_path,
                base_commit,
                requested_commit,
                prior_commit
              )
            end

          case material do
            {:ok, material} ->
              result = %{
                workspace_id: workspace_id,
                commit_hash: material.commit_hash,
                diff: material.diff,
                files: material.files,
                base_ref: material.base_ref,
                branch: map_value(lease, :branch),
                worktree_path: worktree_path
              }

              result =
                if is_nil(prior_commit) do
                  result
                else
                  Map.merge(result, %{
                    prior_candidate_commit: material.prior_candidate_commit,
                    delta_diff: material.delta_diff,
                    delta_files: material.delta_files,
                    delta_ranges: material.delta_ranges
                  })
                end

              Actions.emit_completed(__MODULE__, %{
                workspace_id: workspace_id,
                commit_hash: material.commit_hash,
                files_count: length(material.files)
              })

              {:ok, result}

            {:error, reason} ->
              Actions.emit_failed(__MODULE__, reason)
              {:error, reason}
          end

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    def run(_params, _context), do: {:error, "workspace_id is required"}

    defp map_value(map, key) when is_map(map) and is_atom(key) do
      cond do
        Map.has_key?(map, key) -> Map.get(map, key)
        Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
        true -> nil
      end
    end

    defp map_value(map, key) when is_map(map) and is_binary(key), do: Map.get(map, key)
    defp map_value(_map, _key), do: nil
  end
end
