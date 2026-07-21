defmodule Arbor.Actions.Coding.DiscardFaultStore do
  @moduledoc false
  # Minimal deterministic Persistence.Store double for the discard suite.
  #
  # Modes:
  #   :ok                  — every put succeeds and persists.
  #   :fail_put            — every put fails (nothing persists).
  #   {:fail_put_after, n} — a RELATIVE countdown: setting the mode resets the
  #                          put counter to 0, the next n puts SUCCEED and
  #                          PERSIST, and every put after that fails.
  #   :fail_delete         — puts succeed normally; every delete fails so the
  #                          discard state machine observes a marker-delete
  #                          failure at the exact settlement boundary without
  #                          affecting durable evidence of the marker itself.
  #
  # The relative-countdown contract lets a test seed durable state under :ok,
  # then flip to {:fail_put_after, n} so the real state machine drives the next
  # n writes to disk and the (n+1)th fails naturally — no :sys.replace_state
  # hot/durable mismatch required.
  use GenServer

  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)
    %{id: name, start: {__MODULE__, :start_link, [opts]}, type: :worker, restart: :temporary}
  end

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def put(key, value, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})
  def get(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
  def delete(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})
  def list(opts), do: GenServer.call(Keyword.fetch!(opts, :name), :list)
  def exists?(key, opts), do: match?({:ok, _}, get(key, opts))
  def durability_class(_opts), do: :node_restart

  def set_mode(name, mode), do: GenServer.call(name, {:set_mode, mode})
  def entries(name), do: GenServer.call(name, :entries)

  @impl true
  def init(_opts), do: {:ok, %{entries: %{}, mode: :ok, put_count: 0}}

  # Setting any mode resets the relative-countdown counter so {:fail_put_after, n}
  # is anchored to the set_mode call, not to init. :ok/:fail_put ignore the
  # counter but still reset it for determinism.
  @impl true
  def handle_call({:set_mode, mode}, _from, state),
    do: {:reply, :ok, %{state | mode: mode, put_count: 0}}

  def handle_call(:entries, _from, state), do: {:reply, state.entries, state}

  def handle_call({:put, _key, _value}, _from, %{mode: :fail_put} = state) do
    {:reply, {:error, :injected_put_failure}, state}
  end

  def handle_call({:put, key, value}, _from, %{mode: {:fail_put_after, n}} = state)
      when is_integer(n) do
    count = state.put_count + 1

    if count > n do
      {:reply, {:error, :injected_put_failure}, %{state | put_count: count}}
    else
      # Successful fail-after-N puts MUST persist, so the test's durable
      # assertions reflect the real last-successful write.
      {:reply, :ok, %{state | put_count: count, entries: Map.put(state.entries, key, value)}}
    end
  end

  def handle_call({:put, key, value}, _from, state) do
    {:reply, :ok, %{state | entries: Map.put(state.entries, key, value)}}
  end

  def handle_call({:get, key}, _from, state) do
    case Map.fetch(state.entries, key) do
      {:ok, value} -> {:reply, {:ok, value}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete, _key}, _from, %{mode: :fail_delete} = state) do
    {:reply, {:error, :injected_delete_failure}, state}
  end

  def handle_call({:delete, key}, _from, state) do
    {:reply, :ok, %{state | entries: Map.delete(state.entries, key)}}
  end

  def handle_call(:list, _from, state) do
    {:reply, {:ok, Map.keys(state.entries) |> Enum.sort()}, state}
  end
end

