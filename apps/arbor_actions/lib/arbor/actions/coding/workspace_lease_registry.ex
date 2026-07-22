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
  `Arbor.Shell` Linux baseline lease API. A separately supervised per-resource
  owner holds every Actions cleanup identity and acquires the process-bound
  opaque Shell lease itself. It monitors this registry and cleans the complete
  child resource if the registry restarts; neither the opaque lease nor the
  owner PID is projected in public views.

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

  ## Restart durability

  With a ready retention journal, every newly-created owned worktree writes a
  versioned JSON-clean lifecycle `"active"` marker through the public
  `Arbor.Persistence` facade before the live lease is exposed. Owned retained
  worktrees rewrite that same marker before live lease authority is dropped.
  An explicitly disabled journal is the rollback/runtime-only mode: fresh
  owned leases skip initial durable identity capture and use the legacy
  release-time identity capture and owner-death quarantine behavior.
  Markers are evidence only: reactivation and TTL cleanup revalidate canonical
  worktree path, lstat identity, registered worktree path, branch, and
  nonblank exact `task_id` + `principal_id` with the same identity checks as
  process-local retention. Git HEAD may be retained as evidence but is **not**
  part of authorization/recovery/cleanup identity — a resumed worker may commit.

  Crash consistency: reactivation **never** deletes the durable marker. Before
  converting retained state to a live lease, the registry atomically refreshes
  the same workspace-keyed marker as lifecycle `"active"` bound to the current
  BEAM runtime id with a fresh bounded expiry; if that persistence fails,
  retained state is left unchanged and reactivation is denied. Durable evidence
  remains throughout active ownership. The marker is deleted only after
  explicit/TTL cleanup has positively proved both path and Git registration
  absent. Marker/workspace keys stay stable across reactivation and later
  retain/remove transitions.

  Lifecycle / runtime id:
  * `"retained"` markers hydrate with TTL cleanup timers.
  * `"active"` markers for the **current** BEAM runtime id hydrate as
    orphaned-active (no TTL) so a registry-only restart cannot arm deletion
    while a live owner may still hold the worktree; exact task+principal
    reacquire rebinds them. Safety deliberately wins over liveness here: there
    is no TTL because the old owner process may still be alive in this BEAM.
    Without exact reactivation or release, operator/manual recovery is required.
    If both the canonical path and its Git registration are positively absent,
    hydration instead settles the completed removal by deleting the marker.
  * `"active"` markers from a **prior** BEAM incarnation may become retained
    because that incarnation is gone. Conversion persists one fresh bounded
    retention TTL; later retained restarts consume its remaining time.
  * Operational paths always use the canonical identity-checked
    `worktree_path`; `display_worktree_path` is never used for cleanup or
    identity.

  Retained worktree cleanup never falls back to raw `File.rm_rf` and never
  targets the primary checkout (`repo_path == worktree_path`). On bounded TTL
  expiry, the registry captures and durably binds the exact current branch tip,
  creates/verifies its hidden evidence ref, then advances through identity-bound
  worktree removal and provenance-gated branch retirement. Automatic cleanup
  pre-reserves a durable attempt count before every side effect; reservation
  failure poisons admission and keeps dormant evidence without performing it.

  Production starts a node-restart file backend
  (`WorkspaceRetentionDurableStore`). Tests inject a named backend via
  `:retention_journal` (`{store_name, backend}` or `:disabled`) and may inject
  `:retention_runtime_id` for hermetic incarnation tests.
  """

  use GenServer

  require Logger

  alias Arbor.Actions.Config
  alias Arbor.Actions.Coding.ValidationResourceOwner
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceReconciliationProjection
  alias Arbor.Actions.Coding.WorkspaceBranchLifecycleCore, as: BranchLifecycle
  alias Arbor.Actions.Coding.WorkspaceLifecycleStatusCore, as: LifecycleStatus
  alias Arbor.Actions.Coding.WorkspaceRetentionJournalCore, as: RetentionJournal
  alias Arbor.Actions.Git
  alias Arbor.Common.SafePath
  alias Arbor.Persistence

  @type ownership :: :owned | :reused
  @type branch_provenance :: :created | :reused | :unknown
  @type release_mode :: :retain | :remove | :discard | :publish | :publish_retain
  @type discard_phase :: :archive | :worktree | :branch

  # Owner-death retries are a liveness aid, never deletion authority. An
  # exhausted quarantine remains available to its exact task+principal for
  # explicit inspection and recovery, but stops waking the registry forever.
  @default_owner_death_retry_limit 3
  @max_owner_death_retry_limit 10
  @default_owner_death_retry_base_ms 1_000
  @max_owner_death_retry_base_ms 60_000
  # Automatic retained cleanup / marker-delete retries before dormant evidence.
  @default_retained_cleanup_retry_limit 8
  @validation_owner_cleanup_retry_initial_ms 50
  @validation_owner_cleanup_retry_max_ms 2_000
  @default_validation_owner_cleanup_retry_limit 8
  @max_validation_owner_cleanup_retry_limit 32

  # Actions-owned validation roots accumulate compiled Mix artifact trees
  # (candidate-runtime/build/lib/<app>/ebin, ...). Depth-scaled Shell listing
  # budgets must be raised for those wide directories; keep the ceiling at
  # OwnedTree's public maximum and give cleanup a full bounded wall clock.
  @validation_root_cleanup_listing_heap_words 8_000_000
  @validation_root_cleanup_timeout_ms 10_000

  @type lease :: %{
          optional(:retention_marker_active) => boolean(),
          optional(:retention_repo_path) => String.t(),
          optional(:retention_worktree_path) => String.t(),
          optional(:retention_lstat_identity) => map(),
          optional(:retention_worktree_registration) => map(),
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
          # Path ownership is not branch ownership. Branch deletion is gated
          # solely by branch_provenance == :created plus tip/base equality.
          branch_provenance: branch_provenance(),
          active: boolean(),
          cleanup_armed: boolean()
        }

  @type retained_lease :: %{
          optional(:settlement_tip) => String.t(),
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
          branch_provenance: branch_provenance(),
          # Hot lifecycle: :retained | :active_orphaned | :discarding.
          lifecycle: :retained | :active_orphaned | :discarding,
          # Present only while lifecycle is :discarding.
          discard_phase: discard_phase() | nil,
          runtime_id: String.t(),
          target: tuple(),
          lstat_identity: map() | nil,
          worktree_registration: map() | nil,
          expiry_generation: reference(),
          expiry_ref: reference() | nil,
          expires_at: DateTime.t(),
          expires_at_ms: integer(),
          retry_count: non_neg_integer(),
          cleanup_failure: term() | nil,
          dormant: boolean()
        }

  @type validation_resource :: %{
          resource_id: String.t(),
          workspace_id: String.t(),
          owner_pid: pid(),
          owner_ref: reference(),
          repo_path: String.t(),
          candidate_path: String.t(),
          candidate_commit: String.t() | nil,
          candidate_cleanup_identity: map() | nil,
          base_commit: String.t(),
          root_path: String.t(),
          root_cleanup_identity: map() | nil,
          # Private staging parent (0700). Exact stage_path child is created
          # exclusively by SecurityRegression.Shell.stage_sources/2.
          stage_parent_path: String.t(),
          stage_path: String.t(),
          candidate_runtime_path: String.t(),
          candidate_home_path: String.t(),
          candidate_tmp_path: String.t(),
          candidate_build_path: String.t(),
          candidate_deps_path: String.t() | nil,
          candidate_runner_dir_path: String.t(),
          candidate_runner_path: String.t(),
          candidate_result_dir_path: String.t(),
          candidate_result_path: String.t(),
          base_runtime_path: String.t(),
          base_home_path: String.t(),
          base_tmp_path: String.t(),
          base_build_path: String.t(),
          base_deps_path: String.t() | nil,
          base_worktree_path: String.t(),
          base_cleanup_identity: map() | nil,
          base_runner_dir_path: String.t(),
          base_runner_path: String.t(),
          base_result_dir_path: String.t(),
          base_result_path: String.t(),
          resource_owner_pid: pid() | nil,
          resource_owner_ref: reference() | nil,
          resource_owner_cleanup_retry_ms: pos_integer(),
          resource_owner_cleanup_retry_count: non_neg_integer(),
          resource_owner_cleanup_dormant: boolean(),
          # Internal presence marker only. The opaque Shell lease remains in
          # resource_owner_pid and is never copied into registry/public state.
          dependency_lease: :resource_owner | :owner_lost | nil,
          dependency_root_path: String.t() | nil,
          dependency_receipt: map() | nil,
          dependency_verified_copy: boolean() | nil,
          snapshot_created: boolean(),
          setup_status: :active | :setup_failed,
          cleanup_failures_remaining: non_neg_integer()
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
  Inspect an **active** lease using **only** exact opaque `task_id` +
  `principal_id` lineage.

  Deliberately ignores live owner-PID authority: the GenServer caller PID is
  never consulted. Use this when a process that happens to own the lease must
  still prove exact task+principal binding (for example council root workdir
  derivation). Opaque `workspace_id` alone is never authority.

  Identity strings are opaque after validation: blank, invalid UTF-8, and
  NUL-bearing values are rejected, but accepted values are never trimmed or
  otherwise rewritten before exact comparison. Retained/creation blockers are
  never returned — a missing active lease is `:not_found` even when a blocker
  shares the same lineage.

  Supports `:server` selection like other registry operations.
  """
  @spec inspect_lease_by_lineage(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def inspect_lease_by_lineage(workspace_id, task_id, principal_id, opts \\ [])

  def inspect_lease_by_lineage(workspace_id, task_id, principal_id, opts)
      when is_binary(workspace_id) and is_binary(task_id) and is_binary(principal_id) and
             is_list(opts) do
    # Opaque after validation: blank includes whitespace-only; never rewrite an
    # accepted identity before lookup or exact comparison.
    if valid_opaque_id?(workspace_id) and valid_opaque_id?(task_id) and
         valid_opaque_id?(principal_id) do
      call({:inspect_by_lineage, workspace_id, task_id, principal_id}, opts)
    else
      {:error, :invalid_task_principal}
    end
  end

  def inspect_lease_by_lineage(_workspace_id, _task_id, _principal_id, _opts),
    do: {:error, :invalid_task_principal}

  @doc """
  Release a lease when authorized.

  Modes:
  * `:retain` / `"retain"` - disarm cancellation cleanup and preserve the worktree
  * `:remove` / `"remove"` - remove only invocation-owned worktrees; reused paths
    survive. Local branches are always preserved for review.
  * `:publish` / `"publish"` - archive the exact reviewed candidate tip to its
    task/workspace-bound hidden evidence ref, then apply remove semantics.
  * `:publish_retain` / `"publish_retain"` - archive the exact reviewed candidate
    tip, then apply retain semantics.
  * `:discard` / `"discard"` - remove an invocation-owned worktree and retire the
    local branch only when this invocation created that exact branch and its tip
    still equals the recorded base. Crash-durable: intent is journaled before
    destructive work. Reused/pre-existing branches and uncertain provenance fail
    closed by preserving the ref.

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

  @doc """
  Settle every workspace lease retained or active for an exact task+principal.

  Authority is the nonblank exact `task_id` **and** `principal_id` pair only —
  opaque workspace ids are never accepted as authority. For each matching
  active, retained, or orphaned-active lease the registry attempts remove-mode
  settlement (including both-path-absent marker drop without destructive work).

  Returns:
  * `{:ok, receipt}` when every matching record is positively settled or none
    match (idempotent empty settle)
  * `{:error, reason}` when any matching record cannot be positively confirmed
    settled — parent callers must fail closed and retain their roots
  """
  @spec settle_task_workspaces(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def settle_task_workspaces(task_id, principal_id, opts \\ [])

  def settle_task_workspaces(task_id, principal_id, opts)
      when is_binary(task_id) and is_binary(principal_id) and is_list(opts) do
    if non_empty_id?(task_id) and non_empty_id?(principal_id) do
      call({:settle_task_workspaces, task_id, principal_id}, opts)
    else
      {:error, :invalid_task_principal}
    end
  end

  def settle_task_workspaces(_task_id, _principal_id, _opts),
    do: {:error, :invalid_task_principal}

  @doc """
  Return a bounded, JSON-clean protection inventory for one canonical repository.

  This is intentionally not an authorization lookup: it includes all active,
  retained, orphaned, discarding, dormant, and pre-create durable blockers. The
  caller receives only branch refs and reasons, never task or principal data.
  """
  @spec branch_protection_inventory(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def branch_protection_inventory(repo_path, opts \\ [])

  def branch_protection_inventory(repo_path, opts)
      when is_binary(repo_path) and is_list(opts) do
    max_entries = Keyword.get(opts, :max_entries, RetentionJournal.max_records())

    if is_integer(max_entries) and max_entries > 0 and
         max_entries <= RetentionJournal.max_records() do
      call({:branch_protection_inventory, Path.expand(repo_path), max_entries}, opts)
    else
      {:error, :retention_inventory_oversized}
    end
  end

  def branch_protection_inventory(_repo_path, _opts),
    do: {:error, :retention_inventory_unavailable}

  @doc """
  Return a bounded, JSON-clean aggregate of workspace lifecycle state.

  This is a direct hot-state snapshot and intentionally does not validate the
  retention journal inventory. It remains available while the journal is
  poisoned, degraded, disabled, or malformed.
  """
  @spec lifecycle_status(keyword()) :: {:ok, map()} | {:error, term()}
  def lifecycle_status(opts \\ [])

  def lifecycle_status(opts) when is_list(opts),
    do: call(:lifecycle_status, opts)

  def lifecycle_status(_opts), do: {:error, :invalid_lifecycle_status_options}

  @doc false
  @spec reconciliation_inventory(String.t() | nil, String.t() | nil, pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconciliation_inventory(task_id, principal_id, max_items, opts \\ [])

  def reconciliation_inventory(task_id, principal_id, max_items, opts)
      when (is_binary(task_id) or is_nil(task_id)) and
             (is_binary(principal_id) or is_nil(principal_id)) and
             is_integer(max_items) and max_items > 0 and is_list(opts) do
    if max_items <= RetentionJournal.max_records() do
      call({:reconciliation_inventory, task_id, principal_id, max_items}, opts)
    else
      {:error, :invalid_reconciliation_inventory_options}
    end
  end

  def reconciliation_inventory(_task_id, _principal_id, _max_items, _opts),
    do: {:error, :invalid_reconciliation_inventory_options}

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
      branch_provenance: branch_provenance_string(Map.get(lease, :branch_provenance, :unknown)),
      active: lease.active == true
    }

    view =
      case Map.get(lease, :expires_at) do
        %DateTime{} = expires_at -> Map.put(view, :expires_at, DateTime.to_iso8601(expires_at))
        _ -> view
      end

    view =
      case Map.get(lease, :settlement_tip) do
        tip when is_binary(tip) and tip != "" -> Map.put(view, :settlement_tip, tip)
        _ -> view
      end

    view =
      case {Map.get(lease, :retry_count), Map.get(lease, :cleanup_retry_limit)} do
        {count, limit} when is_integer(count) and is_integer(limit) ->
          view
          |> Map.put(:cleanup_retry_count, count)
          |> Map.put(:cleanup_retry_limit, limit)

        _ ->
          view
      end

    view =
      if Map.has_key?(lease, :dormant),
        do: Map.put(view, :cleanup_dormant, Map.get(lease, :dormant) == true),
        else: view

    view =
      case Map.get(lease, :cleanup_failure) do
        nil ->
          view

        reason ->
          Map.put(view, :cleanup_failure_category, BranchLifecycle.failure_category(reason))
      end

    case Map.get(lease, :discard_phase) do
      phase when phase in [:archive, :worktree, :branch] ->
        Map.put(view, :discard_phase, Atom.to_string(phase))

      phase when phase in ["archive", "worktree", "branch"] ->
        Map.put(view, :discard_phase, phase)

      _ ->
        view
    end
  end

  defp creation_blocker_view(blocker) do
    %{
      workspace_id: blocker.workspace_id,
      repo_path: blocker.repo_path,
      worktree_path: blocker.worktree_path,
      branch: blocker.branch,
      ownership: "pending",
      lifecycle: "creating",
      active: false,
      dormant: true,
      status: "creating_blocked"
    }
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
    server_opts = server_opts(opts)

    state = %{
      leases: %{},
      by_ref: %{},
      retained_by_id: %{},
      retained_by_target: %{},
      retention_blockers: %{},
      retention_blockers_by_target: %{},
      retention_ttl_ms: Config.workspace_retention_ttl_ms(server_opts),
      retained_archive: Keyword.get(server_opts, :retained_archive, &archive_retained_branch/1),
      retained_cleanup:
        Keyword.get(server_opts, :retained_cleanup, &remove_owned_retained_worktree/1),
      retained_cleanup_retry_limit: retained_cleanup_retry_limit(server_opts),
      owner_death_retry_limit: owner_death_retry_limit(server_opts),
      owner_death_retry_base_ms: owner_death_retry_base_ms(server_opts),
      validation_resources: %{},
      validation_by_ref: %{},
      validation_by_resource_owner_ref: %{},
      validation_by_workspace: %{},
      validation_owner_cleanup_retry_limit: validation_owner_cleanup_retry_limit(server_opts),
      validation_resource_supervisor:
        Keyword.get(
          server_opts,
          :validation_resource_supervisor,
          ValidationResourceOwner.supervisor_name()
        ),
      review_attestations: %{},
      attestation_by_workspace: %{},
      attestation_states: %{},
      review_snapshots: %{},
      review_snapshots_by_workspace: %{},
      linux_dependency_baseline_materializer: dependency_baseline_materializer_from_opts(opts),
      retention_journal: journal_config_from_opts(opts),
      # Stable across registry restarts in this BEAM; new after BEAM restart
      # (unless tests inject :retention_runtime_id).
      retention_runtime_id: resolve_retention_runtime_id(server_opts)
    }

    {:ok, hydrate_retained_from_journal(state)}
  end

  defp resolve_retention_runtime_id(opts) when is_list(opts) do
    case Keyword.get(opts, :retention_runtime_id) do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        beam_retention_runtime_id()
    end
  end

  defp resolve_retention_runtime_id(_), do: beam_retention_runtime_id()

  # Process dictionary / persistent_term: survives registry GenServer restarts
  # inside one BEAM incarnation; new OS/BEAM process starts empty.
  defp beam_retention_runtime_id do
    key = {__MODULE__, :retention_runtime_id}

    case :persistent_term.get(key, :undefined) do
      id when is_binary(id) and id != "" ->
        id

      :undefined ->
        id = "rt_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        :persistent_term.put(key, id)
        id
    end
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

  defp retained_cleanup_retry_limit(opts) do
    max = RetentionJournal.max_cleanup_retries()

    case Keyword.get(opts, :retained_cleanup_retry_limit) do
      limit when is_integer(limit) and limit >= 0 and limit <= max ->
        limit

      _ ->
        @default_retained_cleanup_retry_limit
    end
  end

  defp validation_owner_cleanup_retry_limit(opts) do
    case Keyword.get(opts, :validation_owner_cleanup_retry_limit) do
      limit
      when is_integer(limit) and limit >= 0 and
             limit <= @max_validation_owner_cleanup_retry_limit ->
        limit

      _other ->
        @default_validation_owner_cleanup_retry_limit
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
            case ensure_journal_admits_allocation(state, prepared, :existing_marker) do
              :ok -> reactivate_quarantined(lease, prepared, state)
              {:error, reason} -> {:reply, {:error, reason}, state}
            end

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

      {:error, :not_found} ->
        case Map.get(state.retention_blockers, workspace_id) do
          blocker when is_map(blocker) ->
            if principal_task_match?(blocker, caller) do
              {:reply, {:ok, creation_blocker_view(blocker)}, state}
            else
              {:reply, {:error, :not_authorized}, state}
            end

          _ ->
            {:reply, {:error, :not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Lineage-only inspect: never install owner_pid from the GenServer caller.
  # Active leases only — retention/creation blockers are not inspectable here.
  def handle_call(
        {:inspect_by_lineage, workspace_id, task_id, principal_id},
        _from,
        state
      ) do
    caller = %{task_id: task_id, principal_id: principal_id, owner_pid: nil}

    case fetch_lineage_authorized(state, workspace_id, caller) do
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
        case Map.fetch(state.retention_blockers, workspace_id) do
          {:ok, blocker} ->
            if principal_task_match?(blocker, caller) do
              {:reply, {:error, :retention_creation_blocked}, state}
            else
              {:reply, {:error, :not_authorized}, state}
            end

          :error ->
            case Map.fetch(state.retained_by_id, workspace_id) do
              {:ok, %{lifecycle: :active_orphaned} = retained} ->
                if principal_task_match?(retained, caller) do
                  case release_orphaned_retained(state, retained, mode) do
                    {:ok, result, state} -> {:reply, {:ok, result}, state}
                    {:error, reason, state} -> {:reply, {:error, reason}, state}
                  end
                else
                  {:reply, {:error, :not_authorized}, state}
                end

              {:ok, retained} when mode in [:remove, :discard] ->
                # Exact task+principal may force-settle retained leases (TTL
                # evidence) without waiting for expiry. Discard also continues
                # crash-durable branch retirement from a discarding marker.
                # Retain mode remains idempotent success for non-orphaned
                # retained entries.
                release_retained_for_authorized_caller(state, retained, caller, mode)

              _ ->
                already_released_reply(state, workspace_id, mode, caller)
            end
        end

      {:ok, lease} ->
        if authorized?(lease, caller) do
          case cleanup_workspace_validation_resources(state, lease.workspace_id) do
            {:ok, state} ->
              state =
                state
                |> cleanup_workspace_attestations(lease.workspace_id)
                |> cleanup_workspace_review_snapshots(lease.workspace_id)

              release_mode = publish_release_mode(mode, caller)

              case do_release(state, lease, release_mode) do
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

  def handle_call({:settle_task_workspaces, task_id, principal_id}, {_from_pid, _tag}, state) do
    case ensure_journal_inventory_known(state) do
      :ok ->
        settle_task_workspaces_reply(state, task_id, principal_id)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:branch_protection_inventory, repo_path, max_entries}, _from, state) do
    case ensure_journal_inventory_known(state) do
      :ok ->
        case build_branch_protection_inventory(state, repo_path, max_entries) do
          {:ok, inventory} -> {:reply, {:ok, inventory}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:lifecycle_status, _from, state) do
    snapshot = %{
      leases: state.leases,
      retained_by_id: state.retained_by_id,
      retention_blockers: state.retention_blockers,
      validation_resources: state.validation_resources,
      retained_cleanup_retry_limit: Map.get(state, :retained_cleanup_retry_limit),
      owner_death_retry_limit: Map.get(state, :owner_death_retry_limit),
      validation_owner_cleanup_retry_limit: Map.get(state, :validation_owner_cleanup_retry_limit),
      journal_status: get_in(state, [:retention_journal, :status]),
      journal_reason: get_in(state, [:retention_journal, :reason])
    }

    {:reply, {:ok, LifecycleStatus.aggregate(snapshot)}, state}
  end

  def handle_call(
        {:reconciliation_inventory, task_id, principal_id, max_items},
        _from,
        state
      ) do
    inventory =
      WorkspaceReconciliationProjection.from_registry_state(
        state,
        task_id,
        principal_id,
        max_items
      )

    {:reply, {:ok, inventory}, state}
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
    case Map.fetch(Map.get(state, :validation_by_resource_owner_ref, %{}), ref) do
      {:ok, resource_id} ->
        {:noreply, handle_validation_resource_owner_down(state, resource_id, ref)}

      :error ->
        handle_validation_or_workspace_owner_down(ref, state)
    end
  end

  @impl true
  def handle_info({:validation_resource_owner_cleanup_retry, resource_id}, state)
      when is_binary(resource_id) do
    {:noreply, retry_validation_resource_owner_cleanup(state, resource_id)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Internals ------------------------------------------------------

  defp release_retained_for_authorized_caller(state, retained, caller, mode) do
    if principal_task_match?(retained, caller) do
      result =
        cond do
          # Never downgrade an in-flight discard: retain/remove/discard all
          # continue the crash-durable phases so settlement cannot silently
          # reclassify a discarding marker as a plain remove/retain.
          BranchLifecycle.discarding?(retained) ->
            continue_discard_retained(state, retained)

          mode == :discard ->
            begin_discard_from_retained(state, retained)

          true ->
            release_retained_for_settle(state, retained)
        end

      case result do
        {:ok, result, state} -> {:reply, {:ok, result}, state}
        {:error, reason, state} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_authorized}, state}
    end
  end

  # Convert a retained durable marker to discarding/worktree before any
  # destructive cleanup so crash/restart resumes discard rather than TTL remove.
  defp begin_discard_from_retained(state, retained) do
    discard_marker =
      Map.merge(retained, %{
        lifecycle: :discarding,
        discard_phase: :worktree,
        runtime_id: Map.get(retained, :runtime_id) || state.retention_runtime_id,
        durable_lifecycle: "discarding",
        branch_provenance: Map.get(retained, :branch_provenance, :unknown),
        cleanup_failure: nil,
        dormant: false
      })

    case persist_retained_marker(state, discard_marker) do
      :ok ->
        cancel_expiry(Map.get(retained, :expiry_ref))

        discard_marker =
          discard_marker
          |> Map.put(:durable_lifecycle, nil)
          |> Map.put(:expiry_ref, nil)

        state = put_retained(state, discard_marker)
        continue_discard_retained(state, discard_marker)

      {:error, reason} ->
        {:error, {:retention_journal_write_failed, reason}, state}
    end
  end

  defp settle_task_workspaces_reply(state, task_id, principal_id) do
    caller = %{task_id: task_id, principal_id: principal_id, owner_pid: nil}
    {settled, failures, state} = settle_matching_task_workspaces(state, caller)

    # Settlement is confirmed only when every matching live/retained/blocker
    # record is gone. Marker-delete retries and other residues fail closed.
    residues = remaining_task_workspace_ids(state, caller)

    if failures == [] and residues == [] do
      receipt = %{
        "principal_id" => principal_id,
        "settled_count" => length(settled),
        "status" => "settled",
        "task_id" => task_id,
        "workspace_ids" => settled
      }

      {:reply, {:ok, receipt}, state}
    else
      residue_failures =
        Enum.map(residues, fn workspace_id ->
          {workspace_id, :settlement_residue}
        end)

      {:reply, {:error, {:workspace_settlement_unconfirmed, failures ++ residue_failures}}, state}
    end
  end

  defp handle_validation_resource_owner_down(state, resource_id, ref) do
    state =
      Map.put(
        state,
        :validation_by_resource_owner_ref,
        state
        |> Map.get(:validation_by_resource_owner_ref, %{})
        |> Map.delete(ref)
      )

    case Map.get(state.validation_resources, resource_id) do
      nil ->
        state

      resource ->
        dependency_lease =
          if is_nil(Map.get(resource, :dependency_lease)), do: nil, else: :owner_lost

        resource = %{
          resource
          | resource_owner_pid: nil,
            resource_owner_ref: nil,
            dependency_lease: dependency_lease,
            resource_owner_cleanup_retry_count: 0,
            resource_owner_cleanup_dormant: false
        }

        state = %{
          state
          | validation_resources:
              Map.put(state.validation_resources, resource.resource_id, resource)
        }

        retry_validation_resource_owner_cleanup(state, resource_id)
    end
  end

  defp retry_validation_resource_owner_cleanup(state, resource_id) do
    case Map.get(state.validation_resources, resource_id) do
      %{resource_owner_pid: nil} = resource ->
        case do_release_validation_resource(state, resource) do
          {{:ok, _result}, next_state} ->
            next_state

          {{:error, _reason}, next_state} ->
            schedule_validation_resource_owner_cleanup(next_state, resource_id)
        end

      _other ->
        state
    end
  end

  defp schedule_validation_resource_owner_cleanup(state, resource_id) do
    case Map.get(state.validation_resources, resource_id) do
      nil ->
        state

      resource ->
        count = Map.get(resource, :resource_owner_cleanup_retry_count, 0)

        limit =
          Map.get(
            state,
            :validation_owner_cleanup_retry_limit,
            @default_validation_owner_cleanup_retry_limit
          )

        if count >= limit do
          updated = %{
            resource
            | resource_owner_cleanup_dormant: true
          }

          %{
            state
            | validation_resources:
                Map.put(state.validation_resources, resource.resource_id, updated)
          }
        else
          delay =
            Map.get(
              resource,
              :resource_owner_cleanup_retry_ms,
              @validation_owner_cleanup_retry_initial_ms
            )

          _ =
            Process.send_after(
              self(),
              {:validation_resource_owner_cleanup_retry, resource.resource_id},
              delay
            )

          updated = %{
            resource
            | resource_owner_cleanup_retry_ms:
                min(delay * 2, @validation_owner_cleanup_retry_max_ms),
              resource_owner_cleanup_retry_count: count + 1,
              resource_owner_cleanup_dormant: false
          }

          %{
            state
            | validation_resources:
                Map.put(state.validation_resources, resource.resource_id, updated)
          }
        end
    end
  end

  defp handle_validation_or_workspace_owner_down(ref, state) do
    case Map.fetch(state.validation_by_ref, ref) do
      {:ok, resource_id} ->
        case Map.get(state.validation_resources, resource_id) do
          nil ->
            {:noreply, %{state | validation_by_ref: Map.delete(state.validation_by_ref, ref)}}

          resource ->
            {result, state} =
              do_release_validation_resource(state, resource, demonitor: false)

            state =
              complete_owner_death_validation_cleanup(state, resource.workspace_id, result)

            {:noreply, state}
        end

      :error ->
        handle_workspace_owner_down(ref, state)
    end
  end

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

    case create_validation_root(state, lease, candidate_commit, materializer) do
      {:ok, resource_id, root_path, root_cleanup_identity, resource_owner_pid} ->
        resource =
          new_validation_resource(
            lease,
            owner_pid,
            owner_ref,
            resource_id,
            root_path,
            root_cleanup_identity,
            resource_owner_pid,
            candidate_commit,
            cleanup_failures
          )

        case setup_validation_resource(
               resource,
               force_dependency_snapshot_failure,
               setup_opts
             ) do
          {:ok, resource} ->
            {:ok, resource, put_validation_resource(state, resource)}

          {:error, {:cleanup_required, reason}, failed_resource} ->
            handle_dependency_cleanup_required(
              state,
              failed_resource,
              reason,
              force_partial_cleanup_failure_once
            )

          {:error, reason, failed_resource} ->
            case rollback_partial_validation_resource(
                   failed_resource,
                   force_partial_cleanup_failure_once
                 ) do
              :ok ->
                case stop_validation_resource_owner(failed_resource) do
                  :ok ->
                    Process.demonitor(owner_ref, [:flush])
                    {:error, reason}

                  {:error, _stop_reason} ->
                    resource = %{
                      failed_resource
                      | setup_status: :setup_failed,
                        cleanup_failures_remaining: 0
                    }

                    {:error, :validation_resource_setup_failed_cleanup_retained,
                     put_validation_resource(state, resource)}
                end

              {:error, _cleanup_reason} ->
                resource = %{
                  failed_resource
                  | setup_status: :setup_failed,
                    cleanup_failures_remaining: 0
                }

                {:error, :validation_resource_setup_failed_cleanup_retained,
                 put_validation_resource(state, resource)}
            end
        end

      {:error,
       {:validation_root_cleanup_retained, resource_id, root_path, root_cleanup_identity,
        resource_owner_pid}} ->
        resource =
          new_validation_resource(
            lease,
            owner_pid,
            owner_ref,
            resource_id,
            root_path,
            root_cleanup_identity,
            resource_owner_pid,
            candidate_commit,
            0
          )

        resource = %{resource | setup_status: :setup_failed}

        {:error, :validation_resource_setup_failed_cleanup_retained,
         put_validation_resource(state, resource)}

      {:error, reason} ->
        Process.demonitor(owner_ref, [:flush])
        {:error, reason}
    end
  end

  defp handle_dependency_cleanup_required(
         state,
         resource,
         reason,
         force_partial_cleanup_failure_once
       ) do
    case ValidationResourceOwner.release_dependency(resource.resource_owner_pid) do
      :ok ->
        resource = %{resource | dependency_lease: nil}

        case rollback_partial_validation_resource(
               resource,
               force_partial_cleanup_failure_once
             ) do
          :ok ->
            case stop_validation_resource_owner(resource) do
              :ok ->
                Process.demonitor(resource.owner_ref, [:flush])
                {:error, reason}

              {:error, _stop_reason} ->
                retained = %{
                  resource
                  | setup_status: :setup_failed,
                    cleanup_failures_remaining: 0
                }

                {:error, :validation_resource_setup_failed_cleanup_retained,
                 put_validation_resource(state, retained)}
            end

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
            dependency_lease: :resource_owner
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
         root_cleanup_identity,
         resource_owner_pid,
         candidate_commit,
         cleanup_failures
       ) do
    resource_owner_ref = Process.monitor(resource_owner_pid)
    candidate_runtime = Path.join(root_path, "candidate-runtime")
    base_runtime = Path.join(root_path, "base-runtime")
    stage_parent = Path.join(root_path, "staging")
    candidate_runner_dir = Path.join(candidate_runtime, "runner")
    candidate_result_dir = Path.join(candidate_runtime, "result")
    base_runner_dir = Path.join(base_runtime, "runner")
    base_result_dir = Path.join(base_runtime, "result")
    # Exact owner-issued basenames (not evidence_type labels).
    runner_script = "runner.exs"
    result_name = "result.etf"

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
      candidate_cleanup_identity: nil,
      base_commit: lease.base_commit,
      root_path: root_path,
      root_cleanup_identity: root_cleanup_identity,
      resource_owner_pid: resource_owner_pid,
      resource_owner_ref: resource_owner_ref,
      resource_owner_cleanup_retry_ms: @validation_owner_cleanup_retry_initial_ms,
      resource_owner_cleanup_retry_count: 0,
      resource_owner_cleanup_dormant: false,
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
      # Sibling dirs under the unprojected runtime parent — projected as
      # validation_runner (RO) and validation_result (RW), never the parent.
      candidate_runner_dir_path: candidate_runner_dir,
      candidate_runner_path: Path.join(candidate_runner_dir, runner_script),
      candidate_result_dir_path: candidate_result_dir,
      candidate_result_path: Path.join(candidate_result_dir, result_name),
      base_runtime_path: base_runtime,
      base_home_path: Path.join(base_runtime, "home"),
      base_tmp_path: Path.join(base_runtime, "tmp"),
      base_build_path: Path.join(base_runtime, "build"),
      base_deps_path: nil,
      base_worktree_path: Path.join(root_path, "base"),
      base_cleanup_identity: nil,
      base_runner_dir_path: base_runner_dir,
      base_runner_path: Path.join(base_runner_dir, runner_script),
      base_result_dir_path: base_result_dir,
      base_result_path: Path.join(base_result_dir, result_name),
      # Candidate-leg aliases for existing callers.
      home_path: Path.join(candidate_runtime, "home"),
      tmp_path: Path.join(candidate_runtime, "tmp"),
      runner_path: Path.join(candidate_runner_dir, runner_script),
      dependency_lease: nil,
      dependency_root_path: nil,
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
         setup_opts
       ) do
    # Ordering is load-bearing: Actions-owned private dirs and any detached
    # candidate worktree are created and forced private *before* the Shell
    # lease is acquired, so no later filesystem setup can lose the lease.
    with :ok <- check_deadline(setup_opts),
         :ok <- create_private_validation_directories(resource),
         :ok <- check_deadline(setup_opts),
         {:ok, resource} <- create_candidate_snapshot_from_resource(resource) do
      continue_validation_resource_setup(
        resource,
        force_dependency_snapshot_failure,
        setup_opts
      )
    else
      {:error, reason, failed_resource} -> {:error, reason, failed_resource}
      {:error, reason} -> {:error, reason, resource}
    end
  end

  defp continue_validation_resource_setup(
         resource,
         force_dependency_snapshot_failure,
         setup_opts
       ) do
    with :ok <- check_deadline(setup_opts),
         :ok <- force_private_top_boundaries(resource),
         :ok <- maybe_force_dependency_snapshot_failure(force_dependency_snapshot_failure),
         :ok <- check_deadline(setup_opts),
         {:ok, remaining_ms} <- remaining_shell_deadline_ms(setup_opts) do
      case ValidationResourceOwner.acquire_dependency(
             resource.resource_owner_pid,
             remaining_ms
           ) do
        {:ok, view, cleanup_locator} ->
          resource = merge_dependency_cleanup_locator(resource, cleanup_locator)

          case admit_dependency_baseline_view(view, resource.dependency_root_path) do
            {:ok, admitted} ->
              # Pure merge only — no further fallible setup after acquire.
              {:ok, merge_dependency_baseline(resource, admitted)}

            {:error, reason} ->
              case ValidationResourceOwner.release_dependency(resource.resource_owner_pid) do
                :ok ->
                  {:error, reason, resource}

                {:error, _} ->
                  failed = %{resource | dependency_lease: :resource_owner}
                  {:error, {:cleanup_required, reason}, failed}
              end
          end

        {:error, {:cleanup_required, reason, cleanup_locator}} ->
          failed =
            resource
            |> merge_dependency_cleanup_locator(cleanup_locator)
            |> Map.put(:dependency_lease, :resource_owner)

          {:error, {:cleanup_required, reason}, failed}

        {:error, reason} ->
          {:error, reason, resource}
      end
    else
      {:error, reason} -> {:error, reason, resource}
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
      resource.candidate_runner_dir_path,
      resource.candidate_result_dir_path,
      resource.base_runtime_path,
      resource.base_home_path,
      resource.base_tmp_path,
      resource.base_build_path,
      resource.base_runner_dir_path,
      resource.base_result_dir_path
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
        resource.candidate_runner_dir_path,
        resource.candidate_result_dir_path,
        resource.base_runtime_path,
        resource.base_home_path,
        resource.base_tmp_path,
        resource.base_build_path,
        resource.base_runner_dir_path,
        resource.base_result_dir_path
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
    do: {:ok, resource}

  defp create_candidate_snapshot_from_resource(resource) do
    case ValidationResourceOwner.create_candidate(
           resource.resource_owner_pid,
           resource.candidate_commit
         ) do
      {:ok, removal_identity} when is_map(removal_identity) ->
        {:ok, %{resource | candidate_cleanup_identity: removal_identity}}

      {:error, reason, removal_identity} when is_map(removal_identity) ->
        {:error, reason, %{resource | candidate_cleanup_identity: removal_identity}}

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

  defp admit_dependency_baseline_view(view, cleanup_root_path) when is_map(view) do
    candidate = Map.get(view, "candidate_path") || Map.get(view, :candidate_path)
    base = Map.get(view, "base_path") || Map.get(view, :base_path)
    receipt = Map.get(view, "receipt") || Map.get(view, :receipt)
    verified = Map.get(view, "verified_copy") || Map.get(view, :verified_copy)

    with true <- is_binary(candidate) and candidate != "",
         true <- is_binary(base) and base != "",
         true <- Path.type(candidate) == :absolute,
         true <- Path.type(base) == :absolute,
         true <- candidate != base,
         true <- Path.dirname(candidate) == cleanup_root_path,
         true <- Path.dirname(base) == cleanup_root_path,
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

  defp admit_dependency_baseline_view(_view, _cleanup_root_path),
    do: {:error, :invalid_dependency_baseline_view}

  defp merge_dependency_cleanup_locator(resource, %{root_path: root_path}) do
    %{resource | dependency_root_path: root_path}
  end

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

  defp merge_dependency_baseline(resource, admitted) do
    %{
      resource
      | dependency_lease: :resource_owner,
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
    case ValidationResourceOwner.create_base(
           resource.resource_owner_pid,
           resource.base_commit
         ) do
      {:ok, removal_identity} when is_map(removal_identity) ->
        resource = %{
          resource
          | snapshot_created: true,
            base_cleanup_identity: removal_identity
        }

        state = %{
          state
          | validation_resources:
              Map.put(state.validation_resources, resource.resource_id, resource)
        }

        {:reply, {:ok, validation_resource_view(resource)}, state}

      {:error, reason, removal_identity} when is_map(removal_identity) ->
        resource = %{resource | base_cleanup_identity: removal_identity}

        state = %{
          state
          | validation_resources:
              Map.put(state.validation_resources, resource.resource_id, resource)
        }

        {:reply, {:error, reason}, state}

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

  defp attempt_validation_resource_cleanup(
         state,
         %{resource_owner_pid: nil} = resource
       ) do
    with :ok <- cleanup_actions_owned_validation_files(resource),
         :ok <- prove_lost_owner_dependency_absent(resource) do
      cleared = %{resource | dependency_lease: nil}

      state = %{
        state
        | validation_resources: Map.put(state.validation_resources, resource.resource_id, cleared)
      }

      {:ok, state}
    else
      {:error, _reason} -> {:error, state}
    end
  end

  defp attempt_validation_resource_cleanup(state, resource) do
    # Phase 1: Actions-owned root + detached worktrees.
    # Phase 2: resource-owner Shell lease release (idempotent after success).
    case cleanup_actions_owned_validation_files(resource) do
      :ok ->
        case ValidationResourceOwner.release_dependency(resource.resource_owner_pid) do
          :ok ->
            cleared = %{resource | dependency_lease: nil}

            case stop_validation_resource_owner(cleared) do
              :ok ->
                state = %{
                  state
                  | validation_resources:
                      Map.put(state.validation_resources, resource.resource_id, cleared)
                }

                {:ok, state}

              {:error, _reason} ->
                state = %{
                  state
                  | validation_resources:
                      Map.put(state.validation_resources, resource.resource_id, cleared)
                }

                {:error, state}
            end

          {:error, _reason} ->
            # Actions root is gone but the owner may still hold its Shell lease.
            {:error, state}
        end

      {:error, _reason} ->
        # Keep resource + lease for explicit retry.
        {:error, state}
    end
  end

  defp prove_lost_owner_dependency_absent(%{dependency_lease: nil}), do: :ok

  defp prove_lost_owner_dependency_absent(resource) do
    case Map.get(resource, :dependency_root_path) do
      path when is_binary(path) ->
        case File.lstat(path) do
          {:error, :enoent} -> :ok
          _other -> {:error, :dependency_baseline_cleanup_pending}
        end

      _other ->
        {:error, :dependency_baseline_cleanup_unproven}
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

  defp stop_validation_resource_owner(resource) do
    case ValidationResourceOwner.stop(Map.get(resource, :resource_owner_pid)) do
      :ok ->
        case Map.get(resource, :resource_owner_ref) do
          ref when is_reference(ref) -> Process.demonitor(ref, [:flush])
          _other -> :ok
        end

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_candidate_detached_worktree(resource) do
    if is_binary(Map.get(resource, :candidate_commit)) do
      Workspace.remove_detached_worktree(
        resource.repo_path,
        resource.candidate_path,
        Map.get(resource, :candidate_cleanup_identity)
      )
    else
      :ok
    end
  end

  defp cleanup_base_detached_worktree(resource) do
    Workspace.remove_detached_worktree(
      resource.repo_path,
      resource.base_worktree_path,
      Map.get(resource, :base_cleanup_identity)
    )
  end

  defp cleanup_validation_root(resource) do
    root = resource.root_path
    identity = Map.get(resource, :root_cleanup_identity)

    cond do
      is_binary(root) and is_map(identity) and Map.get(identity, :path) == root ->
        case Arbor.Shell.remove_owned_tree(identity, validation_root_cleanup_opts()) do
          :ok -> :ok
          {:error, _reason} -> {:error, :validation_root_cleanup_failed}
        end

      is_binary(root) ->
        case File.lstat(root) do
          {:error, :enoent} -> :ok
          _other -> {:error, :validation_root_cleanup_identity_required}
        end

      true ->
        {:error, :invalid_resource_root}
    end
  end

  defp validation_root_cleanup_opts do
    [
      listing_heap_words: @validation_root_cleanup_listing_heap_words,
      timeout_ms: @validation_root_cleanup_timeout_ms
    ]
  end

  defp put_validation_resource(state, resource) do
    workspace_resources =
      state.validation_by_workspace
      |> Map.get(resource.workspace_id, MapSet.new())
      |> MapSet.put(resource.resource_id)

    validation_by_resource_owner_ref =
      case Map.get(resource, :resource_owner_ref) do
        ref when is_reference(ref) ->
          state
          |> Map.get(:validation_by_resource_owner_ref, %{})
          |> Map.put(ref, resource.resource_id)

        _other ->
          Map.get(state, :validation_by_resource_owner_ref, %{})
      end

    state
    |> Map.put(
      :validation_resources,
      Map.put(state.validation_resources, resource.resource_id, resource)
    )
    |> Map.put(
      :validation_by_ref,
      Map.put(state.validation_by_ref, resource.owner_ref, resource.resource_id)
    )
    |> Map.put(:validation_by_resource_owner_ref, validation_by_resource_owner_ref)
    |> Map.put(
      :validation_by_workspace,
      Map.put(state.validation_by_workspace, resource.workspace_id, workspace_resources)
    )
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

    validation_by_resource_owner_ref =
      case Map.get(resource, :resource_owner_ref) do
        ref when is_reference(ref) ->
          state
          |> Map.get(:validation_by_resource_owner_ref, %{})
          |> Map.delete(ref)

        _other ->
          Map.get(state, :validation_by_resource_owner_ref, %{})
      end

    state
    |> Map.put(
      :validation_resources,
      Map.delete(state.validation_resources, resource.resource_id)
    )
    |> Map.put(:validation_by_ref, Map.delete(state.validation_by_ref, resource.owner_ref))
    |> Map.put(:validation_by_resource_owner_ref, validation_by_resource_owner_ref)
    |> Map.put(:validation_by_workspace, validation_by_workspace)
  end

  defp validation_resource_view(resource) do
    candidate_home =
      Map.get(resource, :candidate_home_path) || Map.get(resource, :home_path)

    candidate_tmp = Map.get(resource, :candidate_tmp_path) || Map.get(resource, :tmp_path)

    candidate_runner =
      Map.get(resource, :candidate_runner_path) || Map.get(resource, :runner_path)

    candidate_runner_dir = Map.get(resource, :candidate_runner_dir_path)
    candidate_result_dir = Map.get(resource, :candidate_result_dir_path)

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
      candidate_runner_dir_path: candidate_runner_dir,
      candidate_runner_path: candidate_runner,
      candidate_result_dir_path: candidate_result_dir,
      candidate_result_path: resource.candidate_result_path,
      base_runtime_path: Map.get(resource, :base_runtime_path),
      base_home_path: Map.get(resource, :base_home_path),
      base_tmp_path: Map.get(resource, :base_tmp_path),
      base_build_path: resource.base_build_path,
      base_deps_path: resource.base_deps_path,
      base_worktree_path: resource.base_worktree_path,
      base_runner_dir_path: Map.get(resource, :base_runner_dir_path),
      base_runner_path: Map.get(resource, :base_runner_path),
      base_result_dir_path: Map.get(resource, :base_result_dir_path),
      base_result_path: resource.base_result_path,
      home_path: candidate_home,
      tmp_path: candidate_tmp,
      runner_path: candidate_runner,
      baseline_receipt: Map.get(resource, :dependency_receipt),
      baseline_verified_copy: Map.get(resource, :dependency_verified_copy),
      snapshot_created: resource.snapshot_created,
      setup_status: Atom.to_string(resource.setup_status),
      cleanup_status: validation_resource_cleanup_status(resource),
      active: true
    }
  end

  defp validation_resource_cleanup_status(resource) do
    cond do
      Map.get(resource, :resource_owner_cleanup_dormant, false) -> "dormant"
      is_nil(Map.get(resource, :resource_owner_pid)) -> "retrying"
      true -> "owned"
    end
  end

  defp create_validation_root(state, lease, candidate_commit, materializer, attempts \\ 4)

  defp create_validation_root(_state, _lease, _candidate_commit, _materializer, 0),
    do: {:error, :validation_resource_collision}

  defp create_validation_root(state, lease, candidate_commit, materializer, attempts) do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    workspace_hash = sha256(lease.workspace_id) |> binary_part(0, 12)
    resource_id = "validation_" <> token

    with {:ok, tmp_root} <- SafePath.resolve_real(System.tmp_dir!()) do
      root_path =
        Path.join(
          tmp_root,
          "arbor-validation-#{workspace_hash}-#{token}"
        )

      candidate_path =
        if is_binary(candidate_commit),
          do: Path.join(root_path, "candidate"),
          else: lease.worktree_path

      owner_opts = [
        registry_pid: self(),
        repo_path: lease.repo_path,
        root_path: root_path,
        candidate_path: candidate_path,
        candidate_commit: candidate_commit,
        base_path: Path.join(root_path, "base"),
        materializer: materializer,
        cleanup_retry_limit:
          Map.get(
            state,
            :validation_owner_cleanup_retry_limit,
            @default_validation_owner_cleanup_retry_limit
          )
      ]

      case ValidationResourceOwner.start(
             state.validation_resource_supervisor,
             owner_opts
           ) do
        {:ok, resource_owner_pid, root_cleanup_identity} ->
          {:ok, resource_id, root_path, root_cleanup_identity, resource_owner_pid}

        {:error, :root_exists} ->
          create_validation_root(state, lease, candidate_commit, materializer, attempts - 1)

        {:error, {:cleanup_retained, resource_owner_pid, root_cleanup_identity}} ->
          {:error,
           {:validation_root_cleanup_retained, resource_id, root_path, root_cleanup_identity,
            resource_owner_pid}}

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
      snapshot_bounds: Keyword.get(opts, :snapshot_bounds) || %{},
      candidate_commit: normalize_candidate_commit(Keyword.get(opts, :candidate_commit)),
      repo_path: normalize_id(Keyword.get(opts, :repo_path))
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
      snapshot_bounds: Map.get(opts, :snapshot_bounds) || Map.get(opts, "snapshot_bounds") || %{},
      candidate_commit:
        normalize_candidate_commit(
          Map.get(opts, :candidate_commit) || Map.get(opts, "candidate_commit")
        ),
      repo_path: normalize_id(Map.get(opts, :repo_path) || Map.get(opts, "repo_path"))
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
         :ok <- validate_task_principal_pair(attrs.task_id, attrs.principal_id),
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
          capacity_mode = fresh_acquire_capacity_mode(prepared)

          with :ok <- ensure_journal_admits_allocation(state, prepared, capacity_mode) do
            if Map.has_key?(state.retained_by_id, prepared.workspace_id) do
              {:reply, {:error, :workspace_id_collision}, state}
            else
              case capacity_mode do
                :new_marker ->
                  case reserve_creating_intent(state, prepared) do
                    {:ok, intent, state} ->
                      perform_acquire(prepared, state, intent, capacity_mode)

                    {:error, reason, state} ->
                      {:reply, {:error, reason}, state}
                  end

                :no_new_marker ->
                  perform_acquire(prepared, state, nil, capacity_mode)
              end
            end
          else
            {:error, reason} -> {:reply, {:error, reason}, state}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}

        {:ok, retained} ->
          continue_retained_acquire(state, retained, prepared)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp continue_retained_acquire(state, retained, prepared) do
    if BranchLifecycle.discarding?(retained) do
      # A crash-durable terminal settlement cannot be downgraded back to an
      # active worker lease. Exact lineage may inspect/continue the residue,
      # but reacquisition must wait for operator resolution.
      {:reply, {:error, :workspace_discard_pending}, state}
    else
      case ensure_journal_admits_allocation(state, prepared, :existing_marker) do
        :ok -> reactivate_retained(retained, prepared, state)
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  # Poisoned/unreadable durable evidence must not be silently overlapped by a
  # fresh checkout. Recheck the backend on every allocation so a store that
  # becomes unavailable or poisoned after registry startup still fails closed.
  # Explicit `:disabled` journals (tests) remain open.
  defp ensure_journal_admits_allocation(
         %{retention_journal: %{status: :poisoned}},
         _prepared,
         _capacity_mode
       ) do
    {:error, :retention_journal_unavailable}
  end

  defp ensure_journal_admits_allocation(
         %{retention_journal: %{status: :ready} = journal} = state,
         prepared,
         capacity_mode
       ) do
    with {:ok, records} <- load_durable_retained_records(journal),
         :ok <- require_available_creation_target(records, prepared),
         :ok <- require_matching_durable_hot_ids(state, records),
         :ok <- require_marker_capacity(records, capacity_mode) do
      :ok
    else
      {:error, :retention_record_limit_exceeded} = error -> error
      {:error, :retention_creation_blocked} = error -> error
      {:error, _reason} -> {:error, :retention_journal_unavailable}
    end
  end

  defp ensure_journal_admits_allocation(
         %{retention_journal: %{status: :disabled}},
         _prepared,
         _capacity_mode
       ),
       do: :ok

  defp ensure_journal_admits_allocation(_state, _prepared, _capacity_mode),
    do: {:error, :retention_journal_unavailable}

  # Bulk settlement cannot trust hot indexes unless the durable inventory is
  # readable and exactly mirrored. Otherwise an "empty" settle could conceal a
  # marker that failed hydration or appeared after startup.
  defp ensure_journal_inventory_known(%{retention_journal: %{status: :disabled}}), do: :ok

  defp ensure_journal_inventory_known(%{retention_journal: %{status: :ready} = journal} = state) do
    with {:ok, records} <- load_durable_retained_records(journal),
         :ok <- validate_protection_inventory_branches(records),
         :ok <- require_matching_durable_hot_ids(state, records) do
      :ok
    else
      {:error, _reason} -> {:error, :retention_journal_unavailable}
    end
  end

  defp ensure_journal_inventory_known(_state), do: {:error, :retention_journal_unavailable}

  defp require_matching_durable_hot_ids(state, records) do
    durable_ids = records |> Enum.map(& &1.workspace_id) |> MapSet.new()

    retained_ids = state.retained_by_id |> Map.keys() |> MapSet.new()

    active_ids =
      state.leases
      |> Enum.reduce(MapSet.new(), fn {_id, lease}, acc ->
        if lease.ownership == :owned and Map.get(lease, :retention_marker_active) == true do
          MapSet.put(acc, lease.workspace_id)
        else
          acc
        end
      end)

    blocker_ids = state.retention_blockers |> Map.keys() |> MapSet.new()

    if durable_ids == MapSet.union(MapSet.union(retained_ids, active_ids), blocker_ids) do
      :ok
    else
      {:error, :retention_inventory_hot_state_mismatch}
    end
  end

  defp build_branch_protection_inventory(state, repo_path, max_entries) do
    records =
      Map.values(state.leases) ++
        Map.values(state.retained_by_id) ++ Map.values(state.retention_blockers)

    with :ok <- validate_protection_inventory_branches(records) do
      do_build_branch_protection_inventory(state, repo_path, max_entries)
    end
  end

  defp do_build_branch_protection_inventory(state, repo_path, max_entries) do
    entries =
      state.leases
      |> Map.values()
      |> Enum.filter(&(Path.expand(&1.repo_path) == repo_path))
      |> Enum.map(&protection_inventory_entry(&1.branch, "active_workspace_ref"))

    retained_entries =
      state.retained_by_id
      |> Map.values()
      |> Enum.filter(&(Path.expand(&1.repo_path) == repo_path))
      |> Enum.map(fn retained ->
        reason =
          case {Map.get(retained, :lifecycle), Map.get(retained, :dormant)} do
            {:discarding, _} -> "discarding_workspace_ref"
            {_, true} -> "dormant_workspace_ref"
            {:active_orphaned, _} -> "active_orphaned_workspace_ref"
            _ -> "retained_workspace_ref"
          end

        protection_inventory_entry(retained.branch, reason)
      end)

    blocker_entries =
      state.retention_blockers
      |> Map.values()
      |> Enum.filter(&(Path.expand(Map.get(&1, :repo_path, "")) == repo_path))
      |> Enum.map(&protection_inventory_entry(&1.branch, "dormant_workspace_ref"))

    entries =
      (entries ++ retained_entries ++ blocker_entries)
      |> Enum.reduce_while({:ok, %{}}, fn
        {:error, reason}, _acc -> {:halt, {:error, reason}}
        entry, {:ok, acc} -> {:cont, {:ok, Map.put(acc, entry["ref"], entry)}}
      end)

    with {:ok, by_ref} <- entries,
         inventory <- by_ref |> Map.values() |> Enum.sort_by(& &1["ref"]),
         true <- length(inventory) <= max_entries do
      {:ok, inventory}
    else
      false -> {:error, :retention_inventory_oversized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp protection_inventory_entry(branch, reason) when is_binary(branch) do
    case Git.validate_branch_name(branch) do
      :ok -> %{"ref" => "refs/heads/" <> branch, "reason" => reason}
      {:error, _reason} -> {:error, :invalid_retention_branch}
    end
  end

  defp protection_inventory_entry(_branch, _reason), do: {:error, :invalid_retention_branch}

  defp validate_protection_inventory_branches(records) when is_list(records) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case Git.validate_branch_name(Map.get(record, :branch)) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :invalid_retention_branch}}
      end
    end)
  end

  defp require_available_creation_target(records, prepared) do
    prepared_target = target_key(prepared.repo_path, prepared.branch, prepared.candidate_path)

    blocker =
      Enum.find(records, fn record ->
        RetentionJournal.creating_record?(record) and
          (record.workspace_id == prepared.workspace_id or
             target_key(record.repo_path, record.branch, record.worktree_path) == prepared_target)
      end)

    if blocker, do: {:error, :retention_creation_blocked}, else: :ok
  end

  defp require_marker_capacity(records, :new_marker) do
    if length(records) < RetentionJournal.max_records() do
      :ok
    else
      {:error, :retention_record_limit_exceeded}
    end
  end

  defp require_marker_capacity(_records, :no_new_marker), do: :ok
  defp require_marker_capacity(_records, :existing_marker), do: :ok

  defp fresh_acquire_capacity_mode(%{create_worktree: fun}) when is_function(fun, 3),
    do: :new_marker

  defp fresh_acquire_capacity_mode(prepared) do
    case Workspace.preflight_worktree_ownership(
           prepared.repo_path,
           prepared.branch,
           prepared.create_params
         ) do
      :reused -> :no_new_marker
      _ -> :new_marker
    end
  end

  defp reserve_creating_intent(%{retention_journal: %{status: :disabled}} = state, _prepared),
    do: {:ok, nil, state}

  defp reserve_creating_intent(%{retention_journal: %{status: :ready}} = state, prepared) do
    intent = initial_creating_marker(state, prepared)

    case persist_retained_marker(state, intent) do
      :ok -> {:ok, intent, state}
      {:error, reason} -> {:error, {:retention_journal_write_failed, reason}, state}
    end
  end

  defp reserve_creating_intent(state, _prepared),
    do: {:error, :retention_journal_unavailable, state}

  defp initial_creating_marker(state, prepared) do
    ttl_ms = min(state.retention_ttl_ms, Config.workspace_retention_max_ttl_ms())

    %{
      workspace_id: prepared.workspace_id,
      task_id: prepared.task_id,
      principal_id: prepared.principal_id,
      repo_path: prepared.repo_path,
      worktree_path: prepared.candidate_path,
      display_worktree_path: prepared.candidate_path,
      branch: prepared.branch,
      base_commit: nil,
      ownership: :pending,
      lifecycle: :creating,
      runtime_id: state.retention_runtime_id,
      target: target_key(prepared.repo_path, prepared.branch, prepared.candidate_path),
      lstat_identity: nil,
      worktree_registration: nil,
      expires_at: DateTime.add(DateTime.utc_now(), ttl_ms, :millisecond),
      retry_count: 0,
      durable_lifecycle: "creating",
      dormant: true,
      cleanup_failure: nil
    }
  end

  defp reserved_creating_intent?(records, prepared, intent) when is_map(intent) do
    Enum.any?(records, fn record ->
      RetentionJournal.creating_record?(record) and
        record.workspace_id == intent.workspace_id and
        record.repo_path == prepared.repo_path and
        record.worktree_path == prepared.candidate_path and
        record.branch == prepared.branch
    end)
  end

  defp reserved_creating_intent?(_records, _prepared, _intent), do: false

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

    deletion_identity =
      case capture_quarantine_deletion_identity(lease) do
        {:ok, identity} -> identity
        {:error, _reason} -> nil
      end

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
        owner_death_retry_ref: nil,
        owner_death_deletion_identity: deletion_identity
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
    Workspace.canonical_path_or_expanded(path)
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

  defp resolve_workspace_id(id) when is_binary(id) and id != "" do
    with {:ok, _key} <- RetentionJournal.record_key(id), do: {:ok, id}
  end

  defp resolve_workspace_id(id) when id in [nil, ""], do: {:ok, generate_workspace_id()}
  defp resolve_workspace_id(_), do: {:error, :invalid_workspace_id}

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

  defp perform_acquire(prepared, state, intent, capacity_mode) do
    # Monitor before any git side effect so a mid-create owner death queues DOWN.
    owner_ref = Process.monitor(prepared.owner_pid)

    case run_create_worktree(prepared, capacity_mode == :no_new_marker) do
      {:ok, worktree_path, ownership, base_commit, branch_provenance} ->
        case prepare_created_lease(
               prepared,
               owner_ref,
               worktree_path,
               ownership,
               base_commit,
               branch_provenance
             ) do
          {:ok, lease, created_identity} ->
            if Map.has_key?(state.leases, lease.workspace_id) do
              Process.demonitor(owner_ref, [:flush])

              handle_post_create_failure(
                state,
                intent,
                lease,
                created_identity,
                :workspace_id_collision
              )
            else
              case ensure_target_free(state, lease.repo_path, lease.branch) do
                :ok ->
                  case ensure_created_ownership_admitted(state, prepared, lease.ownership, intent) do
                    :ok ->
                      case finalize_created_lease(state, lease, intent) do
                        {:ok, finalized, state} ->
                          state = state |> put_lease(finalized) |> put_ref(finalized)
                          {:reply, {:ok, public_view(finalized)}, state}

                        {:error, reason, state, :cleanup_confirmed} ->
                          Process.demonitor(owner_ref, [:flush])
                          {:reply, {:error, reason}, state}

                        {:error, reason, state, :evidence_preserved} ->
                          {:reply, {:error, reason}, state}
                      end

                    {:error, reason} ->
                      Process.demonitor(owner_ref, [:flush])

                      handle_post_create_failure(
                        state,
                        intent,
                        lease,
                        created_identity,
                        reason
                      )
                  end

                {:error, reason} ->
                  Process.demonitor(owner_ref, [:flush])

                  handle_post_create_failure(
                    state,
                    intent,
                    lease,
                    created_identity,
                    reason
                  )
              end
            end

          {:error, reason, ownership_atom, canonical_path, created_identity, provenance_atom} ->
            Process.demonitor(owner_ref, [:flush])

            failed_lease = %{
              workspace_id: prepared.workspace_id,
              task_id: prepared.task_id,
              principal_id: prepared.principal_id,
              repo_path: prepared.repo_path,
              worktree_path: canonical_path || worktree_path,
              branch: prepared.branch,
              ownership: ownership_atom,
              branch_provenance: provenance_atom
            }

            handle_post_create_failure(
              state,
              intent,
              failed_lease,
              created_identity,
              reason
            )
        end

      {:error, reason} ->
        Process.demonitor(owner_ref, [:flush])

        case settle_create_intent_after_failure(state, intent) do
          {:ok, state} ->
            {:reply, {:error, reason}, state}

          {:blocked, _blocker_reason, state} ->
            {:reply, {:error, reason}, state}

          {:error, delete_reason, state} ->
            {:reply, {:error, {:retention_journal_delete_failed, delete_reason}}, state}
        end
    end
  end

  defp prepare_created_lease(
         prepared,
         owner_ref,
         worktree_path,
         ownership,
         base_commit,
         branch_provenance
       ) do
    with {:ok, ownership_atom} <- normalize_ownership(ownership),
         {:ok, provenance_atom} <- normalize_branch_provenance(branch_provenance),
         :ok <- require_binary(worktree_path, :worktree_path),
         {:ok, canonical_worktree_path} <- canonical_existing_path(worktree_path),
         {:ok, created_identity} <-
           capture_created_identity(
             prepared.repo_path,
             canonical_worktree_path,
             prepared.branch,
             ownership_atom
           ) do
      case require_binary(base_commit, :base_commit) do
        :ok ->
          lease = %{
            workspace_id: prepared.workspace_id,
            owner_pid: prepared.owner_pid,
            owner_ref: owner_ref,
            task_id: prepared.task_id,
            principal_id: prepared.principal_id,
            repo_path: prepared.repo_path,
            worktree_path: canonical_worktree_path,
            branch: prepared.branch,
            base_commit: base_commit,
            ownership: ownership_atom,
            branch_provenance: provenance_atom,
            active: true,
            cleanup_armed: true
          }

          {:ok, bind_created_identity(lease, created_identity), created_identity}

        {:error, reason} ->
          {:error, reason, ownership_atom, canonical_worktree_path, created_identity,
           provenance_atom}
      end
    else
      {:error, reason} ->
        ownership_atom = normalize_ownership_for_cleanup(ownership)

        {:error, reason, ownership_atom, normalize_created_path(worktree_path), nil, :unknown}
    end
  end

  defp normalize_ownership_for_cleanup(ownership) do
    case normalize_ownership(ownership) do
      {:ok, normalized} -> normalized
      _ -> ownership
    end
  end

  defp normalize_created_path(path) when is_binary(path), do: path
  defp normalize_created_path(_path), do: nil

  defp handle_post_create_failure(
         state,
         intent,
         failed_lease,
         identity,
         reason
       ) do
    ownership = Map.get(failed_lease, :ownership)

    case {normalize_ownership_for_cleanup(ownership), identity} do
      {:owned, nil} ->
        if is_nil(intent) do
          {:reply, {:error, reason}, state}
        else
          blocker =
            creation_blocker_from_intent(
              intent,
              failed_lease,
              reason
            )

          state =
            state
            |> degrade_retention_journal({:create_identity_unavailable, reason})
            |> put_creation_blocker(blocker)

          {:reply, {:error, reason}, state}
        end

      {:owned, identity} when is_map(identity) ->
        case begin_failed_create_discard(state, intent, failed_lease, identity) do
          {:ok, state} ->
            {:reply, {:error, reason}, state}

          {:pending, _cleanup_reason, state} ->
            {:reply, {:error, reason}, state}

          {:error, cleanup_reason, state} ->
            blocker =
              creation_blocker_from_intent(
                intent,
                failed_lease,
                {reason, cleanup_reason}
              )

            state =
              state
              |> degrade_retention_journal({:create_cleanup_unconfirmed, cleanup_reason})
              |> put_creation_blocker(blocker)

            {:reply, {:error, reason}, state}
        end

      {:reused, _identity} ->
        # A successful reused result did not create an owned worktree. Its
        # reserved intent may therefore be removed without create-cleanup
        # absence proof. Any deletion failure still preserves the blocker.
        case settle_create_intent_after_success(state, intent) do
          {:ok, state} ->
            {:reply, {:error, reason}, state}

          {:error, delete_reason, state} ->
            {:reply, {:error, {:retention_journal_delete_failed, delete_reason}}, state}
        end

      _ ->
        if is_nil(intent) do
          {:reply, {:error, reason}, state}
        else
          blocker =
            creation_blocker_from_intent(
              intent,
              failed_lease,
              reason
            )

          {:reply, {:error, reason},
           put_creation_blocker(degrade_retention_journal(state, reason), blocker)}
        end
    end
  end

  # Convert a failed owned acquisition into the existing crash-durable discard
  # state machine before any destructive cleanup. The registration HEAD captured
  # with the worktree identity is the exact branch deletion authority; the
  # callback's base_commit may itself be the malformed value that caused
  # finalization to fail.
  defp begin_failed_create_discard(state, intent, failed_lease, identity) do
    with {:ok, marker} <- failed_create_discard_marker(state, intent, failed_lease, identity),
         :ok <- persist_retained_marker(state, marker) do
      hot_marker = %{marker | durable_lifecycle: nil}
      state = put_retained(state, hot_marker)

      case continue_discard_retained(state, hot_marker) do
        {:ok, _result, state2} ->
          if Map.has_key?(state2.retained_by_id, marker.workspace_id) do
            {:pending, :cleanup_residue, state2}
          else
            {:ok, state2}
          end

        {:error, reason, state2} ->
          {:pending, reason, state2}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp failed_create_discard_marker(state, intent, failed_lease, identity) do
    registration = Map.get(identity, :worktree_registration)
    expected_tip = if is_map(registration), do: Map.get(registration, :head)
    branch = Map.get(failed_lease, :branch)
    worktree_path = Map.get(failed_lease, :worktree_path)
    repo_path = Map.get(failed_lease, :repo_path)

    with :ok <- require_binary(expected_tip, :base_commit),
         :ok <- require_binary(branch, :branch),
         :ok <- require_binary(worktree_path, :worktree_path),
         :ok <- require_binary(repo_path, :repo_path),
         %{branch: ^branch, path: registration_path} <- registration,
         true <-
           registration_path == worktree_path or
             registration_path_matches?(registration, worktree_path),
         lstat when is_map(lstat) <- Map.get(identity, :lstat_identity) do
      ttl_ms = min(state.retention_ttl_ms, Config.workspace_retention_max_ttl_ms())

      {:ok,
       %{
         workspace_id: Map.get(failed_lease, :workspace_id),
         owner_pid: Map.get(failed_lease, :owner_pid),
         task_id: Map.get(failed_lease, :task_id),
         principal_id: Map.get(failed_lease, :principal_id),
         repo_path: repo_path,
         worktree_path: worktree_path,
         display_worktree_path: worktree_path,
         branch: branch,
         base_commit: expected_tip,
         ownership: :owned,
         branch_provenance:
           BranchLifecycle.normalize_provenance(
             Map.get(failed_lease, :branch_provenance, :unknown)
           ),
         lifecycle: :discarding,
         discard_phase: :worktree,
         runtime_id: Map.get(intent || %{}, :runtime_id) || state.retention_runtime_id,
         durable_lifecycle: "discarding",
         target: target_key(repo_path, branch, worktree_path),
         lstat_identity: lstat,
         worktree_registration: registration,
         expiry_generation: make_ref(),
         expiry_ref: nil,
         expires_at:
           Map.get(intent || %{}, :expires_at) ||
             DateTime.add(DateTime.utc_now(), ttl_ms, :millisecond),
         expires_at_ms: System.monotonic_time(:millisecond) + ttl_ms,
         retry_count: Map.get(intent || %{}, :retry_count, 0),
         cleanup_failure: nil,
         dormant: false
       }}
    else
      _ -> {:error, :failed_create_discard_identity_invalid}
    end
  end

  defp ensure_created_ownership_admitted(_state, _prepared, :reused, _intent), do: :ok

  defp ensure_created_ownership_admitted(
         %{retention_journal: %{status: :disabled}},
         _prepared,
         :owned,
         _intent
       ),
       do: :ok

  defp ensure_created_ownership_admitted(state, prepared, :owned, intent) do
    with %{retention_journal: %{status: :ready} = journal} <- state,
         {:ok, records} <- load_durable_retained_records(journal),
         true <- reserved_creating_intent?(records, prepared, intent) do
      :ok
    else
      _ -> {:error, :retention_creation_intent_missing}
    end
  end

  defp finalize_created_lease(state, %{ownership: :reused} = lease, nil),
    do: {:ok, lease, state}

  defp finalize_created_lease(state, %{ownership: :reused} = lease, intent) do
    case settle_create_intent_after_success(state, intent) do
      {:ok, state} -> {:ok, lease, state}
      {:error, reason, state} -> {:error, reason, state, :evidence_preserved}
    end
  end

  defp finalize_created_lease(
         %{retention_journal: %{status: :disabled}} = state,
         %{ownership: :owned} = lease,
         nil
       ),
       do: {:ok, lease, state}

  defp finalize_created_lease(state, %{ownership: :owned} = lease, intent) do
    with {:ok, identity} <- capture_retention_identity(lease) do
      active_marker = initial_active_marker(state, lease, identity)
      lease = bind_retention_identity(lease, state, active_marker)

      case persist_retained_marker(state, active_marker) do
        :ok ->
          {:ok, lease, state}

        {:error, reason} ->
          preserve_or_cleanup_initial_marker_failure(state, lease, active_marker, intent, reason)
      end
    else
      {:error, reason} ->
        finalize_failed_create_discard(
          state,
          lease,
          intent,
          Map.get(lease, :created_removal_identity),
          :retention_identity_unavailable,
          {:initial_identity_capture_failed, reason}
        )
    end
  end

  defp initial_active_marker(state, lease, identity) do
    ttl_ms = state.retention_ttl_ms
    expires_at = DateTime.add(DateTime.utc_now(), ttl_ms, :millisecond)

    %{
      workspace_id: lease.workspace_id,
      owner_pid: lease.owner_pid,
      task_id: lease.task_id,
      principal_id: lease.principal_id,
      repo_path: identity.repo_path,
      worktree_path: identity.worktree_path,
      display_worktree_path: lease.worktree_path,
      branch: lease.branch,
      base_commit: lease.base_commit,
      ownership: :owned,
      branch_provenance: Map.get(lease, :branch_provenance, :unknown),
      lifecycle: :retained,
      runtime_id: state.retention_runtime_id,
      durable_lifecycle: "active",
      target: target_key(identity.repo_path, lease.branch, identity.worktree_path),
      lstat_identity: identity.lstat_identity,
      worktree_registration: identity.worktree_registration,
      expiry_generation: make_ref(),
      expiry_ref: nil,
      expires_at: expires_at,
      expires_at_ms: System.monotonic_time(:millisecond) + ttl_ms,
      retry_count: 0,
      cleanup_failure: nil,
      dormant: false
    }
  end

  defp settle_create_intent_after_success(state, nil), do: {:ok, state}

  defp settle_create_intent_after_success(state, intent) do
    case delete_retained_marker(state, intent) do
      :ok ->
        {:ok, drop_creation_blocker(state, intent)}

      {:error, reason} ->
        blocker = creation_blocker_from_intent(intent, intent, {:intent_delete_failed, reason})

        state =
          put_creation_blocker(
            degrade_retention_journal(state, {:intent_delete_failed, reason}),
            blocker
          )

        {:error, reason, state}
    end
  end

  defp settle_create_intent_after_failure(state, nil), do: {:ok, state}

  defp settle_create_intent_after_failure(state, intent) do
    case creation_marker_absent?(intent) do
      :ok ->
        case delete_retained_marker(state, intent) do
          :ok ->
            {:ok, drop_creation_blocker(state, intent)}

          {:error, reason} ->
            blocker =
              creation_blocker_from_intent(intent, intent, {:intent_delete_failed, reason})

            state =
              state
              |> degrade_retention_journal({:intent_delete_failed, reason})
              |> put_creation_blocker(blocker)

            {:error, reason, state}
        end

      {:error, reason} ->
        blocker =
          creation_blocker_from_intent(intent, intent, {:create_cleanup_unconfirmed, reason})

        state =
          state
          |> degrade_retention_journal({:create_cleanup_unconfirmed, reason})
          |> put_creation_blocker(blocker)

        {:blocked, reason, state}
    end
  end

  defp creation_blocker_from_intent(nil, fallback, reason) do
    repo_path = Map.get(fallback, :repo_path, "")
    worktree_path = Map.get(fallback, :worktree_path, "")
    branch = Map.get(fallback, :branch, "")

    %{
      workspace_id: Map.get(fallback, :workspace_id, "unknown"),
      task_id: Map.get(fallback, :task_id),
      principal_id: Map.get(fallback, :principal_id),
      repo_path: repo_path,
      worktree_path: worktree_path,
      branch: branch,
      ownership: :pending,
      lifecycle: :creating,
      active: false,
      dormant: true,
      target: target_key(repo_path, branch, worktree_path),
      cleanup_failure: reason
    }
  end

  defp creation_blocker_from_intent(intent, fallback, reason) do
    blocker = %{
      workspace_id: intent.workspace_id,
      task_id: intent.task_id,
      principal_id: intent.principal_id,
      repo_path: intent.repo_path || Map.get(fallback, :repo_path),
      worktree_path: intent.worktree_path || Map.get(fallback, :worktree_path),
      branch: intent.branch || Map.get(fallback, :branch),
      ownership: :pending,
      lifecycle: :creating,
      active: false,
      dormant: true,
      target: target_key(intent.repo_path, intent.branch, intent.worktree_path),
      cleanup_failure: reason
    }

    blocker
  end

  defp put_creation_blocker(state, blocker) do
    %{
      state
      | retention_blockers: Map.put(state.retention_blockers, blocker.workspace_id, blocker),
        retention_blockers_by_target:
          Map.put(state.retention_blockers_by_target, blocker.target, blocker)
    }
  end

  defp drop_creation_blocker(state, blocker) do
    workspace_id = Map.get(blocker, :workspace_id)
    target = Map.get(blocker, :target)

    %{
      state
      | retention_blockers: Map.delete(state.retention_blockers, workspace_id),
        retention_blockers_by_target: Map.delete(state.retention_blockers_by_target, target)
    }
  end

  defp bind_retention_identity(lease, state, marker) do
    Map.merge(lease, %{
      retention_marker_active: true,
      retention_runtime_id: state.retention_runtime_id,
      retention_repo_path: marker.repo_path,
      retention_worktree_path: marker.worktree_path,
      retention_lstat_identity: marker.lstat_identity,
      retention_worktree_registration: marker.worktree_registration,
      retention_expires_at: marker.expires_at,
      retention_expires_at_ms: marker.expires_at_ms,
      owner_death_deletion_identity: %{
        worktree_path: marker.worktree_path,
        lstat_identity: marker.lstat_identity,
        worktree_registration: Map.take(marker.worktree_registration, [:path, :branch])
      }
    })
  end

  defp preserve_or_cleanup_initial_marker_failure(state, lease, marker, intent, reason) do
    failure = {:retention_journal_write_failed, reason}

    finalize_failed_create_discard(
      state,
      lease,
      intent,
      marker,
      failure,
      {:initial_marker_write_failed, reason}
    )
  end

  defp finalize_failed_create_discard(
         state,
         lease,
         intent,
         identity,
         failure,
         failure_context
       ) do
    case begin_failed_create_discard(state, intent, lease, identity) do
      {:ok, state} ->
        {:error, failure, state, :cleanup_confirmed}

      {:pending, _reason, state} ->
        {:error, failure, state, :evidence_preserved}

      {:error, cleanup_reason, state} ->
        Logger.warning(
          "failed workspace acquisition could not enter durable discard; preserving evidence",
          workspace_id: lease.workspace_id,
          detail: inspect({failure_context, cleanup_reason})
        )

        blocker =
          creation_blocker_from_intent(
            intent,
            lease,
            {failure_context, cleanup_reason}
          )

        state =
          state
          |> degrade_retention_journal({failure_context, cleanup_reason})
          |> put_creation_blocker(blocker)

        {:error, failure, state, :evidence_preserved}
    end
  end

  defp reactivate_retained(retained, prepared, state) do
    # Stable workspace_id preserves the durable marker key across reactivation.
    workspace_id = retained.workspace_id

    with :ok <- validate_retained_identity(retained, prepared),
         :ok <- ensure_reactivated_id_usable(state, prepared, workspace_id),
         {:ok, refreshed_retained} <- refresh_marker_before_reactivation(state, retained) do
      owner_ref = Process.monitor(prepared.owner_pid)
      cancel_expiry(refreshed_retained.expiry_ref)

      lease = %{
        workspace_id: workspace_id,
        owner_pid: prepared.owner_pid,
        owner_ref: owner_ref,
        task_id: prepared.task_id || refreshed_retained.task_id,
        principal_id: prepared.principal_id || refreshed_retained.principal_id,
        repo_path: refreshed_retained.repo_path,
        # Display path is never operational — only the identity-checked path.
        worktree_path: refreshed_retained.worktree_path,
        branch: refreshed_retained.branch,
        base_commit: refreshed_retained.base_commit,
        ownership: :owned,
        branch_provenance: Map.get(refreshed_retained, :branch_provenance, :unknown),
        active: true,
        cleanup_armed: true,
        retention_marker_active: true,
        retention_runtime_id: state.retention_runtime_id,
        retention_repo_path: refreshed_retained.repo_path,
        # Identity needed for identity-bound remove while durable marker remains.
        retention_lstat_identity: refreshed_retained.lstat_identity,
        retention_worktree_registration: refreshed_retained.worktree_registration,
        retention_worktree_path: refreshed_retained.worktree_path,
        retention_expires_at: refreshed_retained.expires_at,
        retention_expires_at_ms: refreshed_retained.expires_at_ms
      }

      # Durable marker remains for the entire active ownership window. Never
      # delete it here — only explicit/TTL cleanup after proven absence may.
      state = drop_retained(state, refreshed_retained)
      state = state |> put_lease(lease) |> put_ref(lease)

      {:reply, {:ok, public_view(lease)}, state}
    else
      {:error, reason} ->
        # Persistence or identity failure: leave retained state untouched.
        {:reply, {:error, reason}, state}
    end
  end

  defp ensure_reactivated_id_usable(state, prepared, workspace_id) do
    cond do
      prepared.workspace_id_explicit and prepared.workspace_id != workspace_id ->
        {:error, :workspace_id_collision}

      Map.has_key?(state.leases, workspace_id) ->
        {:error, :workspace_id_collision}

      true ->
        :ok
    end
  end

  # Atomically refresh the durable marker as lifecycle "active" for this BEAM
  # runtime id before converting retained/orphaned → live. Same workspace key;
  # failure denies reactivation.
  defp refresh_marker_before_reactivation(state, retained) do
    ttl_ms = state.retention_ttl_ms
    now_ms = System.monotonic_time(:millisecond)
    expires_at = DateTime.add(DateTime.utc_now(), ttl_ms, :millisecond)
    expires_at_ms = now_ms + ttl_ms

    refreshed =
      Map.merge(retained, %{
        expires_at: expires_at,
        expires_at_ms: expires_at_ms,
        retry_count: 0,
        cleanup_failure: nil,
        dormant: false,
        lifecycle: :retained,
        runtime_id: state.retention_runtime_id,
        # Persist lifecycle "active" while converting; hot retained entry is dropped.
        durable_lifecycle: "active"
      })

    case persist_retained_marker(state, refreshed) do
      :ok ->
        {:ok, Map.put(refreshed, :durable_lifecycle, nil)}

      {:error, reason} ->
        {:error, {:retention_journal_write_failed, reason}}
    end
  end

  defp validate_retained_identity(retained, prepared) do
    with true <-
           target_key(prepared.repo_path, prepared.branch, prepared.candidate_path) ==
             retained.target,
         {:ok, current_path} <- canonical_existing_path(prepared.candidate_path),
         true <- current_path == retained.worktree_path,
         true <- retained.worktree_path != retained.repo_path,
         {:ok, current_lstat} <- File.lstat(retained.worktree_path),
         true <- lstat_identity(current_lstat) == retained.lstat_identity,
         {:ok, registration} <- worktree_registration(retained.repo_path, retained.worktree_path),
         # HEAD is mutable workspace content, not ownership identity.
         true <- registration_matches?(registration, retained.worktree_registration),
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

  defp run_create_worktree(prepared, require_reused?) do
    create_params =
      if require_reused? do
        Map.put(prepared.create_params, :require_reused, true)
      else
        prepared.create_params
      end

    try do
      result =
        case prepared.create_worktree do
          fun when is_function(fun, 3) ->
            fun.(prepared.repo_path, prepared.branch, create_params)

          _ ->
            Workspace.create_worktree(prepared.repo_path, prepared.branch, create_params)
        end

      normalize_create_worktree_result(result)
    rescue
      error ->
        {:error, {:create_worktree_raised, Exception.message(error)}}
    catch
      kind, reason ->
        {:error, {:create_worktree_caught, kind, reason}}
    end
  end

  # Accept both modern 5-tuples (with branch provenance) and legacy 4-tuples
  # from test doubles / older injectors. Missing provenance fails closed as
  # :unknown so discard never deletes the branch.
  defp normalize_create_worktree_result({:ok, path, ownership, base_commit, provenance}),
    do: {:ok, path, ownership, base_commit, provenance}

  defp normalize_create_worktree_result({:ok, path, ownership, base_commit}),
    do: {:ok, path, ownership, base_commit, :unknown}

  defp normalize_create_worktree_result({:error, _} = error), do: error

  defp normalize_create_worktree_result(other),
    do: {:error, {:invalid_create_worktree_result, other}}

  defp capture_created_identity(_repo_path, _path, _branch, :reused), do: {:ok, nil}

  defp capture_created_identity(repo_path, path, branch, :owned) do
    with {:ok, identity} <- Workspace.capture_worktree_removal_identity(repo_path, path),
         %{branch: ^branch} <- identity.worktree_registration do
      {:ok, identity}
    else
      %{branch: _other} -> {:error, :worktree_registration_mismatch}
      %{detached: true} -> {:error, :worktree_registration_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp capture_created_identity(_repo_path, _path, _branch, _ownership),
    do: {:error, :owned_worktree_identity_unavailable}

  defp bind_created_identity(lease, identity) when is_map(identity) do
    Map.put(lease, :created_removal_identity, identity)
  end

  defp bind_created_identity(lease, _identity), do: lease

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

  # Exact task+principal only — never owner_pid / live-process authority.
  defp fetch_lineage_authorized(state, workspace_id, caller) do
    case Map.fetch(state.leases, workspace_id) do
      :error ->
        {:error, :not_found}

      {:ok, lease} ->
        if principal_task_match?(lease, caller),
          do: {:ok, lease},
          else: {:error, :not_authorized}
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

  defp non_empty_id?(id) when is_binary(id), do: String.trim(id) != ""
  defp non_empty_id?(_id), do: false

  # Opaque identity validation for lineage-only inspect: never rewrite accepted
  # values. Blank includes whitespace-only (trim used only as predicate);
  # leading/trailing whitespace around nonblank content remains distinct.
  defp valid_opaque_id?(id) when is_binary(id) do
    String.trim(id) != "" and String.valid?(id) and not String.contains?(id, <<0>>)
  end

  defp valid_opaque_id?(_id), do: false

  defp validate_task_principal_pair(nil, nil), do: :ok

  defp validate_task_principal_pair(task_id, principal_id)
       when is_binary(task_id) and is_binary(principal_id),
       do: :ok

  defp validate_task_principal_pair(_task_id, _principal_id),
    do: {:error, :incomplete_task_principal}

  defp owner_death_quarantined?(lease) do
    Map.get(lease, :owner_death_deletion_disabled) == true
  end

  defp release_orphaned_retained(state, retained, :retain) do
    ttl_ms = state.retention_ttl_ms
    now_ms = System.monotonic_time(:millisecond)
    expires_at = DateTime.add(DateTime.utc_now(), ttl_ms, :millisecond)

    refreshed =
      Map.merge(retained, %{
        lifecycle: :retained,
        runtime_id: state.retention_runtime_id,
        durable_lifecycle: "retained",
        expiry_generation: make_ref(),
        expiry_ref: nil,
        expires_at: expires_at,
        expires_at_ms: now_ms + ttl_ms,
        retry_count: 0,
        cleanup_failure: nil,
        dormant: false
      })

    case persist_retained_marker(state, refreshed) do
      :ok ->
        expiry_ref =
          Process.send_after(
            self(),
            {:retained_expire, refreshed.target, refreshed.expiry_generation},
            ttl_ms
          )

        retained =
          refreshed
          |> Map.put(:expiry_ref, expiry_ref)
          |> Map.put(:durable_lifecycle, nil)

        state = put_retained(state, retained)

        result =
          retained
          |> Map.put(:active, false)
          |> public_view()
          |> Map.put(:active, false)
          |> Map.put(:status, "retained")
          |> Map.put(:expires_at, DateTime.to_iso8601(expires_at))

        {:ok, result, state}

      {:error, reason} ->
        {:error, {:retention_journal_write_failed, reason}, state}
    end
  end

  defp release_orphaned_retained(state, retained, :remove) do
    # Convert the active marker durably before allowing the cleanup machinery
    # to mutate hot state or reserve a destructive attempt.
    retained_for_remove =
      Map.merge(retained, %{
        lifecycle: :retained,
        runtime_id: state.retention_runtime_id,
        durable_lifecycle: "retained"
      })

    case persist_retained_marker(state, retained_for_remove) do
      :ok ->
        state = put_retained(state, Map.put(retained_for_remove, :durable_lifecycle, nil))
        release_retained_for_settle(state, Map.put(retained_for_remove, :durable_lifecycle, nil))

      {:error, reason} ->
        {:error, {:retention_journal_write_failed, reason}, state}
    end
  end

  defp release_orphaned_retained(state, retained, :discard) do
    discard_marker =
      Map.merge(retained, %{
        lifecycle: :discarding,
        discard_phase: :worktree,
        runtime_id: state.retention_runtime_id,
        durable_lifecycle: "discarding",
        branch_provenance: Map.get(retained, :branch_provenance, :unknown)
      })

    case persist_retained_marker(state, discard_marker) do
      :ok ->
        state = put_retained(state, Map.put(discard_marker, :durable_lifecycle, nil))
        continue_discard_retained(state, Map.put(discard_marker, :durable_lifecycle, nil))

      {:error, reason} ->
        {:error, {:retention_journal_write_failed, reason}, state}
    end
  end

  # Force-settle a hot retained/orphaned lease after exact task+principal auth.
  defp release_retained_for_settle(state, retained) do
    cond do
      # Task settlement must continue an in-flight discard rather than treat it
      # as a plain remove; any leftover marker makes settlement report residue.
      BranchLifecycle.discarding?(retained) ->
        continue_discard_retained(state, retained)

      both_paths_positively_absent?(retained.repo_path, retained.worktree_path) ->
        settle_both_absent_retained(state, retained)

      true ->
        case remove_retained_now(state, retained) do
          {:ok, state} ->
            result =
              retained
              |> Map.put(:active, false)
              |> public_view()
              |> Map.put(:active, false)
              |> Map.put(:status, "removed")

            {:ok, result, state}

          {:error, reason, state} ->
            {:error, reason, state}
        end
    end
  end

  # Both recorded parents are gone — drop the marker without destructive work
  # and without consuming cleanup-attempt budget.
  defp settle_both_absent_retained(state, retained) do
    case delete_retained_marker(state, retained) do
      :ok ->
        cancel_expiry(Map.get(retained, :expiry_ref))

        result =
          retained
          |> Map.put(:active, false)
          |> public_view()
          |> Map.put(:active, false)
          |> Map.put(:status, "removed")

        {:ok, result, drop_retained(state, retained)}

      {:error, reason} ->
        {:error, {:marker_delete_failed, reason}, state}
    end
  end

  defp settle_matching_task_workspaces(state, caller) do
    active =
      state.leases
      |> Map.values()
      |> Enum.filter(&principal_task_match?(&1, caller))

    retained =
      state.retained_by_id
      |> Map.values()
      |> Enum.filter(&principal_task_match?(&1, caller))

    blockers =
      state.retention_blockers
      |> Map.values()
      |> Enum.filter(&principal_task_match?(&1, caller))

    {settled_a, failures_a, state} =
      Enum.reduce(active, {[], [], state}, fn lease, {settled, failures, st} ->
        case settle_active_lease_for_task(st, lease) do
          {:ok, st2} -> {[lease.workspace_id | settled], failures, st2}
          {:error, reason, st2} -> {settled, [{lease.workspace_id, reason} | failures], st2}
        end
      end)

    {settled_r, failures_r, state} =
      Enum.reduce(retained, {settled_a, failures_a, state}, &settle_retained_snapshot/2)

    {settled_b, failures_b, state} =
      Enum.reduce(blockers, {settled_r, failures_r, state}, fn blocker, {settled, failures, st} ->
        case settle_creation_blocker_for_task(st, blocker) do
          {:ok, st2} -> {[blocker.workspace_id | settled], failures, st2}
          {:error, reason, st2} -> {settled, [{blocker.workspace_id, reason} | failures], st2}
        end
      end)

    {Enum.reverse(settled_b), Enum.reverse(failures_b), state}
  end

  defp settle_retained_snapshot(retained, {settled, failures, state}) do
    # Re-fetch after prior mutations; skip if already dropped.
    case Map.fetch(state.retained_by_id, retained.workspace_id) do
      :error ->
        {[retained.workspace_id | settled], failures, state}

      {:ok, current} ->
        settle_current_retained(current, settled, failures, state)
    end
  end

  defp settle_current_retained(retained, settled, failures, state) do
    case release_retained_for_settle(state, retained) do
      {:ok, _result, state} ->
        # Only count as settled when the hot retained entry is gone.
        # Marker-delete retry paths leave residue and must not look settled.
        if Map.has_key?(state.retained_by_id, retained.workspace_id) do
          {settled, [{retained.workspace_id, :settlement_residue} | failures], state}
        else
          {[retained.workspace_id | settled], failures, state}
        end

      {:error, reason, state} ->
        {settled, [{retained.workspace_id, reason} | failures], state}
    end
  end

  defp remaining_task_workspace_ids(state, caller) do
    active_ids =
      state.leases
      |> Map.values()
      |> Enum.filter(&principal_task_match?(&1, caller))
      |> Enum.map(& &1.workspace_id)

    retained_ids =
      state.retained_by_id
      |> Map.values()
      |> Enum.filter(&principal_task_match?(&1, caller))
      |> Enum.map(& &1.workspace_id)

    blocker_ids =
      state.retention_blockers
      |> Map.values()
      |> Enum.filter(&principal_task_match?(&1, caller))
      |> Enum.map(& &1.workspace_id)

    Enum.uniq(active_ids ++ retained_ids ++ blocker_ids)
  end

  defp settle_active_lease_for_task(state, lease) do
    # When both recorded parents are already gone (benchmark deleted pair_root
    # under a still-active lease), drop without destructive work after proving
    # absence and confirming durable marker delete.
    if both_paths_positively_absent?(lease.repo_path, lease.worktree_path) do
      settle_both_absent_active(state, lease)
    else
      case cleanup_workspace_validation_resources(state, lease.workspace_id) do
        {:ok, state} ->
          state =
            state
            |> cleanup_workspace_attestations(lease.workspace_id)
            |> cleanup_workspace_review_snapshots(lease.workspace_id)

          case do_release(state, lease, :remove) do
            {:ok, _result, state} -> {:ok, state}
            {:error, reason, state} -> {:error, reason, state}
          end

        {:error, state} ->
          {:error, :validation_resource_cleanup_failed, state}
      end
    end
  end

  defp settle_both_absent_active(state, lease) do
    case cleanup_workspace_validation_resources(state, lease.workspace_id) do
      {:ok, state} ->
        state =
          state
          |> cleanup_workspace_attestations(lease.workspace_id)
          |> cleanup_workspace_review_snapshots(lease.workspace_id)

        case delete_retained_marker(state, lease) do
          :ok ->
            if is_reference(Map.get(lease, :owner_ref)) do
              Process.demonitor(lease.owner_ref, [:flush])
            end

            {:ok, drop_lease(state, lease)}

          {:error, reason} ->
            # Marker remains — leave the live lease so residue checks fail closed.
            {:error, {:marker_delete_failed, reason}, state}
        end

      {:error, state} ->
        {:error, :validation_resource_cleanup_failed, state}
    end
  end

  defp settle_creation_blocker_for_task(state, blocker) do
    case both_paths_positively_absent?(blocker.repo_path, blocker.worktree_path) do
      true ->
        case delete_retained_marker(state, %{workspace_id: blocker.workspace_id}) do
          :ok ->
            {:ok, drop_creation_blocker(state, blocker)}

          {:error, reason} ->
            {:error, {:marker_delete_failed, reason}, state}
        end

      false ->
        {:error, :retention_creation_blocked, state}
    end
  end

  defp remove_retained_now(state, retained) do
    case reserve_cleanup_attempt(state, retained) do
      {:ok, reserved, state2} ->
        case settle_or_cleanup_retained(state2, reserved) do
          :ok ->
            case delete_retained_marker(state2, reserved) do
              :ok ->
                {:ok, drop_retained(state2, reserved)}

              {:error, reason} ->
                # The path is gone and registration is absent, but preserve
                # the marker as evidence until bounded deletion retries settle.
                {:ok,
                 schedule_retry_after_failed_attempt(
                   state2,
                   reserved,
                   {:marker_delete_failed, reason}
                 )}
            end

          {:error, reason} ->
            state = schedule_retry_after_failed_attempt(state2, reserved, reason)
            {:error, reason, state}
        end

      {:error, reason, state} ->
        {:error, reason, state}
    end
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
    case active_lease_retention_identity(state, lease) do
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
          repo_path: identity.repo_path,
          worktree_path: identity.worktree_path,
          display_worktree_path: lease.worktree_path,
          branch: lease.branch,
          base_commit: lease.base_commit,
          ownership: :owned,
          branch_provenance: Map.get(lease, :branch_provenance, :unknown),
          lifecycle: :retained,
          runtime_id: state.retention_runtime_id,
          durable_lifecycle: "retained",
          target: target,
          lstat_identity: identity.lstat_identity,
          worktree_registration: identity.worktree_registration,
          expiry_generation: generation,
          expiry_ref: nil,
          expires_at: expires_at,
          expires_at_ms: expires_at_ms,
          retry_count: 0,
          cleanup_failure: nil,
          dormant: false
        }

        # Persist durable evidence before dropping live authority so a crash
        # cannot turn a retained workspace into an untracked leak.
        case persist_retained_marker(state, retained) do
          :ok ->
            expiry_ref =
              Process.send_after(self(), {:retained_expire, target, generation}, ttl_ms)

            retained = %{retained | expiry_ref: expiry_ref, durable_lifecycle: nil}
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
            Logger.warning(
              "workspace retain durable write failed; keeping live lease",
              workspace_id: lease.workspace_id,
              detail: inspect(reason)
            )

            {:error, {:retention_journal_write_failed, reason}, state}
        end

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
         mode
       )
       when mode in [:remove, :discard] do
    # Exact task+principal can resume a quarantine, but it cannot turn a path
    # that was never identity-pinned into force-delete authority. Reactivation
    # pins a stable filesystem + registration identity; removal must prove the
    # same identity still occupies the target.
    with expected when is_map(expected) <- Map.get(lease, :owner_death_deletion_identity),
         {:ok, current} <- capture_quarantine_deletion_identity(lease),
         true <- current == expected do
      if mode == :discard do
        do_release_discard(state, lease)
      else
        do_release_after_identity_capture(state, lease)
      end
    else
      _ ->
        {:error, :quarantine_identity_unavailable, state}
    end
  end

  defp do_release(state, lease, :remove), do: do_release_after_identity_capture(state, lease)

  defp do_release(state, lease, :discard), do: do_release_discard(state, lease)

  # A reviewable candidate becomes durable evidence before its worktree is
  # released. The expected commit comes from the pinned graph's reviewed
  # candidate context; archive_branch_evidence_ref/5 rechecks that the local
  # branch still points at that exact OID before creating the hidden ref. A
  # successful archive is idempotent, so retry cannot rebind evidence to a
  # replacement branch tip.
  defp do_release(state, lease, {:publish, candidate_commit, target_mode})
       when target_mode in [:remove, :retain] and is_binary(candidate_commit) do
    archive_input = %{
      repo_path: lease.repo_path,
      branch: lease.branch,
      task_id: lease.task_id,
      workspace_id: lease.workspace_id,
      settlement_tip: candidate_commit
    }

    case invoke_retained_archive(state.retained_archive, archive_input) do
      {:ok, %{hidden_ref: hidden_ref}} ->
        case do_release(state, lease, target_mode) do
          {:ok, result, next_state} ->
            result =
              result
              |> Map.put(:published_commit, candidate_commit)
              |> Map.put(:evidence_ref, hidden_ref)

            {:ok, result, next_state}

          {:error, reason, next_state} ->
            {:error, reason, next_state}
        end

      {:error, reason} ->
        {:error, {:candidate_archive_failed, reason}, state}
    end
  end

  defp do_release(state, _lease, {:publish, _candidate_commit, _target_mode}),
    do: {:error, :invalid_publish_release, state}

  # Discard: journal intent before any destructive work, remove owned worktree,
  # then retire the branch only when provenance is :created and tip still equals
  # the recorded base. Uncertain provenance / tip mismatch fail closed.
  defp do_release_discard(state, lease) when lease.ownership == :reused do
    state = drop_lease(state, lease)
    Process.demonitor(lease.owner_ref, [:flush])

    result =
      lease
      |> public_view()
      |> Map.put(:active, false)
      |> Map.put(:status, "discarded")
      |> Map.put(:branch_retired, false)
      |> Map.put(:branch_preserved_reason, "reused_worktree")

    {:ok, result, state}
  end

  defp do_release_discard(state, lease) when lease.ownership == :owned do
    with {:ok, retained_like} <- retained_view_from_active_lease(state, lease) do
      discard_marker =
        retained_like
        |> Map.put(:lifecycle, :discarding)
        |> Map.put(:discard_phase, :worktree)
        |> Map.put(:durable_lifecycle, "discarding")
        |> Map.put(:branch_provenance, Map.get(lease, :branch_provenance, :unknown))

      case persist_retained_marker(state, discard_marker) do
        :ok ->
          state = drop_lease(state, lease)
          Process.demonitor(lease.owner_ref, [:flush])
          state = put_retained(state, Map.put(discard_marker, :durable_lifecycle, nil))
          continue_discard_retained(state, Map.put(discard_marker, :durable_lifecycle, nil))

        {:error, reason} ->
          {:error, {:retention_journal_write_failed, reason}, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp do_release_after_identity_capture(state, lease) do
    if lease.ownership == :owned do
      case remove_active_owned_lease(state, lease) do
        {:ok, state} ->
          Process.demonitor(lease.owner_ref, [:flush])

          result =
            lease
            |> public_view()
            |> Map.put(:active, false)
            |> Map.put(:status, "removed")

          {:ok, result, state}

        {:error, reason, state} ->
          {:error, reason, state}
      end
    else
      state = drop_lease(state, lease)
      Process.demonitor(lease.owner_ref, [:flush])

      result =
        lease
        |> public_view()
        |> Map.put(:active, false)
        |> Map.put(:status, "removed")

      {:ok, result, state}
    end
  end

  # Owned remove: revalidate expected identity, destroy only when it still
  # matches, prove path+Git absence, then delete the durable marker. Marker
  # delete failure schedules bounded retries; dormancy only after the limit.
  defp remove_active_owned_lease(state, lease) do
    with {:ok, retained_like} <- retained_view_from_active_lease(state, lease) do
      case remove_owned_retained_worktree(retained_like) do
        :ok ->
          case verify_retained_removed(retained_like) do
            :ok ->
              state = drop_lease(state, lease)

              case delete_retained_marker(state, retained_like) do
                :ok ->
                  {:ok, state}

                {:error, reason} ->
                  # Path is gone but durable marker remains — schedule bounded
                  # marker deletion retries.  When reservation also fails the
                  # caller installs :active_orphaned residue.
                  state =
                    schedule_retained_retry(
                      state,
                      retained_like,
                      {:marker_delete_failed, reason}
                    )

                  {:ok, state}
              end

            {:error, reason} ->
              {:error, {:cleanup_unconfirmed, reason}, state}
          end

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp retained_view_from_active_lease(state, lease) do
    with {:ok, identity} <- active_lease_retention_identity(state, lease) do
      {:ok,
       %{
         workspace_id: lease.workspace_id,
         owner_pid: lease.owner_pid,
         task_id: lease.task_id,
         principal_id: lease.principal_id,
         repo_path: identity.repo_path,
         worktree_path: identity.worktree_path,
         display_worktree_path: lease.worktree_path,
         branch: lease.branch,
         base_commit: lease.base_commit,
         ownership: :owned,
         branch_provenance: Map.get(lease, :branch_provenance, :unknown),
         lifecycle: :retained,
         runtime_id: Map.get(lease, :retention_runtime_id, state.retention_runtime_id),
         durable_lifecycle: "active",
         target: target_key(identity.repo_path, lease.branch, identity.worktree_path),
         lstat_identity: identity.lstat_identity,
         worktree_registration: identity.worktree_registration,
         expiry_generation: make_ref(),
         expiry_ref: nil,
         expires_at: Map.get(lease, :retention_expires_at, DateTime.utc_now()),
         expires_at_ms:
           Map.get(lease, :retention_expires_at_ms, System.monotonic_time(:millisecond)),
         retry_count: 0,
         cleanup_failure: nil,
         dormant: false
       }}
    end
  end

  # Continue crash-durable discard from a journaled marker. Never silently
  # success when the worktree is gone but branch retirement still pending.
  defp continue_discard_retained(state, retained) do
    case BranchLifecycle.normalize_phase(Map.get(retained, :discard_phase, :worktree)) do
      {:ok, :archive} -> discard_archive_phase(state, retained)
      {:ok, :worktree} -> discard_worktree_phase(state, retained)
      {:ok, :branch} -> discard_branch_phase(state, retained)
      :invalid -> {:error, :invalid_discard_phase, state}
    end
  end

  # Retained-expiry archive phase. The exact expected branch tip is already
  # durable in settlement_tip before this function is entered; base_commit
  # remains the immutable acquisition base. Reserve the bounded attempt before
  # creating/verifying the hidden ref; failures leave the owned worktree and
  # local branch untouched.
  defp discard_archive_phase(state, retained) do
    case reserve_cleanup_attempt(state, retained) do
      {:ok, reserved, state2} ->
        run_reserved_archive(state2, reserved)

      {:error, :retries_exhausted, state2} ->
        dormant_discard_marker(state2, retained, :archive_retries_exhausted)

      {:error, _reason, state2} ->
        {:error, :reservation_failed, state2}
    end
  end

  defp run_reserved_archive(state, reserved) do
    case invoke_retained_archive(state.retained_archive, reserved) do
      {:ok, _proof} ->
        advance_archive_to_worktree_phase(state, reserved)

      {:error, reason} ->
        state = schedule_retry_after_failed_attempt(state, reserved, {:archive_failed, reason})
        discard_pending_result(state, reserved, {:archive_failed, reason})
    end
  end

  defp advance_archive_to_worktree_phase(state, retained) do
    worktree_marker =
      retained
      |> BranchLifecycle.advance_archive_to_worktree_phase()
      |> Map.put(:durable_lifecycle, "discarding")

    case persist_retained_marker(state, worktree_marker) do
      :ok ->
        cancel_expiry(Map.get(retained, :expiry_ref))
        hot_marker = Map.put(worktree_marker, :durable_lifecycle, nil)
        state = put_retained(state, hot_marker)
        discard_worktree_phase(state, hot_marker)

      {:error, reason} ->
        failure = {:archive_phase_persist_failed, reason}
        state = schedule_retry_after_failed_attempt(state, retained, failure)
        discard_pending_result(state, retained, failure)
    end
  end

  defp discard_worktree_phase(state, retained) do
    worktree_absent? =
      match?({:error, :enoent}, File.lstat(retained.worktree_path)) and
        match?(
          {:ok, :absent},
          worktree_path_registration_presence(retained.repo_path, retained.worktree_path)
        )

    if worktree_absent? do
      advance_discard_to_branch_phase(state, retained)
    else
      # Worktree cleanup is a destructive attempt: reserve before invoking the
      # boundary so crash/restart cannot regain free attempts. Reservation
      # failure performs no work and keeps the marker as evidence.
      case reserve_cleanup_attempt(state, retained) do
        {:ok, reserved, state2} ->
          run_reserved_worktree_cleanup(state2, reserved)

        {:error, :retries_exhausted, state2} ->
          dormant_discard_marker(state2, retained, :cleanup_retries_exhausted)

        {:error, _reason, state2} ->
          # Reservation failed: no work performed. Keep the marker so restart
          # resumes discard rather than declaring settlement.
          {:error, :reservation_failed, state2}
      end
    end
  end

  defp run_reserved_worktree_cleanup(state, reserved) do
    case invoke_retained_cleanup(state.retained_cleanup, reserved) do
      :ok ->
        verify_and_advance_worktree_cleanup(state, reserved)

      {:error, reason} ->
        # Schedule a retry on the already-reserved marker without a second
        # reservation.
        state = schedule_retry_after_failed_attempt(state, reserved, reason)
        {:error, reason, state}
    end
  end

  defp verify_and_advance_worktree_cleanup(state, reserved) do
    case verify_retained_removed(reserved) do
      :ok ->
        advance_discard_to_branch_phase(state, reserved)

      {:error, reason} ->
        # Worktree destruction may be partial; keep the durable marker so
        # restart resumes discard rather than declaring settlement.
        state =
          schedule_retry_after_failed_attempt(state, reserved, {:cleanup_unconfirmed, reason})

        discard_pending_result(state, reserved, {:cleanup_unconfirmed, reason})
    end
  end

  defp advance_discard_to_branch_phase(state, retained) do
    branch_marker =
      retained
      |> BranchLifecycle.advance_to_branch_phase()
      |> Map.put(:durable_lifecycle, "discarding")

    case persist_retained_marker(state, branch_marker) do
      :ok ->
        cancel_expiry(Map.get(retained, :expiry_ref))
        state = put_retained(state, Map.put(branch_marker, :durable_lifecycle, nil))
        discard_branch_phase(state, Map.put(branch_marker, :durable_lifecycle, nil))

      {:error, reason} ->
        # Worktree is already gone; keep retrying from the worktree-phase
        # marker so restart does not silently declare success.
        state =
          schedule_retry_after_failed_attempt(
            state,
            retained,
            {:discard_phase_persist_failed, reason}
          )

        discard_pending_result(state, retained, {:discard_phase_persist_failed, reason})
    end
  end

  # Branch-phase discard. The decision matrix lives in
  # `WorkspaceBranchLifecycleCore`; this shell observes the ref, reserves retry
  # budget before destructive attempts, and interprets decisions as effects.
  defp discard_branch_phase(state, retained) do
    limit = Map.get(state, :retained_cleanup_retry_limit, @default_retained_cleanup_retry_limit)

    provenance =
      BranchLifecycle.normalize_provenance(Map.get(retained, :branch_provenance, :unknown))

    observation =
      case Git.observe_branch_ref(retained.repo_path, retained.branch) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end

    expected_tip = Map.get(retained, :settlement_tip) || retained.base_commit
    decision = BranchLifecycle.branch_phase_decision(provenance, observation, expected_tip)

    interpret_branch_decision(state, retained, decision, limit)
  end

  defp interpret_branch_decision(state, retained, {:settle_complete, opts}, _limit) do
    settle_discard_complete(state, retained, Keyword.get(opts, :branch_retired, true), nil, false)
  end

  defp interpret_branch_decision(state, retained, {:settle_preserve_branch, reason}, _limit) do
    # Reused/unknown provenance settles while preserving the pre-existing branch.
    settle_discard_preserving_branch(state, retained, reason)
  end

  defp interpret_branch_decision(state, retained, {:dormant_preserve_branch, reason}, _limit) do
    # Non-retryable (divergent tip / CAS mismatch): keep a dormant branch-phase
    # marker, preserve the branch, and never claim settlement.
    dormant_discard_marker(state, retained, reason)
  end

  defp interpret_branch_decision(state, retained, {:attempt_delete, expected_oid}, limit) do
    # Destructive attempt: reserve before executing. Reservation failure does
    # no work; exhaustion goes dormant with the branch preserved.
    case reserve_cleanup_attempt(state, retained) do
      {:ok, reserved, state2} ->
        outcome = Git.delete_branch_ref(reserved.repo_path, reserved.branch, expected_oid)
        interpret_delete_outcome(state2, reserved, outcome, limit)

      {:error, :retries_exhausted, state2} ->
        dormant_discard_marker(state2, retained, :retries_exhausted)

      {:error, _reason, state2} ->
        {:error, :reservation_failed, state2}
    end
  end

  defp interpret_branch_decision(state, retained, {:retry_branch_phase, reason}, limit) do
    # Retryable observation/delete error: reserve to bound retries, then either
    # schedule a retry (no second reservation) or go dormant when exhausted.
    case reserve_cleanup_attempt(state, retained) do
      {:ok, reserved, state2} ->
        interpret_retry_decision(state2, reserved, reason, limit)

      {:error, :retries_exhausted, state2} ->
        dormant_discard_marker(state2, retained, reason)

      {:error, _reason, state2} ->
        {:error, :reservation_failed, state2}
    end
  end

  defp interpret_delete_outcome(state, reserved, outcome, limit) do
    case BranchLifecycle.classify_delete_outcome(outcome) do
      {:settle_complete, opts} ->
        settle_discard_complete(
          state,
          reserved,
          Keyword.get(opts, :branch_retired, true),
          nil,
          true
        )

      {:dormant_preserve_branch, reason} ->
        dormant_discard_marker(state, reserved, reason)

      {:retry_branch_phase, reason} ->
        interpret_retry_decision(state, reserved, reason, limit)
    end
  end

  defp interpret_retry_decision(state, reserved, reason, limit) do
    retry_count = Map.get(reserved, :retry_count, 0)

    case BranchLifecycle.resolve_retry({:retry_branch_phase, reason}, retry_count, limit) do
      {:retry, reason} ->
        # Schedule on the reserved marker without a second reservation.
        state = schedule_retry_after_failed_attempt(state, reserved, reason)
        discard_pending_result(state, reserved, reason)

      {:dormant, reason} ->
        dormant_discard_marker(state, reserved, reason)
    end
  end

  defp discard_pending_result(state, retained, reason) do
    limit = Map.get(state, :retained_cleanup_retry_limit, @default_retained_cleanup_retry_limit)

    result =
      retained
      |> Map.put(:active, false)
      |> public_view()
      |> Map.put(:active, false)
      |> Map.put(:status, "discard_pending")
      |> Map.put(:branch_retired, false)
      |> Map.put(:cleanup_residue, true)
      |> Map.put(:cleanup_failure_category, BranchLifecycle.failure_category(reason))
      |> Map.put(:cleanup_retry_count, Map.get(retained, :retry_count, 0))
      |> Map.put(:cleanup_retry_limit, limit)
      |> Map.put(:cleanup_dormant, false)

    {:ok, result, state}
  end

  defp settle_discard_complete(state, retained, branch_retired?, preserve_reason, pre_reserved?) do
    result =
      retained
      |> Map.put(:active, false)
      |> public_view()
      |> Map.put(:active, false)
      |> Map.put(:branch_retired, branch_retired? == true)

    result =
      if is_nil(preserve_reason) do
        result
      else
        Map.put(
          result,
          :branch_preserved_reason,
          BranchLifecycle.preservation_reason(preserve_reason)
        )
      end

    case delete_retained_marker(state, retained) do
      :ok ->
        cancel_expiry(Map.get(retained, :expiry_ref))
        {:ok, Map.put(result, :status, "discarded"), drop_retained(state, retained)}

      {:error, reason} ->
        # Branch/worktree settled; marker-delete failure must schedule on the
        # retry budget.  Pre-reserved callers (interpret_delete_outcome after a
        # successful branch delete) already hold a persisted reservation —
        # schedule on it without incrementing again.  Unreserved callers
        # (direct settle_complete / already-absent observation) reserve exactly
        # once before scheduling.
        marker_reason = {:marker_delete_failed, reason}

        pending_result =
          result
          |> Map.put(:status, "discard_pending")
          |> Map.put(:cleanup_residue, true)
          |> Map.put(:cleanup_failure_category, BranchLifecycle.failure_category(marker_reason))
          |> Map.put(:cleanup_retry_count, Map.get(retained, :retry_count, 0))
          |> Map.put(
            :cleanup_retry_limit,
            Map.get(state, :retained_cleanup_retry_limit, @default_retained_cleanup_retry_limit)
          )
          |> Map.put(:cleanup_dormant, false)

        if pre_reserved? do
          {:ok, pending_result,
           schedule_retry_after_failed_attempt(state, retained, marker_reason)}
        else
          case reserve_cleanup_attempt(state, retained) do
            {:ok, reserved, state2} ->
              {:ok, pending_result,
               schedule_retry_after_failed_attempt(state2, reserved, marker_reason)}

            {:error, :retries_exhausted, state2} ->
              dormant_discard_marker(state2, retained, marker_reason)

            {:error, _persist_failure, state2} ->
              {:ok, pending_result, state2}
          end
        end
    end
  end

  # Reused/unknown provenance, or created+already-absent idempotent settle that
  # preserves a pre-existing branch: drop the marker (the branch is not pending
  # discard work) while exposing the preserved branch on the receipt. A non-owned
  # preserved branch is not residue — there is no owned worktree and no lifecycle
  # marker remaining, so the terminal disposition is complete discarded with
  # branch_retired false. Marker delete failure keeps a dormant marker so
  # settlement stays honest.
  defp settle_discard_preserving_branch(state, retained, reason) do
    case delete_retained_marker(state, retained) do
      :ok ->
        cancel_expiry(Map.get(retained, :expiry_ref))
        state = drop_retained(state, retained)

        result =
          retained
          |> Map.put(:active, false)
          |> public_view()
          |> Map.put(:active, false)
          |> Map.put(:status, "discarded")
          |> Map.put(:branch_retired, false)
          |> Map.put(:branch_preserved_reason, BranchLifecycle.preservation_reason(reason))

        {:ok, result, state}

      {:error, delete_reason} ->
        # Marker-delete failed on a reused/unknown branch. Reserve exactly
        # once before scheduling — do NOT go dormant after one transient
        # delete failure. Backend recovery will eventually remove the marker
        # while preserving the reused branch; exhaustion goes dormant.
        combined_reason = {reason, delete_reason}

        pending_result =
          retained
          |> Map.put(:active, false)
          |> public_view()
          |> Map.put(:active, false)
          |> Map.put(:status, "discard_pending")
          |> Map.put(:branch_retired, false)
          |> Map.put(:branch_preserved_reason, BranchLifecycle.preservation_reason(reason))
          |> Map.put(:cleanup_residue, true)
          |> Map.put(
            :cleanup_failure_category,
            BranchLifecycle.failure_category({:marker_delete_failed, delete_reason})
          )
          |> Map.put(:cleanup_retry_count, Map.get(retained, :retry_count, 0))
          |> Map.put(
            :cleanup_retry_limit,
            Map.get(state, :retained_cleanup_retry_limit, @default_retained_cleanup_retry_limit)
          )
          |> Map.put(:cleanup_dormant, false)

        case reserve_cleanup_attempt(state, retained) do
          {:ok, reserved, state2} ->
            {:ok, pending_result,
             schedule_retry_after_failed_attempt(state2, reserved, combined_reason)}

          {:error, :retries_exhausted, state2} ->
            dormant_discard_marker(state2, retained, combined_reason)

          {:error, _persist_failure, state2} ->
            {:ok, pending_result, state2}
        end
    end
  end

  # Non-retryable or exhausted outcome: preserve the branch and keep a DORMANT
  # discarding marker. Do NOT delete the marker and do NOT claim settlement —
  # the receipt reports a pending/dormant discard so callers and task settlement
  # see residue. retry_count is forced to the configured limit so restart cannot
  # regain destructive attempts.
  #
  # The marker preserves the original discard_phase (archive, worktree, or branch) from
  # the retained marker. Worktree-phase exhaustion stays in worktree phase with
  # its lstat_identity and worktree_registration evidence; only branch-phase
  # operations produce a branch-phase dormant marker. This is honest: the
  # evidence shows where discard stalled, not where we wish it had progressed.
  defp dormant_discard_marker(state, retained, reason) do
    limit = Map.get(state, :retained_cleanup_retry_limit, @default_retained_cleanup_retry_limit)

    forced_retry_count =
      BranchLifecycle.force_exhausted(Map.get(retained, :retry_count, 0), limit)

    # Preserve the current discard_phase; fall back to :branch only when the
    # retained marker has no phase at all (shouldn't happen for discarding
    # markers, but fail-closed to :branch for non-discarding callers).
    retained_phase =
      case BranchLifecycle.normalize_phase(Map.get(retained, :discard_phase)) do
        {:ok, phase} -> phase
        :invalid -> :branch
      end

    dormant =
      retained
      |> Map.put(:lifecycle, :discarding)
      |> Map.put(:discard_phase, retained_phase)
      |> Map.put(:dormant, true)
      |> Map.put(:retry_count, forced_retry_count)
      |> Map.put(:expiry_ref, nil)
      |> Map.put(:cleanup_failure, {:discard_preserve_branch, reason})
      |> Map.put(:durable_lifecycle, "discarding")

    cancel_expiry(Map.get(retained, :expiry_ref))

    # Persist dormancy before installing hot state. On failure, retain the
    # prior durable evidence exactly — do NOT install the attempted dormant
    # marker (not even annotated), which would claim an uncommitted transition.
    # Degrade admission and arm no timer.
    {state, hot_marker} =
      case persist_retained_marker(state, dormant) do
        :ok ->
          state = put_retained(state, %{dormant | durable_lifecycle: nil})
          {state, dormant}

        {:error, persist_reason} ->
          Logger.warning(
            "workspace discard dormancy persist failed; journal degraded, no false dormant state",
            workspace_id: retained.workspace_id,
            detail: inspect(persist_reason)
          )

          state = degrade_retention_journal(state, {:durable_persist_failed, persist_reason})
          {state, retained}
      end

    result =
      hot_marker
      |> Map.put(:active, false)
      |> public_view()
      |> Map.put(:status, "discard_pending")
      |> Map.put(:branch_retired, false)
      |> Map.put(:branch_preserved_reason, BranchLifecycle.preservation_reason(reason))
      |> Map.put(:cleanup_residue, true)
      |> Map.put(:cleanup_retry_count, forced_retry_count)
      |> Map.put(:cleanup_retry_limit, limit)
      |> Map.put(:cleanup_dormant, true)

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

  # A publish action may complete its Git side effects and lose its reply when
  # the Engine or caller crashes before checkpointing. The hidden evidence ref
  # is the durable receipt. Reconstruct the response only after observing that
  # exact task/workspace ref at the exact candidate OID; never synthesize
  # publication success from deterministic naming alone.
  defp already_released_reply(state, workspace_id, mode, caller)
       when mode in [:publish, :publish_retain] do
    case Git.verify_archived_evidence_ref(
           caller.repo_path,
           caller.task_id,
           workspace_id,
           caller.candidate_commit
         ) do
      {:ok, %{hidden_ref: hidden_ref}} ->
        result =
          workspace_id
          |> already_released_view()
          |> Map.put(:published_commit, caller.candidate_commit)
          |> Map.put(:evidence_ref, hidden_ref)

        {:reply, {:ok, result}, state}

      {:error, _reason} ->
        # Keep the public failure stable so callers cannot distinguish an
        # absent repository, commit, or hidden ref through this replay path.
        {:reply, {:error, :publication_replay_unverified}, state}
    end
  end

  defp already_released_reply(state, workspace_id, _mode, _caller),
    do: {:reply, {:ok, already_released_view(workspace_id)}, state}

  defp capture_retention_identity(lease) do
    with {:ok, canonical_repo} <- canonical_existing_path(lease.repo_path),
         {:ok, canonical_worktree_path} <- canonical_existing_path(lease.worktree_path),
         :ok <- reject_primary_checkout_paths(canonical_repo, canonical_worktree_path),
         {:ok, lstat} <- File.lstat(canonical_worktree_path),
         {:ok, registration} <- worktree_registration(canonical_repo, canonical_worktree_path),
         true <- registration.path == canonical_worktree_path,
         true <- registration.branch == lease.branch,
         {:ok, current_branch} <- current_branch(canonical_repo, canonical_worktree_path),
         true <- current_branch == lease.branch do
      {:ok,
       %{
         repo_path: canonical_repo,
         worktree_path: canonical_worktree_path,
         lstat_identity: lstat_identity(lstat),
         worktree_registration: registration
       }}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :retained_identity_mismatch}
      other -> {:error, {:unexpected_identity, other}}
    end
  end

  defp active_lease_retention_identity(
         %{retention_journal: %{status: :disabled}},
         lease
       ),
       do: capture_retention_identity(lease)

  defp active_lease_retention_identity(_state, lease),
    do: retention_identity_from_active_lease(lease)

  defp retention_identity_from_active_lease(lease) do
    repo_path = Map.get(lease, :retention_repo_path)
    worktree_path = Map.get(lease, :retention_worktree_path)
    lstat = Map.get(lease, :retention_lstat_identity)
    registration = Map.get(lease, :retention_worktree_registration)

    retained_identity = %{
      repo_path: repo_path,
      worktree_path: worktree_path,
      lstat_identity: lstat,
      worktree_registration: registration
    }

    with true <- is_binary(repo_path) and is_binary(worktree_path),
         true <- is_map(lstat) and is_map(registration),
         true <- repo_path != worktree_path,
         :ok <- revalidate_destruction_identity(retained_identity),
         {:ok, current_branch} <- current_branch(repo_path, worktree_path),
         true <- current_branch == lease.branch do
      {:ok,
       %{
         repo_path: repo_path,
         worktree_path: worktree_path,
         lstat_identity: lstat,
         worktree_registration: registration
       }}
    else
      _ -> {:error, :retention_identity_unavailable}
    end
  end

  defp reject_primary_checkout_paths(repo_path, worktree_path)
       when is_binary(repo_path) and is_binary(worktree_path) do
    if repo_path == worktree_path do
      {:error, :primary_checkout_not_retainable}
    else
      :ok
    end
  end

  defp reject_primary_checkout_paths(_, _), do: {:error, :primary_checkout_not_retainable}

  # HEAD is intentionally excluded: an authorized resumed worker may commit
  # between reactivation and release, while the directory inode, canonical
  # path, and registered branch must remain stable.
  defp capture_quarantine_deletion_identity(lease) do
    with {:ok, identity} <- capture_retention_identity(lease) do
      {:ok,
       %{
         worktree_path: identity.worktree_path,
         lstat_identity: identity.lstat_identity,
         worktree_registration: Map.take(identity.worktree_registration, [:path, :branch])
       }}
    end
  end

  defp expire_retained(state, target, generation) do
    case Map.get(state.retained_by_target, target) do
      %{} = retained when retained.expiry_generation == generation ->
        cond do
          Map.get(retained, :dormant) == true ->
            # Exhausted automatic retries — no recurring timer.
            state

          Map.get(retained, :lifecycle) == :active_orphaned ->
            # Same-BEAM active marker: never arm TTL deletion.
            state

          Map.get(retained, :lifecycle) == :discarding ->
            # Crash-durable discard continuation — never drop the marker as a
            # plain worktree settle; branch retirement may still be pending.
            case continue_discard_retained(state, retained) do
              {:ok, _result, state2} -> state2
              {:error, _reason, state2} -> state2
            end

          System.monotonic_time(:millisecond) < retained.expires_at_ms ->
            reschedule_retained_expiry(state, retained)

          active_target?(state, target) ->
            state

          true ->
            expire_retained_workspace(state, retained)
        end

      _ ->
        state
    end
  end

  # A retained recovery workspace expires through an archive-first settlement.
  # The only non-archiving terminal path is positive absence of both recorded
  # parents, where no repository remains from which archive authority could be
  # derived. Explicit remove continues to use the backward-compatible path.
  defp expire_retained_workspace(state, retained) do
    if both_paths_positively_absent?(retained.repo_path, retained.worktree_path) do
      settle_expired_both_absent(state, retained)
    else
      begin_retained_expiry_archive(state, retained)
    end
  end

  defp settle_expired_both_absent(state, retained) do
    case reserve_cleanup_attempt(state, retained) do
      {:ok, reserved, state2} ->
        case delete_retained_marker(state2, reserved) do
          :ok ->
            drop_retained(state2, reserved)

          {:error, reason} ->
            schedule_retry_after_failed_attempt(
              state2,
              reserved,
              {:marker_delete_failed, reason}
            )
        end

      {:error, _reason, state2} ->
        state2
    end
  end

  # Capture the exact current local-branch tip only while the retained
  # worktree identity is still valid, then persist archive intent before the
  # hidden ref or either destructive phase can run. Once persisted, retries
  # never rebind to a replacement tip.
  defp begin_retained_expiry_archive(state, retained) do
    with :ok <- validate_retained_stored_identity(retained),
         {:ok, {:present, expected_tip}} <-
           Git.observe_branch_ref(retained.repo_path, retained.branch) do
      archive_marker =
        BranchLifecycle.begin_archive_phase(
          retained,
          expected_tip,
          Map.get(retained, :runtime_id) || state.retention_runtime_id
        )

      case persist_retained_marker(state, archive_marker) do
        :ok ->
          cancel_expiry(Map.get(retained, :expiry_ref))

          hot_marker =
            archive_marker
            |> Map.put(:durable_lifecycle, nil)
            |> Map.put(:expiry_ref, nil)

          state = put_retained(state, hot_marker)

          case continue_discard_retained(state, hot_marker) do
            {:ok, _result, state2} -> state2
            {:error, _reason, state2} -> state2
          end

        {:error, reason} ->
          schedule_expiry_transition_retry(
            state,
            retained,
            {:archive_intent_persist_failed, reason}
          )
      end
    else
      {:ok, :absent} ->
        schedule_expiry_transition_retry(state, retained, :archive_branch_absent)

      {:error, reason} ->
        schedule_expiry_transition_retry(state, retained, {:archive_capture_failed, reason})
    end
  end

  # Capture/intent failures occur before archive authority is committed. They
  # stay in retained lifecycle and consume the same durable bounded retry
  # budget without performing a Git or filesystem side effect.
  defp schedule_expiry_transition_retry(state, retained, reason) do
    case reserve_cleanup_attempt(state, retained) do
      {:ok, reserved, state2} ->
        schedule_retry_after_failed_attempt(state2, reserved, reason)

      {:error, _reserve_reason, state2} ->
        state2
    end
  end

  # Positive absence settles without destructive work:
  # * both recorded repo_path and worktree_path positively absent (enoent), or
  # * worktree path gone and Git registration positively absent while repo lives
  # Never treats one missing path, identity mismatch on a present path, or an
  # unreadable state as absence.
  defp settle_or_cleanup_retained(state, retained) do
    if both_paths_positively_absent?(retained.repo_path, retained.worktree_path) do
      :ok
    else
      case verify_retained_removed(retained) do
        :ok ->
          :ok

        {:error, _} ->
          cleanup_retained_worktree(state, retained)
      end
    end
  end

  defp both_paths_positively_absent?(repo_path, worktree_path)
       when is_binary(repo_path) and is_binary(worktree_path) do
    case {File.lstat(repo_path), File.lstat(worktree_path)} do
      {{:error, :enoent}, {:error, :enoent}} -> true
      _other -> false
    end
  end

  defp both_paths_positively_absent?(_repo_path, _worktree_path), do: false

  defp active_target?(state, target) do
    Enum.any?(state.leases, fn {_id, lease} ->
      target_key(lease.repo_path, lease.branch, lease.worktree_path) == target
    end)
  end

  defp cleanup_retained_worktree(state, retained) do
    case validate_retained_stored_identity(retained) do
      :ok ->
        # Pass the full retained identity into the cleanup boundary so the
        # default path can revalidate immediately before every destructive
        # fallback (never unconditional rm_rf after identity change).
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
         # HEAD is evidence only; ownership identity is path + branch + lstat.
         true <- registration_matches?(registration, retained.worktree_registration),
         {:ok, current_branch} <- current_branch(retained.repo_path, retained.worktree_path),
         true <- current_branch == retained.branch do
      :ok
    else
      _ -> {:error, :retained_identity_mismatch}
    end
  end

  defp archive_retained_branch(retained) when is_map(retained) do
    Git.archive_branch_evidence_ref(
      Map.get(retained, :repo_path),
      Map.get(retained, :branch),
      Map.get(retained, :task_id),
      Map.get(retained, :workspace_id),
      Map.get(retained, :settlement_tip)
    )
  end

  defp archive_retained_branch(_), do: {:error, :invalid_retained_archive}

  defp invoke_retained_archive(archive, retained) when is_function(archive, 1) do
    case archive.(retained) do
      {:ok, %{hidden_ref: hidden_ref} = proof}
      when is_binary(hidden_ref) and hidden_ref != "" ->
        {:ok, proof}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_retained_archive_result}
    end
  rescue
    _ -> {:error, :retained_archive_failed}
  catch
    kind, reason -> {:error, {:retained_archive_thrown, kind, reason}}
  end

  defp invoke_retained_archive(_archive, _retained),
    do: {:error, :invalid_retained_archive}

  defp invoke_retained_cleanup(cleanup, retained) when is_function(cleanup, 1) do
    case cleanup.(retained) do
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
         {:ok, :absent} <-
           worktree_path_registration_presence(retained.repo_path, retained.worktree_path) do
      :ok
    else
      _ -> {:error, :retained_cleanup_unconfirmed}
    end
  end

  # Pre-reserve one durable cleanup/delete attempt. Failed reservation performs
  # no attempt, poisons admission, stops recurring cleanup, and keeps dormant
  # evidence so a restart cannot regain free retries.
  defp reserve_cleanup_attempt(state, retained) do
    limit = Map.get(state, :retained_cleanup_retry_limit, @default_retained_cleanup_retry_limit)
    retry_count = Map.get(retained, :retry_count, 0)

    cond do
      Map.get(retained, :dormant) == true ->
        {:error, :already_dormant, state}

      Map.get(retained, :lifecycle) == :active_orphaned ->
        {:error, :orphaned_active_not_cleaned, state}

      retry_count >= limit ->
        # Derive the lifecycle that represents the committed dormant state.
        # A stale "active" durable_lifecycle from retained_view_from_active_lease
        # must NOT carry through a dormant transition — restart hydration would
        # misinterpret it as :active_orphaned and regain behavior.
        durable_lifecycle =
          case Map.get(retained, :lifecycle) do
            :discarding -> "discarding"
            "discarding" -> "discarding"
            _ -> "retained"
          end

        dormant =
          %{
            retained
            | dormant: true,
              expiry_ref: nil,
              cleanup_failure: :cleanup_retries_exhausted,
              durable_lifecycle: durable_lifecycle
          }

        cancel_expiry(Map.get(retained, :expiry_ref))

        Logger.warning(
          "workspace retained cleanup retries exhausted; dormant evidence kept",
          workspace_id: retained.workspace_id
        )

        # Persist dormancy before installing hot state so restart cannot regain
        # attempts. On failure, degrade admission and retain the prior durable
        # evidence exactly — never install the attempted dormant marker (not
        # even annotated) over a stale journal, and arm no timer.
        state =
          case persist_retained_marker(state, dormant) do
            :ok ->
              put_retained(state, dormant)

            {:error, persist_reason} ->
              degrade_retention_journal(state, {:durable_persist_failed, persist_reason})
          end

        {:error, :retries_exhausted, state}

      true ->
        # Preserve discarding lifecycle + discard_phase on every reservation so
        # retry encoding does not fail closed as :discard_phase_not_allowed.
        durable_lifecycle =
          case Map.get(retained, :lifecycle) do
            :discarding -> "discarding"
            "discarding" -> "discarding"
            _ -> "retained"
          end

        reserved = %{
          retained
          | retry_count: retry_count + 1,
            dormant: false,
            durable_lifecycle: durable_lifecycle
        }

        case persist_retained_marker(state, reserved) do
          :ok ->
            cancel_expiry(Map.get(retained, :expiry_ref))
            reserved = %{reserved | expiry_ref: nil, durable_lifecycle: nil}
            {:ok, reserved, put_retained(state, reserved)}

          {:error, reason} ->
            cancel_expiry(Map.get(retained, :expiry_ref))

            Logger.warning(
              "workspace retained cleanup reservation failed; no attempt; journal poisoned",
              workspace_id: retained.workspace_id,
              detail: inspect(reason)
            )

            # Retain the prior durable evidence; do not install the attempted
            # dormant/reserved state. Admission is degraded so the journal is
            # not trusted and no destructive attempt can proceed on restart.
            state =
              degrade_retention_journal(state, {:retry_reservation_failed, reason})

            {:error, :reservation_failed, state}
        end
    end
  end

  # After a reserved attempt fails, reschedule without incrementing again.
  # Restart still sees the pre-reserved retry_count.
  #
  # Durable ordering: the retry/dormant marker must persist BEFORE any timer is
  # armed or matching hot state is installed. A persistence failure never
  # installs the attempted transition (not even with a failure annotation) —
  # doing so would make hot state claim a transition the journal never
  # committed. Instead: cancel the old timer, arm no new timer, retain the
  # prior durable/hot evidence exactly, and degrade admission so callers and
  # restart cannot mistake a stale journal for authoritative.
  defp schedule_retry_after_failed_attempt(state, retained, reason) do
    limit = Map.get(state, :retained_cleanup_retry_limit, @default_retained_cleanup_retry_limit)
    retry_count = Map.get(retained, :retry_count, 0)

    durable_lifecycle =
      case Map.get(retained, :lifecycle) do
        :discarding -> "discarding"
        "discarding" -> "discarding"
        _ -> "retained"
      end

    if retry_count >= limit do
      dormant = %{
        retained
        | expiry_ref: nil,
          dormant: true,
          cleanup_failure: {:cleanup_retries_exhausted, reason},
          durable_lifecycle: durable_lifecycle
      }

      case persist_retained_marker(state, dormant) do
        :ok ->
          cancel_expiry(Map.get(retained, :expiry_ref))
          put_retained(state, %{dormant | durable_lifecycle: nil})

        {:error, persist_reason} ->
          Logger.warning(
            "workspace retained dormancy persist failed; journal degraded, no fake timer",
            workspace_id: retained.workspace_id,
            detail: inspect(persist_reason)
          )

          # Retain the prior durable evidence; do not install the attempted
          # dormant state. Admission is degraded so the journal is not trusted.
          cancel_expiry(Map.get(retained, :expiry_ref))
          degrade_retention_journal(state, {:durable_persist_failed, persist_reason})
      end
    else
      # retry_count is pre-reserved before the attempt. Preserve the original
      # backoff sequence: the first failed attempt waits one base interval,
      # then subsequent reserved attempts double from there.
      exponent = retry_count |> Kernel.-(1) |> max(0) |> min(5)
      delay = min(1_000 * Integer.pow(2, exponent), 60_000)

      pending = %{
        retained
        | expiry_ref: nil,
          cleanup_failure: reason,
          dormant: false,
          durable_lifecycle: durable_lifecycle
      }

      case persist_retained_marker(state, pending) do
        :ok ->
          cancel_expiry(Map.get(retained, :expiry_ref))

          generation = make_ref()

          expiry_ref =
            Process.send_after(self(), {:retained_expire, retained.target, generation}, delay)

          next = %{
            pending
            | expiry_generation: generation,
              expiry_ref: expiry_ref
          }

          put_retained(state, %{next | durable_lifecycle: nil})

        {:error, persist_reason} ->
          Logger.warning(
            "workspace retained retry persist failed; journal degraded, no fake timer",
            workspace_id: retained.workspace_id,
            detail: inspect(persist_reason)
          )

          # Retain the prior durable evidence; do not install the attempted
          # pending state or arm a timer. Admission is degraded.
          cancel_expiry(Map.get(retained, :expiry_ref))
          degrade_retention_journal(state, {:durable_persist_failed, persist_reason})
      end
    end
  end

  # Compatibility path used by active-lease marker-delete failure after path
  # remove: pre-reserve then schedule.  Only an actual :reservation_failed
  # (persist failed) may install :active_orphaned residue — the precise
  # :retry_reservation_failed poison reason from reserve_cleanup_attempt is
  # preserved.  Other committed outcomes (:retries_exhausted, :already_dormant,
  # :orphaned_active_not_cleaned) have already committed their durable
  # transition and must be preserved exactly.
  defp schedule_retained_retry(state, retained, reason) do
    case reserve_cleanup_attempt(state, retained) do
      {:ok, reserved, state2} ->
        schedule_retry_after_failed_attempt(state2, reserved, reason)

      {:error, :reservation_failed, state2} ->
        # Persist failed: nothing was committed.  Preserve the last committed
        # active lifecycle plus observed path absence with :active_orphaned.
        # state2 already carries the precise :retry_reservation_failed poison
        # reason — do not overwrite it.
        orphaned =
          retained
          |> Map.put(:lifecycle, :active_orphaned)
          |> Map.put(:durable_lifecycle, nil)
          |> Map.put(:expiry_ref, nil)
          |> Map.put(:dormant, false)
          |> Map.put(:cleanup_failure, nil)
          |> Map.put(:retry_count, Map.get(retained, :retry_count, 0))

        put_retained(state2, orphaned)

      {:error, _committed, state2} ->
        # :retries_exhausted / :already_dormant / :orphaned_active_not_cleaned:
        # reserve_cleanup_attempt already committed the durable transition
        # (dormancy persist or admission degrade).  Preserve exactly.
        state2
    end
  end

  defp reschedule_retained_expiry(state, retained) do
    remaining = max(retained.expires_at_ms - System.monotonic_time(:millisecond), 1)
    generation = make_ref()

    expiry_ref =
      Process.send_after(self(), {:retained_expire, retained.target, generation}, remaining)

    put_retained(state, %{retained | expiry_generation: generation, expiry_ref: expiry_ref})
  end

  # -- Retention journal (Persistence facade) -------------------------

  defp journal_config_from_opts(opts) do
    journal =
      case Keyword.fetch(server_opts(opts), :retention_journal) do
        {:ok, configured} -> configured
        :error -> Config.application_retention_journal()
      end

    case journal do
      :disabled ->
        %{status: :disabled}

      {store_name, backend}
      when is_atom(store_name) and is_atom(backend) and not is_nil(backend) ->
        %{status: :ready, store_name: store_name, backend: backend}

      %{store_name: store_name, backend: backend}
      when is_atom(store_name) and is_atom(backend) and not is_nil(backend) ->
        %{status: :ready, store_name: store_name, backend: backend}

      _ ->
        %{status: :poisoned, reason: :invalid_retention_journal_configuration}
    end
  end

  defp hydrate_retained_from_journal(%{retention_journal: %{status: :disabled}} = state),
    do: state

  defp hydrate_retained_from_journal(%{retention_journal: %{status: :poisoned}} = state),
    do: state

  # All-or-nothing: fully validate/materialize the durable inventory (including
  # duplicate-target rejection and far-future expiry rewrites) before any timer
  # is scheduled or hot retained entry is installed. A single bad/duplicate
  # record poisons the journal and leaves no partial hot state.
  defp hydrate_retained_from_journal(%{retention_journal: journal} = state) do
    case load_durable_retained_records(journal) do
      {:ok, records} ->
        case materialize_all_retained(records, state) do
          {:ok, retained_list, state_after} ->
            install_retained_list(state_after, retained_list)

          {:error, reason} ->
            Logger.warning(
              "workspace retention journal hydrate failed closed; no hot retained state",
              detail: inspect(reason)
            )

            poison_retention_journal(state, reason)
        end

      {:error, reason} ->
        Logger.warning(
          "workspace retention journal load failed; starting poisoned without hot restore",
          detail: inspect(reason)
        )

        poison_retention_journal(state, reason)
    end
  end

  defp poison_retention_journal(%{retention_journal: journal} = state, reason) do
    %{
      state
      | retained_by_id: %{},
        retained_by_target: %{},
        retention_blockers: %{},
        retention_blockers_by_target: %{},
        retention_journal:
          journal
          |> Map.put(:status, :poisoned)
          |> Map.put(:reason, reason)
    }
  end

  # Degrade admission without wiping already-materialized dormant evidence.
  defp degrade_retention_journal(%{retention_journal: journal} = state, reason) do
    %{
      state
      | retention_journal:
          journal
          |> Map.put(:status, :poisoned)
          |> Map.put(:reason, reason)
    }
  end

  defp materialize_all_retained(records, state) when is_list(records) do
    records
    |> Enum.reduce_while({:ok, [], MapSet.new(), MapSet.new(), state}, fn record,
                                                                          {:ok, acc, ids, targets,
                                                                           st} ->
      case RetentionJournal.restore_decision(record) do
        :restore ->
          case materialize_durable_record(record, st) do
            {:ok, :settled, st2} ->
              {:cont, {:ok, acc, ids, targets, st2}}

            {:ok, materialized, st2} ->
              cond do
                MapSet.member?(ids, materialized.workspace_id) ->
                  {:halt, {:error, {:duplicate_workspace_id, materialized.workspace_id}}}

                MapSet.member?(targets, materialized.target) ->
                  {:halt, {:error, {:duplicate_workspace_target, materialized.target}}}

                true ->
                  {:cont,
                   {:ok, [materialized | acc], MapSet.put(ids, materialized.workspace_id),
                    MapSet.put(targets, materialized.target), st2}}
              end

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        {:reject, reason} ->
          {:halt, {:error, {:restore_rejected, Map.get(record, :workspace_id), reason}}}
      end
    end)
    |> case do
      {:ok, list, _ids, _targets, st} -> {:ok, Enum.reverse(list), st}
      {:error, reason} -> {:error, reason}
    end
  end

  defp materialize_durable_record(record, state) do
    cond do
      RetentionJournal.creating_record?(record) ->
        materialize_creation_blocker(record, state)

      RetentionJournal.discarding_record?(record) ->
        materialize_discarding_from_durable(record, state)

      true ->
        case settle_absent_orphaned_marker(record, state) do
          {:ok, :settled, state2} ->
            {:ok, :settled, state2}

          {:ok, :keep, state2} ->
            case materialize_retained_from_durable(record, state2) do
              {:ok, retained, state3} ->
                {:ok, retained, state3}

              {:error, reason} ->
                {:error, {:materialize_failed, Map.get(record, :workspace_id), reason}}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Crash/restart continuation for discard: rehydrate the durable marker and
  # immediately continue from the recorded phase rather than declaring success.
  defp materialize_discarding_from_durable(record, state) do
    phase =
      case Map.get(record, :discard_phase) do
        "archive" -> :archive
        "branch" -> :branch
        "worktree" -> :worktree
        other when other in [:archive, :branch, :worktree] -> other
        _ -> :worktree
      end

    provenance =
      BranchLifecycle.normalize_provenance(Map.get(record, :branch_provenance, "unknown"))

    repo_path = canonical_path_or_expanded(record.repo_path)
    worktree_path = canonical_path_or_expanded(record.worktree_path)

    retry_count = Map.get(record, :retry_count, 0)

    limit =
      Map.get(state, :retained_cleanup_retry_limit, @default_retained_cleanup_retry_limit)

    {lstat, registration, identity_available?} = hydrate_discard_identity(phase, record)

    # Dormancy is derived from the durable retry budget so a restart cannot
    # regain destructive attempts. Worktree-phase identity loss also keeps the
    # marker dormant (residue is preserved, the branch is never deleted).
    dormant? =
      if phase in [:archive, :worktree] and not identity_available? do
        true
      else
        BranchLifecycle.dormant_on_hydrate?(phase, retry_count, limit)
      end

    cleanup_failure =
      cond do
        phase in [:archive, :worktree] and not identity_available? ->
          :discard_identity_unavailable

        dormant? ->
          :cleanup_retries_exhausted

        true ->
          nil
      end

    retained = %{
      workspace_id: record.workspace_id,
      owner_pid: nil,
      task_id: record.task_id,
      principal_id: record.principal_id,
      repo_path: repo_path,
      worktree_path: worktree_path,
      display_worktree_path: record.display_worktree_path,
      branch: record.branch,
      base_commit: record.base_commit,
      settlement_tip: Map.get(record, :settlement_tip),
      ownership: :owned,
      branch_provenance: provenance,
      lifecycle: :discarding,
      discard_phase: phase,
      runtime_id: state.retention_runtime_id,
      durable_lifecycle: nil,
      target: target_key(repo_path, record.branch, worktree_path),
      lstat_identity: lstat,
      worktree_registration: registration,
      expiry_generation: make_ref(),
      expiry_ref: nil,
      expires_at: DateTime.utc_now(),
      expires_at_ms: System.monotonic_time(:millisecond),
      retry_count: retry_count,
      cleanup_failure: cleanup_failure,
      dormant: dormant?
    }

    {:ok, retained, state}
  end

  defp hydrate_discard_identity(:branch, _record), do: {nil, nil, true}

  defp hydrate_discard_identity(phase, record) when phase in [:archive, :worktree] do
    case {hydrate_lstat_identity(record.lstat_identity),
          hydrate_worktree_registration(record.worktree_registration)} do
      {{:ok, lstat}, {:ok, registration}} -> {lstat, registration, true}
      _ -> {nil, nil, false}
    end
  end

  defp materialize_creation_blocker(record, state) do
    blocker = %{
      workspace_id: record.workspace_id,
      task_id: record.task_id,
      principal_id: record.principal_id,
      repo_path: canonical_path_or_expanded(record.repo_path),
      worktree_path: canonical_path_or_expanded(record.worktree_path),
      branch: record.branch,
      base_commit: nil,
      ownership: :pending,
      lifecycle: :creating,
      runtime_id: record.runtime_id,
      lstat_identity: nil,
      worktree_registration: nil,
      target: target_key(record.repo_path, record.branch, record.worktree_path),
      expires_at: record.expires_at,
      retry_count: record.retry_count,
      dormant: true,
      cleanup_failure: :creating_intent_unresolved
    }

    case creation_marker_absent?(blocker) do
      :ok ->
        case delete_retained_marker(state, record) do
          :ok ->
            {:ok, :settled, state}

          {:error, reason} ->
            {:ok, %{blocker | cleanup_failure: {:intent_delete_failed, reason}}, state}
        end

      {:error, reason} ->
        {:ok, %{blocker | cleanup_failure: reason}, state}
    end
  end

  defp creation_marker_absent?(blocker) do
    with {:error, :enoent} <- File.lstat(blocker.worktree_path),
         {:ok, :absent} <-
           worktree_path_registration_presence(blocker.repo_path, blocker.worktree_path) do
      :ok
    else
      {:ok, :present} -> {:error, :creation_path_or_registration_present}
      {:error, reason} -> {:error, {:creation_absence_uncertain, reason}}
      {:ok, _stat} -> {:error, :creation_path_present}
    end
  end

  # Hydration reconciliation for durable markers whose recorded parents are
  # already gone (e.g. a benchmark deleted pair_root under retained leases).
  # Both paths must independently be :enoent; one missing or unreadable path
  # is not absence. Same-runtime active markers may still settle when the
  # worktree is gone and Git registration is positively absent.
  defp settle_absent_orphaned_marker(record, state) do
    repo_path = canonical_path_or_expanded(record.repo_path)
    worktree_path = canonical_path_or_expanded(record.worktree_path)

    if both_paths_positively_absent?(repo_path, worktree_path) do
      case delete_retained_marker(state, %{workspace_id: record.workspace_id}) do
        :ok ->
          {:ok, :settled, state}

        {:error, reason} ->
          {:error, {:absent_marker_delete_failed, record.workspace_id, reason}}
      end
    else
      settle_absent_same_runtime_active_marker(record, state)
    end
  end

  defp settle_absent_same_runtime_active_marker(
         %{lifecycle: "active", runtime_id: runtime_id} = record,
         %{retention_runtime_id: runtime_id} = state
       ) do
    repo_path = canonical_path_or_expanded(record.repo_path)
    worktree_path = canonical_path_or_expanded(record.worktree_path)

    case File.lstat(worktree_path) do
      {:error, :enoent} ->
        case worktree_path_registration_presence(repo_path, worktree_path) do
          {:ok, :absent} ->
            case delete_retained_marker(state, %{workspace_id: record.workspace_id}) do
              :ok ->
                {:ok, :settled, state}

              {:error, reason} ->
                {:error, {:stale_active_marker_delete_failed, record.workspace_id, reason}}
            end

          _present_or_uncertain ->
            {:ok, :keep, state}
        end

      _present_or_uncertain ->
        {:ok, :keep, state}
    end
  end

  defp settle_absent_same_runtime_active_marker(_record, state),
    do: {:ok, :keep, state}

  # Install hot retained entries and schedule expiry timers only after the full
  # inventory has been validated. No orphan timers on partial failure.
  # Same-BEAM active markers and dormant evidence get no TTL timers.
  defp install_retained_list(state, retained_list) when is_list(retained_list) do
    Enum.reduce(retained_list, state, fn retained, acc ->
      cond do
        Map.get(retained, :lifecycle) == :creating ->
          put_creation_blocker(acc, retained)

        Map.get(retained, :lifecycle) == :discarding and Map.get(retained, :dormant) != true ->
          # Resume discard immediately after hydration; do not wait for TTL.
          generation = make_ref()
          retained = %{retained | expiry_generation: generation, expiry_ref: nil}
          state2 = put_retained(acc, retained)
          # Schedule a near-immediate retry so init stays non-blocking.
          expiry_ref =
            Process.send_after(self(), {:retained_expire, retained.target, generation}, 1)

          put_retained(state2, %{retained | expiry_ref: expiry_ref})

        Map.get(retained, :dormant) == true ->
          put_retained(acc, retained)

        Map.get(retained, :lifecycle) == :active_orphaned ->
          put_retained(acc, %{retained | expiry_ref: nil})

        true ->
          now_ms = System.monotonic_time(:millisecond)
          remaining = max(retained.expires_at_ms - now_ms, 1)
          generation = make_ref()

          expiry_ref =
            Process.send_after(self(), {:retained_expire, retained.target, generation}, remaining)

          put_retained(acc, %{
            retained
            | expiry_generation: generation,
              expiry_ref: expiry_ref
          })
      end
    end)
  end

  defp load_durable_retained_records(%{status: status} = journal)
       when status in [:ready, :poisoned] do
    store_name = journal.store_name
    backend = journal.backend

    try do
      with {:ok, keys} when is_list(keys) <- Persistence.list(store_name, backend),
           {:ok, values} <- fetch_durable_values(store_name, backend, keys),
           {:ok, records} <- RetentionJournal.decode_inventory(keys, values) do
        {:ok, records}
      else
        {:error, reason} -> {:error, reason}
        {:ok, _non_list} -> {:error, :invalid_key_list}
        other -> {:error, other}
      end
    catch
      kind, reason ->
        {:error, {:retention_journal_unavailable, kind, reason}}
    end
  end

  defp load_durable_retained_records(_), do: {:ok, []}

  defp fetch_durable_values(store_name, backend, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      if RetentionJournal.retained_key?(key) do
        try do
          case Persistence.get(store_name, backend, key) do
            {:ok, value} ->
              {:cont, {:ok, Map.put(acc, key, value)}}

            {:error, :not_found} ->
              {:halt, {:error, {:missing_retention_value, key}}}

            {:error, reason} ->
              {:halt, {:error, {:retention_journal_get_failed, key, reason}}}
          end
        catch
          kind, reason ->
            {:halt, {:error, {:retention_journal_unavailable, kind, reason}}}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  # Build a retained map without scheduling timers. Far-future expiry is clamped
  # to the operator/global ceiling and **persisted** before the record is admitted
  # so a later restart cannot regain the original unbounded expiry.
  # Active markers for the current runtime become orphaned-active (no TTL);
  # prior-incarnation active markers become retained (TTL eligible).
  defp materialize_retained_from_durable(record, state) do
    with {:ok, expires_at, _} <- DateTime.from_iso8601(record.expires_at),
         {:ok, lstat} <- hydrate_lstat_identity(record.lstat_identity),
         {:ok, hydrated_registration} <-
           hydrate_worktree_registration(record.worktree_registration),
         # Canonicalize before any identity/target work. Display is never operational.
         repo_path = canonical_path_or_expanded(record.repo_path),
         worktree_path = canonical_path_or_expanded(record.worktree_path),
         true <- worktree_path != repo_path,
         true <-
           hydrated_registration.path == worktree_path or
             registration_path_matches?(hydrated_registration, worktree_path),
         paths_changed? =
           record.repo_path != repo_path or record.worktree_path != worktree_path or
             hydrated_registration.path != worktree_path,
         registration = %{hydrated_registration | path: worktree_path},
         {:ok, hot_lifecycle, durable_lifecycle, convert?} <-
           hydrate_lifecycle(record, state.retention_runtime_id),
         {:ok, remaining_ms, bounded_expires_at, clamped?} <-
           bound_hydration_expiry(expires_at, state, convert?),
         {:ok, state2} <-
           maybe_persist_hydration_rewrite(
             state,
             record,
             bounded_expires_at,
             clamped? or convert? or paths_changed?,
             durable_lifecycle,
             lstat,
             registration,
             repo_path,
             worktree_path
           ) do
      now_ms = System.monotonic_time(:millisecond)
      expires_at_ms = now_ms + remaining_ms
      target = target_key(repo_path, record.branch, worktree_path)

      retry_count = Map.get(record, :retry_count, 0)

      limit =
        Map.get(state2, :retained_cleanup_retry_limit, @default_retained_cleanup_retry_limit)

      dormant? = retry_count >= limit and hot_lifecycle == :retained

      provenance =
        case Map.get(record, :branch_provenance, "unknown") do
          "created" -> :created
          "reused" -> :reused
          "unknown" -> :unknown
          other when other in [:created, :reused, :unknown] -> other
          _ -> :unknown
        end

      retained = %{
        workspace_id: record.workspace_id,
        # PIDs are never durable; restart reactivation requires task+principal.
        owner_pid: nil,
        task_id: record.task_id,
        principal_id: record.principal_id,
        repo_path: repo_path,
        worktree_path: worktree_path,
        display_worktree_path: record.display_worktree_path,
        branch: record.branch,
        base_commit: record.base_commit,
        ownership: :owned,
        branch_provenance: provenance,
        lifecycle: hot_lifecycle,
        runtime_id: state2.retention_runtime_id,
        durable_lifecycle: nil,
        target: target,
        lstat_identity: lstat,
        worktree_registration: registration,
        expiry_generation: make_ref(),
        expiry_ref: nil,
        expires_at: bounded_expires_at,
        expires_at_ms: expires_at_ms,
        retry_count: retry_count,
        cleanup_failure: if(dormant?, do: :cleanup_retries_exhausted, else: nil),
        dormant: dormant?
      }

      {:ok, retained, state2}
    else
      false -> {:error, :primary_checkout_not_retainable}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_durable_expires_at}
    end
  end

  defp registration_path_matches?(%{path: path}, worktree_path) when is_binary(path) do
    canonical_path_or_expanded(path) == worktree_path
  end

  defp registration_path_matches?(_, _), do: false

  # Decide hot lifecycle from durable marker + current BEAM runtime id.
  # Returns {hot_lifecycle, durable_lifecycle_to_persist, must_rewrite?}.
  defp hydrate_lifecycle(record, current_runtime_id) do
    case Map.get(record, :lifecycle) do
      "active" when record.runtime_id == current_runtime_id ->
        {:ok, :active_orphaned, "active", false}

      "active" ->
        # Prior BEAM incarnation: may become retained with TTL.
        {:ok, :retained, "retained", true}

      "retained" ->
        {:ok, :retained, "retained", false}

      other ->
        {:error, {:invalid_lifecycle, other}}
    end
  end

  defp maybe_persist_hydration_rewrite(
         state,
         record,
         bounded_expires_at,
         false,
         _durable_lifecycle,
         _lstat,
         _registration,
         _repo_path,
         _worktree_path
       ) do
    # No clamp, lifecycle conversion, or path normalization — leave durable bytes untouched.
    _ = record
    _ = bounded_expires_at
    {:ok, state}
  end

  defp maybe_persist_hydration_rewrite(
         state,
         record,
         bounded_expires_at,
         true,
         durable_lifecycle,
         lstat,
         registration,
         repo_path,
         worktree_path
       ) do
    retained_for_persist = %{
      workspace_id: record.workspace_id,
      task_id: record.task_id,
      principal_id: record.principal_id,
      repo_path: repo_path,
      worktree_path: worktree_path,
      display_worktree_path: record.display_worktree_path,
      branch: record.branch,
      base_commit: record.base_commit,
      ownership: :owned,
      branch_provenance: Map.get(record, :branch_provenance, :unknown),
      lifecycle: :retained,
      runtime_id: state.retention_runtime_id,
      durable_lifecycle: durable_lifecycle,
      lstat_identity: lstat,
      worktree_registration: registration,
      expires_at: bounded_expires_at,
      retry_count: Map.get(record, :retry_count, 0)
    }

    case persist_retained_marker(state, retained_for_persist) do
      :ok ->
        {:ok, state}

      {:error, reason} ->
        {:error, {:hydration_rewrite_persist_failed, reason}}
    end
  end

  # No durable input may schedule an unbounded timer. Clamp remaining lifetime
  # to the registry operator TTL and the global configured maximum. Returns
  # `{remaining_ms, bounded_expires_at, clamped?}`.
  defp bound_hydration_expiry(_expires_at, state, true) do
    now = DateTime.utc_now()
    ceiling = min(state.retention_ttl_ms, Config.workspace_retention_max_ttl_ms())
    bounded = DateTime.add(now, ceiling, :millisecond)
    {:ok, ceiling, bounded, true}
  end

  defp bound_hydration_expiry(%DateTime{} = expires_at, state, false) do
    now = DateTime.utc_now()
    raw_remaining = DateTime.diff(expires_at, now, :millisecond)
    configured_ttl = state.retention_ttl_ms
    global_max = Config.workspace_retention_max_ttl_ms()
    ceiling = min(configured_ttl, global_max)

    cond do
      # Far-future durable expiry is not authority to schedule an unbounded timer.
      raw_remaining > ceiling ->
        bounded = DateTime.add(now, ceiling, :millisecond)
        {:ok, ceiling, bounded, true}

      raw_remaining < 0 ->
        {:ok, 0, expires_at, false}

      true ->
        {:ok, raw_remaining, expires_at, false}
    end
  end

  defp bound_hydration_expiry(_, _, _), do: {:error, :invalid_durable_expires_at}

  defp hydrate_lstat_identity(%{type: type} = identity) when is_map(identity) do
    type_atom =
      case type do
        t when is_atom(t) ->
          t

        "directory" ->
          :directory

        "regular" ->
          :regular

        "symlink" ->
          :symlink

        "device" ->
          :device

        "other" ->
          :other

        _ ->
          nil
      end

    if is_atom(type_atom) and not is_nil(type_atom) and
         is_integer(Map.get(identity, :major_device)) and
         is_integer(Map.get(identity, :minor_device)) and
         is_integer(Map.get(identity, :inode)) do
      {:ok,
       %{
         type: type_atom,
         major_device: identity.major_device,
         minor_device: identity.minor_device,
         inode: identity.inode
       }}
    else
      {:error, :invalid_lstat_identity}
    end
  end

  defp hydrate_lstat_identity(_), do: {:error, :invalid_lstat_identity}

  defp hydrate_worktree_registration(%{path: path, head: head, branch: branch})
       when is_binary(path) and is_binary(head) and is_binary(branch) do
    {:ok, %{path: path, head: head, branch: branch}}
  end

  defp hydrate_worktree_registration(_), do: {:error, :invalid_worktree_registration}

  defp persist_retained_marker(%{retention_journal: %{status: :disabled}}, _retained), do: :ok

  defp persist_retained_marker(%{retention_journal: %{status: :poisoned}}, _retained) do
    {:error, :retention_journal_poisoned}
  end

  defp persist_retained_marker(%{retention_journal: journal} = state, retained)
       when journal.status == :ready do
    try do
      lifecycle =
        Map.get(retained, :durable_lifecycle) ||
          case Map.get(retained, :lifecycle, :retained) do
            :active_orphaned -> "active"
            :retained -> "retained"
            :discarding -> "discarding"
            :creating -> "creating"
            "active" -> "active"
            "retained" -> "retained"
            "discarding" -> "discarding"
            "creating" -> "creating"
            _ -> "retained"
          end

      runtime_id =
        Map.get(retained, :runtime_id) || Map.get(state, :retention_runtime_id) ||
          beam_retention_runtime_id()

      encode_input = %{
        workspace_id: retained.workspace_id,
        task_id: retained.task_id,
        principal_id: retained.principal_id,
        repo_path: retained.repo_path,
        worktree_path: retained.worktree_path,
        display_worktree_path: Map.get(retained, :display_worktree_path, retained.worktree_path),
        branch: retained.branch,
        base_commit: retained.base_commit,
        ownership: Map.get(retained, :ownership, :owned),
        lifecycle: lifecycle,
        runtime_id: runtime_id,
        lstat_identity: retained.lstat_identity,
        worktree_registration: retained.worktree_registration,
        expires_at: retained.expires_at,
        retry_count: Map.get(retained, :retry_count, 0),
        branch_provenance: Map.get(retained, :branch_provenance, :unknown)
      }

      encode_input = maybe_put_settlement_tip(encode_input, retained)
      encode_input = maybe_put_discard_phase(encode_input, retained)

      with {:ok, key} <- RetentionJournal.record_key(retained.workspace_id),
           {:ok, payload} <- RetentionJournal.encode_record(encode_input),
           :ok <- Persistence.put(journal.store_name, journal.backend, key, payload) do
        :ok
      else
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    catch
      kind, reason ->
        {:error, {:retention_journal_unavailable, kind, reason}}
    end
  end

  defp persist_retained_marker(_state, _retained), do: {:error, :retention_journal_unavailable}

  defp maybe_put_settlement_tip(encode_input, retained) do
    case Map.get(retained, :settlement_tip) do
      tip when is_binary(tip) and tip != "" -> Map.put(encode_input, :settlement_tip, tip)
      _ -> encode_input
    end
  end

  defp maybe_put_discard_phase(encode_input, retained) do
    case Map.get(retained, :discard_phase) do
      phase when phase in [:archive, :worktree, :branch, "archive", "worktree", "branch"] ->
        Map.put(encode_input, :discard_phase, phase)

      _ ->
        encode_input
    end
  end

  defp delete_retained_marker(%{retention_journal: %{status: :disabled}}, _retained), do: :ok

  defp delete_retained_marker(%{retention_journal: journal}, retained)
       when journal.status in [:ready, :poisoned] do
    try do
      with {:ok, key} <- RetentionJournal.record_key(retained.workspace_id),
           :ok <- Persistence.delete(journal.store_name, journal.backend, key) do
        :ok
      else
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    catch
      kind, reason ->
        {:error, {:retention_journal_unavailable, kind, reason}}
    end
  end

  defp delete_retained_marker(_state, _retained), do: {:error, :retention_journal_unavailable}

  # Canonicalize path components so /var vs /private/var aliases cannot form
  # distinct ownership targets for the same worktree.
  defp target_key(repo_path, branch, worktree_path) do
    {:workspace_target, canonical_path_or_expanded(repo_path), branch,
     canonical_path_or_expanded(worktree_path)}
  end

  defp lstat_identity(%File.Stat{} = stat) do
    Map.take(Map.from_struct(stat), [:type, :major_device, :minor_device, :inode])
  end

  defp worktree_registration(repo_path, worktree_path) do
    case worktree_registration_status(repo_path, worktree_path) do
      {:ok, %{branch: branch} = registration} when is_binary(branch) -> {:ok, registration}
      {:ok, %{detached: true}} -> {:error, :worktree_detached}
      {:ok, nil} -> {:error, :worktree_not_registered}
      {:error, reason} -> {:error, reason}
    end
  end

  defp worktree_registration_status(repo_path, worktree_path),
    do: Git.worktree_registration(repo_path, worktree_path)

  defp worktree_path_registration_presence(repo_path, worktree_path) do
    case worktree_registration_status(repo_path, worktree_path) do
      {:ok, nil} -> {:ok, :absent}
      {:ok, registration} when is_map(registration) -> {:ok, :present}
      {:error, reason} -> {:error, reason}
    end
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

  defp normalize_branch_provenance(:created), do: {:ok, :created}
  defp normalize_branch_provenance(:reused), do: {:ok, :reused}
  defp normalize_branch_provenance(:unknown), do: {:ok, :unknown}
  defp normalize_branch_provenance("created"), do: {:ok, :created}
  defp normalize_branch_provenance("reused"), do: {:ok, :reused}
  defp normalize_branch_provenance("unknown"), do: {:ok, :unknown}
  defp normalize_branch_provenance(nil), do: {:ok, :unknown}
  defp normalize_branch_provenance(_), do: {:error, :invalid_branch_provenance}

  defp branch_provenance_string(:created), do: "created"
  defp branch_provenance_string(:reused), do: "reused"
  defp branch_provenance_string(:unknown), do: "unknown"
  defp branch_provenance_string(other) when is_binary(other), do: other
  defp branch_provenance_string(_), do: "unknown"

  defp normalize_mode(:retain), do: {:ok, :retain}
  defp normalize_mode(:remove), do: {:ok, :remove}
  defp normalize_mode(:discard), do: {:ok, :discard}
  defp normalize_mode(:publish), do: {:ok, :publish}
  defp normalize_mode(:publish_retain), do: {:ok, :publish_retain}
  defp normalize_mode("retain"), do: {:ok, :retain}
  defp normalize_mode("remove"), do: {:ok, :remove}
  defp normalize_mode("discard"), do: {:ok, :discard}
  defp normalize_mode("publish"), do: {:ok, :publish}
  defp normalize_mode("publish_retain"), do: {:ok, :publish_retain}

  defp normalize_mode(other),
    do:
      {:error,
       "release mode must be \"retain\", \"remove\", \"discard\", \"publish\", or \"publish_retain\", got: #{inspect(other)}"}

  defp publish_release_mode(:publish, %{candidate_commit: candidate_commit}),
    do: {:publish, candidate_commit, :remove}

  defp publish_release_mode(:publish_retain, %{candidate_commit: candidate_commit}),
    do: {:publish, candidate_commit, :retain}

  defp publish_release_mode(mode, _caller), do: mode

  defp normalize_candidate_commit(commit) when is_binary(commit) do
    commit = commit |> String.trim() |> String.downcase()

    if Regex.match?(~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, commit), do: commit, else: nil
  end

  defp normalize_candidate_commit(_commit), do: nil

  defp normalize_id(id) when is_binary(id) do
    if String.trim(id) == "", do: nil, else: id
  end

  defp normalize_id(_), do: nil

  defp normalize_cleanup_failures(count, _force_once)
       when is_integer(count) and count >= 0 and count <= 10,
       do: count

  defp normalize_cleanup_failures(_count, true), do: 1
  defp normalize_cleanup_failures(_count, _force_once), do: 0

  defp require_binary(value, _field) when is_binary(value) and value != "", do: :ok
  defp require_binary(_value, field), do: {:error, {:invalid, field}}

  # Destructive: identity-bound remove for retained TTL / explicit cleanup.
  # Revalidates expected filesystem + Git identity. Uses `git worktree remove`
  # only — never File.rm_rf. On failure, retain the path as evidence.
  @doc false
  @spec remove_owned_retained_worktree(map()) :: :ok | {:error, term()}
  def remove_owned_retained_worktree(retained) when is_map(retained) do
    repo_root = retained.repo_path
    worktree_path = retained.worktree_path

    with :ok <- require_binary(repo_root, :repo_path),
         :ok <- require_binary(worktree_path, :worktree_path),
         true <- worktree_path != repo_root,
         :ok <- revalidate_destruction_identity(retained) do
      if match?({:ok, %File.Stat{}}, File.lstat(worktree_path)) do
        removal_identity = %{
          lstat_identity: normalize_lstat_for_compare(retained.lstat_identity),
          worktree_registration: retained.worktree_registration
        }

        case Git.remove_worktree(repo_root, worktree_path, removal_identity) do
          :ok ->
            :ok

          {:error, reason} ->
            # No raw File.rm_rf fallback — retain evidence for operator recovery.
            {:error, {:worktree_remove_failed, reason}}
        end
      else
        # Path already absent — treat as success for settle/verify to confirm.
        :ok
      end
    else
      false ->
        {:error, :primary_checkout_not_retainable}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, {:cleanup_raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:cleanup_thrown, kind, reason}}
  end

  def remove_owned_retained_worktree(_), do: {:error, :invalid_retained_cleanup}

  defp revalidate_destruction_identity(retained) when is_map(retained) do
    expected_lstat = Map.get(retained, :lstat_identity)
    expected_reg = Map.get(retained, :worktree_registration)
    path = Map.get(retained, :worktree_path)
    repo = Map.get(retained, :repo_path)

    cond do
      not is_map(expected_lstat) or not is_map(expected_reg) ->
        {:error, :missing_expected_identity}

      not is_binary(path) or not is_binary(repo) ->
        {:error, :invalid_cleanup_paths}

      path == repo ->
        {:error, :primary_checkout_not_retainable}

      true ->
        with {:ok, current_path} <- canonical_existing_path(path),
             true <- current_path == path,
             {:ok, current_repo} <- canonical_existing_path(repo),
             true <- current_path != current_repo,
             {:ok, current_lstat} <- File.lstat(path),
             true <- lstat_identity(current_lstat) == normalize_lstat_for_compare(expected_lstat),
             {:ok, registration} <- worktree_registration(repo, path),
             true <- registration_matches?(registration, expected_reg) do
          :ok
        else
          _ -> {:error, :retained_identity_mismatch}
        end
    end
  end

  defp revalidate_destruction_identity(_), do: {:error, :invalid_retained_cleanup}

  defp normalize_lstat_for_compare(%{type: type} = identity) when is_atom(type), do: identity

  defp normalize_lstat_for_compare(%{type: type} = identity) when is_binary(type) do
    type_atom =
      case type do
        "directory" -> :directory
        "regular" -> :regular
        "symlink" -> :symlink
        "device" -> :device
        "other" -> :other
        _ -> type
      end

    %{identity | type: type_atom}
  end

  defp normalize_lstat_for_compare(other), do: other

  # Ownership identity is registered path + branch only. Git HEAD is mutable
  # workspace content (a resumed worker may commit) and must not gate
  # reactivation, cleanup, or destruction.
  defp registration_matches?(current, expected) when is_map(current) and is_map(expected) do
    Map.get(current, :path) == Map.get(expected, :path) and
      Map.get(current, :branch) == Map.get(expected, :branch)
  end

  defp registration_matches?(_, _), do: false
end
