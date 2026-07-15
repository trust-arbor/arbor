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
  DOWN retains an owned lease once it is stored. Post-create failures remove
  invocation-owned worktrees before returning.

  ## Owner-death cleanup

  Owner death is the authoritative fallback used by TaskStore hard cancellation
  and unexpected crashes. The registry always cleans child validation resources
  and private attestations/review snapshots first. Then:

  * **reused** leases — drop the lease record only; reused paths are never
    deletion authority and always survive
  * **owned** leases — always convert atomically to the existing bounded-TTL
    retained lease, preserving exact `task_id` + `principal_id` reactivation
    authority. Owner death cannot prove that an external ACP worker has stopped;
    even a currently pristine worktree may receive a late write after an
    inspect-then-remove check.

  Owner-death conversion reuses the bounded `:retain` identity/TTL machinery.
  If that identity cannot be proven, the lease remains as an explicit
  non-destructive quarantine for authorized inspection/release and retries
  identity capture rather than becoming deletion authority.

  Two-revision validation resources are child leases. Their private staging,
  isolated build directories, and detached base worktree are monitored against
  both the invoking process and the parent workspace owner. Normal release,
  validation-process death, workspace-owner death, and workspace removal all
  clean those resources. Dependency trees are materialized through the public
  `Arbor.Shell` Linux baseline lease API; the opaque lease stays private to the
  registry's validation_resource record and is never projected in public views.

  ## Review snapshots

  Commit-bound review snapshots pin exact candidate/base commit and tree OIDs
  for schema-bounded tree read/search. Opening requires an active lease,
  matching task+principal (or live owner) authority, a clean worktree, and a
  HEAD that exactly equals the supplied full candidate commit hash. Opaque
  `review_snapshot_id` values are **not** authority. Workspace release and
  owner-death cleanup drop all snapshots for that workspace.

  ## Public views

  All client-facing maps are JSON-clean: no PIDs, monitor refs, functions, or
  rich structs.

  Retained records are process state and are intentionally not deletion
  authority across a registry restart. A restarted registry may leak retained
  worktrees; durable restart markers and reconciliation are a follow-up.
  """

  use GenServer

  require Logger

  alias Arbor.Actions.Config
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Git
  alias Arbor.Common.SafePath

  @type ownership :: :owned | :reused
  @type release_mode :: :retain | :remove

  # Owner-death retries are a liveness aid, never deletion authority. An
  # exhausted quarantine remains available to its exact task+principal for
  # explicit inspection and recovery, but stops waking the registry forever.
  @default_owner_death_retry_limit 3
  @max_owner_death_retry_limit 10
  @default_owner_death_retry_base_ms 1_000
  @max_owner_death_retry_base_ms 60_000

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

  @type retained_lease :: %{
          workspace_id: String.t(),
          owner_pid: pid(),
          task_id: String.t() | nil,
          principal_id: String.t() | nil,
          repo_path: String.t(),
          worktree_path: String.t(),
          display_worktree_path: String.t(),
          branch: String.t(),
          base_commit: String.t(),
          ownership: :owned,
          target: tuple(),
          lstat_identity: map(),
          worktree_registration: map(),
          expiry_generation: reference(),
          expiry_ref: reference() | nil,
          expires_at: DateTime.t(),
          expires_at_ms: integer(),
          retry_count: non_neg_integer(),
          cleanup_failure: term() | nil
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
          # Private staging parent (0700). Exact stage_path child is created
          # exclusively by SecurityRegression.Shell.stage_sources/2.
          stage_parent_path: String.t(),
          stage_path: String.t(),
          candidate_runtime_path: String.t(),
          candidate_home_path: String.t(),
          candidate_tmp_path: String.t(),
          candidate_build_path: String.t(),
          candidate_deps_path: String.t() | nil,
          candidate_runner_path: String.t(),
          candidate_result_path: String.t(),
          base_runtime_path: String.t(),
          base_home_path: String.t(),
          base_tmp_path: String.t(),
          base_build_path: String.t(),
          base_deps_path: String.t() | nil,
          base_worktree_path: String.t(),
          base_runner_path: String.t(),
          base_result_path: String.t(),
          # Opaque Shell dependency-baseline lease. Process-private only —
          # never projected through validation_resource_view/1.
          dependency_lease: term() | nil,
          dependency_receipt: map() | nil,
          dependency_verified_copy: boolean() | nil,
          snapshot_created: boolean()
        }

  @registry_name __MODULE__

  # -- Public API -----------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @registry_name)
    GenServer.start_link(__MODULE__, opts, name: name)
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

  @doc """
  Open a commit-bound review snapshot for an active workspace lease.

  Requires the same authority as lease inspect/release (live owner process, or
  matching non-empty `task_id` **and** `principal_id`). The worktree must be
  clean and its HEAD must equal `candidate_commit` exactly (full object hash).
  The lease `base_commit` is bound as the snapshot base. Records exact
  candidate/base commit and tree OIDs. Returns a JSON-clean map including an
  opaque `review_snapshot_id` that is never authority by itself.
  """
  @spec open_review_snapshot(String.t(), String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def open_review_snapshot(workspace_id, candidate_commit, opts \\ %{})
      when is_binary(workspace_id) and is_binary(candidate_commit) do
    {server_opts, caller} = split_caller_opts(opts)
    call({:open_review_snapshot, workspace_id, candidate_commit, caller}, server_opts)
  end

  @doc """
  Resolve a review snapshot when authorized for its parent workspace lease.

  Authority is the live owner process, or matching non-empty `task_id` plus
  non-empty `principal_id`. Opaque `review_snapshot_id` alone is not enough.
  """
  @spec resolve_review_snapshot(String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_review_snapshot(review_snapshot_id, opts \\ %{})
      when is_binary(review_snapshot_id) do
    {server_opts, caller} = split_caller_opts(opts)
    call({:resolve_review_snapshot, review_snapshot_id, caller}, server_opts)
  end

  @doc false
  @spec resolve_review_snapshot_for_action(String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_review_snapshot_for_action(review_snapshot_id, opts \\ %{})
      when is_binary(review_snapshot_id) do
    {server_opts, caller} = split_caller_opts(opts)
    call({:resolve_review_snapshot_for_action, review_snapshot_id, caller}, server_opts)
  end

  @doc """
  Close a review snapshot when authorized.

  Idempotent: closing an unknown/already-closed id returns success without
  treating the id as authority for any other operation. Closing a live
  snapshot requires the same lease authority as resolve.
  """
  @spec close_review_snapshot(String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def close_review_snapshot(review_snapshot_id, opts \\ %{})
      when is_binary(review_snapshot_id) do
    {server_opts, caller} = split_caller_opts(opts)
    call({:close_review_snapshot, review_snapshot_id, caller}, server_opts)
  end

  @doc false
  @spec public_view(map()) :: map()
  def public_view(lease) when is_map(lease) do
    view = %{
      workspace_id: lease.workspace_id,
      repo_path: lease.repo_path,
      worktree_path: lease.worktree_path,
      branch: lease.branch,
      base_commit: lease.base_commit,
      ownership: ownership_string(lease.ownership),
      active: lease.active == true
    }

    case Map.get(lease, :expires_at) do
      %DateTime{} = expires_at -> Map.put(view, :expires_at, DateTime.to_iso8601(expires_at))
      _ -> view
    end
  end

  @doc false
  @spec review_snapshot_view(map()) :: map()
  def review_snapshot_view(snapshot) when is_map(snapshot) do
    %{
      review_snapshot_id: snapshot.review_snapshot_id,
      workspace_id: snapshot.workspace_id,
      candidate_commit: snapshot.candidate_commit,
      base_commit: snapshot.base_commit,
      candidate_tree_oid: snapshot.candidate_tree_oid,
      base_tree_oid: snapshot.base_tree_oid,
      active: true
    }
  end

  defp review_snapshot_action_view(snapshot) do
    Map.put(review_snapshot_view(snapshot), :repo_path, snapshot.repo_path)
  end

  # -- GenServer ------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
       leases: %{},
       by_ref: %{},
       retained_by_id: %{},
       retained_by_target: %{},
       retention_ttl_ms: Config.workspace_retention_ttl_ms(server_opts(opts)),
       retained_cleanup:
         Keyword.get(server_opts(opts), :retained_cleanup, &remove_owned_worktree/2),
       owner_death_retry_limit: owner_death_retry_limit(server_opts(opts)),
       owner_death_retry_base_ms: owner_death_retry_base_ms(server_opts(opts)),
       validation_resources: %{},
       validation_by_ref: %{},
       validation_by_workspace: %{},
       review_attestations: %{},
       attestation_by_workspace: %{},
       attestation_states: %{},
       review_snapshots: %{},
       review_snapshots_by_workspace: %{},
       linux_dependency_baseline_materializer: dependency_baseline_materializer_from_opts(opts)
     }}
  end

  defp server_opts(opts) when is_list(opts), do: opts
  defp server_opts(_opts), do: []

  defp owner_death_retry_limit(opts) do
    case Keyword.get(opts, :owner_death_retry_limit) do
      limit when is_integer(limit) and limit >= 0 and limit <= @max_owner_death_retry_limit ->
        limit

      _ ->
        @default_owner_death_retry_limit
    end
  end

  defp owner_death_retry_base_ms(opts) do
    case Keyword.get(opts, :owner_death_retry_base_ms) do
      delay when is_integer(delay) and delay >= 1 and delay <= @max_owner_death_retry_base_ms ->
        delay

      _ ->
        @default_owner_death_retry_base_ms
    end
  end

  defp dependency_baseline_materializer_from_opts(opts) when is_list(opts) do
    case Keyword.get(server_opts(opts), :linux_dependency_baseline_materializer) do
      mod when is_atom(mod) and not is_nil(mod) -> mod
      _ -> Arbor.Shell
    end
  end

  defp dependency_baseline_materializer_from_opts(_opts), do: Arbor.Shell

  @impl true
  def handle_call({:acquire, attrs}, {owner_pid, _tag}, state) do
    # Owner authority is always the GenServer caller, never a supplied pid.
    case prepare_acquire_identity(attrs, owner_pid) do
      {:ok, prepared} ->
        case quarantined_acquire(state, prepared) do
          {:ok, lease} ->
            reactivate_quarantined(lease, prepared, state)

          {:error, reason} ->
            {:reply, {:error, reason}, state}

          :none ->
            continue_acquire(state, prepared)
        end

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
              state =
                state
                |> cleanup_workspace_attestations(lease.workspace_id)
                |> cleanup_workspace_review_snapshots(lease.workspace_id)

              case do_release(state, lease, mode) do
                {:ok, result, state} -> {:reply, {:ok, result}, state}
                {:error, reason, state} -> {:reply, {:error, reason}, state}
              end

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
            state = complete_owner_death_validation_cleanup(state, resource.workspace_id, result)
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

  def handle_call(
        {:open_review_snapshot, workspace_id, candidate_commit, caller},
        {from_pid, _tag},
        state
      ) do
    caller = %{caller | owner_pid: from_pid}
    state = ensure_review_snapshot_state(state)

    case perform_open_review_snapshot(state, workspace_id, candidate_commit, caller) do
      {:ok, view, state} -> {:reply, {:ok, view}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resolve_review_snapshot, review_snapshot_id, caller}, {from_pid, _tag}, state) do
    caller = %{caller | owner_pid: from_pid}
    state = ensure_review_snapshot_state(state)

    case fetch_authorized_review_snapshot(state, review_snapshot_id, caller) do
      {:ok, snapshot} -> {:reply, {:ok, review_snapshot_view(snapshot)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:resolve_review_snapshot_for_action, review_snapshot_id, caller},
        {from_pid, _tag},
        state
      ) do
    caller = %{caller | owner_pid: from_pid}
    state = ensure_review_snapshot_state(state)

    case fetch_authorized_review_snapshot(state, review_snapshot_id, caller) do
      {:ok, snapshot} -> {:reply, {:ok, review_snapshot_action_view(snapshot)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:close_review_snapshot, review_snapshot_id, caller}, {from_pid, _tag}, state) do
    caller = %{caller | owner_pid: from_pid}
    state = ensure_review_snapshot_state(state)

    case Map.fetch(state.review_snapshots, review_snapshot_id) do
      :error ->
        {:reply,
         {:ok,
          %{
            review_snapshot_id: review_snapshot_id,
            active: false,
            status: "already_closed"
          }}, state}

      {:ok, snapshot} ->
        case fetch_authorized(state, snapshot.workspace_id, caller) do
          {:ok, _lease} ->
            state = drop_review_snapshot(state, snapshot)

            {:reply,
             {:ok,
              %{
                review_snapshot_id: review_snapshot_id,
                workspace_id: snapshot.workspace_id,
                active: false,
                status: "closed"
              }}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_info({:retained_expire, target, generation}, state)
      when is_tuple(target) and is_reference(generation) do
    {:noreply, expire_retained(state, target, generation)}
  end

  def handle_info({:retained_expire, _target, _generation}, state), do: {:noreply, state}

  @impl true
  def handle_info({:owner_death_retention_retry, workspace_id, generation}, state)
      when is_binary(workspace_id) and is_reference(generation) do
    state = retry_owner_death_retention(state, workspace_id, generation)
    {:noreply, state}
  end

  def handle_info({:owner_death_retention_retry, _workspace_id, _generation}, state),
    do: {:noreply, state}

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
           caller.force_partial_cleanup_failure_once,
           setup_opts_from_caller(caller)
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
      caller.force_partial_cleanup_failure_once,
      setup_opts_from_caller(caller)
    )
  end

  defp create_validation_resource(
         state,
         lease,
         owner_pid,
         candidate_commit,
         force_dependency_snapshot_failure,
         cleanup_failures,
         force_partial_cleanup_failure_once,
         setup_opts
       ) do
    owner_ref = Process.monitor(owner_pid)
    materializer = state.linux_dependency_baseline_materializer

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

        case setup_validation_resource(
               resource,
               force_dependency_snapshot_failure,
               setup_opts,
               materializer
             ) do
          {:ok, resource} ->
            {:ok, resource, put_validation_resource(state, resource)}

          {:error, {:cleanup_required, reason, dep_lease}} ->
            handle_dependency_cleanup_required(
              state,
              resource,
              materializer,
              dep_lease,
              reason,
              force_partial_cleanup_failure_once
            )

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

  defp handle_dependency_cleanup_required(
         state,
         resource,
         materializer,
         dep_lease,
         reason,
         force_partial_cleanup_failure_once
       ) do
    # Registry owns the lease: attempt Shell release immediately so failures
    # never leave an untracked Shell root. Release only from this process.
    case release_dependency_baseline_lease(materializer, dep_lease) do
      :ok ->
        resource = %{resource | dependency_lease: nil}

        case rollback_partial_validation_resource(
               resource,
               force_partial_cleanup_failure_once
             ) do
          :ok ->
            Process.demonitor(resource.owner_ref, [:flush])
            {:error, reason}

          {:error, _cleanup_reason} ->
            resource = %{
              resource
              | setup_status: :setup_failed,
                cleanup_failures_remaining: 0,
                dependency_lease: nil
            }

            {:error, :validation_resource_setup_failed_cleanup_retained,
             put_validation_resource(state, resource)}
        end

      {:error, _release_reason} ->
        resource = %{
          resource
          | setup_status: :setup_failed,
            cleanup_failures_remaining: 0,
            dependency_lease: dep_lease
        }

        {:error, :validation_resource_setup_failed_cleanup_retained,
         put_validation_resource(state, resource)}
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
    candidate_runtime = Path.join(root_path, "candidate-runtime")
    base_runtime = Path.join(root_path, "base-runtime")
    stage_parent = Path.join(root_path, "staging")

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
      # Parent is private/owned; exact stage_path child is created exclusively by
      # SecurityRegression.Shell.stage_sources/2 (must not pre-exist).
      stage_parent_path: stage_parent,
      stage_path: Path.join(stage_parent, "tests"),
      candidate_runtime_path: candidate_runtime,
      candidate_home_path: Path.join(candidate_runtime, "home"),
      candidate_tmp_path: Path.join(candidate_runtime, "tmp"),
      candidate_build_path: Path.join(candidate_runtime, "build"),
      # Filled from Shell baseline lease view after successful acquire.
      candidate_deps_path: nil,
      candidate_runner_path: Path.join(candidate_runtime, "runner.exs"),
      candidate_result_path: Path.join(candidate_runtime, "result.etf"),
      base_runtime_path: base_runtime,
      base_home_path: Path.join(base_runtime, "home"),
      base_tmp_path: Path.join(base_runtime, "tmp"),
      base_build_path: Path.join(base_runtime, "build"),
      base_deps_path: nil,
      base_worktree_path: Path.join(root_path, "base"),
      base_runner_path: Path.join(base_runtime, "runner.exs"),
      base_result_path: Path.join(base_runtime, "result.etf"),
      # Candidate-leg aliases for existing callers.
      home_path: Path.join(candidate_runtime, "home"),
      tmp_path: Path.join(candidate_runtime, "tmp"),
      runner_path: Path.join(candidate_runtime, "runner.exs"),
      dependency_lease: nil,
      dependency_receipt: nil,
      dependency_verified_copy: nil,
      snapshot_created: false,
      setup_status: :active,
      cleanup_failures_remaining: cleanup_failures
    }
  end

  # Absolute monotonic deadline default when caller omits one (relative budget).
  @default_dependency_lease_deadline_ms 120_000
  # Shell facade accepts at most this relative deadline.
  @max_dependency_lease_deadline_ms 3_600_000
  @max_dependency_receipt_bytes 16_384

  defp setup_validation_resource(
         resource,
         force_dependency_snapshot_failure,
         setup_opts,
         materializer
       ) do
    # Ordering is load-bearing: Actions-owned private dirs and any detached
    # candidate worktree are created and forced private *before* the Shell
    # lease is acquired, so no later filesystem setup can lose the lease.
    with :ok <- check_deadline(setup_opts),
         :ok <- create_private_validation_directories(resource),
         :ok <- check_deadline(setup_opts),
         {:ok, _candidate_path} <- create_candidate_snapshot_from_resource(resource),
         :ok <- check_deadline(setup_opts),
         :ok <- force_private_top_boundaries(resource),
         :ok <- maybe_force_dependency_snapshot_failure(force_dependency_snapshot_failure),
         :ok <- check_deadline(setup_opts),
         {:ok, remaining_ms} <- remaining_shell_deadline_ms(setup_opts) do
      case acquire_dependency_baseline_lease(materializer, remaining_ms) do
        {:ok, dep_lease, view} ->
          case admit_dependency_baseline_view(view) do
            {:ok, admitted} ->
              # Pure merge only — no further fallible setup after acquire.
              {:ok, merge_dependency_baseline(resource, dep_lease, admitted)}

            {:error, reason} ->
              case release_dependency_baseline_lease(materializer, dep_lease) do
                :ok ->
                  {:error, reason}

                {:error, _} ->
                  {:error, {:cleanup_required, reason, dep_lease}}
              end
          end

        {:error, {:cleanup_required, reason, dep_lease}} ->
          {:error, {:cleanup_required, reason, dep_lease}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp setup_opts_from_caller(caller) when is_map(caller) do
    [
      deadline_ms: Map.get(caller, :deadline_ms) || Map.get(caller, "deadline_ms")
    ]
  end

  defp setup_opts_from_caller(_), do: []

  defp create_private_validation_directories(resource) do
    # Independent per-revision private roots (0700). Do NOT create stage_path —
    # stage_sources/2 creates that exact child exclusively. Only its parent.
    # Candidate/base deps live under the Shell-owned baseline lease root and are
    # intentionally not created under the Actions validation root.
    private_dirs = [
      resource.stage_parent_path,
      resource.candidate_runtime_path,
      resource.candidate_home_path,
      resource.candidate_tmp_path,
      resource.candidate_build_path,
      resource.base_runtime_path,
      resource.base_home_path,
      resource.base_tmp_path,
      resource.base_build_path
    ]

    Enum.reduce_while(private_dirs, :ok, fn path, :ok ->
      case ensure_private_directory(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp force_private_top_boundaries(resource) do
    Enum.reduce_while(
      [
        resource.root_path,
        resource.stage_parent_path,
        resource.candidate_runtime_path,
        resource.candidate_home_path,
        resource.candidate_tmp_path,
        resource.candidate_build_path,
        resource.base_runtime_path,
        resource.base_home_path,
        resource.base_tmp_path,
        resource.base_build_path
      ],
      :ok,
      fn path, :ok ->
        case File.chmod(path, 0o700) do
          :ok ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, {:validation_private_dir_chmod_failed, path, reason}}}
        end
      end
    )
  end

  defp ensure_private_directory(path) when is_binary(path) do
    case File.mkdir(path) do
      :ok ->
        case File.chmod(path, 0o700) do
          :ok -> :ok
          {:error, reason} -> {:error, {:validation_private_dir_chmod_failed, path, reason}}
        end

      {:error, :eexist} ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} ->
            case File.chmod(path, 0o700) do
              :ok -> :ok
              {:error, reason} -> {:error, {:validation_private_dir_chmod_failed, path, reason}}
            end

          _ ->
            {:error, {:validation_private_dir_invalid, path}}
        end

      {:error, reason} ->
        {:error, {:validation_private_dir_create_failed, path, reason}}
    end
  end

  defp rollback_partial_validation_resource(_resource, true),
    do: {:error, :injected_partial_cleanup_failure}

  defp rollback_partial_validation_resource(resource, false),
    do: cleanup_actions_owned_validation_files(resource)

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

  defp maybe_force_dependency_snapshot_failure(true), do: {:error, :dependency_snapshot_failed}
  defp maybe_force_dependency_snapshot_failure(_), do: :ok

  defp remaining_shell_deadline_ms(opts) when is_list(opts) do
    deadline = Keyword.get(opts, :deadline_ms) || Keyword.get(opts, :deadline)

    case deadline do
      nil ->
        {:ok, @default_dependency_lease_deadline_ms}

      ms when is_integer(ms) ->
        remaining = ms - System.monotonic_time(:millisecond)

        cond do
          remaining <= 0 ->
            {:error, :operation_deadline_exceeded}

          remaining > @max_dependency_lease_deadline_ms ->
            {:ok, @max_dependency_lease_deadline_ms}

          true ->
            {:ok, remaining}
        end

      _ ->
        {:error, :invalid_deadline}
    end
  end

  defp remaining_shell_deadline_ms(opts) when is_map(opts) do
    remaining_shell_deadline_ms(Map.to_list(opts))
  end

  defp remaining_shell_deadline_ms(_), do: {:ok, @default_dependency_lease_deadline_ms}

  defp acquire_dependency_baseline_lease(materializer, remaining_ms)
       when is_atom(materializer) and is_integer(remaining_ms) and remaining_ms > 0 do
    try do
      case materializer.acquire_linux_dependency_baseline_lease(remaining_ms) do
        # Ownership transfers on any non-nil lease. View shape is admitted only
        # after transfer so a malformed/non-map view cannot drop a live lease.
        {:ok, lease, view} when not is_nil(lease) ->
          {:ok, lease, view}

        {:error, {:cleanup_required, reason, lease}} when not is_nil(lease) ->
          {:error, {:cleanup_required, reason, lease}}

        {:error, reason} ->
          {:error, reason}

        _other ->
          {:error, :dependency_baseline_acquire_failed}
      end
    rescue
      _ -> {:error, :dependency_baseline_acquire_failed}
    catch
      :exit, _ -> {:error, :dependency_baseline_acquire_failed}
      :throw, _ -> {:error, :dependency_baseline_acquire_failed}
    end
  end

  defp acquire_dependency_baseline_lease(_materializer, _remaining_ms),
    do: {:error, :invalid_deadline}

  defp release_dependency_baseline_lease(_materializer, nil), do: :ok

  defp release_dependency_baseline_lease(materializer, lease) when is_atom(materializer) do
    try do
      case materializer.release_linux_dependency_baseline_lease(lease) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        _other -> {:error, :dependency_baseline_release_failed}
      end
    rescue
      _ -> {:error, :dependency_baseline_release_failed}
    catch
      :exit, _ -> {:error, :dependency_baseline_release_failed}
      :throw, _ -> {:error, :dependency_baseline_release_failed}
    end
  end

  defp release_dependency_baseline_lease(_materializer, _lease),
    do: {:error, :dependency_baseline_release_failed}

  defp admit_dependency_baseline_view(view) when is_map(view) do
    candidate = Map.get(view, "candidate_path") || Map.get(view, :candidate_path)
    base = Map.get(view, "base_path") || Map.get(view, :base_path)
    receipt = Map.get(view, "receipt") || Map.get(view, :receipt)
    verified = Map.get(view, "verified_copy") || Map.get(view, :verified_copy)

    with true <- is_binary(candidate) and candidate != "",
         true <- is_binary(base) and base != "",
         true <- Path.type(candidate) == :absolute,
         true <- Path.type(base) == :absolute,
         true <- candidate != base,
         true <- verified === true,
         :ok <- validate_json_clean_receipt(receipt) do
      {:ok,
       %{
         candidate_deps_path: candidate,
         base_deps_path: base,
         dependency_receipt: receipt,
         dependency_verified_copy: true
       }}
    else
      _ -> {:error, :invalid_dependency_baseline_view}
    end
  end

  defp admit_dependency_baseline_view(_view), do: {:error, :invalid_dependency_baseline_view}

  defp validate_json_clean_receipt(receipt) when is_map(receipt) do
    # Closed-enough JSON-clean contract: encodeable, bounded, no rich terms.
    # Evidence only — never treated as execution authority.
    try do
      case Jason.encode(receipt) do
        {:ok, encoded} when byte_size(encoded) <= @max_dependency_receipt_bytes ->
          if json_clean_term?(receipt), do: :ok, else: {:error, :invalid_dependency_receipt}

        {:ok, _too_large} ->
          {:error, :invalid_dependency_receipt}

        {:error, _} ->
          {:error, :invalid_dependency_receipt}
      end
    rescue
      _ -> {:error, :invalid_dependency_receipt}
    end
  end

  defp validate_json_clean_receipt(_), do: {:error, :invalid_dependency_receipt}

  defp json_clean_term?(term)
       when is_binary(term) or is_integer(term) or is_float(term) or is_boolean(term) or
              is_nil(term),
       do: true

  defp json_clean_term?(term) when is_atom(term), do: true

  defp json_clean_term?(list) when is_list(list),
    do: Enum.all?(list, &json_clean_term?/1)

  defp json_clean_term?(map) when is_map(map) do
    Enum.all?(map, fn
      {k, v} when is_binary(k) or is_atom(k) -> json_clean_term?(v)
      _ -> false
    end)
  end

  defp json_clean_term?(_), do: false

  defp merge_dependency_baseline(resource, dep_lease, admitted) do
    %{
      resource
      | dependency_lease: dep_lease,
        candidate_deps_path: admitted.candidate_deps_path,
        base_deps_path: admitted.base_deps_path,
        dependency_receipt: admitted.dependency_receipt,
        dependency_verified_copy: admitted.dependency_verified_copy
    }
  end

  defp check_deadline(opts) when is_list(opts) do
    deadline =
      Keyword.get(opts, :deadline_ms) || Keyword.get(opts, :deadline)

    case deadline do
      nil ->
        :ok

      ms when is_integer(ms) ->
        if System.monotonic_time(:millisecond) < ms,
          do: :ok,
          else: {:error, :operation_deadline_exceeded}

      _ ->
        {:error, :invalid_deadline}
    end
  end

  defp check_deadline(opts) when is_map(opts) do
    check_deadline(Map.to_list(opts))
  end

  defp check_deadline(_), do: :ok

  # Used by workspace acquire/release retained-identity checks. Not the retired
  # host dependency snapshot walk.
  defp canonical_existing_path(path) when is_binary(path) do
    case SafePath.resolve_real(path) do
      {:ok, resolved} ->
        {:ok, resolved}

      _ ->
        case System.cmd("realpath", [path], stderr_to_stdout: true) do
          {resolved, 0} -> {:ok, String.trim(resolved)}
          _ -> {:error, :path_resolve_failed}
        end
    end
  rescue
    _ -> {:error, :path_resolve_failed}
  end

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
    materializer = state.linux_dependency_baseline_materializer

    # Phase 1: Actions-owned root + detached worktrees.
    # Phase 2: Shell dependency-baseline lease release (idempotent after success).
    case cleanup_actions_owned_validation_files(resource) do
      :ok ->
        case release_dependency_baseline_lease(
               materializer,
               Map.get(resource, :dependency_lease)
             ) do
          :ok ->
            # Drop the opaque lease from the retained record only after proven release.
            cleared = %{resource | dependency_lease: nil}

            state = %{
              state
              | validation_resources:
                  Map.put(state.validation_resources, resource.resource_id, cleared)
            }

            {:ok, state}

          {:error, _reason} ->
            # Actions root is gone but Shell lease remains — retain for retry.
            {:error, state}
        end

      {:error, _reason} ->
        # Keep resource + lease for explicit retry.
        {:error, state}
    end
  end

  defp cleanup_actions_owned_validation_files(resource) do
    # Fail closed: never report Actions cleanup success (and thus never release
    # the Shell dependency lease) unless every Actions-owned step succeeded.
    with :ok <- cleanup_candidate_detached_worktree(resource),
         :ok <- cleanup_base_detached_worktree(resource),
         :ok <- cleanup_validation_root(resource) do
      :ok
    end
  rescue
    _error -> {:error, :resource_cleanup_failed}
  catch
    :exit, _reason -> {:error, :resource_cleanup_failed}
  end

  defp cleanup_candidate_detached_worktree(resource) do
    if is_binary(Map.get(resource, :candidate_commit)) do
      Workspace.remove_detached_worktree(resource.repo_path, resource.candidate_path)
    else
      :ok
    end
  end

  defp cleanup_base_detached_worktree(resource) do
    Workspace.remove_detached_worktree(resource.repo_path, resource.base_worktree_path)
  end

  defp cleanup_validation_root(resource) do
    root = resource.root_path

    if is_binary(root) do
      case File.rm_rf(root) do
        {:ok, _paths} ->
          case File.lstat(root) do
            {:error, :enoent} -> :ok
            _other -> {:error, :resource_root_still_exists}
          end

        {:error, reason, _path} ->
          {:error, reason}
      end
    else
      {:error, :invalid_resource_root}
    end
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
    candidate_home =
      Map.get(resource, :candidate_home_path) || Map.get(resource, :home_path)

    candidate_tmp = Map.get(resource, :candidate_tmp_path) || Map.get(resource, :tmp_path)

    candidate_runner =
      Map.get(resource, :candidate_runner_path) || Map.get(resource, :runner_path)

    # JSON-clean only. Never include dependency_lease, token, worker, owner,
    # private Shell root, or any other rich term from the opaque lease.
    %{
      resource_id: resource.resource_id,
      workspace_id: resource.workspace_id,
      repo_path: resource.repo_path,
      candidate_path: resource.candidate_path,
      candidate_commit: resource.candidate_commit,
      base_commit: resource.base_commit,
      root_path: resource.root_path,
      stage_parent_path: Map.get(resource, :stage_parent_path),
      stage_path: resource.stage_path,
      candidate_runtime_path: Map.get(resource, :candidate_runtime_path),
      candidate_home_path: candidate_home,
      candidate_tmp_path: candidate_tmp,
      candidate_build_path: resource.candidate_build_path,
      candidate_deps_path: resource.candidate_deps_path,
      candidate_runner_path: candidate_runner,
      candidate_result_path: resource.candidate_result_path,
      base_runtime_path: Map.get(resource, :base_runtime_path),
      base_home_path: Map.get(resource, :base_home_path),
      base_tmp_path: Map.get(resource, :base_tmp_path),
      base_build_path: resource.base_build_path,
      base_deps_path: resource.base_deps_path,
      base_worktree_path: resource.base_worktree_path,
      base_runner_path: Map.get(resource, :base_runner_path),
      base_result_path: resource.base_result_path,
      home_path: candidate_home,
      tmp_path: candidate_tmp,
      runner_path: candidate_runner,
      baseline_receipt: Map.get(resource, :dependency_receipt),
      baseline_verified_copy: Map.get(resource, :dependency_verified_copy),
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
    resource_id = "validation_" <> token

    with {:ok, tmp_root} <- SafePath.resolve_real(System.tmp_dir!()) do
      root_path =
        Path.join(
          tmp_root,
          "arbor-validation-#{workspace_hash}-#{token}"
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
    else
      _ -> {:error, :validation_resource_create_failed}
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
            # The dead owner ref is gone, but exact task+principal authority
            # must remain available for the child cleanup. Quarantine the
            # parent and retry the child cleanup before retention conversion.
            case Map.get(state.leases, workspace_id) do
              nil ->
                {:noreply, state}

              lease ->
                {:noreply, preserve_cleanup_pending_after_owner_death(state, lease)}
            end

          {:ok, state} ->
            state =
              state
              |> cleanup_workspace_attestations(workspace_id)
              |> cleanup_workspace_review_snapshots(workspace_id)

            case Map.get(state.leases, workspace_id) do
              nil ->
                {:noreply, state}

              lease ->
                {:noreply, apply_owner_death_workspace_policy(state, lease)}
            end
        end
    end
  end

  # Registry lifecycle policy for owner death (TaskStore hard cancel / crash).
  # Serialized inside the GenServer — never a DOT node or Jido action.
  defp apply_owner_death_workspace_policy(state, lease) do
    cond do
      owner_death_quarantined?(lease) and lease.ownership == :owned ->
        # A reactivated quarantine keeps its deletion-disabled marker. On a
        # later owner death it must re-enter retention, never be dropped.
        retain_on_owner_death(state, lease, :owner_terminated)

      lease.cleanup_armed != true ->
        drop_lease(state, lease)

      lease.ownership == :reused ->
        # Reused paths are never deletion authority.
        drop_lease(state, lease)

      lease.ownership == :owned ->
        # Unexpected owner termination is not evidence that an external ACP
        # worker is quiescent. Never grant immediate deletion authority here.
        retain_on_owner_death(state, lease, :owner_terminated)

      true ->
        drop_lease(state, lease)
    end
  end

  defp retain_on_owner_death(state, lease, reason) do
    case do_release(state, lease, :retain) do
      {:ok, _result, state} ->
        state

      {:error, :retention_identity_unavailable, state} ->
        preserve_or_drop_after_failed_retain(
          state,
          lease,
          reason,
          :retention_identity_unavailable,
          :retention_identity_unavailable
        )

      {:error, other, state} ->
        preserve_or_drop_after_failed_retain(state, lease, reason, :retain_failed, other)
    end
  end

  defp preserve_or_drop_after_failed_retain(state, lease, reason, policy, detail) do
    path = lease.worktree_path

    if is_binary(path) and path != "" and File.dir?(path) do
      # Path still present: fail safe against data loss. Keep task+principal
      # authority with cleanup disarmed as an explicit quarantine.
      Logger.warning(
        "workspace owner-death retain failed while worktree still present; preserving lease",
        workspace_id: lease.workspace_id,
        task_id: lease.task_id,
        principal_id: lease.principal_id,
        ownership: lease.ownership,
        reason: reason,
        policy: policy,
        detail: inspect(detail)
      )

      lease =
        lease
        |> preserve_lease_after_owner_death(reason, policy, detail)
        |> schedule_owner_death_retention_retry(state)

      put_lease(state, lease)
    else
      # Path already gone (common teardown race): drop the lease only.
      drop_lease(state, lease)
    end
  end

  defp preserve_lease_after_owner_death(lease, reason, policy, detail) do
    lease
    |> Map.put(:cleanup_armed, false)
    |> Map.put(:active, true)
    |> Map.put(:owner_death_deletion_disabled, true)
    |> Map.put(:owner_death_quarantine_state, :identity_pending)
    |> Map.put(:owner_death_policy, policy)
    |> Map.put(:owner_death_policy_reason, reason)
    |> Map.put(:owner_death_policy_error, detail)
  end

  defp preserve_cleanup_pending_after_owner_death(state, lease) do
    lease =
      lease
      |> preserve_lease_after_owner_death(
        :owner_terminated,
        :validation_cleanup_pending,
        :validation_resource_cleanup_failed
      )
      |> Map.put(:owner_death_quarantine_state, :validation_cleanup_pending)

    put_lease(state, schedule_owner_death_retention_retry(lease, state))
  end

  defp schedule_owner_death_retention_retry(lease, state) do
    retry_count = Map.get(lease, :owner_death_retry_count, 0)
    limit = state.owner_death_retry_limit

    if retry_count >= limit do
      quarantine_state =
        case Map.get(lease, :owner_death_quarantine_state) do
          :validation_cleanup_pending -> :validation_cleanup_dormant
          _ -> :dormant
        end

      lease
      |> Map.put(:owner_death_retry_exhausted, true)
      |> Map.put(:owner_death_retry_generation, nil)
      |> Map.put(:owner_death_retry_ref, nil)
      |> Map.put(:owner_death_quarantine_state, quarantine_state)
    else
      delay_ms =
        min(
          state.owner_death_retry_base_ms * Integer.pow(2, min(retry_count, 5)),
          @max_owner_death_retry_base_ms
        )

      generation = make_ref()

      retry_ref =
        Process.send_after(
          self(),
          {:owner_death_retention_retry, lease.workspace_id, generation},
          delay_ms
        )

      lease
      |> Map.put(:owner_death_retry_count, retry_count + 1)
      |> Map.put(:owner_death_retry_exhausted, false)
      |> Map.put(:owner_death_retry_generation, generation)
      |> Map.put(:owner_death_retry_ref, retry_ref)
    end
  end

  defp retry_owner_death_retention(state, workspace_id, generation) do
    case Map.get(state.leases, workspace_id) do
      %{cleanup_armed: false, owner_death_retry_generation: ^generation} = lease ->
        retry_owner_death_quarantine(state, lease)

      _ ->
        state
    end
  end

  defp retry_owner_death_quarantine(
         state,
         %{owner_death_quarantine_state: :validation_cleanup_pending} = lease
       ) do
    case cleanup_workspace_validation_resources(state, lease.workspace_id) do
      {:error, state} ->
        preserve_cleanup_pending_after_owner_death(state, lease)

      {:ok, state} ->
        complete_owner_death_validation_cleanup(state, lease.workspace_id, {:ok, %{}})
    end
  end

  defp retry_owner_death_quarantine(state, lease),
    do: retain_on_owner_death(state, lease, :identity_retry)

  defp complete_owner_death_validation_cleanup(state, workspace_id, {:ok, _result}) do
    case Map.get(state.leases, workspace_id) do
      %{owner_death_quarantine_state: quarantine_state} = lease
      when quarantine_state in [:validation_cleanup_pending, :validation_cleanup_dormant] ->
        state =
          state
          |> cleanup_workspace_attestations(workspace_id)
          |> cleanup_workspace_review_snapshots(workspace_id)

        lease =
          lease
          |> Map.put(:owner_death_quarantine_state, :identity_pending)
          |> Map.put(:owner_death_policy, :retention_identity_unavailable)
          |> Map.put(:owner_death_policy_error, nil)

        state = put_lease(state, lease)
        apply_owner_death_workspace_policy(state, lease)

      _ ->
        state
    end
  end

  defp complete_owner_death_validation_cleanup(state, _workspace_id, _result), do: state

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

  # Hot-load compatibility: a long-lived GenServer may still hold a
  # pre-review-snapshot state map after new code is loaded. Lazily fill the
  # snapshot indexes without weakening workspace/task/principal authorization.
  defp ensure_review_snapshot_state(state) when is_map(state) do
    state
    |> Map.put_new(:review_snapshots, %{})
    |> Map.put_new(:review_snapshots_by_workspace, %{})
  end

  defp perform_open_review_snapshot(state, workspace_id, candidate_commit, caller) do
    state = ensure_review_snapshot_state(state)

    with {:ok, lease} <- fetch_authorized(state, workspace_id, caller),
         true <- lease.active == true || {:error, :not_found},
         :ok <- require_exact_commit_hash(candidate_commit),
         :ok <- require_exact_commit_hash(lease.base_commit),
         inspection <- Workspace.inspect_worktree(lease.worktree_path, lease.base_commit),
         :ok <- require_existing_worktree(inspection),
         :ok <- require_clean_worktree(inspection),
         :ok <- require_head_equals_candidate(inspection, candidate_commit),
         {:ok, candidate_tree_oid} <- git_tree_oid(lease.repo_path, candidate_commit),
         {:ok, base_tree_oid} <- git_tree_oid(lease.repo_path, lease.base_commit) do
      snapshot = %{
        review_snapshot_id: generate_review_snapshot_id(),
        workspace_id: lease.workspace_id,
        task_id: lease.task_id,
        principal_id: lease.principal_id,
        repo_path: lease.repo_path,
        candidate_commit: candidate_commit,
        base_commit: lease.base_commit,
        candidate_tree_oid: candidate_tree_oid,
        base_tree_oid: base_tree_oid
      }

      state = put_review_snapshot(state, snapshot)
      {:ok, review_snapshot_view(snapshot), state}
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_authorized_review_snapshot(state, review_snapshot_id, caller) do
    with {:ok, snapshot} <- fetch_review_snapshot(state, review_snapshot_id),
         {:ok, _lease} <- fetch_authorized(state, snapshot.workspace_id, caller) do
      {:ok, snapshot}
    end
  end

  defp fetch_review_snapshot(state, review_snapshot_id) do
    state = ensure_review_snapshot_state(state)

    case Map.fetch(state.review_snapshots, review_snapshot_id) do
      {:ok, snapshot} -> {:ok, snapshot}
      :error -> {:error, :not_found}
    end
  end

  defp put_review_snapshot(state, snapshot) do
    state = ensure_review_snapshot_state(state)

    ids =
      state.review_snapshots_by_workspace
      |> Map.get(snapshot.workspace_id, MapSet.new())
      |> MapSet.put(snapshot.review_snapshot_id)

    %{
      state
      | review_snapshots: Map.put(state.review_snapshots, snapshot.review_snapshot_id, snapshot),
        review_snapshots_by_workspace:
          Map.put(state.review_snapshots_by_workspace, snapshot.workspace_id, ids)
    }
  end

  defp drop_review_snapshot(state, snapshot) do
    state = ensure_review_snapshot_state(state)

    ids =
      state.review_snapshots_by_workspace
      |> Map.get(snapshot.workspace_id, MapSet.new())
      |> MapSet.delete(snapshot.review_snapshot_id)

    by_workspace =
      if MapSet.size(ids) == 0 do
        Map.delete(state.review_snapshots_by_workspace, snapshot.workspace_id)
      else
        Map.put(state.review_snapshots_by_workspace, snapshot.workspace_id, ids)
      end

    %{
      state
      | review_snapshots: Map.delete(state.review_snapshots, snapshot.review_snapshot_id),
        review_snapshots_by_workspace: by_workspace
    }
  end

  defp cleanup_workspace_review_snapshots(state, workspace_id) do
    state = ensure_review_snapshot_state(state)

    ids =
      state.review_snapshots_by_workspace
      |> Map.get(workspace_id, MapSet.new())
      |> MapSet.to_list()

    %{
      state
      | review_snapshots: Map.drop(state.review_snapshots, ids),
        review_snapshots_by_workspace:
          Map.delete(state.review_snapshots_by_workspace, workspace_id)
    }
  end

  defp require_exact_commit_hash(commit) when is_binary(commit) do
    if Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, commit) do
      :ok
    else
      {:error, :invalid_candidate_commit}
    end
  end

  defp require_exact_commit_hash(_), do: {:error, :invalid_candidate_commit}

  defp require_existing_worktree(%{exists: true}), do: :ok
  defp require_existing_worktree(_), do: {:error, :worktree_missing}

  defp require_clean_worktree(%{dirty: true}), do: {:error, :dirty_workspace}
  defp require_clean_worktree(_), do: :ok

  defp require_head_equals_candidate(%{head_commit: head}, candidate)
       when is_binary(head) and head != "" do
    if head == candidate, do: :ok, else: {:error, :head_commit_mismatch}
  end

  defp require_head_equals_candidate(_, _), do: {:error, :missing_commit_hash}

  defp git_tree_oid(repo_path, commit) do
    case System.cmd(
           "git",
           ["-C", repo_path, "rev-parse", "--verify", "#{commit}^{tree}"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        oid = String.trim(output)

        if Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, oid) do
          {:ok, oid}
        else
          {:error, :tree_oid_failed}
        end

      {_output, _code} ->
        {:error, :tree_oid_failed}
    end
  rescue
    _ -> {:error, :tree_oid_failed}
  end

  defp generate_review_snapshot_id do
    "review_snap_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
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
        Keyword.get(opts, :force_partial_cleanup_failure_once) == true,
      deadline_ms: Keyword.get(opts, :deadline_ms),
      snapshot_bounds: Keyword.get(opts, :snapshot_bounds) || %{}
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
          Map.get(opts, "force_partial_cleanup_failure_once") == true,
      deadline_ms: Map.get(opts, :deadline_ms) || Map.get(opts, "deadline_ms"),
      snapshot_bounds: Map.get(opts, :snapshot_bounds) || Map.get(opts, "snapshot_bounds") || %{}
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
      worktree_path: Map.get(attrs, :worktree_path) || Map.get(attrs, "worktree_path"),
      create_worktree: create_worktree
    }
  end

  defp prepare_acquire_identity(attrs, owner_pid) do
    with true <- is_pid(owner_pid) || {:error, :invalid_owner_pid},
         :ok <- require_binary(attrs.repo_path, :repo_path),
         :ok <- require_binary(attrs.branch, :branch),
         {:ok, repo_path} <- canonical_repo_path(attrs.repo_path, attrs.create_worktree),
         {:ok, branch} <- validate_branch(attrs.branch),
         {:ok, workspace_id} <- resolve_workspace_id(attrs.workspace_id),
         {:ok, candidate_path} <- candidate_worktree_path(attrs, branch) do
      {:ok,
       %{
         workspace_id: workspace_id,
         owner_pid: owner_pid,
         task_id: attrs.task_id,
         principal_id: attrs.principal_id,
         repo_path: repo_path,
         branch: branch,
         workspace_id_explicit: is_binary(attrs.workspace_id) and attrs.workspace_id != "",
         candidate_path: candidate_path,
         create_params: create_params(attrs),
         create_worktree: attrs.create_worktree
       }}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_owner_pid}
    end
  end

  defp continue_acquire(state, prepared) do
    with :ok <- ensure_workspace_id_free(state, prepared.workspace_id),
         :ok <- ensure_target_free(state, prepared.repo_path, prepared.branch) do
      case retained_acquire(state, prepared) do
        :none ->
          if Map.has_key?(state.retained_by_id, prepared.workspace_id) do
            {:reply, {:error, :workspace_id_collision}, state}
          else
            perform_acquire(prepared, state)
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}

        {:ok, retained} ->
          reactivate_retained(retained, prepared, state)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp quarantined_acquire(state, prepared) do
    quarantine =
      Enum.find_value(state.leases, fn {_workspace_id, lease} ->
        if quarantined_target?(lease, prepared), do: lease
      end)

    case quarantine do
      nil ->
        :none

      lease ->
        cond do
          prepared.workspace_id_explicit and prepared.workspace_id != lease.workspace_id ->
            {:error, :workspace_in_use}

          canonical_path_or_expanded(prepared.candidate_path) !=
              canonical_path_or_expanded(lease.worktree_path) ->
            {:error, :workspace_in_use}

          Map.get(lease, :owner_death_quarantine_state) in [
            :validation_cleanup_pending,
            :validation_cleanup_dormant
          ] ->
            # Child cleanup is still registry-owned after the parent owner
            # died. A new owner cannot adopt the parent around that cleanup.
            {:error, :workspace_cleanup_pending}

          principal_task_match?(lease, prepared) ->
            {:ok, lease}

          true ->
            {:error, :workspace_in_use}
        end
    end
  end

  defp quarantined_target?(lease, prepared) do
    lease.cleanup_armed == false and
      owner_death_quarantined?(lease) and
      lease.repo_path == prepared.repo_path and lease.branch == prepared.branch and
      (not is_pid(lease.owner_pid) or not Process.alive?(lease.owner_pid))
  end

  defp reactivate_quarantined(lease, prepared, state) do
    cancel_owner_death_retry(lease)
    owner_ref = Process.monitor(prepared.owner_pid)

    lease =
      lease
      |> Map.merge(%{
        owner_pid: prepared.owner_pid,
        owner_ref: owner_ref,
        active: true,
        cleanup_armed: true,
        owner_death_quarantine_state: :reactivated,
        owner_death_retry_count: 0,
        owner_death_retry_exhausted: false,
        owner_death_retry_generation: nil,
        owner_death_retry_ref: nil
      })

    state = state |> put_lease(lease) |> put_ref(lease)
    {:reply, {:ok, public_view(lease)}, state}
  end

  defp create_params(attrs) do
    %{}
    |> put_optional(:base_ref, attrs.base_ref)
    |> put_optional(:worktree_base_dir, attrs.worktree_base_dir)
    |> put_optional(:task, attrs.task)
  end

  defp candidate_worktree_path(attrs, branch) do
    base_dir = attrs.worktree_base_dir || System.tmp_dir!()

    path =
      if is_binary(attrs.worktree_path) and attrs.worktree_path != "" do
        Path.expand(attrs.worktree_path)
      else
        Path.join(Path.expand(base_dir), Workspace.worktree_dir_name(branch))
      end

    with :ok <- require_binary(base_dir, :worktree_base_dir) do
      {:ok, canonical_path_or_expanded(path)}
    end
  end

  defp canonical_path_or_expanded(path) do
    case SafePath.resolve_real(path) do
      {:ok, canonical} -> canonical
      {:error, _} -> Path.expand(path)
    end
  end

  defp canonical_repo_path(path, create_worktree) do
    case Git.execute(path, ["rev-parse", "--show-toplevel"]) do
      {:ok, %{exit_code: 0, stdout: output}} ->
        case String.trim(output) do
          "" -> {:error, :invalid_git_repository}
          canonical -> {:ok, canonical}
        end

      _ when is_function(create_worktree, 3) ->
        # Injected callbacks are deliberately allowed to model registry
        # behavior without a real repository. Real repositories still take
        # the hardened Git facade path above.
        {:ok, Path.expand(path)}

      _ ->
        {:error, :invalid_git_repository}
    end
  end

  defp validate_branch(branch) do
    case Git.validate_branch_name(branch) do
      :ok -> {:ok, branch}
      {:error, _} -> {:error, {:invalid, :branch}}
    end
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

  defp retained_acquire(state, prepared) do
    target = target_key(prepared.repo_path, prepared.branch, prepared.candidate_path)

    case Map.get(state.retained_by_target, target) do
      nil ->
        case retained_for_repo_branch(state, prepared.repo_path, prepared.branch) do
          nil ->
            :none

          retained ->
            if retained_authorized?(retained, prepared) do
              {:error, :retained_target_mismatch}
            else
              {:error, :retained_workspace_not_authorized}
            end
        end

      retained ->
        if retained_authorized?(retained, prepared) do
          {:ok, retained}
        else
          {:error, :retained_workspace_not_authorized}
        end
    end
  end

  defp retained_for_repo_branch(state, repo_path, branch) do
    Enum.find_value(state.retained_by_id, fn {_id, retained} ->
      if retained.repo_path == repo_path and retained.branch == branch, do: retained
    end)
  end

  defp retained_authorized?(retained, prepared) do
    (is_pid(retained.owner_pid) and retained.owner_pid == prepared.owner_pid and
       Process.alive?(retained.owner_pid)) or
      principal_task_match?(retained, prepared)
  end

  defp perform_acquire(prepared, state) do
    # Monitor before any git side effect so a mid-create owner death queues DOWN.
    owner_ref = Process.monitor(prepared.owner_pid)

    case run_create_worktree(prepared) do
      {:ok, worktree_path, ownership, base_commit} ->
        with {:ok, ownership_atom} <- normalize_ownership(ownership),
             :ok <- require_binary(worktree_path, :worktree_path),
             {:ok, canonical_worktree_path} <- canonical_existing_path(worktree_path),
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
            cleanup_failed_create(prepared.repo_path, canonical_worktree_path, ownership_atom)
            {:reply, {:error, :workspace_id_collision}, state}
          else
            case ensure_target_free(state, lease.repo_path, lease.branch) do
              :ok ->
                state =
                  state
                  |> put_lease(lease)
                  |> put_ref(lease)

                # If the owner already died, DOWN is queued and will move an
                # owned worktree into bounded retention.
                {:reply, {:ok, public_view(lease)}, state}

              {:error, reason} ->
                Process.demonitor(owner_ref, [:flush])
                cleanup_failed_create(prepared.repo_path, canonical_worktree_path, ownership_atom)
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

  defp reactivate_retained(retained, prepared, state) do
    with :ok <- validate_retained_identity(retained, prepared),
         {:ok, workspace_id} <- fresh_workspace_id(state, prepared, retained) do
      owner_ref = Process.monitor(prepared.owner_pid)
      cancel_expiry(retained.expiry_ref)

      lease = %{
        workspace_id: workspace_id,
        owner_pid: prepared.owner_pid,
        owner_ref: owner_ref,
        task_id: prepared.task_id || retained.task_id,
        principal_id: prepared.principal_id || retained.principal_id,
        repo_path: retained.repo_path,
        worktree_path: Map.get(retained, :display_worktree_path, retained.worktree_path),
        branch: retained.branch,
        base_commit: retained.base_commit,
        ownership: :owned,
        active: true,
        cleanup_armed: true
      }

      state = drop_retained(state, retained)
      state = state |> put_lease(lease) |> put_ref(lease)
      {:reply, {:ok, public_view(lease)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp fresh_workspace_id(
         state,
         %{workspace_id_explicit: true, workspace_id: workspace_id},
         retained
       ) do
    cond do
      workspace_id == retained.workspace_id ->
        {:ok, workspace_id}

      Map.has_key?(state.leases, workspace_id) or Map.has_key?(state.retained_by_id, workspace_id) ->
        {:error, :workspace_id_collision}

      true ->
        {:ok, workspace_id}
    end
  end

  defp fresh_workspace_id(state, _prepared, _retained) do
    workspace_id = generate_workspace_id()

    if Map.has_key?(state.leases, workspace_id) or
         Map.has_key?(state.retained_by_id, workspace_id),
       do: fresh_workspace_id(state, %{workspace_id_explicit: false}, nil),
       else: {:ok, workspace_id}
  end

  defp validate_retained_identity(retained, prepared) do
    with true <-
           target_key(prepared.repo_path, prepared.branch, prepared.candidate_path) ==
             retained.target,
         {:ok, current_path} <- canonical_existing_path(prepared.candidate_path),
         true <- current_path == retained.worktree_path,
         {:ok, current_lstat} <- File.lstat(retained.worktree_path),
         true <- lstat_identity(current_lstat) == retained.lstat_identity,
         {:ok, registration} <- worktree_registration(retained.repo_path, retained.worktree_path),
         true <- registration == retained.worktree_registration,
         {:ok, current_branch} <- current_branch(retained.repo_path, retained.worktree_path),
         true <- current_branch == retained.branch do
      :ok
    else
      _ -> {:error, :retained_identity_mismatch}
    end
  end

  defp cancel_expiry(nil), do: :ok
  defp cancel_expiry(ref) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_expiry(_), do: :ok

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

  defp owner_death_quarantined?(lease) do
    Map.get(lease, :owner_death_deletion_disabled) == true
  end

  defp do_release(state, lease, :retain) when lease.ownership == :reused do
    state = drop_lease(state, lease)
    # A reused path never becomes deletion authority and never gets a timer.
    Process.demonitor(lease.owner_ref, [:flush])

    result =
      lease
      |> public_view()
      |> Map.put(:active, false)
      |> Map.put(:status, "retained")

    {:ok, result, state}
  end

  defp do_release(state, lease, :retain) when lease.ownership == :owned do
    case capture_retention_identity(lease) do
      {:ok, identity} ->
        now_ms = System.monotonic_time(:millisecond)
        ttl_ms = state.retention_ttl_ms
        expires_at_ms = now_ms + ttl_ms
        expires_at = DateTime.add(DateTime.utc_now(), ttl_ms, :millisecond)
        generation = make_ref()
        target = target_key(lease.repo_path, lease.branch, identity.worktree_path)

        retained = %{
          workspace_id: lease.workspace_id,
          owner_pid: lease.owner_pid,
          task_id: lease.task_id,
          principal_id: lease.principal_id,
          repo_path: lease.repo_path,
          worktree_path: identity.worktree_path,
          display_worktree_path: lease.worktree_path,
          branch: lease.branch,
          base_commit: lease.base_commit,
          ownership: :owned,
          target: target,
          lstat_identity: identity.lstat_identity,
          worktree_registration: identity.worktree_registration,
          expiry_generation: generation,
          expiry_ref: nil,
          expires_at: expires_at,
          expires_at_ms: expires_at_ms,
          retry_count: 0,
          cleanup_failure: nil
        }

        expiry_ref = Process.send_after(self(), {:retained_expire, target, generation}, ttl_ms)
        retained = %{retained | expiry_ref: expiry_ref}
        state = drop_lease(state, lease) |> put_retained(retained)
        Process.demonitor(lease.owner_ref, [:flush])

        result =
          lease
          |> public_view()
          |> Map.put(:active, false)
          |> Map.put(:status, "retained")
          |> Map.put(:expires_at, DateTime.to_iso8601(expires_at))

        {:ok, result, state}

      {:error, reason} ->
        # Public release surface keeps the stable atom; owner-death logging uses the detail.
        Logger.debug(
          "workspace retain identity unavailable",
          workspace_id: lease.workspace_id,
          detail: inspect(reason)
        )

        {:error, :retention_identity_unavailable, state}
    end
  end

  defp do_release(
         state,
         %{ownership: :owned, owner_death_deletion_disabled: true} = lease,
         :remove
       ) do
    # Exact task+principal can resume a quarantine, but it cannot turn a path
    # that was never identity-pinned into force-delete authority. Capture a
    # currently registered identity immediately before the destructive call.
    case capture_retention_identity(lease) do
      {:ok, _identity} ->
        do_release_after_identity_capture(state, lease)

      {:error, _reason} ->
        {:error, :quarantine_identity_unavailable, state}
    end
  end

  defp do_release(state, lease, :remove), do: do_release_after_identity_capture(state, lease)

  defp do_release_after_identity_capture(state, lease) do
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

    {:ok, result, state}
  end

  defp drop_lease(state, lease) do
    cancel_owner_death_retry(lease)

    %{
      state
      | leases: Map.delete(state.leases, lease.workspace_id),
        by_ref: Map.delete(state.by_ref, lease.owner_ref)
    }
  end

  defp cancel_owner_death_retry(lease) do
    case Map.get(lease, :owner_death_retry_ref) do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end
  end

  defp put_retained(state, retained) do
    %{
      state
      | retained_by_id: Map.put(state.retained_by_id, retained.workspace_id, retained),
        retained_by_target: Map.put(state.retained_by_target, retained.target, retained)
    }
  end

  defp drop_retained(state, retained) do
    %{
      state
      | retained_by_id: Map.delete(state.retained_by_id, retained.workspace_id),
        retained_by_target: Map.delete(state.retained_by_target, retained.target)
    }
  end

  defp already_released_view(workspace_id) do
    %{
      workspace_id: workspace_id,
      active: false,
      status: "already_released"
    }
  end

  defp capture_retention_identity(lease) do
    with {:ok, canonical_worktree_path} <- canonical_existing_path(lease.worktree_path),
         {:ok, lstat} <- File.lstat(canonical_worktree_path),
         {:ok, registration} <- worktree_registration(lease.repo_path, canonical_worktree_path),
         true <- registration.branch == lease.branch,
         {:ok, current_branch} <- current_branch(lease.repo_path, canonical_worktree_path),
         true <- current_branch == lease.branch do
      {:ok,
       %{
         worktree_path: canonical_worktree_path,
         lstat_identity: lstat_identity(lstat),
         worktree_registration: registration
       }}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_identity, other}}
    end
  end

  defp expire_retained(state, target, generation) do
    case Map.get(state.retained_by_target, target) do
      %{} = retained when retained.expiry_generation == generation ->
        cond do
          System.monotonic_time(:millisecond) < retained.expires_at_ms ->
            reschedule_retained_expiry(state, retained)

          active_target?(state, target) ->
            state

          true ->
            case cleanup_retained_worktree(state, retained) do
              :ok ->
                drop_retained(state, retained)

              {:error, reason} ->
                schedule_retained_retry(state, retained, reason)
            end
        end

      _ ->
        state
    end
  end

  defp active_target?(state, target) do
    Enum.any?(state.leases, fn {_id, lease} ->
      target_key(lease.repo_path, lease.branch, lease.worktree_path) == target
    end)
  end

  defp cleanup_retained_worktree(state, retained) do
    case validate_retained_stored_identity(retained) do
      :ok ->
        case invoke_retained_cleanup(state.retained_cleanup, retained) do
          :ok ->
            case verify_retained_removed(retained) do
              :ok -> :ok
              {:error, reason} -> {:error, {:cleanup_execution, reason}}
            end

          {:error, reason} ->
            {:error, {:cleanup_execution, reason}}
        end

      {:error, reason} ->
        {:error, {:identity_uncertain, reason}}
    end
  end

  defp validate_retained_stored_identity(retained) do
    with target <- target_key(retained.repo_path, retained.branch, retained.worktree_path),
         true <- target == retained.target,
         {:ok, current_path} <- canonical_existing_path(retained.worktree_path),
         true <- current_path == retained.worktree_path,
         {:ok, current_lstat} <- File.lstat(retained.worktree_path),
         true <- lstat_identity(current_lstat) == retained.lstat_identity,
         {:ok, registration} <- worktree_registration(retained.repo_path, retained.worktree_path),
         true <- registration == retained.worktree_registration,
         {:ok, current_branch} <- current_branch(retained.repo_path, retained.worktree_path),
         true <- current_branch == retained.branch do
      :ok
    else
      _ -> {:error, :retained_identity_mismatch}
    end
  end

  defp invoke_retained_cleanup(cleanup, retained) when is_function(cleanup, 2) do
    case cleanup.(retained.repo_path, retained.worktree_path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :retained_cleanup_failed}
    end
  rescue
    _ -> {:error, :retained_cleanup_failed}
  catch
    kind, reason -> {:error, {:retained_cleanup_thrown, kind, reason}}
  end

  defp invoke_retained_cleanup(_cleanup, _retained), do: {:error, :retained_cleanup_failed}

  defp verify_retained_removed(retained) do
    with {:error, :enoent} <- File.lstat(retained.worktree_path),
         {:ok, nil} <- worktree_registration_status(retained.repo_path, retained.worktree_path) do
      :ok
    else
      _ -> {:error, :retained_cleanup_unconfirmed}
    end
  end

  defp schedule_retained_retry(state, %{retry_count: retry_count} = retained, reason) do
    generation = make_ref()
    delay = min(1_000 * Integer.pow(2, min(retry_count, 5)), 60_000)

    expiry_ref =
      Process.send_after(self(), {:retained_expire, retained.target, generation}, delay)

    retained = %{
      retained
      | expiry_generation: generation,
        expiry_ref: expiry_ref,
        retry_count: retry_count + 1,
        cleanup_failure: reason
    }

    put_retained(state, retained)
  end

  defp reschedule_retained_expiry(state, retained) do
    remaining = max(retained.expires_at_ms - System.monotonic_time(:millisecond), 1)
    generation = make_ref()

    expiry_ref =
      Process.send_after(self(), {:retained_expire, retained.target, generation}, remaining)

    put_retained(state, %{retained | expiry_generation: generation, expiry_ref: expiry_ref})
  end

  defp target_key(repo_path, branch, worktree_path),
    do: {:workspace_target, repo_path, branch, worktree_path}

  defp lstat_identity(%File.Stat{} = stat) do
    Map.take(Map.from_struct(stat), [:type, :major_device, :minor_device, :inode])
  end

  defp worktree_registration(repo_path, worktree_path) do
    case worktree_registration_status(repo_path, worktree_path) do
      {:ok, registration} when is_map(registration) -> {:ok, registration}
      {:ok, nil} -> {:error, :worktree_not_registered}
      {:error, reason} -> {:error, reason}
    end
  end

  defp worktree_registration_status(repo_path, worktree_path) do
    with {:ok, output} <- git_output(repo_path, ["worktree", "list", "--porcelain"]) do
      registration =
        output
        |> String.split("\n\n", trim: true)
        |> Enum.map(&parse_worktree_registration/1)
        |> Enum.find(fn
          {:ok, %{path: path}} -> path == worktree_path
          _ -> false
        end)

      case registration do
        {:ok, value} -> {:ok, value}
        nil -> {:ok, nil}
      end
    end
  end

  defp parse_worktree_registration(entry) do
    lines = String.split(entry, "\n", trim: true)
    path = line_value(lines, "worktree ")
    head = line_value(lines, "HEAD ")
    branch = line_value(lines, "branch refs/heads/")

    if is_binary(path) and is_binary(head) and is_binary(branch) do
      {:ok, %{path: canonical_path_or_expanded(path), head: head, branch: branch}}
    else
      :error
    end
  end

  defp line_value(lines, prefix) do
    Enum.find_value(lines, fn line ->
      if String.starts_with?(line, prefix), do: String.replace_prefix(line, prefix, "")
    end)
  end

  defp current_branch(repo_path, worktree_path) do
    result =
      Git.with_storage_authority(repo_path, worktree_path, fn ->
        git_output(worktree_path, ["branch", "--show-current"])
      end)

    case result do
      {:ok, branch} ->
        case String.trim(branch) do
          "" -> {:error, :worktree_detached}
          current -> {:ok, current}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp git_output(path, args) do
    case Git.execute(path, args) do
      {:ok, %{exit_code: 0, stdout: output}} -> {:ok, output}
      {:ok, %{exit_code: code}} -> {:error, {:git_failed, code}}
      {:error, reason} -> {:error, reason}
    end
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

  # Destructive: explicit remove-of-owned and failed-create cleanup only.
  defp remove_owned_worktree(repo_root, worktree_path)
       when is_binary(repo_root) and is_binary(worktree_path) do
    if File.dir?(worktree_path) do
      result =
        Git.with_storage_authority(repo_root, worktree_path, fn ->
          Git.execute(repo_root, ["worktree", "remove", "--force", worktree_path])
        end)

      case result do
        {:ok, %{exit_code: 0}} ->
          :ok

        _ ->
          # Force-remove even if git worktree metadata is stale (dirty cancel).
          File.rm_rf(worktree_path)
          _ = Git.execute(repo_root, ["worktree", "prune"])

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
