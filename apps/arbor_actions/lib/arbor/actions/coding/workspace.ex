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
  | `Release` | `arbor://action/coding/workspace/release` |
  | `CommittedChange` | `arbor://action/coding/workspace/committed_change` |
  """

  # -- Shared worktree lifecycle (pure helpers + git side effects) ---

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
  # removed before returning an error.
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

        with {:ok, base_commit} <- rev_parse(repo_root, base_ref),
             {:ok, path, ownership, reset?} <-
               ensure_worktree(repo_root, branch_name, worktree_path, base_commit),
             :ok <- finalize_created_worktree(repo_root, path, ownership, base_commit, reset?) do
          {:ok, path, ownership, base_commit}
        end

      {:error, reason} ->
        {:error, "failed to create worktree base dir #{base_dir}: #{inspect(reason)}"}
    end
  end

  @doc false
  @spec create_detached_worktree(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def create_detached_worktree(repo_root, worktree_path, commit)
      when is_binary(repo_root) and is_binary(worktree_path) and is_binary(commit) do
    with :ok <- require_exact_commit_hash(commit),
         :ok <- require_absent_path(worktree_path),
         {_output, 0} <-
           System.cmd(
             "git",
             ["-C", repo_root, "worktree", "add", "--detach", worktree_path, commit],
             stderr_to_stdout: true
           ),
         {:ok, actual_commit} <- git(worktree_path, ["rev-parse", "HEAD"]),
         true <- String.trim(actual_commit) == commit do
      {:ok, worktree_path}
    else
      {_output, code} when is_integer(code) ->
        remove_detached_worktree(repo_root, worktree_path)
        {:error, :detached_snapshot_create_failed}

      false ->
        remove_detached_worktree(repo_root, worktree_path)
        {:error, :detached_snapshot_commit_mismatch}

      {:error, _reason} = error ->
        remove_detached_worktree(repo_root, worktree_path)
        error
    end
  rescue
    _error ->
      remove_detached_worktree(repo_root, worktree_path)
      {:error, :detached_snapshot_create_failed}
  catch
    :exit, _reason ->
      remove_detached_worktree(repo_root, worktree_path)
      {:error, :detached_snapshot_create_failed}
  end

  def create_detached_worktree(_repo_root, _worktree_path, _commit),
    do: {:error, :invalid_detached_snapshot}

  @doc false
  @spec remove_detached_worktree(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_detached_worktree(repo_root, worktree_path)
      when is_binary(repo_root) and is_binary(worktree_path) do
    _ =
      System.cmd(
        "git",
        ["-C", repo_root, "worktree", "remove", "--force", worktree_path],
        stderr_to_stdout: true
      )

    _ = File.rm_rf(worktree_path)
    _ = System.cmd("git", ["-C", repo_root, "worktree", "prune"], stderr_to_stdout: true)

    case File.lstat(worktree_path) do
      {:error, :enoent} -> :ok
      _other -> {:error, :detached_snapshot_cleanup_failed}
    end
  rescue
    _error -> {:error, :detached_snapshot_cleanup_failed}
  catch
    :exit, _reason -> {:error, :detached_snapshot_cleanup_failed}
  end

  def remove_detached_worktree(_repo_root, _worktree_path),
    do: {:error, :invalid_detached_snapshot}

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
  @spec inspect_worktree(String.t() | nil, String.t() | nil) :: map()
  def inspect_worktree(worktree_path, base_commit) do
    exists = is_binary(worktree_path) and worktree_path != "" and File.dir?(worktree_path)

    if exists do
      dirty = worktree_dirty?(worktree_path)
      head_commit = head_commit(worktree_path)

      changed_from_base =
        dirty or
          (is_binary(head_commit) and is_binary(base_commit) and base_commit != "" and
             head_commit != base_commit)

      %{
        exists: true,
        dirty: dirty,
        head_commit: head_commit,
        changed_from_base: changed_from_base
      }
    else
      %{
        exists: false,
        dirty: false,
        head_commit: nil,
        changed_from_base: false
      }
    end
  end

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
  defp ensure_worktree(repo_root, branch_name, worktree_path, base_commit) do
    cond do
      File.dir?(worktree_path) ->
        with {:ok, path} <- ensure_existing_worktree_branch(worktree_path, branch_name) do
          {:ok, path, :reused, true}
        end

      existing_path = worktree_for_branch(repo_root, branch_name) ->
        {:ok, existing_path, :reused, true}

      branch_exists?(repo_root, branch_name) ->
        with {:ok, path} <- add_existing_branch_worktree(repo_root, branch_name, worktree_path) do
          {:ok, path, :owned, true}
        end

      true ->
        with {:ok, path} <-
               add_new_branch_worktree(repo_root, branch_name, worktree_path, base_commit) do
          {:ok, path, :owned, false}
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
    with {:ok, output} <- git(repo_root, ["worktree", "list", "--porcelain"]) do
      output
      |> String.split("\n\n", trim: true)
      |> Enum.find_value(fn entry ->
        lines = String.split(entry, "\n", trim: true)
        path = line_value(lines, "worktree ")
        branch = line_value(lines, "branch refs/heads/")

        if branch == branch_name, do: path
      end)
    else
      _ -> nil
    end
  end

  defp line_value(lines, prefix) do
    lines
    |> Enum.find_value(fn line ->
      if String.starts_with?(line, prefix) do
        String.replace_prefix(line, prefix, "")
      end
    end)
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
  defp finalize_created_worktree(repo_root, path, ownership, base_commit, reset?) do
    case maybe_reset_reused_worktree(path, base_commit, reset?) do
      :ok ->
        :ok

      {:error, _reason} = err ->
        if ownership == :owned do
          remove_owned_worktree(repo_root, path)
        end

        err
    end
  end

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
  defp remove_owned_worktree(repo_root, worktree_path)
       when is_binary(repo_root) and is_binary(worktree_path) do
    if File.dir?(worktree_path) do
      case System.cmd(
             "git",
             ["-C", repo_root, "worktree", "remove", "--force", worktree_path],
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          :ok

        {_output, _code} ->
          File.rm_rf(worktree_path)
          _ = System.cmd("git", ["-C", repo_root, "worktree", "prune"], stderr_to_stdout: true)
          :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
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
    case git(worktree_path, ["status", "--porcelain"]) do
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

      with {:ok, repo_root} <- Workspace.resolve_repo_root(repo_path),
           {:ok, branch_name} <- Workspace.resolve_branch_name(params),
           {:ok, lease} <-
             WorkspaceLeaseRegistry.acquire(%{
               repo_path: repo_root,
               branch: branch_name,
               base_ref: get_param(params, :base_ref),
               worktree_base_dir: get_param(params, :worktree_base_dir),
               task: get_param(params, :task),
               task_id: Workspace.context_task_id(context),
               principal_id: Workspace.context_principal_id(context)
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
    `head_commit`, and `changed_from_base` (dirty OR HEAD differs from the
    acquired `base_commit`). PID/ref/function data stay private.
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
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Coding.Workspace
    alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

    def taint_roles do
      %{workspace_id: :control}
    end

    def effect_class, do: :read

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(%{workspace_id: workspace_id}, context) when is_binary(workspace_id) do
      Actions.emit_started(__MODULE__, %{workspace_id: workspace_id})

      case WorkspaceLeaseRegistry.inspect_lease(workspace_id, %{
             task_id: Workspace.context_task_id(context),
             principal_id: Workspace.context_principal_id(context)
           }) do
        {:ok, lease} ->
          view =
            lease
            |> Map.merge(
              Workspace.inspect_worktree(
                map_value(lease, :worktree_path),
                map_value(lease, :base_commit)
              )
            )

          Actions.emit_completed(__MODULE__, %{workspace_id: workspace_id})
          {:ok, view}

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
    rejected before any git read. Returns JSON-clean `diff`, `files`,
    `commit_hash` (HEAD), and `base_ref` (lease base_commit). Does not mutate
    the worktree.
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
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Coding.Workspace
    alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

    def taint_roles do
      %{
        workspace_id: :control,
        commit: {:control, requires: [:command_injection]}
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
          base_commit = map_value(lease, :base_commit)
          requested_commit = map_value(params, :commit)

          case Workspace.materialize_committed_change(
                 worktree_path,
                 base_commit,
                 requested_commit
               ) do
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
