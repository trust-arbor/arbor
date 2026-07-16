defmodule Arbor.Actions.Coding.ValidationResourceOwner do
  @moduledoc false

  use GenServer

  alias Arbor.Actions.Coding.Workspace

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
      root_status: :starting
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
end
