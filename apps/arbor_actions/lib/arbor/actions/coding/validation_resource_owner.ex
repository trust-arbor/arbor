defmodule Arbor.Actions.Coding.ValidationResourceOwner do
  @moduledoc false

  use GenServer

  alias Arbor.Actions.Coding.BlobManifest
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Mix, as: MixAction

  @supervisor Arbor.Actions.Coding.ValidationResourceSupervisor
  @cleanup_retry_initial_ms 50
  @cleanup_retry_max_ms 2_000
  @default_cleanup_retry_limit 8
  @max_cleanup_retry_limit 32
  @supervisor_cleanup_budget_ms 20_000
  @cleanup_attempted_key {__MODULE__, :bounded_cleanup_attempted}

  @doc false
  def supervisor_name, do: @supervisor

  @doc false
  def supervisor_child_spec do
    %{
      id: @supervisor,
      start:
        {DynamicSupervisor, :start_link,
         [[name: @supervisor, strategy: :one_for_one, max_restarts: 100, max_seconds: 1]]},
      type: :supervisor
    }
  end

  @doc false
  def start(supervisor, opts) when is_list(opts) do
    spec = %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 30_000,
      type: :worker
    }

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, pid} ->
        case GenServer.call(pid, :root_result, :infinity) do
          {:ok, identity} -> {:ok, pid, identity}
          {:error, {:cleanup_retained, identity}} -> {:error, {:cleanup_retained, pid, identity}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, _reason -> {:error, :validation_resource_owner_unavailable}
  end

  @doc false
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  def create_candidate(owner, commit), do: call(owner, {:create_candidate, commit})

  @doc false
  def create_committable_candidate(owner, meta) when is_map(meta),
    do: call(owner, {:create_committable_candidate, meta})

  @doc false
  def recapture_committable_candidate(owner, expected_oid, opts \\ [])

  def recapture_committable_candidate(owner, expected_oid, opts) when is_list(opts),
    do: call(owner, {:recapture_committable_candidate, expected_oid, opts})

  @doc false
  def bind_committable_candidate(owner, expected_oid, opts \\ [])

  def bind_committable_candidate(owner, expected_oid, opts) when is_list(opts),
    do: call(owner, {:bind_committable_candidate, expected_oid, opts})

  @doc false
  def create_base(owner, commit), do: call(owner, {:create_base, commit})

  @doc false
  def acquire_dependency(owner, deadline_ms),
    do: call(owner, {:acquire_dependency, deadline_ms})

  @doc false
  def release_dependency(owner), do: call(owner, :release_dependency)

  @doc false
  def cleanup_actions(owner), do: call(owner, :cleanup_actions)

  @doc false
  def stop(owner), do: call(owner, :stop)

  defp call(owner, message) when is_pid(owner) do
    GenServer.call(owner, message, :infinity)
  catch
    :exit, _reason -> {:error, :validation_resource_owner_unavailable}
  end

  defp call(_owner, _message), do: {:error, :validation_resource_owner_unavailable}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    registry_pid = Keyword.fetch!(opts, :registry_pid)
    root_path = Keyword.fetch!(opts, :root_path)

    state = %{
      supervisor_pid: validation_resource_supervisor_pid(),
      registry_pid: registry_pid,
      registry_ref: Process.monitor(registry_pid),
      repo_path: Keyword.fetch!(opts, :repo_path),
      root_path: root_path,
      root_identity: nil,
      candidate_path: Keyword.fetch!(opts, :candidate_path),
      candidate_commit: Keyword.get(opts, :candidate_commit),
      candidate_identity: nil,
      base_path: Keyword.fetch!(opts, :base_path),
      base_identity: nil,
      materializer: Keyword.fetch!(opts, :materializer),
      dependency_lease: nil,
      dependency_root_path: nil,
      cleanup_retry_ms: @cleanup_retry_initial_ms,
      cleanup_retry_count: 0,
      cleanup_retry_limit: cleanup_retry_limit(opts),
      cleanup_dormant: false,
      cleanup_timer: nil,
      root_status: :starting,
      snapshot_objects: nil,
      snapshot_index: nil,
      snapshot_dest: nil,
      snapshot_tree_oid: nil,
      snapshot_head: nil
    }

    case Arbor.Shell.create_private_owned_tree(root_path) do
      {:ok, identity} ->
        {:ok, %{state | root_identity: identity, root_status: :ready}}

      {:error, {:owned_tree_cleanup_retained, _reason, %{path: ^root_path, identity: identity}}} ->
        {:ok, %{state | root_identity: identity, root_status: :cleanup_retained}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(_request, {caller, _tag}, %{registry_pid: registry_pid} = state)
      when caller != registry_pid do
    {:reply, {:error, :foreign_caller}, state}
  end

  def handle_call(:root_result, _from, %{root_status: :ready} = state) do
    {:reply, {:ok, state.root_identity}, state}
  end

  def handle_call(:root_result, _from, %{root_status: :cleanup_retained} = state) do
    {:reply, {:error, {:cleanup_retained, state.root_identity}}, state}
  end

  def handle_call({:create_committable_candidate, meta}, _from, state) when is_map(meta) do
    case materialize_committable_candidate(state, meta) do
      {:ok, tree_oid, next} -> {:reply, {:ok, tree_oid}, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:recapture_committable_candidate, expected_oid, opts}, _from, state)
      when is_list(opts) do
    case recapture_held_tree(state, expected_oid, opts) do
      {:ok, _binding} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:bind_committable_candidate, expected_oid, opts}, _from, state)
      when is_list(opts) do
    case recapture_held_tree(state, expected_oid, opts) do
      {:ok, binding} -> {:reply, {:ok, binding}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:create_candidate, _commit}, _from, %{candidate_commit: nil} = state) do
    {:reply, {:ok, nil}, state}
  end

  def handle_call({:create_candidate, commit}, _from, state) when is_binary(commit) do
    case Workspace.create_detached_worktree_with_identity(
           state.repo_path,
           state.candidate_path,
           commit
         ) do
      {:ok, %{path: path, removal_identity: identity}} when path == state.candidate_path ->
        {:reply, {:ok, identity}, %{state | candidate_identity: identity}}

      {:ok, _unexpected} ->
        {:reply, {:error, :detached_snapshot_path_mismatch}, state}

      {:error, {:detached_snapshot_cleanup_retained, reason, cleanup_reason, removal_identity}} ->
        next = %{state | candidate_identity: removal_identity}

        {:reply,
         {:error, {:detached_snapshot_cleanup_retained, reason, cleanup_reason},
          removal_identity}, next}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:create_base, commit}, _from, state) when is_binary(commit) do
    case Workspace.create_detached_worktree_with_identity(
           state.repo_path,
           state.base_path,
           commit
         ) do
      {:ok, %{path: path, removal_identity: identity}} when path == state.base_path ->
        {:reply, {:ok, identity}, %{state | base_identity: identity}}

      {:ok, _unexpected} ->
        {:reply, {:error, :detached_snapshot_path_mismatch}, state}

      {:error, {:detached_snapshot_cleanup_retained, reason, cleanup_reason, removal_identity}} ->
        next = %{state | base_identity: removal_identity}

        {:reply,
         {:error, {:detached_snapshot_cleanup_retained, reason, cleanup_reason},
          removal_identity}, next}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:acquire_dependency, deadline_ms}, _from, %{dependency_lease: nil} = state)
      when is_integer(deadline_ms) and deadline_ms > 0 do
    case acquire_dependency_lease(state.materializer, deadline_ms) do
      {:ok, lease, view, cleanup_locator} ->
        {:reply, {:ok, view, cleanup_locator},
         %{
           state
           | dependency_lease: lease,
             dependency_root_path: cleanup_locator.root_path
         }}

      {:error, {:cleanup_required, reason, lease, cleanup_locator}} ->
        {:reply, {:error, {:cleanup_required, reason, cleanup_locator}},
         %{
           state
           | dependency_lease: lease,
             dependency_root_path: cleanup_locator.root_path
         }}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:acquire_dependency, _deadline_ms}, _from, state) do
    {:reply, {:error, :dependency_baseline_already_acquired}, state}
  end

  def handle_call(:release_dependency, _from, state) do
    case release_dependency_lease(state.materializer, state.dependency_lease, []) do
      :ok -> {:reply, :ok, %{state | dependency_lease: nil}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:cleanup_actions, _from, state) do
    case do_cleanup_actions(state) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  def handle_call(:stop, _from, state) do
    if actions_absent?(state) and is_nil(state.dependency_lease) do
      Process.put(@cleanup_attempted_key, true)
      {:stop, :normal, :ok, cancel_cleanup_timer(state)}
    else
      {:reply, {:error, :validation_resource_still_owned}, state}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{registry_ref: ref, registry_pid: pid} = state
      ) do
    cleanup_after_registry_exit(%{state | registry_ref: nil})
  end

  def handle_info(:cleanup_retry, state) do
    cleanup_after_registry_exit(%{state | cleanup_timer: nil})
  end

  def handle_info({:EXIT, port, _reason}, state) when is_port(port) do
    {:noreply, state}
  end

  def handle_info(
        {:EXIT, supervisor_pid, reason},
        %{supervisor_pid: supervisor_pid} = state
      ) do
    deadline_ms = System.monotonic_time(:millisecond) + @supervisor_cleanup_budget_ms
    Process.put(@cleanup_attempted_key, true)

    case cleanup_all(state, deadline_ms: deadline_ms) do
      {:ok, next} -> {:stop, reason, cancel_cleanup_timer(next)}
      {:error, next} -> {:stop, reason, cancel_cleanup_timer(next)}
    end
  end

  def handle_info({:EXIT, _from, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    unless Process.get(@cleanup_attempted_key, false) do
      Process.put(@cleanup_attempted_key, true)
      deadline_ms = System.monotonic_time(:millisecond) + @supervisor_cleanup_budget_ms
      _ = cleanup_all(state, deadline_ms: deadline_ms)
    end

    :ok
  end

  @impl true
  def format_status(status) when is_map(status) do
    state = Map.get(status, :state, %{})

    redacted = %{
      root_status: Map.get(state, :root_status, :unknown),
      candidate_owned: is_map(Map.get(state, :candidate_identity)),
      base_owned: is_map(Map.get(state, :base_identity)),
      dependency_lease_active: not is_nil(Map.get(state, :dependency_lease)),
      cleanup_pending: not is_nil(Map.get(state, :cleanup_timer)),
      cleanup_dormant: Map.get(state, :cleanup_dormant, false)
    }

    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, redacted)
    |> Map.update(:log, :redacted, fn _log -> :redacted end)
    |> Map.update(:reason, :redacted, fn _reason -> :redacted end)
  end

  def format_status(status), do: status

  defp cleanup_after_registry_exit(state) do
    case cleanup_all(state) do
      {:ok, next} ->
        Process.put(@cleanup_attempted_key, true)
        {:stop, :normal, cancel_cleanup_timer(next)}

      {:error, next} ->
        {:noreply, schedule_cleanup_retry(next)}
    end
  end

  defp cleanup_all(state, opts \\ []) do
    with {:ok, state} <- do_cleanup_actions(state, opts),
         :ok <- release_dependency_lease(state.materializer, state.dependency_lease, opts) do
      {:ok, %{state | dependency_lease: nil}}
    else
      {:error, _reason, next} -> {:error, next}
      {:error, _reason} -> {:error, state}
    end
  end

  defp do_cleanup_actions(state, opts \\ []) do
    with :ok <- cleanup_candidate(state, opts),
         :ok <- cleanup_base(state, opts),
         :ok <- cleanup_root(state, opts) do
      {:ok,
       %{
         state
         | candidate_identity: nil,
           base_identity: nil,
           root_identity: nil,
           root_status: :removed
       }}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp cleanup_candidate(%{candidate_commit: nil}, _opts), do: :ok

  defp cleanup_candidate(state, opts) do
    with {:ok, cleanup_opts} <- workspace_cleanup_opts(opts) do
      remove_detached_worktree(
        state.repo_path,
        state.candidate_path,
        state.candidate_identity,
        cleanup_opts
      )
    end
  end

  defp cleanup_base(state, opts) do
    with {:ok, cleanup_opts} <- workspace_cleanup_opts(opts) do
      remove_detached_worktree(
        state.repo_path,
        state.base_path,
        state.base_identity,
        cleanup_opts
      )
    end
  end

  defp cleanup_root(%{root_identity: identity}, opts) when is_map(identity) do
    with {:ok, cleanup_opts} <- tree_cleanup_opts(opts) do
      case cleanup_opts do
        [] -> Arbor.Shell.remove_owned_tree(identity)
        _bounded -> Arbor.Shell.remove_owned_tree(identity, cleanup_opts)
      end
    end
  end

  defp cleanup_root(%{root_path: path}, _opts) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _other -> {:error, :validation_root_cleanup_identity_required}
    end
  end

  defp remove_detached_worktree(repo_path, worktree_path, identity, []) do
    Workspace.remove_detached_worktree(repo_path, worktree_path, identity)
  end

  defp remove_detached_worktree(repo_path, worktree_path, identity, cleanup_opts) do
    Workspace.remove_detached_worktree(repo_path, worktree_path, identity, cleanup_opts)
  end

  defp workspace_cleanup_opts(opts) do
    case remaining_cleanup_timeout(opts, 30_000) do
      {:ok, nil} -> {:ok, []}
      {:ok, timeout_ms} -> {:ok, [timeout_ms: timeout_ms]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tree_cleanup_opts(opts) do
    case remaining_cleanup_timeout(opts, 10_000) do
      {:ok, nil} -> {:ok, []}
      {:ok, timeout_ms} -> {:ok, [timeout_ms: timeout_ms]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remaining_cleanup_timeout(opts, maximum_ms) do
    case Keyword.get(opts, :deadline_ms) do
      nil ->
        {:ok, nil}

      deadline_ms when is_integer(deadline_ms) ->
        remaining = deadline_ms - System.monotonic_time(:millisecond)

        if remaining > 0,
          do: {:ok, min(remaining, maximum_ms)},
          else: {:error, :validation_resource_cleanup_deadline_exceeded}

      _other ->
        {:error, :invalid_validation_resource_cleanup_deadline}
    end
  end

  defp actions_absent?(state) do
    match?({:error, :enoent}, File.lstat(state.root_path)) and
      match?(
        {:ok, nil},
        Arbor.Actions.Git.worktree_registration(state.repo_path, state.base_path)
      ) and
      (is_nil(state.candidate_commit) or
         match?(
           {:ok, nil},
           Arbor.Actions.Git.worktree_registration(state.repo_path, state.candidate_path)
         ))
  end

  defp acquire_dependency_lease(materializer, deadline_ms) when is_atom(materializer) do
    try do
      case materializer.acquire_linux_dependency_baseline_lease_with_cleanup_locator(deadline_ms) do
        {:ok, lease, view, cleanup_locator} when not is_nil(lease) ->
          with {:ok, cleanup_locator} <- admit_cleanup_locator(cleanup_locator) do
            {:ok, lease, view, cleanup_locator}
          end

        {:error, {:cleanup_required, reason, lease, cleanup_locator}} when not is_nil(lease) ->
          with {:ok, cleanup_locator} <- admit_cleanup_locator(cleanup_locator) do
            {:error, {:cleanup_required, reason, lease, cleanup_locator}}
          end

        {:error, reason} ->
          {:error, reason}

        _other ->
          {:error, :dependency_baseline_acquire_failed}
      end
    rescue
      _error -> {:error, :dependency_baseline_acquire_failed}
    catch
      _kind, _reason -> {:error, :dependency_baseline_acquire_failed}
    end
  end

  defp admit_cleanup_locator(%{root_path: root_path} = locator)
       when map_size(locator) == 1 and is_binary(root_path) and root_path != "" do
    if Path.type(root_path) == :absolute,
      do: {:ok, locator},
      else: {:error, :invalid_dependency_cleanup_locator}
  end

  defp admit_cleanup_locator(%{"root_path" => root_path} = locator)
       when map_size(locator) == 1 and is_binary(root_path) and root_path != "" do
    if Path.type(root_path) == :absolute,
      do: {:ok, %{root_path: root_path}},
      else: {:error, :invalid_dependency_cleanup_locator}
  end

  defp admit_cleanup_locator(_locator),
    do: {:error, :invalid_dependency_cleanup_locator}

  defp release_dependency_lease(_materializer, nil, _opts), do: :ok

  defp release_dependency_lease(materializer, lease, opts) when is_atom(materializer) do
    try do
      result =
        case remaining_cleanup_timeout(opts, 3_600_000) do
          {:ok, nil} ->
            materializer.release_linux_dependency_baseline_lease(lease)

          {:ok, timeout_ms} ->
            materializer.release_linux_dependency_baseline_lease(lease, timeout_ms)

          {:error, reason} ->
            {:error, reason}
        end

      case result do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        _other -> {:error, :dependency_baseline_release_failed}
      end
    rescue
      _error -> {:error, :dependency_baseline_release_failed}
    catch
      _kind, _reason -> {:error, :dependency_baseline_release_failed}
    end
  end

  defp release_dependency_lease(_materializer, _lease, _opts),
    do: {:error, :dependency_baseline_release_failed}

  defp schedule_cleanup_retry(state) do
    count = Map.get(state, :cleanup_retry_count, 0)
    limit = Map.get(state, :cleanup_retry_limit, @default_cleanup_retry_limit)

    if count >= limit do
      %{state | cleanup_timer: nil, cleanup_dormant: true}
    else
      delay = state.cleanup_retry_ms
      timer = Process.send_after(self(), :cleanup_retry, delay)

      %{
        state
        | cleanup_timer: timer,
          cleanup_retry_ms: min(delay * 2, @cleanup_retry_max_ms),
          cleanup_retry_count: count + 1,
          cleanup_dormant: false
      }
    end
  end

  defp cancel_cleanup_timer(%{cleanup_timer: nil} = state), do: state

  defp cancel_cleanup_timer(state) do
    _ = Process.cancel_timer(state.cleanup_timer)
    %{state | cleanup_timer: nil}
  end

  defp validation_resource_supervisor_pid do
    case Process.get(:"$ancestors") do
      [pid | _rest] when is_pid(pid) -> pid
      [name | _rest] when is_atom(name) -> Process.whereis(name)
      _other -> nil
    end
  end

  defp cleanup_retry_limit(opts) do
    case Keyword.get(opts, :cleanup_retry_limit) do
      limit when is_integer(limit) and limit >= 0 and limit <= @max_cleanup_retry_limit -> limit
      _other -> @default_cleanup_retry_limit
    end
  end

  defp materialize_committable_candidate(state, meta) do
    source = Map.get(meta, :source_worktree) || Map.get(meta, "source_worktree")
    expected = Map.get(meta, :expected_tree_oid) || Map.get(meta, "expected_tree_oid")
    head = Map.get(meta, :candidate_head) || Map.get(meta, "candidate_head")
    dest = state.candidate_path
    objects = Path.join(state.root_path, "candidate-objects")
    index = Path.join(state.root_path, "candidate.index")

    admitted = Map.get(meta, :blob_manifest) || Map.get(meta, "blob_manifest")

    with true <- is_binary(source) and source != "",
         {:ok, entries} <- BlobManifest.canonical_entries(admitted),
         :ok <- init_owner_git(objects),
         :ok <- stage_tree_entries(objects, index, source, entries),
         {:ok, tree_oid} <- write_owner_tree(objects, index),
         :ok <- match_expected_tree(tree_oid, expected),
         :ok <- File.mkdir_p(dest),
         :ok <- checkout_held_tree(objects, index, dest) do
      next = %{
        state
        | snapshot_objects: objects,
          snapshot_index: index,
          snapshot_tree_oid: tree_oid,
          snapshot_dest: dest,
          snapshot_head: if(is_binary(head) and head != "", do: head, else: nil)
      }

      {:ok, tree_oid, next}
    else
      false -> {:error, :invalid_committable_snapshot}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :committable_snapshot_failed}
    end
  end

  defp recapture_held_tree(state, expected_oid, opts) when is_list(opts) do
    objects = Map.get(state, :snapshot_objects)
    index = Map.get(state, :snapshot_index)
    dest = Map.get(state, :snapshot_dest) || state.candidate_path
    held = Map.get(state, :snapshot_tree_oid)

    with true <- is_binary(expected_oid) and expected_oid != "",
         true <- is_binary(objects) and objects != "",
         true <- is_binary(index) and index != "",
         true <- is_binary(dest) and dest != "",
         true <- is_binary(held) and held != "",
         :ok <- match_expected_tree(held, expected_oid),
         {:ok, held_entries} <- verify_destination_against_held(state, dest_budget(opts)),
         :ok <- read_held_tree(objects, index, held),
         :ok <- checkout_held_tree(objects, index, dest) do
      {:ok, snapshot_binding(state, held_entries)}
    else
      false -> {:error, :admitted_tree_mismatch}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :admitted_tree_mismatch}
    end
  end

  defp snapshot_binding(state, held_entries) when is_list(held_entries) do
    %{
      head: Map.get(state, :snapshot_head),
      tree_oid: Map.get(state, :snapshot_tree_oid),
      paths: held_entries |> Enum.map(& &1.path) |> Enum.sort()
    }
  end

  defp match_expected_tree(_actual, nil), do: :ok
  defp match_expected_tree(actual, actual) when is_binary(actual), do: :ok
  defp match_expected_tree(_actual, _expected), do: {:error, :admitted_tree_mismatch}

  defp init_owner_git(objects) do
    case File.mkdir_p(objects) do
      :ok ->
        case git(["--git-dir", objects, "init", "--bare"]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:snapshot_git_init_failed, reason}}
    end
  end

  defp stage_tree_entries(objects, index, source, entries) do
    _ = File.rm(index)

    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      from = Path.join(source, entry.path)

      case hash_source_blob(objects, from, entry.mode) do
        {:ok, oid} ->
          if oid == entry.oid do
            case git(
                   [
                     "--git-dir",
                     objects,
                     "update-index",
                     "--add",
                     "--cacheinfo",
                     "#{entry.mode},#{oid},#{entry.path}"
                   ],
                   [{"GIT_INDEX_FILE", index}]
                 ) do
              {:ok, _} -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          else
            {:halt, {:error, :admitted_tree_mismatch}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp hash_source_blob(objects, path, "120000") do
    case File.read_link(path) do
      {:ok, target} ->
        tmp = Path.join(Path.dirname(objects), "symlink-blob")

        with :ok <- File.write(tmp, target),
             {:ok, oid} <-
               git(["--git-dir", objects, "hash-object", "-w", "--no-filters", "--", tmp]) do
          _ = File.rm(tmp)
          {:ok, oid}
        else
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:snapshot_symlink_unreadable, reason}}
    end
  end

  defp hash_source_blob(objects, path, _mode) do
    git(["--git-dir", objects, "hash-object", "-w", "--no-filters", "--", path])
  end

  defp write_owner_tree(objects, index) do
    with {:ok, tree} <-
           git(["--git-dir", objects, "write-tree"], [{"GIT_INDEX_FILE", index}]) do
      oid = String.trim(tree)

      if Regex.match?(~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, oid),
        do: {:ok, oid},
        else: {:error, :committable_snapshot_failed}
    end
  end

  defp read_held_tree(objects, index, tree_oid) when is_binary(tree_oid) do
    case git(
           ["--git-dir", objects, "read-tree", tree_oid],
           [{"GIT_INDEX_FILE", index}]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_held_tree(_objects, _index, _tree_oid), do: {:error, :invalid_committable_snapshot}

  defp checkout_held_tree(objects, index, dest) when is_binary(dest) and dest != "" do
    dest = Path.expand(dest)

    case git(
           ["--git-dir", objects, "--work-tree", dest, "checkout-index", "-a", "-f"],
           [{"GIT_INDEX_FILE", index}]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp checkout_held_tree(_objects, _index, _dest), do: {:error, :admitted_tree_mismatch}

  defp dest_budget(opts) when is_list(opts) do
    bounds = MixAction.snapshot_bounds()

    %{
      entries: 0,
      bytes: 0,
      max_entries: clamp_bound(Keyword.get(opts, :max_entries), bounds.max_entries),
      max_bytes: clamp_bound(Keyword.get(opts, :max_bytes), bounds.max_bytes),
      max_depth: clamp_bound(Keyword.get(opts, :max_depth), bounds.max_depth)
    }
  end

  defp clamp_bound(value, ceiling)
       when is_integer(value) and is_integer(ceiling) and value >= 0 and ceiling >= 0,
       do: min(value, ceiling)

  defp clamp_bound(_value, ceiling) when is_integer(ceiling) and ceiling >= 0, do: ceiling

  defp verify_destination_against_held(state, budget) when is_map(budget) do
    objects = Map.get(state, :snapshot_objects)
    dest = Map.get(state, :snapshot_dest) || state.candidate_path
    held = Map.get(state, :snapshot_tree_oid)

    with {:ok, listing} <-
           git(["--git-dir", objects, "ls-tree", "-r", "-z", held], [], raw: true),
         {:ok, held_entries} <- BlobManifest.parse_ls_tree_z(listing),
         {:ok, dest_blobs, extra_dirs?} <-
           walk_destination(dest, objects, budget, held_ancestor_dirs(held_entries)),
         :ok <- compare_dest_to_held(dest_blobs, extra_dirs?, held_entries) do
      {:ok, held_entries}
    end
  end

  defp held_ancestor_dirs(entries) when is_list(entries) do
    Enum.reduce(entries, MapSet.new(), fn %{path: path}, acc ->
      MapSet.union(acc, MapSet.new(ancestor_dirs(path)))
    end)
  end

  defp ancestor_dirs(path) when is_binary(path) do
    parts = Path.split(path)

    if length(parts) < 2 do
      []
    else
      Enum.map(1..(length(parts) - 1), fn n ->
        parts |> Enum.take(n) |> Enum.join("/")
      end)
    end
  end

  defp walk_destination(dest, objects, budget, ancestors)
       when is_binary(dest) and dest != "" do
    case File.lstat(dest, time: :posix) do
      {:ok, %File.Stat{type: :directory}} ->
        case walk_dest_dir(dest, dest, "", objects, budget, ancestors, %{}, false) do
          {:ok, _budget, blobs, extra_dirs?} -> {:ok, blobs, extra_dirs?}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %File.Stat{}} ->
        {:error, :validation_tree_mutated}

      {:error, _reason} ->
        {:error, :validation_tree_mutated}
    end
  end

  defp walk_destination(_dest, _objects, _budget, _ancestors),
    do: {:error, :validation_tree_mutated}

  defp walk_dest_dir(root, abs, rel, objects, budget, ancestors, blobs, extra_dirs?) do
    case File.ls(abs) do
      {:ok, names} ->
        reduce_dest_entries(names, root, abs, rel, objects, budget, ancestors, blobs, extra_dirs?)

      {:error, reason} ->
        {:error, {:snapshot_dest_unreadable, reason}}
    end
  end

  defp reduce_dest_entries(
         [],
         _root,
         _abs,
         _rel,
         _objects,
         budget,
         _ancestors,
         blobs,
         extra_dirs?
       ) do
    {:ok, budget, blobs, extra_dirs?}
  end

  defp reduce_dest_entries(
         [name | rest],
         root,
         abs,
         rel,
         objects,
         budget,
         ancestors,
         blobs,
         extra_dirs?
       ) do
    case visit_dest_entry(root, abs, rel, name, objects, budget, ancestors, blobs, extra_dirs?) do
      {:ok, budget, blobs, extra_dirs?} ->
        reduce_dest_entries(rest, root, abs, rel, objects, budget, ancestors, blobs, extra_dirs?)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp visit_dest_entry(root, abs, rel, name, objects, budget, ancestors, blobs, extra_dirs?) do
    with true <- safe_dest_name?(name),
         child_rel = join_rel(rel, name),
         child_abs = abs <> "/" <> name,
         true <- within_dest?(root, child_abs),
         {:ok, %File.Stat{} = stat} <- File.lstat(child_abs, time: :posix),
         {:ok, budget} <- account_dest_entry(budget, child_rel, stat) do
      case stat.type do
        :directory ->
          extra_dirs? = extra_dirs? or not MapSet.member?(ancestors, child_rel)

          walk_dest_dir(
            root,
            child_abs,
            child_rel,
            objects,
            budget,
            ancestors,
            blobs,
            extra_dirs?
          )

        :regular ->
          hash_dest_regular(objects, child_abs, child_rel, budget, blobs, extra_dirs?, stat)

        :symlink ->
          hash_dest_symlink(objects, child_abs, child_rel, budget, blobs, extra_dirs?)

        _other ->
          {:error, :validation_tree_mutated}
      end
    else
      false -> {:error, :validation_tree_mutated}
      {:error, :enoent} -> {:error, :validation_tree_mutated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp hash_dest_regular(objects, abs, rel, budget, blobs, extra_dirs?, stat) do
    case hash_destination_blob(objects, abs, "100644") do
      {:ok, oid} ->
        mode = if executable_mode?(stat.mode), do: "100755", else: "100644"
        {:ok, budget, Map.put(blobs, rel, {mode, oid}), extra_dirs?}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp hash_dest_symlink(objects, abs, rel, budget, blobs, extra_dirs?) do
    case File.read_link(abs) do
      {:ok, target} when is_binary(target) ->
        next_bytes = budget.bytes + byte_size(target)

        cond do
          next_bytes > budget.max_bytes ->
            {:error, :tree_binding_bounds_exceeded}

          true ->
            case hash_destination_blob(objects, abs, "120000") do
              {:ok, oid} ->
                {:ok, %{budget | bytes: next_bytes}, Map.put(blobs, rel, {"120000", oid}),
                 extra_dirs?}

              {:error, reason} ->
                {:error, reason}
            end
        end

      {:error, _reason} ->
        {:error, :validation_tree_mutated}

      _other ->
        {:error, :validation_tree_mutated}
    end
  end

  defp compare_dest_to_held(dest_blobs, extra_dirs?, held_entries)
       when is_map(dest_blobs) and is_boolean(extra_dirs?) and is_list(held_entries) do
    held_map = Map.new(held_entries, &{&1.path, {&1.mode, &1.oid}})
    dest_paths = MapSet.new(Map.keys(dest_blobs))
    held_paths = MapSet.new(Map.keys(held_map))

    mismatched? =
      extra_dirs? or dest_paths != held_paths or
        Enum.any?(held_map, fn {path, held} -> Map.get(dest_blobs, path) != held end)

    if mismatched?, do: {:error, :validation_tree_mutated}, else: :ok
  end

  defp compare_dest_to_held(_dest_blobs, _extra_dirs?, _held_entries),
    do: {:error, :validation_tree_mutated}

  defp account_dest_entry(budget, rel, %File.Stat{} = stat) do
    next = budget.entries + 1
    file_bytes = if stat.type == :regular, do: max(stat.size || 0, 0), else: 0
    next_bytes = budget.bytes + file_bytes

    cond do
      next > budget.max_entries ->
        {:error, :tree_binding_bounds_exceeded}

      match?({:error, _}, check_path_depth(rel, budget.max_depth)) ->
        {:error, :tree_binding_bounds_exceeded}

      next_bytes > budget.max_bytes ->
        {:error, :tree_binding_bounds_exceeded}

      true ->
        {:ok, %{budget | entries: next, bytes: next_bytes}}
    end
  end

  defp check_path_depth(path, max_depth)
       when is_binary(path) and is_integer(max_depth) and max_depth >= 0 do
    depth =
      path
      |> :binary.split(<<"/">>, [:global])
      |> Enum.reject(&(&1 == <<>>))
      |> length()

    if depth > max_depth,
      do: {:error, :tree_binding_bounds_exceeded},
      else: :ok
  end

  defp check_path_depth(_, _), do: {:error, :tree_binding_bounds_exceeded}

  defp safe_dest_name?(name) when is_binary(name) do
    name != "" and name != "." and name != ".." and not String.contains?(name, "/") and
      not String.contains?(name, <<0>>)
  end

  defp safe_dest_name?(_), do: false

  defp join_rel("", name), do: name
  defp join_rel(rel, name) when is_binary(rel) and is_binary(name), do: rel <> "/" <> name

  defp within_dest?(root, abs) when is_binary(root) and is_binary(abs) do
    root_parts = Path.split(root)
    abs_parts = Path.split(abs)
    List.starts_with?(abs_parts, root_parts)
  end

  defp within_dest?(_, _), do: false

  defp executable_mode?(mode) when is_integer(mode), do: Bitwise.band(mode, 0o111) != 0
  defp executable_mode?(_), do: false

  # Independent dest hashing must not write dest bytes into the owner object
  # store. Source staging keeps hash_source_blob/3 with hash-object -w.
  defp hash_destination_blob(objects, path, "120000") do
    case File.read_link(path) do
      {:ok, target} when is_binary(target) ->
        case git(
               ["--git-dir", objects, "hash-object", "--stdin", "--no-filters"],
               [],
               stdin: target
             ) do
          {:ok, oid} -> admit_oid(oid)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:snapshot_symlink_unreadable, reason}}
    end
  end

  defp hash_destination_blob(objects, path, _mode) do
    case git(["--git-dir", objects, "hash-object", "--no-filters", "--", path]) do
      {:ok, oid} -> admit_oid(oid)
      {:error, reason} -> {:error, reason}
    end
  end

  defp admit_oid(oid) when is_binary(oid) do
    oid = String.trim(oid)

    if Regex.match?(~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, oid),
      do: {:ok, oid},
      else: {:error, :committable_snapshot_failed}
  end

  defp admit_oid(_oid), do: {:error, :committable_snapshot_failed}

  defp git(args, env \\ [], opts \\ [])

  defp git(args, env, opts)
       when is_list(args) and is_list(env) and is_list(opts) do
    env_map = Map.new(env, fn {k, v} -> {to_string(k), to_string(v)} end)

    shell_opts =
      [env: env_map, timeout: 30_000, sandbox: :none]
      |> maybe_put_git_stdin(Keyword.get(opts, :stdin))

    case Arbor.Shell.execute_direct("git", args, shell_opts) do
      {:ok, %{exit_code: 0, stdout: stdout}} ->
        output = stdout || ""

        if Keyword.get(opts, :raw) == true do
          {:ok, output}
        else
          {:ok, String.trim(output)}
        end

      {:ok, %{exit_code: code}} ->
        {:error, {:git_failed, code}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_git_stdin(opts, stdin) when is_binary(stdin) do
    Keyword.put(opts, :stdin, stdin)
  end

  defp maybe_put_git_stdin(opts, _stdin), do: opts
end
