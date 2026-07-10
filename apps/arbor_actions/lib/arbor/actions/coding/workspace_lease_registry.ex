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

  Two-revision validation resources are child leases. Their private staging,
  isolated build directories, and detached base worktree are monitored against
  both the invoking process and the parent workspace owner. Normal release,
  validation-process death, workspace-owner death, and workspace removal all
  clean those resources.

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

  @type validation_resource :: %{
          resource_id: String.t(),
          workspace_id: String.t(),
          owner_pid: pid(),
          owner_ref: reference(),
          repo_path: String.t(),
          candidate_path: String.t(),
          candidate_commit: String.t() | nil,
          base_commit: String.t(),
          root_path: String.t(),
          stage_path: String.t(),
          candidate_build_path: String.t(),
          candidate_deps_path: String.t(),
          base_build_path: String.t(),
          base_deps_path: String.t(),
          base_worktree_path: String.t(),
          runner_path: String.t(),
          candidate_result_path: String.t(),
          base_result_path: String.t(),
          snapshot_created: boolean()
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
  @spec acquire_validation_resource(String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def acquire_validation_resource(workspace_id, opts \\ %{}) when is_binary(workspace_id) do
    {server_opts, caller} = split_caller_opts(opts)
    call({:acquire_validation_resource, workspace_id, caller}, server_opts)
  end

  @doc false
  @spec create_validation_snapshot(String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_validation_snapshot(resource_id, opts \\ %{}) when is_binary(resource_id) do
    {server_opts, caller} = split_caller_opts(opts)
    call({:create_validation_snapshot, resource_id, caller}, server_opts)
  end

  @doc false
  @spec release_validation_resource(String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def release_validation_resource(resource_id, opts \\ %{}) when is_binary(resource_id) do
    {server_opts, caller} = split_caller_opts(opts)
    call({:release_validation_resource, resource_id, caller}, server_opts)
  end

  @doc false
  @spec validation_resources(String.t(), map() | keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def validation_resources(workspace_id, opts \\ %{}) when is_binary(workspace_id) do
    {server_opts, caller} = split_caller_opts(opts)
    call({:validation_resources, workspace_id, caller}, server_opts)
  end

  @doc false
  @spec issue_review_attestation(String.t(), map(), String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def issue_review_attestation(workspace_id, material, council_decision_digest, opts \\ %{})
      when is_binary(workspace_id) and is_map(material) and is_binary(council_decision_digest) do
    {server_opts, caller} = split_caller_opts(opts)

    call(
      {:issue_review_attestation, workspace_id, material, council_decision_digest, caller},
      server_opts
    )
  end

  @doc false
  @spec claim_review_attestation(String.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def claim_review_attestation(attestation_id, opts \\ %{}) when is_binary(attestation_id) do
    {server_opts, caller} = split_caller_opts(opts)
    call({:claim_review_attestation, attestation_id, caller}, server_opts)
  end

  @doc false
  @spec revoke_review_attestation(String.t(), map() | keyword()) :: :ok | {:error, term()}
  def revoke_review_attestation(attestation_id, opts \\ %{}) when is_binary(attestation_id) do
    {server_opts, caller} = split_caller_opts(opts)
    call({:revoke_review_attestation, attestation_id, caller}, server_opts)
  end

  @doc false
  @spec finalize_review_attestation(String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def finalize_review_attestation(attestation_id, opts \\ %{}) when is_binary(attestation_id) do
    {server_opts, caller} = split_caller_opts(opts)
    call({:finalize_review_attestation, attestation_id, caller}, server_opts)
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
    {:ok,
     %{
       leases: %{},
       by_ref: %{},
       validation_resources: %{},
       validation_by_ref: %{},
       validation_by_workspace: %{},
       review_attestations: %{},
       attestation_by_workspace: %{},
       attestation_states: %{}
     }}
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
          case cleanup_workspace_validation_resources(state, lease.workspace_id) do
            {:ok, state} ->
              state = cleanup_workspace_attestations(state, lease.workspace_id)
              {result, state} = do_release(state, lease, mode)
              {:reply, {:ok, result}, state}

            {:error, state} ->
              {:reply, {:error, :validation_resource_cleanup_failed}, state}
          end
        else
          {:reply, {:error, :not_authorized}, state}
        end
    end
  end

  def handle_call(
        {:acquire_validation_resource, workspace_id, caller},
        {from_pid, _tag},
        state
      ) do
    caller = %{caller | owner_pid: from_pid}

    with {:ok, lease} <- fetch_authorized(state, workspace_id, caller),
         :ok <- ensure_no_validation_resource(state, workspace_id) do
      perform_validation_resource_acquire(state, lease, from_pid, caller)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:create_validation_snapshot, resource_id, caller},
        {from_pid, _tag},
        state
      ) do
    caller = %{caller | owner_pid: from_pid}

    case fetch_authorized_validation_resource(state, resource_id, caller) do
      {:ok, resource} ->
        perform_validation_snapshot_create(state, resource)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:release_validation_resource, resource_id, caller},
        {from_pid, _tag},
        state
      ) do
    caller = %{caller | owner_pid: from_pid}

    case Map.fetch(state.validation_resources, resource_id) do
      :error ->
        {:reply, {:ok, %{resource_id: resource_id, active: false, status: "already_released"}},
         state}

      {:ok, resource} ->
        case fetch_authorized_validation_resource(state, resource_id, caller) do
          {:ok, _authorized} ->
            {result, state} = do_release_validation_resource(state, resource)
            {:reply, result, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:validation_resources, workspace_id, caller}, {from_pid, _tag}, state) do
    caller = %{caller | owner_pid: from_pid}

    case fetch_authorized(state, workspace_id, caller) do
      {:ok, _lease} ->
        resources =
          state.validation_by_workspace
          |> Map.get(workspace_id, MapSet.new())
          |> Enum.map(&Map.fetch!(state.validation_resources, &1))
          |> Enum.map(&validation_resource_view/1)
          |> Enum.sort_by(& &1.resource_id)

        {:reply, {:ok, resources}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:issue_review_attestation, workspace_id, material, council_decision_digest, caller},
        {from_pid, _tag},
        state
      ) do
    caller = %{caller | owner_pid: from_pid}

    with {:ok, lease} <- fetch_authorized(state, workspace_id, caller),
         {:ok, canonical} <-
           Arbor.Actions.Coding.SecurityRegression.Attestation.new(
             material,
             council_decision_digest
           ),
         :ok <- ensure_material_matches_lease(canonical, lease),
         :ok <- verify_review_material(lease, canonical),
         true <- valid_digest?(council_decision_digest) do
      attestation_id =
        "review_attestation_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      record = %{
        attestation_id: attestation_id,
        workspace_id: workspace_id,
        material: canonical,
        council_decision_digest: council_decision_digest,
        task_id: lease.task_id,
        principal_id: lease.principal_id
      }

      state = put_review_attestation(state, record)
      {:reply, {:ok, %{review_attestation_id: attestation_id}}, state}
    else
      false -> {:reply, {:error, :invalid_council_decision_digest}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:claim_review_attestation, attestation_id, caller}, {from_pid, _tag}, state) do
    caller = %{caller | owner_pid: from_pid}

    with {:ok, record} <- fetch_review_attestation(state, attestation_id),
         :ok <- ensure_attestation_available(state, attestation_id),
         {:ok, lease} <- fetch_authorized(state, record.workspace_id, caller),
         :ok <- ensure_record_authority(record, lease, caller),
         :ok <- verify_review_material(lease, record.material),
         {:ok, state} <- mark_attestation_claimed(state, attestation_id),
         {:ok, resource, state} <-
           create_attested_validation_resource(state, lease, from_pid, record.material, caller) do
      {:reply,
       {:ok,
        %{
          material: record.material,
          council_decision_digest: record.council_decision_digest,
          resource: validation_resource_view(resource)
        }}, state}
    else
      {:error, reason, failed_state} ->
        {:reply, {:error, reason}, failed_state}

      {:error, reason} ->
        state = mark_attestation_revoked_if_present(state, attestation_id, reason)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:revoke_review_attestation, attestation_id, caller}, {from_pid, _tag}, state) do
    caller = %{caller | owner_pid: from_pid}

    with {:ok, record} <- fetch_review_attestation(state, attestation_id),
         {:ok, lease} <- fetch_authorized(state, record.workspace_id, caller),
         :ok <- ensure_record_authority(record, lease, caller) do
      {:reply, :ok, put_attestation_state(state, attestation_id, :revoked)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:finalize_review_attestation, attestation_id, caller}, {from_pid, _tag}, state) do
    caller = %{caller | owner_pid: from_pid}

    with {:ok, record} <- fetch_review_attestation(state, attestation_id),
         :claimed <- Map.get(state.attestation_states, attestation_id),
         {:ok, lease} <- fetch_authorized(state, record.workspace_id, caller),
         :ok <- ensure_record_authority(record, lease, caller),
         :ok <- verify_review_material(lease, record.material) do
      {:reply, {:ok, record.material}, state}
    else
      :available -> {:reply, {:error, :attestation_not_claimed}, state}
      :revoked -> {:reply, {:error, :attestation_revoked}, state}
      nil -> {:reply, {:error, :attestation_revoked}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.validation_by_ref, ref) do
      {:ok, resource_id} ->
        case Map.get(state.validation_resources, resource_id) do
          nil ->
            {:noreply, %{state | validation_by_ref: Map.delete(state.validation_by_ref, ref)}}

          resource ->
            {_result, state} =
              do_release_validation_resource(state, resource, demonitor: false)

            {:noreply, state}
        end

      :error ->
        handle_workspace_owner_down(ref, state)
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

  defp ensure_no_validation_resource(state, workspace_id) do
    resources = Map.get(state.validation_by_workspace, workspace_id, MapSet.new())

    if MapSet.size(resources) == 0,
      do: :ok,
      else: {:error, :validation_in_progress}
  end

  defp perform_validation_resource_acquire(state, lease, owner_pid, caller) do
    case create_validation_resource(
           state,
           lease,
           owner_pid,
           nil,
           caller.force_dependency_snapshot_failure,
           caller.cleanup_failures,
           caller.force_partial_cleanup_failure_once
         ) do
      {:ok, resource, state} -> {:reply, {:ok, validation_resource_view(resource)}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp create_attested_validation_resource(state, lease, owner_pid, material, caller) do
    create_validation_resource(
      state,
      lease,
      owner_pid,
      material.candidate_commit,
      caller.force_dependency_snapshot_failure,
      caller.cleanup_failures,
      caller.force_partial_cleanup_failure_once
    )
  end

  defp create_validation_resource(
         state,
         lease,
         owner_pid,
         candidate_commit,
         force_dependency_snapshot_failure,
         cleanup_failures,
         force_partial_cleanup_failure_once
       ) do
    owner_ref = Process.monitor(owner_pid)

    case create_validation_root(lease.workspace_id) do
      {:ok, resource_id, root_path} ->
        resource =
          new_validation_resource(
            lease,
            owner_pid,
            owner_ref,
            resource_id,
            root_path,
            candidate_commit,
            cleanup_failures
          )

        case setup_validation_resource(resource, force_dependency_snapshot_failure) do
          {:ok, resource} ->
            {:ok, resource, put_validation_resource(state, resource)}

          {:error, reason} ->
            case rollback_partial_validation_resource(
                   resource,
                   force_partial_cleanup_failure_once
                 ) do
              :ok ->
                Process.demonitor(owner_ref, [:flush])
                {:error, reason}

              {:error, _cleanup_reason} ->
                resource = %{
                  resource
                  | setup_status: :setup_failed,
                    cleanup_failures_remaining: 0
                }

                {:error, :validation_resource_setup_failed_cleanup_retained,
                 put_validation_resource(state, resource)}
            end
        end

      {:error, reason} ->
        Process.demonitor(owner_ref, [:flush])
        {:error, reason}
    end
  end

  defp new_validation_resource(
         lease,
         owner_pid,
         owner_ref,
         resource_id,
         root_path,
         candidate_commit,
         cleanup_failures
       ) do
    %{
      resource_id: resource_id,
      workspace_id: lease.workspace_id,
      owner_pid: owner_pid,
      owner_ref: owner_ref,
      repo_path: lease.repo_path,
      candidate_path:
        if(is_binary(candidate_commit),
          do: Path.join(root_path, "candidate"),
          else: lease.worktree_path
        ),
      candidate_commit: candidate_commit,
      base_commit: lease.base_commit,
      root_path: root_path,
      stage_path: Path.join(root_path, "staged"),
      candidate_build_path: Path.join(root_path, "build-candidate"),
      candidate_deps_path: Path.join(root_path, "deps-candidate"),
      base_build_path: Path.join(root_path, "build-base"),
      base_deps_path: Path.join(root_path, "deps-base"),
      base_worktree_path: Path.join(root_path, "base"),
      runner_path: Path.join(root_path, "runner.exs"),
      candidate_result_path: Path.join(root_path, "candidate-result.etf"),
      base_result_path: Path.join(root_path, "base-result.etf"),
      snapshot_created: false,
      setup_status: :active,
      cleanup_failures_remaining: cleanup_failures
    }
  end

  defp setup_validation_resource(resource, force_dependency_snapshot_failure) do
    with {:ok, _candidate_path} <-
           create_candidate_snapshot_from_resource(resource),
         :ok <- maybe_force_dependency_snapshot_failure(force_dependency_snapshot_failure),
         :ok <-
           snapshot_dependencies(resource.repo_path, resource.candidate_deps_path),
         :ok <- snapshot_dependencies(resource.repo_path, resource.base_deps_path) do
      {:ok, resource}
    end
  end

  defp rollback_partial_validation_resource(_resource, true),
    do: {:error, :injected_partial_cleanup_failure}

  defp rollback_partial_validation_resource(resource, false),
    do: cleanup_validation_resource_files(resource)

  defp create_candidate_snapshot_from_resource(%{candidate_commit: nil} = resource),
    do: {:ok, resource.candidate_path}

  defp create_candidate_snapshot_from_resource(resource) do
    case Workspace.create_detached_worktree(
           resource.repo_path,
           resource.candidate_path,
           resource.candidate_commit
         ) do
      {:ok, candidate_path} when candidate_path == resource.candidate_path ->
        {:ok, candidate_path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp snapshot_dependencies(repo_path, destination) do
    source = Path.join(repo_path, "deps")

    cond do
      not File.dir?(source) ->
        File.mkdir(destination)

      true ->
        with :ok <- copy_dependency_tree(source, destination),
             :ok <- verify_snapshot_symlinks(destination) do
          :ok
        else
          _ -> {:error, :dependency_snapshot_failed}
        end
    end
  rescue
    _ -> {:error, :dependency_snapshot_failed}
  end

  defp maybe_force_dependency_snapshot_failure(true), do: {:error, :dependency_snapshot_failed}
  defp maybe_force_dependency_snapshot_failure(_), do: :ok

  defp copy_dependency_tree(source, destination) do
    with {:ok, %File.Stat{type: :directory} = stat} <- File.lstat(source),
         {:ok, source_root} <- canonical_existing_path(source),
         :ok <- File.mkdir(destination),
         :ok <- File.chmod(destination, permission_bits(stat.mode)),
         :ok <- copy_dependency_children(source_root, source, destination) do
      :ok
    else
      other -> {:error, {:copy_dependency_tree_failed, other}}
    end
  end

  defp copy_dependency_children(source_root, source, destination) do
    source
    |> File.ls!()
    |> Enum.reduce_while(:ok, fn name, :ok ->
      source_path = Path.join(source, name)
      destination_path = Path.join(destination, name)

      case File.lstat(source_path) do
        {:ok, %File.Stat{type: :directory} = stat} ->
          with :ok <- File.mkdir(destination_path),
               :ok <- File.chmod(destination_path, permission_bits(stat.mode)),
               :ok <- copy_dependency_children(source_root, source_path, destination_path) do
            {:cont, :ok}
          else
            other -> {:halt, {:error, {:dependency_directory_copy_failed, other}}}
          end

        {:ok, %File.Stat{type: :regular} = stat} ->
          case File.copy(source_path, destination_path) do
            {:ok, _bytes} ->
              case File.chmod(destination_path, permission_bits(stat.mode)) do
                :ok -> {:cont, :ok}
                other -> {:halt, {:error, {:dependency_file_mode_failed, other}}}
              end

            other ->
              {:halt, {:error, {:dependency_file_copy_failed, other}}}
          end

        {:ok, %File.Stat{type: :symlink}} ->
          case copy_dependency_symlink(source_root, source_path, destination_path) do
            :ok -> {:cont, :ok}
            other -> {:halt, {:error, {:dependency_symlink_copy_failed, other}}}
          end

        other ->
          {:halt, {:error, {:dependency_stat_failed, other}}}
      end
    end)
  rescue
    _ -> {:error, :dependency_snapshot_failed}
  end

  defp copy_dependency_symlink(source_root, source_path, destination_path) do
    with {:ok, target} <- File.read_link(source_path),
         {:ok, resolved_source} <-
           canonical_existing_path(Path.expand(target, Path.dirname(source_path))),
         true <- path_within?(resolved_source, source_root),
         relative_source <- Path.relative_to(resolved_source, source_root),
         destination_root <- snapshot_root_for(destination_path, source_path, source_root),
         resolved_destination <- Path.join(destination_root, relative_source),
         target_from_destination <-
           Path.relative_to(resolved_destination, Path.dirname(destination_path)),
         :ok <- File.ln_s(target_from_destination, destination_path) do
      :ok
    else
      _ -> {:error, :dependency_snapshot_failed}
    end
  end

  defp snapshot_root_for(destination_path, source_path, source_root) do
    source_relative_parent =
      Path.relative_to(Path.dirname(source_path), source_root)
      |> Path.split()
      |> Enum.reject(&(&1 == "."))

    Enum.reduce(source_relative_parent, Path.dirname(destination_path), fn _segment, acc ->
      Path.dirname(acc)
    end)
  end

  defp verify_snapshot_symlinks(destination) do
    verify_snapshot_children(destination, destination)
  end

  defp verify_snapshot_children(root, path) do
    path
    |> File.ls!()
    |> Enum.reduce_while(:ok, fn name, :ok ->
      child = Path.join(path, name)

      case File.lstat(child) do
        {:ok, %File.Stat{type: :directory}} ->
          case verify_snapshot_children(root, child) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        {:ok, %File.Stat{type: :symlink}} ->
          case File.read_link(child) do
            {:ok, target} ->
              if path_within?(Path.expand(target, Path.dirname(child)), root),
                do: {:cont, :ok},
                else: {:halt, {:error, :dependency_snapshot_failed}}

            _ ->
              {:halt, {:error, :dependency_snapshot_failed}}
          end

        {:ok, %File.Stat{type: :regular}} ->
          {:cont, :ok}

        _ ->
          {:halt, {:error, :dependency_snapshot_failed}}
      end
    end)
  rescue
    _ -> {:error, :dependency_snapshot_failed}
  end

  defp path_within?(path, root) do
    relative = Path.relative_to(Path.expand(path), Path.expand(root))

    relative != ".." and not String.starts_with?(relative, "../") and
      Path.type(relative) == :relative
  end

  defp canonical_existing_path(path) do
    case System.cmd("realpath", [path], stderr_to_stdout: true) do
      {resolved, 0} -> {:ok, String.trim(resolved)}
      _ -> {:error, :dependency_snapshot_failed}
    end
  rescue
    _ -> {:error, :dependency_snapshot_failed}
  end

  defp permission_bits(mode) when is_integer(mode), do: Bitwise.band(mode, 0o777)

  defp perform_validation_snapshot_create(state, %{snapshot_created: true} = resource) do
    {:reply, {:ok, validation_resource_view(resource)}, state}
  end

  defp perform_validation_snapshot_create(state, resource) do
    case Workspace.create_detached_worktree(
           resource.repo_path,
           resource.base_worktree_path,
           resource.base_commit
         ) do
      {:ok, _path} ->
        resource = %{resource | snapshot_created: true}

        state = %{
          state
          | validation_resources:
              Map.put(state.validation_resources, resource.resource_id, resource)
        }

        {:reply, {:ok, validation_resource_view(resource)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp fetch_authorized_validation_resource(state, resource_id, caller) do
    with {:ok, resource} <- fetch_validation_resource(state, resource_id),
         {:ok, lease} <- fetch_lease(state, resource.workspace_id),
         true <- validation_resource_authorized?(resource, lease, caller) do
      {:ok, resource}
    else
      false -> {:error, :not_authorized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_validation_resource(state, resource_id) do
    case Map.fetch(state.validation_resources, resource_id) do
      {:ok, resource} -> {:ok, resource}
      :error -> {:error, :not_found}
    end
  end

  defp fetch_lease(state, workspace_id) do
    case Map.fetch(state.leases, workspace_id) do
      {:ok, lease} -> {:ok, lease}
      :error -> {:error, :not_found}
    end
  end

  defp validation_resource_authorized?(resource, lease, caller) do
    resource_owner_match?(resource, caller) or authorized?(lease, caller)
  end

  defp resource_owner_match?(resource, caller) do
    is_pid(caller.owner_pid) and is_pid(resource.owner_pid) and
      caller.owner_pid == resource.owner_pid and Process.alive?(resource.owner_pid)
  end

  defp do_release_validation_resource(state, resource, opts \\ []) do
    case attempt_validation_resource_cleanup(state, resource) do
      {:ok, state} ->
        if Keyword.get(opts, :demonitor, true) do
          Process.demonitor(resource.owner_ref, [:flush])
        end

        result =
          {:ok,
           %{
             resource_id: resource.resource_id,
             workspace_id: resource.workspace_id,
             active: false,
             status: "removed"
           }}

        {result, drop_validation_resource(state, resource)}

      {:error, state} ->
        {{:error, :validation_resource_cleanup_failed}, state}
    end
  end

  defp cleanup_workspace_validation_resources(state, workspace_id) do
    resource_ids =
      state.validation_by_workspace
      |> Map.get(workspace_id, MapSet.new())
      |> Enum.to_list()

    Enum.reduce_while(resource_ids, {:ok, state}, fn resource_id, {:ok, acc} ->
      case Map.get(acc.validation_resources, resource_id) do
        nil ->
          {:cont, {:ok, acc}}

        resource ->
          case do_release_validation_resource(acc, resource) do
            {{:ok, _result}, next_state} -> {:cont, {:ok, next_state}}
            {{:error, _reason}, next_state} -> {:halt, {:error, next_state}}
          end
      end
    end)
  end

  defp attempt_validation_resource_cleanup(
         state,
         %{cleanup_failures_remaining: failures} = resource
       )
       when failures > 0 do
    resource = %{resource | cleanup_failures_remaining: failures - 1}

    state = %{
      state
      | validation_resources: Map.put(state.validation_resources, resource.resource_id, resource)
    }

    {:error, state}
  end

  defp attempt_validation_resource_cleanup(state, resource) do
    case cleanup_validation_resource_files(resource) do
      :ok -> {:ok, state}
      {:error, _reason} -> {:error, state}
    end
  end

  defp cleanup_validation_resource_files(resource) do
    if is_binary(resource.candidate_commit) do
      _ = Workspace.remove_detached_worktree(resource.repo_path, resource.candidate_path)
    end

    _ =
      Workspace.remove_detached_worktree(
        resource.repo_path,
        resource.base_worktree_path
      )

    _ = File.rm_rf(resource.root_path)

    case File.lstat(resource.root_path) do
      {:error, :enoent} -> :ok
      _other -> {:error, :resource_root_still_exists}
    end
  rescue
    _error -> {:error, :resource_cleanup_failed}
  catch
    :exit, _reason -> {:error, :resource_cleanup_failed}
  end

  defp put_validation_resource(state, resource) do
    workspace_resources =
      state.validation_by_workspace
      |> Map.get(resource.workspace_id, MapSet.new())
      |> MapSet.put(resource.resource_id)

    %{
      state
      | validation_resources: Map.put(state.validation_resources, resource.resource_id, resource),
        validation_by_ref:
          Map.put(state.validation_by_ref, resource.owner_ref, resource.resource_id),
        validation_by_workspace:
          Map.put(state.validation_by_workspace, resource.workspace_id, workspace_resources)
    }
  end

  defp drop_validation_resource(state, resource) do
    workspace_resources =
      state.validation_by_workspace
      |> Map.get(resource.workspace_id, MapSet.new())
      |> MapSet.delete(resource.resource_id)

    validation_by_workspace =
      if MapSet.size(workspace_resources) == 0 do
        Map.delete(state.validation_by_workspace, resource.workspace_id)
      else
        Map.put(state.validation_by_workspace, resource.workspace_id, workspace_resources)
      end

    %{
      state
      | validation_resources: Map.delete(state.validation_resources, resource.resource_id),
        validation_by_ref: Map.delete(state.validation_by_ref, resource.owner_ref),
        validation_by_workspace: validation_by_workspace
    }
  end

  defp validation_resource_view(resource) do
    %{
      resource_id: resource.resource_id,
      workspace_id: resource.workspace_id,
      repo_path: resource.repo_path,
      candidate_path: resource.candidate_path,
      candidate_commit: resource.candidate_commit,
      base_commit: resource.base_commit,
      root_path: resource.root_path,
      stage_path: resource.stage_path,
      candidate_build_path: resource.candidate_build_path,
      candidate_deps_path: resource.candidate_deps_path,
      base_build_path: resource.base_build_path,
      base_deps_path: resource.base_deps_path,
      base_worktree_path: resource.base_worktree_path,
      runner_path: resource.runner_path,
      candidate_result_path: resource.candidate_result_path,
      base_result_path: resource.base_result_path,
      snapshot_created: resource.snapshot_created,
      setup_status: Atom.to_string(resource.setup_status),
      active: true
    }
  end

  defp create_validation_root(workspace_id, attempts \\ 4)

  defp create_validation_root(_workspace_id, 0),
    do: {:error, :validation_resource_collision}

  defp create_validation_root(workspace_id, attempts) do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    workspace_hash = sha256(workspace_id) |> binary_part(0, 12)
    resource_id = "security_regression_" <> token

    root_path =
      Path.join(
        System.tmp_dir!(),
        "arbor-security-regression-#{workspace_hash}-#{token}"
      )

    case File.mkdir(root_path) do
      :ok ->
        case File.chmod(root_path, 0o700) do
          :ok ->
            {:ok, resource_id, root_path}

          {:error, _reason} ->
            _ = File.rm_rf(root_path)
            {:error, :validation_resource_create_failed}
        end

      {:error, :eexist} ->
        create_validation_root(workspace_id, attempts - 1)

      {:error, _reason} ->
        {:error, :validation_resource_create_failed}
    end
  rescue
    _error -> {:error, :validation_resource_create_failed}
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  defp handle_workspace_owner_down(ref, state) do
    case Map.pop(state.by_ref, ref) do
      {nil, _by_ref} ->
        {:noreply, state}

      {workspace_id, by_ref} ->
        state = %{state | by_ref: by_ref}

        case cleanup_workspace_validation_resources(state, workspace_id) do
          {:error, state} ->
            # The dead owner ref is gone, but the lease remains as the
            # task+principal authority needed to discover and retry cleanup.
            {:noreply, state}

          {:ok, state} ->
            state = cleanup_workspace_attestations(state, workspace_id)

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
  end

  defp ensure_material_matches_lease(material, lease) do
    if material.workspace_id == lease.workspace_id and material.base_commit == lease.base_commit and
         material.validation_profile == "security_regression" do
      :ok
    else
      {:error, :attestation_lease_mismatch}
    end
  end

  defp verify_review_material(lease, material) do
    paths = Enum.map(material.selected_tests, & &1.path)

    with {:ok, actual} <-
           Workspace.materialize_security_regression_material(
             lease.worktree_path,
             lease.workspace_id,
             lease.base_commit,
             paths
           ),
         true <- material_without_diff(actual) == material_without_diff(material) do
      :ok
    else
      false -> {:error, :reviewed_material_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp material_without_diff(material),
    do: Map.drop(material, [:diff, :canonical_digest, :council_decision_digest])

  defp valid_digest?(digest), do: is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp put_review_attestation(state, record) do
    ids =
      state.attestation_by_workspace
      |> Map.get(record.workspace_id, MapSet.new())
      |> MapSet.put(record.attestation_id)

    %{
      state
      | review_attestations: Map.put(state.review_attestations, record.attestation_id, record),
        attestation_by_workspace:
          Map.put(state.attestation_by_workspace, record.workspace_id, ids),
        attestation_states: Map.put(state.attestation_states, record.attestation_id, :available)
    }
  end

  defp fetch_review_attestation(state, attestation_id) do
    case Map.fetch(state.review_attestations, attestation_id) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :not_found}
    end
  end

  defp ensure_attestation_available(state, attestation_id) do
    case Map.get(state.attestation_states, attestation_id) do
      :available -> :ok
      :claimed -> {:error, :attestation_already_claimed}
      :revoked -> {:error, :attestation_revoked}
      _ -> {:error, :attestation_revoked}
    end
  end

  defp ensure_record_authority(record, lease, caller) do
    if record.task_id == lease.task_id and record.principal_id == lease.principal_id and
         authorized?(lease, caller) do
      :ok
    else
      {:error, :not_authorized}
    end
  end

  defp mark_attestation_claimed(state, attestation_id) do
    case ensure_attestation_available(state, attestation_id) do
      :ok -> {:ok, put_attestation_state(state, attestation_id, :claimed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_attestation_revoked_if_present(state, attestation_id, reason) do
    if Map.has_key?(state.review_attestations, attestation_id) and
         reason not in [
           :not_found,
           :not_authorized,
           :attestation_already_claimed,
           :attestation_revoked
         ] do
      put_attestation_state(state, attestation_id, :revoked)
    else
      state
    end
  end

  defp put_attestation_state(state, attestation_id, status) do
    %{state | attestation_states: Map.put(state.attestation_states, attestation_id, status)}
  end

  defp cleanup_workspace_attestations(state, workspace_id) do
    ids = Map.get(state.attestation_by_workspace, workspace_id, MapSet.new())

    %{
      state
      | review_attestations: Map.drop(state.review_attestations, MapSet.to_list(ids)),
        attestation_states: Map.drop(state.attestation_states, MapSet.to_list(ids)),
        attestation_by_workspace: Map.delete(state.attestation_by_workspace, workspace_id)
    }
  end

  defp split_caller_opts(opts) when is_list(opts) do
    server_opts = Keyword.take(opts, [:server])

    caller = %{
      # owner_pid is overwritten by the GenServer caller on handle_call
      owner_pid: nil,
      task_id: normalize_id(Keyword.get(opts, :task_id)),
      principal_id:
        normalize_id(Keyword.get(opts, :principal_id) || Keyword.get(opts, :agent_id)),
      force_dependency_snapshot_failure:
        Keyword.get(opts, :force_dependency_snapshot_failure) == true,
      cleanup_failures:
        normalize_cleanup_failures(
          Keyword.get(opts, :cleanup_failures),
          Keyword.get(opts, :force_cleanup_failure_once)
        ),
      force_partial_cleanup_failure_once:
        Keyword.get(opts, :force_partial_cleanup_failure_once) == true
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
      principal_id: principal,
      force_dependency_snapshot_failure:
        Map.get(opts, :force_dependency_snapshot_failure) == true ||
          Map.get(opts, "force_dependency_snapshot_failure") == true,
      cleanup_failures:
        normalize_cleanup_failures(
          Map.get(opts, :cleanup_failures) || Map.get(opts, "cleanup_failures"),
          Map.get(opts, :force_cleanup_failure_once) ||
            Map.get(opts, "force_cleanup_failure_once")
        ),
      force_partial_cleanup_failure_once:
        Map.get(opts, :force_partial_cleanup_failure_once) == true ||
          Map.get(opts, "force_partial_cleanup_failure_once") == true
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

  defp normalize_cleanup_failures(count, _force_once)
       when is_integer(count) and count >= 0 and count <= 10,
       do: count

  defp normalize_cleanup_failures(_count, true), do: 1
  defp normalize_cleanup_failures(_count, _force_once), do: 0

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
