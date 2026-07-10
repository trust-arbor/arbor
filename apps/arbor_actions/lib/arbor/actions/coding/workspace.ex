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
end