defmodule Arbor.Actions.Coding.WorkspaceBranchDiscardTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.DiscardFaultStore
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Coding.WorkspaceRetentionJournalCore, as: Core
  alias Arbor.Actions.Git
  alias Arbor.Persistence

  @moduletag :fast
  @moduletag :security_regression

  # Mirrors WorkspaceLeaseRegistry's default retry budget so dormant residue
  # assertions stay accurate if either default changes.
  @default_retained_cleanup_retry_limit 8

  # Lock in the DiscardFaultStore contract independently of the registry flow:
  # the discard regression below depends on successful fail-after-N puts
  # actually persisting and on the countdown being relative to set_mode.
  describe "DiscardFaultStore fault modes" do
    test ":ok mode persists every put" do
      {name, backend} = start_controllable_store()

      assert :ok = Persistence.put(name, backend, "k1", %{"v" => 1})
      assert :ok = Persistence.put(name, backend, "k2", %{"v" => 2})

      assert {:ok, %{"v" => 1}} = Persistence.get(name, backend, "k1")
      assert {:ok, %{"v" => 2}} = Persistence.get(name, backend, "k2")
    end

    test ":fail_put mode rejects every put and persists nothing" do
      {name, backend} = start_controllable_store()
      :ok = DiscardFaultStore.set_mode(name, :fail_put)

      assert {:error, :injected_put_failure} = Persistence.put(name, backend, "k1", %{"v" => 1})
      assert {:error, :not_found} = Persistence.get(name, backend, "k1")
    end

    test "{:fail_put_after, n} persists the first n puts then fails, relative to set_mode" do
      {name, backend} = start_controllable_store()

      # One put lands before the countdown is armed — it must persist and must
      # NOT count toward the limit (relative, not absolute from init).
      assert :ok = Persistence.put(name, backend, "seed", %{"v" => "seed"})

      :ok = DiscardFaultStore.set_mode(name, {:fail_put_after, 1})

      # First put AFTER set_mode succeeds and PERSISTS (this is the contract
      # the reservation-exhaustion regression relies on).
      assert :ok = Persistence.put(name, backend, "reserved", %{"retry" => 1})
      assert {:ok, %{"retry" => 1}} = Persistence.get(name, backend, "reserved")

      # Second put after set_mode fails; prior durable evidence is untouched.
      assert {:error, :injected_put_failure} =
               Persistence.put(name, backend, "dormant", %{"retry" => 2})

      assert {:error, :not_found} = Persistence.get(name, backend, "dormant")
      assert {:ok, %{"retry" => 1}} = Persistence.get(name, backend, "reserved")
      assert {:ok, %{"v" => "seed"}} = Persistence.get(name, backend, "seed")

      # Re-arming the countdown resets it: one more success, then failure.
      :ok = DiscardFaultStore.set_mode(name, {:fail_put_after, 1})
      assert :ok = Persistence.put(name, backend, "retry-2", %{"retry" => 2})

      assert {:error, :injected_put_failure} =
               Persistence.put(name, backend, "retry-3", %{"retry" => 3})
    end
  end

  describe "branch provenance at acquire" do
    test "records created provenance for a new branch", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/discard-created-provenance"
      worktree_base = Path.join(tmp_dir, "worktrees")

      assert {:ok, lease} =
               Workspace.Acquire.run(
                 %{
                   repo_path: repo,
                   branch_name: branch,
                   worktree_base_dir: worktree_base
                 },
                 %{}
               )

      assert lease.ownership == "owned"
      assert lease.branch_provenance == "created"
      assert branch_exists?(repo, branch)

      assert {:ok, _} =
               Workspace.Release.run(%{workspace_id: lease.workspace_id, mode: "remove"}, %{})
    end

    test "records reused provenance for a pre-existing branch with a new owned worktree", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/discard-reused-branch-owned-path"
      worktree_base = Path.join(tmp_dir, "worktrees")
      git!(repo, ["branch", branch])

      assert {:ok, lease} =
               Workspace.Acquire.run(
                 %{
                   repo_path: repo,
                   branch_name: branch,
                   worktree_base_dir: worktree_base
                 },
                 %{}
               )

      assert lease.ownership == "owned"
      assert lease.branch_provenance == "reused"

      assert {:ok, _} =
               Workspace.Release.run(%{workspace_id: lease.workspace_id, mode: "remove"}, %{})

      assert branch_exists?(repo, branch)
    end
  end

  describe "discard release mode" do
    test "security regression: malformed lifecycle receipt fails closed without raw reasons" do
      result = %{
        status: "discard_pending",
        pending_reason: {:backend, "/private/secret"},
        cleanup_failure: {:internal, "/private/secret"}
      }

      assert Workspace.Release.format_release_result(result) ==
               {:error, {:invalid_release_receipt, "discard_pending"}}
    end

    test "already released remains lifecycle-less after internal reason scrubbing" do
      assert {:ok, result} =
               Workspace.Release.format_release_result(%{
                 status: "already_released",
                 pending_reason: {:backend, "/private/secret"}
               })

      assert result == %{status: "already_released"}
    end

    test "created no-change branch is removed with the owned worktree", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/discard-created-no-change"
      worktree_base = Path.join(tmp_dir, "worktrees")

      assert {:ok, lease} =
               Workspace.Acquire.run(
                 %{
                   repo_path: repo,
                   branch_name: branch,
                   worktree_base_dir: worktree_base
                 },
                 %{}
               )

      assert lease.branch_provenance == "created"
      worktree_path = lease.worktree_path
      assert File.dir?(worktree_path)
      assert branch_exists?(repo, branch)
      assert git!(lease.worktree_path, ["rev-parse", "HEAD"]) == lease.base_commit

      assert {:ok, discarded} =
               Workspace.Release.run(
                 %{workspace_id: lease.workspace_id, mode: "discard"},
                 %{}
               )

      assert discarded.status == "discarded"
      assert discarded.branch_retired == true
      refute File.dir?(worktree_path)
      refute branch_exists?(repo, branch)
    end

    test "reused branch is preserved on discard", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/discard-reused-preserve"
      worktree_base = Path.join(tmp_dir, "worktrees")
      git!(repo, ["branch", branch])

      assert {:ok, lease} =
               Workspace.Acquire.run(
                 %{
                   repo_path: repo,
                   branch_name: branch,
                   worktree_base_dir: worktree_base
                 },
                 %{}
               )

      assert lease.ownership == "owned"
      assert lease.branch_provenance == "reused"
      worktree_path = lease.worktree_path

      assert {:ok, discarded} =
               Workspace.Release.run(
                 %{workspace_id: lease.workspace_id, mode: "discard"},
                 %{}
               )

      assert discarded.status == "discarded"
      assert discarded.branch_retired == false

      assert discarded.branch_preserved_reason in [
               "branch_provenance_not_created",
               "reused_worktree"
             ]

      # Non-owned preserved branch is NOT residue — no cleanup_residue flag.
      refute Map.get(discarded, :cleanup_residue, false)
      refute File.dir?(worktree_path)
      assert branch_exists?(repo, branch)
    end

    @tag :security_regression
    test "security regression: settlement receipt truthfulness — terminal complete means no marker residue",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/discard-terminal-truth"
      worktree_base = Path.join(tmp_dir, "worktrees")
      {store_name, backend} = start_journal_store()
      server = start_registry(retention_journal: {store_name, backend})

      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: branch,
                   worktree_base_dir: worktree_base
                 },
                 server: server
               )

      assert lease.branch_provenance == "created"
      workspace_id = lease.workspace_id
      worktree_path = lease.worktree_path

      assert {:ok, key} = Core.record_key(workspace_id)

      assert {:ok, discarded} =
               WorkspaceLeaseRegistry.release(workspace_id, :discard, %{server: server})

      assert discarded.status == "discarded"
      assert discarded.branch_retired == true
      refute File.dir?(worktree_path)
      refute branch_exists?(repo, branch)

      # Terminal settlement means exactly absent — no lifecycle marker remains.
      assert {:error, :not_found} = Persistence.get(store_name, backend, key)
      # No cleanup residue in the receipt.
      refute Map.get(discarded, :cleanup_residue, false)
    end

    @tag :security_regression
    test "security regression: reused+unknown provenance terminal settlement has no cleanup_residue",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/discard-preserved-terminal"
      worktree_base = Path.join(tmp_dir, "worktrees")
      {store_name, backend} = start_journal_store()
      server = start_registry(retention_journal: {store_name, backend})
      git!(repo, ["branch", branch])

      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: branch,
                   worktree_base_dir: worktree_base
                 },
                 server: server
               )

      workspace_id = lease.workspace_id
      assert {:ok, key} = Core.record_key(workspace_id)

      assert {:ok, discarded} =
               WorkspaceLeaseRegistry.release(workspace_id, :discard, %{server: server})

      assert discarded.status == "discarded"
      assert discarded.branch_retired == false
      assert is_binary(discarded.branch_preserved_reason)
      # Non-owned preserved branch: no residue, no cleanup_residue flag.
      refute Map.get(discarded, :cleanup_residue, false)
      # Marker is deleted — terminal settlement.
      assert {:error, :not_found} = Persistence.get(store_name, backend, key)
      assert branch_exists?(repo, branch)
    end

    @tag :security_regression
    test "security regression: created divergent tip keeps a dormant branch-phase marker and never claims settlement",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/discard-changed-tip"
      worktree_base = Path.join(tmp_dir, "worktrees")
      {store_name, backend} = start_journal_store()
      server = start_registry(retention_journal: {store_name, backend})

      task_id = "task-divergent-tip-#{System.unique_integer([:positive])}"
      principal_id = "agent-divergent-tip-#{System.unique_integer([:positive])}"

      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: branch,
                   worktree_base_dir: worktree_base,
                   task_id: task_id,
                   principal_id: principal_id
                 },
                 server: server
               )

      assert lease.branch_provenance == "created"

      File.write!(Path.join(lease.worktree_path, "change.txt"), "committed\n")
      git!(lease.worktree_path, ["add", "change.txt"])
      git!(lease.worktree_path, ["commit", "-m", "tip diverged"])
      tip = git!(lease.worktree_path, ["rev-parse", "HEAD"])
      refute tip == lease.base_commit

      workspace_id = lease.workspace_id
      worktree_path = lease.worktree_path

      assert {:ok, discarded} =
               WorkspaceLeaseRegistry.release(workspace_id, :discard, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      # Divergent tip is non-retryable: settlement must NOT be claimed.
      assert discarded.status == "discard_pending"
      assert discarded.branch_retired == false
      assert discarded.branch_preserved_reason == "branch_tip_diverged"
      assert discarded.cleanup_residue == true
      refute File.dir?(worktree_path)

      # The branch itself remains as local evidence at the divergent tip.
      assert branch_exists?(repo, branch)
      assert git!(repo, ["rev-parse", branch]) == tip

      # The durable marker is preserved as a dormant branch-phase discarding
      # marker — restart cannot regain destructive attempts and re-settle.
      assert {:ok, key} = Core.record_key(workspace_id)
      assert {:ok, durable} = Persistence.get(store_name, backend, key)
      assert (Map.get(durable, :lifecycle) || Map.get(durable, "lifecycle")) == "discarding"
      assert (Map.get(durable, :discard_phase) || Map.get(durable, "discard_phase")) == "branch"

      assert (Map.get(durable, :retry_count) || Map.get(durable, "retry_count")) >=
               @default_retained_cleanup_retry_limit

      # Re-releasing (retain/remove/discard) continues — never downgrades — and
      # still reports the in-flight discard rather than settling.
      assert {:ok, again} =
               WorkspaceLeaseRegistry.release(workspace_id, :remove, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert again.status == "discard_pending"
      assert again.cleanup_residue == true
      assert branch_exists?(repo, branch)
    end

    @tag :security_regression
    test "security regression: retry_count is reserved BEFORE injected worktree cleanup runs",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/discard-pre-reservation"
      worktree_base = Path.join(tmp_dir, "worktrees")
      task_id = "task-pre-res-#{System.unique_integer([:positive])}"
      principal_id = "agent-pre-res-#{System.unique_integer([:positive])}"
      {store_name, backend} = start_journal_store()
      parent = self()

      # The cleanup callback reads the durable marker at the instant it runs.
      # retry_count must already be reserved (incremented and persisted) so a
      # crash between reservation and cleanup cannot regain free attempts.
      cleanup = fn retained_entry ->
        with {:ok, marker_key} <- Core.record_key(retained_entry.workspace_id),
             {:ok, marker} <- Persistence.get(store_name, backend, marker_key) do
          count = Map.get(marker, :retry_count) || Map.get(marker, "retry_count")
          send(parent, {:reserved_at_cleanup, count})
        else
          other -> send(parent, {:reserved_at_cleanup_miss, other})
        end

        WorkspaceLeaseRegistry.remove_owned_retained_worktree(retained_entry)
      end

      server =
        start_registry(
          retention_journal: {store_name, backend},
          retained_cleanup: cleanup
        )

      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: branch,
                   worktree_base_dir: worktree_base,
                   task_id: task_id,
                   principal_id: principal_id
                 },
                 server: server
               )

      assert lease.branch_provenance == "created"

      assert {:ok, _retained} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :retain, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert {:ok, _discarded} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :discard, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      # Pre-reservation invariant: the cleanup boundary observed a reserved
      # retry_count (>= 1), not the pre-discard zero.
      assert_receive {:reserved_at_cleanup, count}, 1_000
      assert is_integer(count) and count >= 1
    end

    @tag :security_regression
    test "security regression: exhausted branch-phase marker stays dormant after restart",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/discard-exhausted-dormant"
      worktree_base = Path.join(tmp_dir, "worktrees")
      base_commit = git!(repo, ["rev-parse", "HEAD"])
      git!(repo, ["branch", branch])
      {store_name, backend} = start_journal_store()

      # A durable branch-phase discarding marker whose retry budget is already
      # exhausted. Worktree phase is complete (no worktree path on disk).
      workspace_id = "ws_exhausted_#{System.unique_integer([:positive])}"

      marker = %{
        workspace_id: workspace_id,
        task_id: nil,
        principal_id: nil,
        repo_path: repo,
        worktree_path: Path.join(worktree_base, Workspace.worktree_dir_name(branch)),
        display_worktree_path: Path.join(worktree_base, Workspace.worktree_dir_name(branch)),
        branch: branch,
        base_commit: base_commit,
        ownership: :owned,
        branch_provenance: :created,
        lifecycle: :discarding,
        discard_phase: :branch,
        durable_lifecycle: "discarding",
        runtime_id: "rt_exhausted",
        lstat_identity: nil,
        worktree_registration: nil,
        expires_at: DateTime.utc_now(),
        retry_count: 2
      }

      assert {:ok, payload} = Core.encode_record(marker)
      assert {:ok, key} = Core.record_key(workspace_id)
      assert :ok = Persistence.put(store_name, backend, key, payload)

      server =
        start_registry(
          retention_journal: {store_name, backend},
          retained_cleanup_retry_limit: 2
        )

      # Give hydration + any scheduled retry a chance to run; the exhausted
      # marker must NOT regain attempts and delete the branch.
      Process.sleep(200)

      assert branch_exists?(repo, branch)
      assert git!(repo, ["rev-parse", branch]) == base_commit

      state = :sys.get_state(server)
      hydrated = Map.fetch!(state.retained_by_id, workspace_id)
      assert Map.get(hydrated, :dormant) == true
      assert Map.get(hydrated, :retry_count) >= 2
      # No expiry retry scheduled for a dormant marker.
      assert Map.get(hydrated, :expiry_ref) == nil
    end

    @tag :security_regression
    test "security regression: exhausted worktree-phase marker preserves worktree phase and identity on restart",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/discard-worktree-exhausted"
      worktree_base = Path.join(tmp_dir, "worktrees")
      base_commit = git!(repo, ["rev-parse", "HEAD"])
      {store_name, backend} = start_journal_store()

      # A durable worktree-phase discarding marker whose retry budget is
      # exhausted. The worktree still exists on disk (cleanup failed).
      workspace_id = "ws_wt_exhausted_#{System.unique_integer([:positive])}"
      worktree_path = Path.join(worktree_base, Workspace.worktree_dir_name(branch))

      # Create a fake worktree path to simulate the surviving worktree.
      File.mkdir_p!(worktree_path)

      marker = %{
        workspace_id: workspace_id,
        task_id: nil,
        principal_id: nil,
        repo_path: repo,
        worktree_path: worktree_path,
        display_worktree_path: worktree_path,
        branch: branch,
        base_commit: base_commit,
        ownership: :owned,
        branch_provenance: :created,
        lifecycle: :discarding,
        discard_phase: :worktree,
        durable_lifecycle: "discarding",
        runtime_id: "rt_wt_exhausted",
        lstat_identity: %{
          type: "directory",
          major_device: 0,
          minor_device: 0,
          inode: 1
        },
        worktree_registration: %{
          path: worktree_path,
          head: base_commit,
          branch: branch
        },
        expires_at: DateTime.utc_now(),
        retry_count: 2
      }

      assert {:ok, payload} = Core.encode_record(marker)
      assert {:ok, key} = Core.record_key(workspace_id)
      assert :ok = Persistence.put(store_name, backend, key, payload)

      server =
        start_registry(
          retention_journal: {store_name, backend},
          retained_cleanup_retry_limit: 2
        )

      # Give hydration a chance to run; the exhausted worktree-phase marker
      # must stay dormant in worktree phase with its identity evidence intact.
      Process.sleep(200)

      state = :sys.get_state(server)
      hydrated = Map.fetch!(state.retained_by_id, workspace_id)
      assert Map.get(hydrated, :dormant) == true
      assert Map.get(hydrated, :retry_count) >= 2
      assert Map.get(hydrated, :discard_phase) == :worktree
      assert Map.get(hydrated, :expiry_ref) == nil

      # Identity evidence must be preserved — not forced to branch phase.
      assert Map.get(hydrated, :lstat_identity) != nil
      assert Map.get(hydrated, :worktree_registration) != nil

      # The durable marker must also preserve the worktree phase.
      assert {:ok, durable} = Persistence.get(store_name, backend, key)
      assert (Map.get(durable, :lifecycle) || Map.get(durable, "lifecycle")) == "discarding"
      assert (Map.get(durable, :discard_phase) || Map.get(durable, "discard_phase")) == "worktree"
    end

    @tag :security_regression
    test "security regression: reservation persistence failure degrades journal without installing fake hot state",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/discard-reservation-poison"
      worktree_base = Path.join(tmp_dir, "worktrees")
      task_id = "task-reservation-poison-#{System.unique_integer([:positive])}"
      principal_id = "agent-reservation-poison-#{System.unique_integer([:positive])}"
      {store_name, backend} = start_controllable_store()

      parent = self()

      cleanup = fn retained_entry ->
        # Observe the durable retry_count at cleanup time — the reservation
        # must have persisted before destructive work ran.
        with {:ok, marker_key} <- Core.record_key(retained_entry.workspace_id),
             {:ok, marker} <- Persistence.get(store_name, backend, marker_key) do
          count = Map.get(marker, :retry_count) || Map.get(marker, "retry_count")
          send(parent, {:cleanup_reserved_count, count})
        else
          _ -> send(parent, {:cleanup_reserved_count, :miss})
        end

        # Deterministic fault injection: poison puts AFTER the worktree-phase
        # reservation has persisted and the destructive worktree removal has
        # run. The post-cleanup phase-advance persist and the retry persist
        # both fail; admission must degrade without installing a fake timer.
        :ok = DiscardFaultStore.set_mode(store_name, :fail_put)

        WorkspaceLeaseRegistry.remove_owned_retained_worktree(retained_entry)
      end

      server =
        start_registry(
          retention_journal: {store_name, backend},
          retained_cleanup: cleanup
        )

      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: branch,
                   worktree_base_dir: worktree_base,
                   task_id: task_id,
                   principal_id: principal_id
                 },
                 server: server
               )

      assert {:ok, _retained} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :retain, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      # The discard runs synchronously; the injected fault surfaces as
      # discard_pending residue, never as settled success.
      assert {:ok, discarded} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :discard, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert discarded.status == "discard_pending"

      # The reservation persisted before the destructive work ran.
      assert_receive {:cleanup_reserved_count, count}, 1_000
      assert is_integer(count) and count >= 1

      state = :sys.get_state(server)

      # Admission is degraded — the journal is not trusted as authoritative.
      assert state.retention_journal.status == :poisoned

      retained = Map.get(state.retained_by_id, lease.workspace_id)

      # Bounded evidence is retained in hot state — never silently dropped.
      assert retained != nil

      # Prior durable evidence is retained EXACTLY: the attempted pending
      # state was NOT installed (no uncommitted transition, no failure
      # annotation, no fake timer, no false dormancy). The journal
      # degradation is the sole signal that the transition did not commit.
      assert Map.get(retained, :expiry_ref) == nil
      assert Map.get(retained, :dormant) == false
      assert Map.get(retained, :cleanup_failure) == nil
    end

    @tag :security_regression
    test "security regression: reservation exhaustion persist failure retains prior evidence without false dormancy",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/discard-exhaust-poison"
      worktree_base = Path.join(tmp_dir, "worktrees")
      base_commit = git!(repo, ["rev-parse", "HEAD"])
      git!(repo, ["branch", branch])

      # Check out the branch in the MAIN repo so delete_branch_ref returns
      # :branch_checked_out (retryable). With retry_limit=1 this drives the
      # branch-phase discard to exhaustion through the real state machine:
      # hydrate resumes the branch-phase marker, the reservation persist
      # (retry_count 0->1) succeeds, the destructive delete is rejected, and
      # resolve_retry sends the already-reserved marker dormant — whose persist
      # then fails under the injected fault below.
      git!(repo, ["checkout", branch])

      {store_name, backend} = start_controllable_store()

      workspace_id = "ws_exhaust_poison_#{System.unique_integer([:positive])}"
      worktree_path = Path.join(worktree_base, Workspace.worktree_dir_name(branch))

      # Seed a branch-phase discarding marker at retry_count=0. The worktree
      # phase is complete (no leased worktree on disk).
      marker = %{
        workspace_id: workspace_id,
        task_id: nil,
        principal_id: nil,
        repo_path: repo,
        worktree_path: worktree_path,
        display_worktree_path: worktree_path,
        branch: branch,
        base_commit: base_commit,
        ownership: :owned,
        branch_provenance: :created,
        lifecycle: :discarding,
        discard_phase: :branch,
        durable_lifecycle: "discarding",
        runtime_id: "rt_exhaust_poison",
        lstat_identity: nil,
        worktree_registration: nil,
        expires_at: DateTime.utc_now(),
        retry_count: 0
      }

      # PUT #1 (seed) persists under the default :ok mode BEFORE the countdown
      # is armed, so it is not counted toward {:fail_put_after, n}.
      assert {:ok, payload} = Core.encode_record(marker)
      assert {:ok, key} = Core.record_key(workspace_id)
      assert :ok = Persistence.put(store_name, backend, key, payload)

      # Relative countdown: after this set_mode the NEXT 1 put succeeds and
      # persists (PUT #2 = reservation retry_count 0->1), and the put after
      # that fails (PUT #3 = dormancy persist at exhaustion). set_mode resets
      # the counter, so the seed does not count.
      :ok = DiscardFaultStore.set_mode(store_name, {:fail_put_after, 1})

      server =
        start_registry(
          retention_journal: {store_name, backend},
          retained_cleanup_retry_limit: 1
        )

      # The hydrate arms a 1ms timer; the whole discard cycle (reserve ->
      # delete -> dormancy persist) runs synchronously inside that handler.
      # Wait until admission is poisoned AND the reservation (retry_count=1)
      # has installed — the combined condition is only reachable when the
      # reservation persisted and the subsequent dormancy persist failed.
      assert_eventually(
        fn ->
          state = :sys.get_state(server)
          assert state.retention_journal.status == :poisoned

          retained = Map.fetch!(state.retained_by_id, workspace_id)
          assert Map.get(retained, :retry_count) == 1
        end,
        200
      )

      state = :sys.get_state(server)
      retained = Map.fetch!(state.retained_by_id, workspace_id)

      # Prior evidence retained EXACTLY — the last successful persist was the
      # reservation (retry_count=1). NO false dormancy, NO fake timer, NO
      # uncommitted cleanup_failure annotation.
      assert Map.get(retained, :retry_count) == 1
      assert Map.get(retained, :dormant) == false
      assert Map.get(retained, :expiry_ref) == nil
      assert Map.get(retained, :cleanup_failure) == nil

      # Durable payload remains the last successful reservation.
      {:ok, durable} = Persistence.get(store_name, backend, key)
      assert (Map.get(durable, :retry_count) || Map.get(durable, "retry_count")) == 1

      # No destructive cleanup after the failed persist — branch preserved.
      assert branch_exists?(repo, branch)
    end

    @tag :security_regression
    test "security regression: reused and unknown provenance settle without deleting the pre-existing branch",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      base_commit = git!(repo, ["rev-parse", "HEAD"])

      for {provenance, branch, label} <- [
            {:reused, "test/discard-reused-no-delete", "reused"},
            {:unknown, "test/discard-unknown-no-delete", "unknown"}
          ] do
        worktree_base = Path.join(tmp_dir, "worktrees-#{label}")
        # Pre-existing branch — not created by this invocation.
        git!(repo, ["branch", branch])
        worktree_path = expected_worktree_path(worktree_base, branch)
        File.mkdir_p!(worktree_base)
        # Real owned worktree path on a pre-existing branch: path is owned,
        # branch provenance is reused/unknown — never deletion authority.
        git!(repo, ["worktree", "add", worktree_path, branch])

        server = start_registry()

        assert {:ok, lease} =
                 WorkspaceLeaseRegistry.acquire(
                   %{
                     repo_path: repo,
                     branch: branch,
                     worktree_base_dir: worktree_base,
                     create_worktree: fn _repo, _branch, _params ->
                       result =
                         case provenance do
                           :reused -> {:ok, worktree_path, :owned, base_commit, :reused}
                           :unknown -> {:ok, worktree_path, :owned, base_commit}
                         end

                       result
                     end
                   },
                   server: server
                 )

        assert lease.branch_provenance == Atom.to_string(provenance)

        assert {:ok, discarded} =
                 WorkspaceLeaseRegistry.release(lease.workspace_id, :discard, server: server)

        # Settlement is reported, the owned worktree is gone, but the
        # pre-existing branch is preserved at its original tip.
        assert discarded.status == "discarded"
        assert discarded.branch_retired == false
        assert branch_exists?(repo, branch)
        assert git!(repo, ["rev-parse", branch]) == base_commit
      end
    end

    test "remove remains backward compatible: owned worktree gone, branch preserved", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/remove-preserves-branch"
      worktree_base = Path.join(tmp_dir, "worktrees")

      assert {:ok, lease} =
               Workspace.Acquire.run(
                 %{
                   repo_path: repo,
                   branch_name: branch,
                   worktree_base_dir: worktree_base
                 },
                 %{}
               )

      worktree_path = lease.worktree_path

      assert {:ok, removed} =
               Workspace.Release.run(
                 %{workspace_id: lease.workspace_id, mode: "remove"},
                 %{}
               )

      assert removed.status == "removed"
      refute Map.has_key?(removed, :branch_retired)
      refute File.dir?(worktree_path)
      assert branch_exists?(repo, branch)
    end

    test "legacy unknown provenance fails closed and preserves the branch", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/discard-legacy-unknown"
      worktree_base = Path.join(tmp_dir, "worktrees")
      worktree_path = expected_worktree_path(worktree_base, branch)
      File.mkdir_p!(worktree_base)
      base_commit = git!(repo, ["rev-parse", "HEAD"])
      git!(repo, ["worktree", "add", "-b", branch, worktree_path, base_commit])

      server = start_registry()

      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: branch,
                   worktree_base_dir: worktree_base,
                   create_worktree: fn _repo, _branch, _params ->
                     # Legacy injector omits provenance → hydrate as unknown.
                     {:ok, worktree_path, :owned, base_commit}
                   end
                 },
                 server: server
               )

      assert lease.branch_provenance == "unknown"

      assert {:ok, discarded} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :discard, server: server)

      assert discarded.status == "discarded"
      assert discarded.branch_retired == false
      assert discarded.branch_preserved_reason == "branch_provenance_not_created"
      refute File.dir?(worktree_path)
      assert branch_exists?(repo, branch)
    end

    test "security regression: crash between worktree removal and ref retirement resumes discard",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/discard-crash-resume"
      worktree_base = Path.join(tmp_dir, "worktrees")
      {store_name, backend} = start_journal_store()
      server = start_registry(retention_journal: {store_name, backend})

      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: branch,
                   worktree_base_dir: worktree_base
                 },
                 server: server
               )

      assert lease.branch_provenance == "created"
      worktree_path = lease.worktree_path
      base_commit = lease.base_commit
      workspace_id = lease.workspace_id
      state = :sys.get_state(server)
      lease_state = Map.fetch!(state.leases, workspace_id)

      identity = %{
        lstat_identity: Map.fetch!(lease_state, :retention_lstat_identity),
        worktree_registration: Map.fetch!(lease_state, :retention_worktree_registration)
      }

      assert :ok = Git.remove_worktree(repo, worktree_path, identity)
      refute File.dir?(worktree_path)
      assert branch_exists?(repo, branch)

      # Durable marker in branch phase — worktree gone, ref still present.
      marker = %{
        workspace_id: workspace_id,
        task_id: nil,
        principal_id: nil,
        repo_path: lease.repo_path,
        worktree_path: worktree_path,
        display_worktree_path: worktree_path,
        branch: branch,
        base_commit: base_commit,
        ownership: :owned,
        branch_provenance: :created,
        lifecycle: :discarding,
        discard_phase: :branch,
        durable_lifecycle: "discarding",
        runtime_id: "rt_crash_resume",
        lstat_identity: nil,
        worktree_registration: nil,
        expires_at: DateTime.utc_now(),
        retry_count: 0
      }

      assert {:ok, payload} = Core.encode_record(marker)
      assert {:ok, key} = Core.record_key(workspace_id)
      assert :ok = Persistence.put(store_name, backend, key, payload)

      # Crash: stop the registry while the branch still exists.
      stop_supervised(server)
      assert branch_exists?(repo, branch)

      # Restart must continue discard from the durable branch-phase marker.
      _server2 = start_registry(retention_journal: {store_name, backend})

      assert_eventually(
        fn ->
          refute branch_exists?(repo, branch)

          # Exactly absent — a poison/corruption error must NOT masquerade as a
          # settled marker here.
          assert {:error, :not_found} = Persistence.get(store_name, backend, key)
        end,
        # Bounded longer wait: restart schedules discard on a 1ms timer, then
        # the branch-phase CAS delete runs two structured observe probes and a
        # worktree-inventory race probe (verify_after_delete) before the marker
        # is deleted. The default ~1s window ends while that second probe is
        # still in flight; this bounded window proves the probe completes and
        # the marker is retired, without weakening or removing the race check.
        300
      )
    end

    test "security regression: retain then discard converts journal before cleanup and retires branch",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/discard-after-retain"
      worktree_base = Path.join(tmp_dir, "worktrees")
      task_id = "task-discard-after-retain-#{System.unique_integer([:positive])}"
      principal_id = "agent-discard-after-retain-#{System.unique_integer([:positive])}"
      {store_name, backend} = start_journal_store()
      parent = self()

      # Observe durable lifecycle at the cleanup boundary — conversion must
      # already be discarding/worktree before any destructive work runs.
      cleanup = fn retained_entry ->
        with {:ok, marker_key} <- Core.record_key(retained_entry.workspace_id),
             {:ok, marker} <- Persistence.get(store_name, backend, marker_key) do
          lifecycle = Map.get(marker, :lifecycle) || Map.get(marker, "lifecycle")
          phase = Map.get(marker, :discard_phase) || Map.get(marker, "discard_phase")
          send(parent, {:discard_cleanup_marker, lifecycle, phase})
        else
          other -> send(parent, {:discard_cleanup_marker_miss, other})
        end

        WorkspaceLeaseRegistry.remove_owned_retained_worktree(retained_entry)
      end

      server =
        start_registry(
          retention_journal: {store_name, backend},
          retained_cleanup: cleanup
        )

      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: branch,
                   worktree_base_dir: worktree_base,
                   task_id: task_id,
                   principal_id: principal_id
                 },
                 server: server
               )

      assert lease.branch_provenance == "created"
      workspace_id = lease.workspace_id
      worktree_path = lease.worktree_path
      assert {:ok, key} = Core.record_key(workspace_id)

      assert {:ok, retained} =
               WorkspaceLeaseRegistry.release(workspace_id, :retain, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert retained.status == "retained"
      assert File.dir?(worktree_path)
      assert branch_exists?(repo, branch)

      assert {:ok, retained_marker} = Persistence.get(store_name, backend, key)

      assert (Map.get(retained_marker, :lifecycle) || Map.get(retained_marker, "lifecycle")) ==
               "retained"

      refute Map.has_key?(retained_marker, :discard_phase)
      refute Map.has_key?(retained_marker, "discard_phase")

      # Crash/restart while still retained, then discard from the restored marker.
      stop_supervised(server)

      server2 =
        start_registry(
          retention_journal: {store_name, backend},
          retained_cleanup: cleanup
        )

      assert {:ok, discarded} =
               WorkspaceLeaseRegistry.release(workspace_id, :discard, %{
                 server: server2,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert discarded.status == "discarded"
      assert discarded.branch_retired == true
      refute File.dir?(worktree_path)
      refute branch_exists?(repo, branch)

      assert_receive {:discard_cleanup_marker, "discarding", phase}, 1_000
      assert phase in ["worktree", :worktree]

      # Exactly absent — settlement must leave no durable marker behind.
      assert {:error, :not_found} = Persistence.get(store_name, backend, key)
    end

    test "security regression: durable discard marker combinations fail closed", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      worktree_path = Path.join(tmp_dir, "wt")
      File.mkdir_p!(worktree_path)
      base = git!(repo, ["rev-parse", "HEAD"])

      lstat = %{
        type: "directory",
        major_device: 0,
        minor_device: 0,
        inode: 1
      }

      registration = %{path: worktree_path, head: base, branch: "test/marker"}

      base_input = %{
        workspace_id: "ws_marker_combo",
        task_id: nil,
        principal_id: nil,
        repo_path: repo,
        worktree_path: worktree_path,
        display_worktree_path: worktree_path,
        branch: "test/marker",
        base_commit: base,
        ownership: :owned,
        runtime_id: "rt_marker_combo",
        expires_at: DateTime.utc_now(),
        retry_count: 0
      }

      # Valid discarding phases encode.
      assert {:ok, worktree_record} =
               Core.encode_record(
                 Map.merge(base_input, %{
                   lifecycle: :discarding,
                   discard_phase: :worktree,
                   branch_provenance: :created,
                   lstat_identity: lstat,
                   worktree_registration: registration
                 })
               )

      assert worktree_record.lifecycle == "discarding"
      assert worktree_record.discard_phase == "worktree"
      assert worktree_record.branch_provenance == "created"

      assert {:ok, branch_record} =
               Core.encode_record(
                 Map.merge(base_input, %{
                   lifecycle: :discarding,
                   discard_phase: :branch,
                   branch_provenance: :unknown,
                   lstat_identity: nil,
                   worktree_registration: nil
                 })
               )

      assert branch_record.lifecycle == "discarding"
      assert branch_record.discard_phase == "branch"
      assert branch_record.branch_provenance == "unknown"
      assert branch_record.lstat_identity == nil
      assert branch_record.worktree_registration == nil

      # discard_phase only legal on discarding lifecycle.
      assert {:error, :discard_phase_not_allowed} =
               Core.encode_record(
                 Map.merge(base_input, %{
                   lifecycle: :retained,
                   discard_phase: :worktree,
                   branch_provenance: :created,
                   lstat_identity: lstat,
                   worktree_registration: registration
                 })
               )

      assert {:error, :missing_discard_phase} =
               Core.encode_record(
                 Map.merge(base_input, %{
                   lifecycle: :discarding,
                   branch_provenance: :created,
                   lstat_identity: lstat,
                   worktree_registration: registration
                 })
               )

      # Branch phase must drop identity; worktree phase requires it.
      assert {:error, :discard_branch_phase_has_lstat_identity} =
               Core.encode_record(
                 Map.merge(base_input, %{
                   lifecycle: :discarding,
                   discard_phase: :branch,
                   branch_provenance: :created,
                   lstat_identity: lstat,
                   worktree_registration: nil
                 })
               )

      assert {:error, :invalid_lstat_identity} =
               Core.encode_record(
                 Map.merge(base_input, %{
                   lifecycle: :discarding,
                   discard_phase: :worktree,
                   branch_provenance: :created,
                   lstat_identity: nil,
                   worktree_registration: nil
                 })
               )
    end

    @tag :security_regression
    test "security regression: checked-out-branch retry exhaustion plus restart preserves branch and dormant marker",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/discard-checked-out-exhausted"
      worktree_base = Path.join(tmp_dir, "worktrees")
      base_commit = git!(repo, ["rev-parse", "HEAD"])
      {store_name, backend} = start_journal_store()

      # Create a second worktree that keeps the branch checked out, preventing
      # deletion. Then inject a branch-phase discarding marker with retries
      # exhausted.
      {_, 0} = System.cmd("git", ["branch", branch], cd: repo)
      second_wt = Path.join(tmp_dir, "second-wt")
      {_, 0} = System.cmd("git", ["worktree", "add", second_wt, branch], cd: repo)

      workspace_id = "ws_co_exhausted_#{System.unique_integer([:positive])}"
      worktree_path = Path.join(worktree_base, Workspace.worktree_dir_name(branch))

      marker = %{
        workspace_id: workspace_id,
        task_id: nil,
        principal_id: nil,
        repo_path: repo,
        worktree_path: worktree_path,
        display_worktree_path: worktree_path,
        branch: branch,
        base_commit: base_commit,
        ownership: :owned,
        branch_provenance: :created,
        lifecycle: :discarding,
        discard_phase: :branch,
        durable_lifecycle: "discarding",
        runtime_id: "rt_co_exhausted",
        lstat_identity: nil,
        worktree_registration: nil,
        expires_at: DateTime.utc_now(),
        retry_count: 3
      }

      assert {:ok, payload} = Core.encode_record(marker)
      assert {:ok, key} = Core.record_key(workspace_id)
      assert :ok = Persistence.put(store_name, backend, key, payload)

      server =
        start_registry(
          retention_journal: {store_name, backend},
          retained_cleanup_retry_limit: 3
        )

      # Give hydration + any scheduled retry a chance to run. The branch is
      # checked out and retries are exhausted — the marker must stay dormant
      # and the branch must survive.
      Process.sleep(300)

      assert branch_exists?(repo, branch)
      assert git!(repo, ["rev-parse", branch]) == base_commit

      state = :sys.get_state(server)
      hydrated = Map.fetch!(state.retained_by_id, workspace_id)
      assert Map.get(hydrated, :dormant) == true
      assert Map.get(hydrated, :retry_count) >= 3
      assert Map.get(hydrated, :discard_phase) == :branch
      assert Map.get(hydrated, :expiry_ref) == nil

      # Durable marker survives.
      assert {:ok, durable} = Persistence.get(store_name, backend, key)
      assert (Map.get(durable, :lifecycle) || Map.get(durable, "lifecycle")) == "discarding"
      assert (Map.get(durable, :discard_phase) || Map.get(durable, "discard_phase")) == "branch"

      # Cleanup the second worktree to allow later settlement.
      System.cmd("git", ["worktree", "remove", "--force", second_wt], cd: repo)
    end

    @tag :security_regression
    test "security regression: tuple-valued preserve reason renders as a string receipt, not a crash",
         %{tmp_dir: tmp_dir} do
      # Receipt-formatting boundary in dormant_discard_marker/3: when a marker
      # delete fails inside settle_discard_preserving_branch, dormancy receives
      # the tuple reason {preserve_reason, delete_reason}. String.Chars is not
      # implemented for tuples, so a naive to_string/1 on the reason would
      # raise Protocol.UndefinedError and silently drop the honest dormant
      # receipt the caller needs to see residue. The safe formatter must
      # render arbitrary terms via inspect while keeping atoms/strings readable.
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/discard-tuple-reason"
      worktree_base = Path.join(tmp_dir, "worktrees")
      worktree_path = expected_worktree_path(worktree_base, branch)
      File.mkdir_p!(worktree_base)
      base_commit = git!(repo, ["rev-parse", "HEAD"])
      git!(repo, ["worktree", "add", "-b", branch, worktree_path, base_commit])

      {store_name, backend} = start_controllable_store()

      server = start_registry(retention_journal: {store_name, backend})

      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: branch,
                   worktree_base_dir: worktree_base,
                   create_worktree: fn _repo, _branch, _params ->
                     # Legacy injector omits provenance → hydrate as unknown, so
                     # discard routes through settle_discard_preserving_branch.
                     {:ok, worktree_path, :owned, base_commit}
                   end
                 },
                 server: server
               )

      assert lease.branch_provenance == "unknown"

      # Poison deletes AFTER acquire so the marker exists durably; the next
      # delete_retained_marker call inside settle_discard_preserving_branch
      # fails and constructs the tuple {atom, delete_reason} handed to
      # dormant_discard_marker.
      :ok = DiscardFaultStore.set_mode(store_name, :fail_delete)

      assert {:ok, discarded} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :discard, server: server)

      # The cleanup path did not crash and the receipt reports pending
      # truthfully — never a fake settled "discarded".
      assert discarded.status == "discard_pending"
      assert discarded.branch_retired == false
      assert discarded.cleanup_residue == true

      # The receipt carries only bounded categories. Raw marker/delete terms
      # and backend details never cross the Actions boundary.
      assert is_binary(discarded.branch_preserved_reason)
      assert discarded.branch_preserved_reason =~ "branch_provenance_not_created"
      assert discarded.cleanup_failure_category == "marker_delete_failed"
      refute Map.has_key?(discarded, :pending_reason)
      refute Map.has_key?(discarded, :cleanup_failure)

      # Marker remains durably present — settlement stays honest.
      assert {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, durable} = Persistence.get(store_name, backend, key)
      assert (Map.get(durable, :lifecycle) || Map.get(durable, "lifecycle")) == "discarding"

      # Unreserved marker-delete retry advances exactly once (worktree-phase
      # reserve 0->1, then marker-delete retry reserve 1->2).
      assert (Map.get(durable, :retry_count) || Map.get(durable, "retry_count")) == 2

      # Branch is preserved — provenance was not :created.
      assert branch_exists?(repo, branch)
    end

    test "security regression: pre-reserved branch-delete marker-delete failure keeps retry_count at 1; unreserved already-absent advances 0->1",
         %{tmp_dir: tmp_dir} do
      # Canonicalize so git's internal paths match the registry's hydration.
      tmp_dir = Workspace.canonical_path_or_expanded(tmp_dir)
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      worktree_base = Path.join(tmp_dir, "worktrees")
      base_commit = git!(repo, ["rev-parse", "HEAD"])

      # --- Pre-reserved path: seed a branch-phase discarding marker with a
      # created branch present and the worktree absent. Hydration resumes the
      # discard, observes the branch at expected_oid, reserves 0->1 for the
      # destructive delete, deletes the branch, then fails only the marker
      # delete. settle_discard_complete(pre_reserved: true) must schedule on
      # the existing reservation without incrementing again. ---
      branch_created = "test/pre-reserved-seed-created"
      {_, 0} = System.cmd("git", ["branch", branch_created], cd: repo)

      ws_pre = "ws_pre_reserved_#{System.unique_integer([:positive])}"
      wt_pre = Path.join(worktree_base, "wt-pre-reserved")

      marker_pre = %{
        workspace_id: ws_pre,
        task_id: nil,
        principal_id: nil,
        repo_path: repo,
        worktree_path: wt_pre,
        display_worktree_path: wt_pre,
        branch: branch_created,
        base_commit: base_commit,
        ownership: :owned,
        branch_provenance: :created,
        lifecycle: :discarding,
        discard_phase: :branch,
        durable_lifecycle: "discarding",
        runtime_id: "rt_pre_reserved",
        lstat_identity: nil,
        worktree_registration: nil,
        expires_at: DateTime.utc_now(),
        retry_count: 0
      }

      {store_pre, backend_pre} = start_controllable_store()
      {:ok, payload_pre} = Core.encode_record(marker_pre)
      {:ok, key_pre} = Core.record_key(ws_pre)
      :ok = Persistence.put(store_pre, backend_pre, key_pre, payload_pre)

      :ok = DiscardFaultStore.set_mode(store_pre, :fail_delete)

      server_pre =
        start_registry(
          retention_journal: {store_pre, backend_pre},
          retained_cleanup_retry_limit: 5
        )

      # Wait for the combined authoritative postcondition: branch deleted,
      # worktree absent, durable marker present at retry_count exactly 1
      # (branch-delete reserve only; marker-delete failure did NOT increment).
      assert_eventually(
        fn ->
          refute branch_exists?(repo, branch_created)
          refute File.dir?(wt_pre)
          assert {:ok, d} = Persistence.get(store_pre, backend_pre, key_pre)
          assert (Map.get(d, :retry_count) || Map.get(d, "retry_count")) == 1
        end,
        50
      )

      stop_supervised(server_pre)

      # --- Unreserved path: seed a branch-phase discarding marker with the
      # branch already absent. Hydration resumes, observes absence, routes to
      # settle_discard_complete(pre_reserved: false) which reserves exactly
      # once for the marker-delete retry (0->1). ---
      branch_absent = "test/unreserved-seed-absent"

      ws_un = "ws_unreserved_#{System.unique_integer([:positive])}"
      wt_un = Path.join(worktree_base, "wt-unreserved")

      marker_un = %{
        workspace_id: ws_un,
        task_id: nil,
        principal_id: nil,
        repo_path: repo,
        worktree_path: wt_un,
        display_worktree_path: wt_un,
        branch: branch_absent,
        base_commit: base_commit,
        ownership: :owned,
        branch_provenance: :created,
        lifecycle: :discarding,
        discard_phase: :branch,
        durable_lifecycle: "discarding",
        runtime_id: "rt_unreserved",
        lstat_identity: nil,
        worktree_registration: nil,
        expires_at: DateTime.utc_now(),
        retry_count: 0
      }

      {store_un, backend_un} = start_controllable_store()
      {:ok, payload_un} = Core.encode_record(marker_un)
      {:ok, key_un} = Core.record_key(ws_un)
      :ok = Persistence.put(store_un, backend_un, key_un, payload_un)

      :ok = DiscardFaultStore.set_mode(store_un, :fail_delete)

      server_un =
        start_registry(
          retention_journal: {store_un, backend_un},
          retained_cleanup_retry_limit: 5
        )

      # Wait for the combined authoritative postcondition: worktree absent,
      # durable marker present at retry_count exactly 1 (unreserved
      # marker-delete retry advances 0->1).
      assert_eventually(
        fn ->
          refute branch_exists?(repo, branch_absent)
          refute File.dir?(wt_un)
          assert {:ok, d} = Persistence.get(store_un, backend_un, key_un)
          assert (Map.get(d, :retry_count) || Map.get(d, "retry_count")) == 1
        end,
        50
      )

      stop_supervised(server_un)
    end
  end

  describe "retained expiry archive settlement" do
    test "journal admits archive phase only with exact worktree identity" do
      acquisition_base = "0123456789abcdef0123456789abcdef01234567"
      settlement_tip = "fedcba9876543210fedcba9876543210fedcba98"

      marker = %{
        workspace_id: "ws_archive_phase_core",
        task_id: "task_archive_phase_core",
        principal_id: "agent_archive_phase_core",
        repo_path: "/tmp/archive-phase-repo",
        worktree_path: "/tmp/archive-phase-worktree",
        display_worktree_path: "/tmp/archive-phase-worktree",
        branch: "test/archive-phase-core",
        base_commit: acquisition_base,
        settlement_tip: settlement_tip,
        ownership: :owned,
        branch_provenance: :created,
        lifecycle: :discarding,
        discard_phase: :archive,
        runtime_id: "rt_archive_phase_core",
        lstat_identity: %{
          type: :directory,
          major_device: 1,
          minor_device: 2,
          inode: 3
        },
        worktree_registration: %{
          path: "/tmp/archive-phase-worktree",
          head: settlement_tip,
          branch: "test/archive-phase-core"
        },
        expires_at: DateTime.utc_now(),
        retry_count: 0
      }

      assert {:ok, encoded} = Core.encode_record(marker)
      assert encoded.discard_phase == "archive"
      assert encoded.base_commit == acquisition_base
      assert encoded.settlement_tip == settlement_tip
      assert {:ok, decoded} = Core.decode_record(encoded)
      assert decoded.discard_phase == "archive"
      assert decoded.base_commit == acquisition_base
      assert decoded.settlement_tip == settlement_tip

      assert {:error, :missing_settlement_tip} =
               marker
               |> Map.delete(:settlement_tip)
               |> Core.encode_record()

      assert {:error, :invalid_lstat_identity} =
               marker
               |> Map.put(:lstat_identity, nil)
               |> Core.encode_record()
    end

    test "created branch archives its exact tip before worktree and branch retirement", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/expiry-archive-created"
      worktree_base = Path.join(tmp_dir, "worktrees")
      task_id = "task-expiry-created-#{System.unique_integer([:positive])}"
      principal_id = "agent-expiry-created"
      parent = self()

      archive = fn retained ->
        result =
          Git.archive_branch_evidence_ref(
            retained.repo_path,
            retained.branch,
            retained.task_id,
            retained.workspace_id,
            retained.settlement_tip
          )

        send(
          parent,
          {:archive_result, result, retained.base_commit, retained.settlement_tip}
        )

        result
      end

      server = start_registry(retained_archive: archive)

      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: branch,
                   worktree_base_dir: worktree_base,
                   task_id: task_id,
                   principal_id: principal_id
                 },
                 server: server
               )

      acquisition_base = git!(lease.worktree_path, ["rev-parse", "HEAD"])
      File.write!(Path.join(lease.worktree_path, "candidate.txt"), "candidate\n")
      git!(lease.worktree_path, ["add", "candidate.txt"])
      git!(lease.worktree_path, ["commit", "-m", "candidate"])
      expected_tip = git!(lease.worktree_path, ["rev-parse", "HEAD"])

      assert {:ok, _retained} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :retain, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      force_retained_expired(server)
      {target, generation} = retained_target_and_generation(server)
      send(Process.whereis(server), {:retained_expire, target, generation})

      assert acquisition_base != expected_tip

      assert_receive {:archive_result, archive_result, ^acquisition_base, ^expected_tip},
                     2_000

      assert {:ok, %{hidden_ref: hidden_ref}} = archive_result

      assert_eventually(
        fn ->
          refute File.dir?(lease.worktree_path)
          refute branch_exists?(repo, branch)
          assert :sys.get_state(server).retained_by_id == %{}
        end,
        100
      )

      assert git!(repo, ["rev-parse", hidden_ref]) == expected_tip
    end

    test "reused and unknown branches are archived but preserved", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      expected_tip = git!(repo, ["rev-parse", "HEAD"])

      for {provenance, label} <- [{:reused, "reused"}, {:unknown, "unknown"}] do
        branch = "test/expiry-archive-#{label}"
        worktree_base = Path.join(tmp_dir, "worktrees-#{label}")
        worktree_path = expected_worktree_path(worktree_base, branch)
        task_id = "task-expiry-#{label}-#{System.unique_integer([:positive])}"
        principal_id = "agent-expiry-#{label}"

        git!(repo, ["branch", branch])
        git!(repo, ["worktree", "add", worktree_path, branch])
        server = start_registry()

        assert {:ok, lease} =
                 WorkspaceLeaseRegistry.acquire(
                   %{
                     repo_path: repo,
                     branch: branch,
                     worktree_base_dir: worktree_base,
                     task_id: task_id,
                     principal_id: principal_id,
                     create_worktree: fn _repo, _branch, _params ->
                       case provenance do
                         :reused -> {:ok, worktree_path, :owned, expected_tip, :reused}
                         :unknown -> {:ok, worktree_path, :owned, expected_tip}
                       end
                     end
                   },
                   server: server
                 )

        assert {:ok, _retained} =
                 WorkspaceLeaseRegistry.release(lease.workspace_id, :retain, %{
                   server: server,
                   task_id: task_id,
                   principal_id: principal_id
                 })

        force_retained_expired(server)
        {target, generation} = retained_target_and_generation(server)
        send(Process.whereis(server), {:retained_expire, target, generation})

        assert_eventually(
          fn ->
            refute File.dir?(worktree_path)
            assert branch_exists?(repo, branch)
            assert git!(repo, ["rev-parse", branch]) == expected_tip
            assert :sys.get_state(server).retained_by_id == %{}
          end,
          150
        )

        hidden_ref = evidence_ref_for(task_id, lease.workspace_id)
        assert git!(repo, ["rev-parse", hidden_ref]) == expected_tip
      end
    end

    test "archive failure preserves worktree and branch in a durable archive-phase marker", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/expiry-archive-failure"
      worktree_base = Path.join(tmp_dir, "worktrees")
      task_id = "task-expiry-archive-failure"
      principal_id = "agent-expiry-archive-failure"
      parent = self()
      {store_name, backend} = start_journal_store()

      server =
        start_registry(
          retention_journal: {store_name, backend},
          retained_cleanup_retry_limit: 1,
          retained_archive: fn _retained -> {:error, :injected_archive_failure} end,
          retained_cleanup: fn _retained ->
            send(parent, :unexpected_expiry_cleanup)
            :ok
          end
        )

      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: branch,
                   worktree_base_dir: worktree_base,
                   task_id: task_id,
                   principal_id: principal_id
                 },
                 server: server
               )

      acquisition_base = git!(lease.worktree_path, ["rev-parse", "HEAD"])
      File.write!(Path.join(lease.worktree_path, "archive-failure.txt"), "candidate\n")
      git!(lease.worktree_path, ["add", "archive-failure.txt"])
      git!(lease.worktree_path, ["commit", "-m", "archive failure candidate"])
      expected_tip = git!(lease.worktree_path, ["rev-parse", "HEAD"])

      assert {:ok, _retained} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :retain, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      force_retained_expired(server)
      {target, generation} = retained_target_and_generation(server)
      send(Process.whereis(server), {:retained_expire, target, generation})

      assert_eventually(
        fn ->
          retained = retained_record(server)
          assert retained.lifecycle == :discarding
          assert retained.discard_phase == :archive
          assert retained.base_commit == acquisition_base
          assert retained.settlement_tip == expected_tip
          assert retained.dormant == true
        end,
        100
      )

      refute_received :unexpected_expiry_cleanup
      assert File.dir?(lease.worktree_path)
      assert branch_exists?(repo, branch)
      refute ref_exists?(repo, evidence_ref_for(task_id, lease.workspace_id))

      assert {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, durable} = Persistence.get(store_name, backend, key)
      assert (Map.get(durable, :lifecycle) || Map.get(durable, "lifecycle")) == "discarding"
      assert (Map.get(durable, :discard_phase) || Map.get(durable, "discard_phase")) == "archive"

      assert (Map.get(durable, :base_commit) || Map.get(durable, "base_commit")) ==
               acquisition_base

      assert (Map.get(durable, :settlement_tip) || Map.get(durable, "settlement_tip")) ==
               expected_tip
    end

    test "tip movement after capture cannot be rebound or archived", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/expiry-archive-tip-race"
      worktree_base = Path.join(tmp_dir, "worktrees")
      task_id = "task-expiry-tip-race"
      principal_id = "agent-expiry-tip-race"
      parent = self()
      {store_name, backend} = start_journal_store()
      expected_tip = git!(repo, ["rev-parse", "HEAD"])
      File.write!(Path.join(repo, "replacement.txt"), "replacement\n")
      git!(repo, ["add", "replacement.txt"])
      git!(repo, ["commit", "-m", "replacement tip"])
      replacement_tip = git!(repo, ["rev-parse", "HEAD"])

      archive = fn retained ->
        git!(repo, [
          "update-ref",
          "refs/heads/#{branch}",
          replacement_tip,
          retained.settlement_tip
        ])

        result =
          Git.archive_branch_evidence_ref(
            retained.repo_path,
            retained.branch,
            retained.task_id,
            retained.workspace_id,
            retained.settlement_tip
          )

        send(parent, {:tip_race_archive, result})
        result
      end

      server =
        start_registry(
          retention_journal: {store_name, backend},
          retained_cleanup_retry_limit: 1,
          retained_archive: archive
        )

      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: branch,
                   base_ref: expected_tip,
                   worktree_base_dir: worktree_base,
                   task_id: task_id,
                   principal_id: principal_id
                 },
                 server: server
               )

      assert git!(lease.worktree_path, ["rev-parse", "HEAD"]) == expected_tip

      assert {:ok, _retained} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :retain, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      force_retained_expired(server)
      {target, generation} = retained_target_and_generation(server)
      send(Process.whereis(server), {:retained_expire, target, generation})

      assert_receive {:tip_race_archive, {:error, :branch_ref_oid_mismatch}}, 2_000

      assert_eventually(
        fn ->
          retained = retained_record(server)
          assert retained.discard_phase == :archive
          assert retained.settlement_tip == expected_tip
          assert retained.dormant == true
        end,
        100
      )

      assert File.dir?(lease.worktree_path)
      assert git!(repo, ["rev-parse", branch]) == replacement_tip
      refute ref_exists?(repo, evidence_ref_for(task_id, lease.workspace_id))
    end

    test "restart after archive creation replays archive phase before cleanup", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/expiry-archive-restart"
      worktree_base = Path.join(tmp_dir, "worktrees")
      task_id = "task-expiry-archive-restart"
      principal_id = "agent-expiry-archive-restart"
      {store_name, backend} = start_journal_store()
      server = start_registry(retention_journal: {store_name, backend})

      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: branch,
                   worktree_base_dir: worktree_base,
                   task_id: task_id,
                   principal_id: principal_id
                 },
                 server: server
               )

      assert {:ok, _retained} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :retain, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      retained = retained_record(server)
      expected_tip = git!(lease.worktree_path, ["rev-parse", "HEAD"])

      assert {:ok, %{hidden_ref: hidden_ref}} =
               Git.archive_branch_evidence_ref(
                 repo,
                 branch,
                 task_id,
                 lease.workspace_id,
                 expected_tip
               )

      archive_marker =
        Map.merge(retained, %{
          settlement_tip: expected_tip,
          lifecycle: :discarding,
          discard_phase: :archive,
          retry_count: 0
        })

      persist_marker!(store_name, backend, archive_marker)
      stop_supervised(server)

      server2 = start_registry(retention_journal: {store_name, backend})

      assert_eventually(
        fn ->
          refute File.dir?(lease.worktree_path)
          refute branch_exists?(repo, branch)
          assert :sys.get_state(server2).retained_by_id == %{}

          assert {:ok, key} = Core.record_key(lease.workspace_id)
          assert {:error, :not_found} = Persistence.get(store_name, backend, key)
        end,
        300
      )

      assert git!(repo, ["rev-parse", hidden_ref]) == expected_tip
    end

    test "restart after worktree removal resumes branch retirement", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/expiry-worktree-restart"
      worktree_base = Path.join(tmp_dir, "worktrees")
      task_id = "task-expiry-worktree-restart"
      principal_id = "agent-expiry-worktree-restart"
      {store_name, backend} = start_journal_store()
      server = start_registry(retention_journal: {store_name, backend})

      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: branch,
                   worktree_base_dir: worktree_base,
                   task_id: task_id,
                   principal_id: principal_id
                 },
                 server: server
               )

      assert {:ok, _retained} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :retain, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      retained = retained_record(server)
      expected_tip = git!(lease.worktree_path, ["rev-parse", "HEAD"])

      assert {:ok, %{hidden_ref: hidden_ref}} =
               Git.archive_branch_evidence_ref(
                 repo,
                 branch,
                 task_id,
                 lease.workspace_id,
                 expected_tip
               )

      worktree_marker =
        Map.merge(retained, %{
          settlement_tip: expected_tip,
          lifecycle: :discarding,
          discard_phase: :worktree,
          retry_count: 0
        })

      # Durable worktree phase precedes removal. Simulate a crash after the
      # identity-checked remove but before the branch-phase marker is written.
      persist_marker!(store_name, backend, worktree_marker)
      assert :ok = WorkspaceLeaseRegistry.remove_owned_retained_worktree(retained)
      refute File.dir?(lease.worktree_path)
      assert branch_exists?(repo, branch)
      stop_supervised(server)

      server2 = start_registry(retention_journal: {store_name, backend})

      assert_eventually(
        fn ->
          refute branch_exists?(repo, branch)
          assert :sys.get_state(server2).retained_by_id == %{}

          assert {:ok, key} = Core.record_key(lease.workspace_id)
          assert {:error, :not_found} = Persistence.get(store_name, backend, key)
        end,
        300
      )

      assert git!(repo, ["rev-parse", hidden_ref]) == expected_tip
    end

    test "legacy retained record without task or provenance cannot gain cleanup authority", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/expiry-legacy-no-authority"
      worktree_base = Path.join(tmp_dir, "worktrees")
      {store_name, backend} = start_journal_store()
      server = start_registry(retention_journal: {store_name, backend})

      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: branch,
                   worktree_base_dir: worktree_base
                 },
                 server: server
               )

      assert {:ok, _retained} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :retain, %{server: server})

      assert {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, durable} = Persistence.get(store_name, backend, key)

      legacy =
        durable
        |> Map.delete(:branch_provenance)
        |> Map.delete("branch_provenance")
        |> Map.put(
          :expires_at,
          DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
        )

      assert :ok = Persistence.put(store_name, backend, key, legacy)
      stop_supervised(server)

      server2 =
        start_registry(
          retention_journal: {store_name, backend},
          retained_cleanup_retry_limit: 1
        )

      assert_eventually(
        fn ->
          retained = retained_record(server2)
          assert retained.lifecycle == :discarding
          assert retained.discard_phase == :archive
          assert retained.branch_provenance == :unknown
          assert retained.settlement_tip == git!(repo, ["rev-parse", branch])
          assert retained.dormant == true
        end,
        200
      )

      assert File.dir?(lease.worktree_path)
      assert branch_exists?(repo, branch)
      assert {:ok, durable_after} = Persistence.get(store_name, backend, key)

      assert (Map.get(durable_after, :discard_phase) ||
                Map.get(durable_after, "discard_phase")) == "archive"

      assert is_binary(
               Map.get(durable_after, :settlement_tip) ||
                 Map.get(durable_after, "settlement_tip")
             )
    end
  end

  # -- helpers --------------------------------------------------------

  defp start_journal_store do
    name = String.to_atom("discard_journal_#{System.unique_integer([:positive])}")
    start_supervised!({Arbor.Persistence.Store.ETS, name: name, max_entries: 1_000}, id: name)
    {name, Arbor.Persistence.Store.ETS}
  end

  # Deterministic fault-injecting journal backend local to the discard suite.
  # Used to poison persistence at precise points in the discard flow so
  # degraded admission is exercised without process-kill races.
  defp start_controllable_store do
    name = String.to_atom("discard_ctrl_#{System.unique_integer([:positive])}")
    start_supervised!({DiscardFaultStore, name: name}, id: name)
    {name, DiscardFaultStore}
  end

  defp start_registry(opts \\ []) do
    server = :"ws_discard_#{System.unique_integer([:positive])}"

    start_opts =
      [
        name: server,
        retention_ttl_ms: Keyword.get(opts, :retention_ttl_ms, 60_000),
        linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer
      ]
      |> maybe_put(:retention_journal, Keyword.get(opts, :retention_journal))
      |> maybe_put(:retained_archive, Keyword.get(opts, :retained_archive))
      |> maybe_put(:retained_cleanup, Keyword.get(opts, :retained_cleanup))
      |> maybe_put(
        :retained_cleanup_retry_limit,
        Keyword.get(opts, :retained_cleanup_retry_limit)
      )

    start_supervised!({WorkspaceLeaseRegistry, start_opts}, id: server)
    server
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp expected_worktree_path(base_dir, branch_name) do
    Path.join(base_dir, Workspace.worktree_dir_name(branch_name))
  end

  defp branch_exists?(repo, branch) do
    case System.cmd(
           "git",
           ["-C", repo, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}"],
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp ref_exists?(repo, full_ref) do
    case System.cmd(
           "git",
           ["-C", repo, "show-ref", "--verify", "--quiet", full_ref],
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp evidence_ref_for(task_id, workspace_id) do
    workspace_digest = :crypto.hash(:sha256, workspace_id) |> Base.encode16(case: :lower)
    task_digest = :crypto.hash(:sha256, task_id) |> Base.encode16(case: :lower)
    "refs/arbor/evidence/#{workspace_digest}/#{task_digest}"
  end

  defp retained_record(server) do
    [{_workspace_id, retained}] = Map.to_list(:sys.get_state(server).retained_by_id)
    retained
  end

  defp persist_marker!(store_name, backend, marker) do
    assert {:ok, payload} = Core.encode_record(marker)
    assert {:ok, key} = Core.record_key(marker.workspace_id)
    assert :ok = Persistence.put(store_name, backend, key, payload)
  end

  defp retained_target_and_generation(server) do
    [{target, retained}] = Map.to_list(:sys.get_state(server).retained_by_target)
    {target, retained.expiry_generation}
  end

  defp force_retained_expired(server) do
    now = System.monotonic_time(:millisecond)

    :sys.replace_state(server, fn state ->
      retained_by_id =
        Map.new(state.retained_by_id, fn {id, retained} ->
          {id, %{retained | expires_at_ms: now - 1}}
        end)

      retained_by_target =
        Map.new(state.retained_by_target, fn {target, retained} ->
          {target, %{retained | expires_at_ms: now - 1}}
        end)

      %{state | retained_by_id: retained_by_id, retained_by_target: retained_by_target}
    end)
  end

  defp assert_eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    error in [ExUnit.AssertionError] ->
      if attempts == 1 do
        reraise error, __STACKTRACE__
      else
        Process.sleep(20)
        assert_eventually(fun, attempts - 1)
      end
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
