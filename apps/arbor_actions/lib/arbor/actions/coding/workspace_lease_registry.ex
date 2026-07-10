defmodule Arbor.Actions.Coding.WorkspaceLeaseRegistry do
  @moduledoc """
  Monitored workspace lease registry owned by `Arbor.Actions`.

  Tracks opaque coding-workspace leases independently of the orchestrator.
  Each lease is scoped to an invoking owner process. Cross-process resume
  requires both a non-empty `task_id` and the same non-empty `principal_id`
  (agent id). Opaque `workspace_id` values are **not** authority.

  ## Acquisition

  `acquire/2` is a registry-owned operation: the live owner PID is taken from
  the GenServer caller, monitored **before** any git worktree side effect,
  and create+register run as one call. Caller-supplied `owner_pid` is never
  authority. If the caller dies while acquisition is in progress, the queued
  DOWN cleans an owned lease once it is stored. Post-create failures remove
  invocation-owned worktrees before returning.

  ## Owner-death cleanup

  The registry monitors the owner process. If it dies before a normal release:

  * **owned** leases - immediately remove only the worktree path created by
    that lease
  * **reused** leases - drop the lease record only; never remove a pre-existing
    worktree

  ## Public views

  All client-facing maps are JSON-clean: no PIDs, monitor refs, functions, or
  rich structs.
  """

  use GenServer

  alias Arbor.Actions.Coding.Workspace

  @type ownership :: :owned | :reused
  @type release_mode :: :retain | :remove

  @type lease :: %{
          workspace_id: String.t(),
          owner_pid: pid(),
          owner_ref: reference(),
          task_id: String.t() | nil,
          principal_id: String.t() | nil,
          repo_path: String.t(),
          worktree_path: String.t(),
          branch: String.t(),
          base_commit: String.t(),
          ownership: ownership(),
          active: boolean(),
          cleanup_armed: boolean()
        }

  @registry_name __MODULE__

  # -- Public API -----------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @registry_name)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Acquire a workspace lease as a registry-owned create+register operation.

  The live owner PID is always the GenServer caller. Required attrs:
  `:repo_path`, `:branch` (or `:branch_name`).

  Optional: `:workspace_id`, `:task_id`, `:principal_id`, `:base_ref`,
  `:worktree_base_dir`, `:task`, and test-only `:create_worktree` (arity-3).

  Rejects `:workspace_id` collisions rather than overwriting an existing lease.
  Rejects a second active lease for the same canonical `repo_path` + `branch`
  with `{:error, :workspace_in_use}` before invoking create.
  """
  @spec acquire(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def acquire(attrs, opts \\ []) when is_map(attrs) do
    call({:acquire, normalize_acquire_attrs(attrs)}, opts)
  end

  @doc """
  Inspect a lease when authorized for the caller.

  Authority: same live owner process (GenServer caller), or matching non-empty
  `task_id` **and** non-empty `principal_id`.
  """
  @spec inspect_lease(String.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_lease(workspace_id, opts \\ %{}) when is_binary(workspace_id) do
    {server_opts, caller} = split_caller_opts(opts)
    call({:inspect, workspace_id, caller}, server_opts)
  end

  @doc """
  Release a lease when authorized.

  Modes:
  * `:retain` / `"retain"` - disarm cancellation cleanup and preserve the worktree
  * `:remove` / `"remove"` - remove only invocation-owned worktrees; reused paths survive

  Idempotent: releasing an unknown/already-released id returns success.
  """
  @spec release(String.t(), release_mode() | String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def release(workspace_id, mode, opts \\ %{}) when is_binary(workspace_id) do
    with {:ok, mode_atom} <- normalize_mode(mode) do
      {server_opts, caller} = split_caller_opts(opts)
      call({:release, workspace_id, mode_atom, caller}, server_opts)
    end
  end

  @doc false
  @spec public_view(map()) :: map()
  def public_view(lease) when is_map(lease) do
    %{
      workspace_id: lease.workspace_id,
      repo_path: lease.repo_path,
      worktree_path: lease.worktree_path,
      branch: lease.branch,
      base_commit: lease.base_commit,
      ownership: ownership_string(lease.ownership),
      active: lease.active == true
    }
  end

  # -- GenServer ------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{leases: %{}, by_ref: %{}}}
  end

  @impl true
  def handle_call({:acquire, attrs}, {owner_pid, _tag}, state) do
    # Owner authority is always the GenServer caller, never a supplied pid.
    case prepare_acquire(attrs, owner_pid, state) do
      {:ok, prepared} ->
        perform_acquire(prepared, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:inspect, workspace_id, caller}, {from_pid, _tag}, state) do
    caller = %{caller | owner_pid: from_pid}

    case fetch_authorized(state, workspace_id, caller) do
      {:ok, lease} ->
        {:reply, {:ok, public_view(lease)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release, workspace_id, mode, caller}, {from_pid, _tag}, state) do
    caller = %{caller | owner_pid: from_pid}

    case Map.fetch(state.leases, workspace_id) do
      :error ->
        {:reply, {:ok, already_released_view(workspace_id)}, state}

      {:ok, lease} ->
        if authorized?(lease, caller) do
          {result, state} = do_release(state, lease, mode)
          {:reply, {:ok, result}, state}
        else
          {:reply, {:error, :not_authorized}, state}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.by_ref, ref) do
      {nil, _by_ref} ->
        {:noreply, state}

      {workspace_id, by_ref} ->
        state = %{state | by_ref: by_ref}

        case Map.pop(state.leases, workspace_id) do
          {nil, _leases} ->
            {:noreply, state}

          {lease, leases} ->
            if lease.cleanup_armed and lease.ownership == :owned do
              remove_owned_worktree(lease.repo_path, lease.worktree_path)
            end

            {:noreply, %{state | leases: leases}}
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Internals ------------------------------------------------------

  defp call(message, opts) do
    server = Keyword.get(opts, :server, @registry_name)

    try do
      GenServer.call(server, message, :infinity)
    catch
      :exit, {:noproc, _} ->
        {:error, :registry_unavailable}

      :exit, {:normal, _} ->
        {:error, :registry_unavailable}
    end
  end

  defp split_caller_opts(opts) when is_list(opts) do
    server_opts = Keyword.take(opts, [:server])

    caller = %{
      # owner_pid is overwritten by the GenServer caller on handle_call
      owner_pid: nil,
      task_id: normalize_id(Keyword.get(opts, :task_id)),
      principal_id: normalize_id(Keyword.get(opts, :principal_id) || Keyword.get(opts, :agent_id))
    }

    {server_opts, caller}
  end

  defp split_caller_opts(opts) when is_map(opts) do
    server =
      case Map.get(opts, :server) || Map.get(opts, "server") do
        nil -> []
        name -> [server: name]
      end

    principal =
      normalize_id(
        Map.get(opts, :principal_id) ||
          Map.get(opts, "principal_id") ||
          Map.get(opts, :agent_id) ||
          Map.get(opts, "agent_id")
      )

    caller = %{
      owner_pid: nil,
      task_id: normalize_id(Map.get(opts, :task_id) || Map.get(opts, "task_id")),
      principal_id: principal
    }

    {server, caller}
  end

  defp normalize_acquire_attrs(attrs) do
    branch =
      Map.get(attrs, :branch) ||
        Map.get(attrs, "branch") ||
        Map.get(attrs, :branch_name) ||
        Map.get(attrs, "branch_name")

    create_worktree =
      Map.get(attrs, :create_worktree) || Map.get(attrs, "create_worktree")

    %{
      workspace_id: Map.get(attrs, :workspace_id) || Map.get(attrs, "workspace_id"),
      task_id: normalize_id(Map.get(attrs, :task_id) || Map.get(attrs, "task_id")),
      principal_id:
        normalize_id(
          Map.get(attrs, :principal_id) ||
            Map.get(attrs, "principal_id") ||
            Map.get(attrs, :agent_id) ||
            Map.get(attrs, "agent_id")
        ),
      repo_path: Map.get(attrs, :repo_path) || Map.get(attrs, "repo_path"),
      branch: branch,
      base_ref: Map.get(attrs, :base_ref) || Map.get(attrs, "base_ref"),
      worktree_base_dir:
        Map.get(attrs, :worktree_base_dir) || Map.get(attrs, "worktree_base_dir"),
      task: Map.get(attrs, :task) || Map.get(attrs, "task"),
      create_worktree: create_worktree
    }
  end

  defp prepare_acquire(attrs, owner_pid, state) do
    with true <- is_pid(owner_pid) || {:error, :invalid_owner_pid},
         :ok <- require_binary(attrs.repo_path, :repo_path),
         :ok <- require_binary(attrs.branch, :branch),
         {:ok, workspace_id} <- resolve_workspace_id(attrs.workspace_id),
         :ok <- ensure_workspace_id_free(state, workspace_id),
         :ok <- ensure_target_free(state, attrs.repo_path, attrs.branch) do
      {:ok,
       %{
         workspace_id: workspace_id,
         owner_pid: owner_pid,
         task_id: attrs.task_id,
         principal_id: attrs.principal_id,
         repo_path: attrs.repo_path,
         branch: attrs.branch,
         create_params: create_params(attrs),
         create_worktree: attrs.create_worktree
       }}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_owner_pid}
    end
  end

  defp create_params(attrs) do
    %{}
    |> put_optional(:base_ref, attrs.base_ref)
    |> put_optional(:worktree_base_dir, attrs.worktree_base_dir)
    |> put_optional(:task, attrs.task)
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, ""), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp resolve_workspace_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp resolve_workspace_id(_), do: {:ok, generate_workspace_id()}

  defp ensure_workspace_id_free(state, workspace_id) do
    if Map.has_key?(state.leases, workspace_id) do
      {:error, :workspace_id_collision}
    else
      :ok
    end
  end

  # One active lease per canonical repo + branch. Checked before create so the
  # second acquire never runs git / test create callbacks.
  defp ensure_target_free(state, repo_path, branch) do
    conflict? =
      Enum.any?(state.leases, fn {_id, lease} ->
        lease.active == true and lease.repo_path == repo_path and lease.branch == branch
      end)

    if conflict?, do: {:error, :workspace_in_use}, else: :ok
  end

  defp perform_acquire(prepared, state) do
    # Monitor before any git side effect so a mid-create owner death queues DOWN.
    owner_ref = Process.monitor(prepared.owner_pid)

    case run_create_worktree(prepared) do
      {:ok, worktree_path, ownership, base_commit} ->
        with {:ok, ownership_atom} <- normalize_ownership(ownership),
             :ok <- require_binary(worktree_path, :worktree_path),
             :ok <- require_binary(base_commit, :base_commit) do
          lease = %{
            workspace_id: prepared.workspace_id,
            owner_pid: prepared.owner_pid,
            owner_ref: owner_ref,
            task_id: prepared.task_id,
            principal_id: prepared.principal_id,
            repo_path: prepared.repo_path,
            worktree_path: worktree_path,
            branch: prepared.branch,
            base_commit: base_commit,
            ownership: ownership_atom,
            active: true,
            cleanup_armed: true
          }

          # Re-check after create (defensive with single GenServer).
          if Map.has_key?(state.leases, lease.workspace_id) do
            Process.demonitor(owner_ref, [:flush])
            cleanup_failed_create(prepared.repo_path, worktree_path, ownership_atom)
            {:reply, {:error, :workspace_id_collision}, state}
          else
            case ensure_target_free(state, lease.repo_path, lease.branch) do
              :ok ->
                state =
                  state
                  |> put_lease(lease)
                  |> put_ref(lease)

                # If the owner already died, DOWN is queued and will clean an
                # owned worktree before any other process can observe a leak.
                {:reply, {:ok, public_view(lease)}, state}

              {:error, reason} ->
                Process.demonitor(owner_ref, [:flush])
                cleanup_failed_create(prepared.repo_path, worktree_path, ownership_atom)
                {:reply, {:error, reason}, state}
            end
          end
        else
          {:error, reason} ->
            Process.demonitor(owner_ref, [:flush])
            cleanup_failed_create(prepared.repo_path, worktree_path, ownership)
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        Process.demonitor(owner_ref, [:flush])
        {:reply, {:error, reason}, state}
    end
  end

  defp run_create_worktree(prepared) do
    try do
      case prepared.create_worktree do
        fun when is_function(fun, 3) ->
          fun.(prepared.repo_path, prepared.branch, prepared.create_params)

        _ ->
          Workspace.create_worktree(prepared.repo_path, prepared.branch, prepared.create_params)
      end
    rescue
      error ->
        {:error, {:create_worktree_raised, Exception.message(error)}}
    catch
      kind, reason ->
        {:error, {:create_worktree_caught, kind, reason}}
    end
  end

  # Post-create registration/finalization failed. Delete only when the callback
  # supplied a valid owned marker; unknown ownership is never deletion authority.
  defp cleanup_failed_create(repo_path, worktree_path, ownership) do
    case normalize_ownership(ownership) do
      {:ok, :owned} -> remove_owned_worktree(repo_path, worktree_path)
      _ -> :ok
    end
  end

  defp put_lease(state, lease) do
    %{state | leases: Map.put(state.leases, lease.workspace_id, lease)}
  end

  defp put_ref(state, lease) do
    %{state | by_ref: Map.put(state.by_ref, lease.owner_ref, lease.workspace_id)}
  end

  defp fetch_authorized(state, workspace_id, caller) do
    case Map.fetch(state.leases, workspace_id) do
      :error ->
        {:error, :not_found}

      {:ok, lease} ->
        if authorized?(lease, caller), do: {:ok, lease}, else: {:error, :not_authorized}
    end
  end

  defp authorized?(lease, caller) do
    owner_match?(lease, caller) or principal_task_match?(lease, caller)
  end

  defp owner_match?(lease, caller) do
    is_pid(caller.owner_pid) and is_pid(lease.owner_pid) and caller.owner_pid == lease.owner_pid and
      Process.alive?(lease.owner_pid)
  end

  # Cross-process resume requires BOTH non-empty task_id and principal_id.
  # Task IDs alone are predictable identifiers, not capabilities.
  defp principal_task_match?(lease, caller) do
    non_empty_id?(lease.task_id) and non_empty_id?(caller.task_id) and
      lease.task_id == caller.task_id and
      non_empty_id?(lease.principal_id) and non_empty_id?(caller.principal_id) and
      lease.principal_id == caller.principal_id
  end

  defp non_empty_id?(id), do: is_binary(id) and id != ""

  defp do_release(state, lease, :retain) do
    state = drop_lease(state, lease)
    # Disarm: do not remove worktree. Demonitor so owner death is a no-op.
    Process.demonitor(lease.owner_ref, [:flush])

    result =
      lease
      |> public_view()
      |> Map.put(:active, false)
      |> Map.put(:status, "retained")

    {result, state}
  end

  defp do_release(state, lease, :remove) do
    state = drop_lease(state, lease)
    Process.demonitor(lease.owner_ref, [:flush])

    if lease.ownership == :owned do
      remove_owned_worktree(lease.repo_path, lease.worktree_path)
    end

    result =
      lease
      |> public_view()
      |> Map.put(:active, false)
      |> Map.put(:status, "removed")

    {result, state}
  end

  defp drop_lease(state, lease) do
    %{
      state
      | leases: Map.delete(state.leases, lease.workspace_id),
        by_ref: Map.delete(state.by_ref, lease.owner_ref)
    }
  end

  defp already_released_view(workspace_id) do
    %{
      workspace_id: workspace_id,
      active: false,
      status: "already_released"
    }
  end

  defp generate_workspace_id do
    "ws_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp normalize_ownership(:owned), do: {:ok, :owned}
  defp normalize_ownership(:reused), do: {:ok, :reused}
  defp normalize_ownership("owned"), do: {:ok, :owned}
  defp normalize_ownership("reused"), do: {:ok, :reused}
  # Historical ProduceReviewableChange token for reused paths.
  defp normalize_ownership(:not_owned), do: {:ok, :reused}
  defp normalize_ownership("not_owned"), do: {:ok, :reused}
  defp normalize_ownership(_), do: {:error, :invalid_ownership}

  defp ownership_string(:owned), do: "owned"
  defp ownership_string(:reused), do: "reused"
  defp ownership_string(other) when is_binary(other), do: other

  defp normalize_mode(:retain), do: {:ok, :retain}
  defp normalize_mode(:remove), do: {:ok, :remove}
  defp normalize_mode("retain"), do: {:ok, :retain}
  defp normalize_mode("remove"), do: {:ok, :remove}

  defp normalize_mode(other),
    do: {:error, "release mode must be \"retain\" or \"remove\", got: #{inspect(other)}"}

  defp normalize_id(id) when is_binary(id) and id != "", do: id
  defp normalize_id(_), do: nil

  defp require_binary(value, _field) when is_binary(value) and value != "", do: :ok
  defp require_binary(_value, field), do: {:error, {:invalid, field}}

  # Destructive: only owner-death cleanup and explicit remove-of-owned may call this.
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
          # Force-remove even if git worktree metadata is stale (dirty cancel).
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
end
