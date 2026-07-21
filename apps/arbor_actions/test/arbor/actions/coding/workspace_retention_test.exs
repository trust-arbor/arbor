defmodule Arbor.Actions.Coding.WorkspaceRetentionTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Coding.WorkspaceRetentionJournalCore, as: Core
  alias Arbor.Actions.Config
  alias Arbor.Actions.Git

  @moduletag :fast
  @owner_operation_timeout 10_000

  test "security regression: closed creating records accept normalized string-key base fields" do
    input = %{
      "schema_version" => Core.schema_version(),
      "workspace_id" => "ws_pending_core",
      "task_id" => "task_pending_core",
      "principal_id" => "agent_pending_core",
      "repo_path" => "/tmp/pending-core-repo",
      "worktree_path" => "/tmp/pending-core-worktree",
      "display_worktree_path" => "/tmp/pending-core-worktree",
      "branch" => "test/pending-core",
      "base_commit" => nil,
      "ownership" => "pending",
      "lifecycle" => "creating",
      "runtime_id" => "rt_pending_core",
      "lstat_identity" => nil,
      "worktree_registration" => nil,
      "expires_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "retry_count" => 0
    }

    assert {:ok, record} = Core.decode_record(input)
    assert Core.creating_record?(record)
    assert Core.restore_decision(record) == :restore
  end

  test "retention TTL has the configured default and hard bounds" do
    previous = Application.get_env(:arbor_actions, :workspace_retention_ttl_ms)
    Application.delete_env(:arbor_actions, :workspace_retention_ttl_ms)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:arbor_actions, :workspace_retention_ttl_ms),
        else: Application.put_env(:arbor_actions, :workspace_retention_ttl_ms, previous)
    end)

    assert Config.workspace_retention_ttl_ms([]) == 24 * 60 * 60 * 1_000

    assert Config.workspace_retention_ttl_ms(retention_ttl_ms: 1) ==
             Config.workspace_retention_min_ttl_ms()

    assert Config.workspace_retention_ttl_ms(retention_ttl_ms: 8 * 24 * 60 * 60 * 1_000) ==
             Config.workspace_retention_max_ttl_ms()
  end

  test "owned retain expires and removes only the exact retained worktree", %{tmp_dir: tmp_dir} do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    # Config clamps TTL to a 1s minimum; give the eventual assertion headroom.
    server = start_registry(1_000)
    task_id = "task-retention-expiry-#{System.unique_integer([:positive])}"
    principal_id = "agent-retention-expiry"

    assert {:ok, lease} =
             acquire(server, repo, "test/retention-expiry", tmp_dir, nil,
               task_id: task_id,
               principal_id: principal_id
             )

    path = lease.worktree_path

    assert {:ok, retained} = release(server, lease.workspace_id, :retain)
    assert retained.status == "retained"
    assert is_binary(retained.expires_at)
    assert File.dir?(path)

    assert_eventually(fn -> refute File.dir?(path) end, 200)
    assert retained_state(server) == {[], []}
  end

  test "reused retain has no retained record, timer, or deletion authority", %{
    tmp_dir: tmp_dir
  } do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    branch = "test/reused-retain"
    base = Path.join(tmp_dir, "worktrees")
    path = expected_worktree_path(base, branch)
    git!(repo, ["branch", branch])
    git!(repo, ["worktree", "add", path, branch])

    server = start_registry(50)
    assert {:ok, lease} = acquire(server, repo, branch, tmp_dir, base)
    assert lease.ownership == "reused"
    File.write!(Path.join(path, "keep.txt"), "keep\n")
    assert {:ok, _} = release(server, lease.workspace_id, :retain)
    assert retained_state(server) == {[], []}

    Process.sleep(100)
    assert File.dir?(path)
    assert File.exists?(Path.join(path, "keep.txt"))
  end

  test "authorized reactivation is direct and preserves dirty, untracked, and committed state", %{
    tmp_dir: tmp_dir
  } do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    branch = "test/direct-reactivation"
    base = Path.join(tmp_dir, "worktrees")
    server = start_registry(5_000)

    assert {:ok, lease} = acquire(server, repo, branch, tmp_dir, base)
    File.write!(Path.join(lease.worktree_path, "untracked.txt"), "preserve\n")
    File.write!(Path.join(lease.worktree_path, "committed.txt"), "commit\n")
    git!(lease.worktree_path, ["add", "committed.txt"])
    git!(lease.worktree_path, ["commit", "-m", "retained commit"])
    head = git!(lease.worktree_path, ["rev-parse", "HEAD"])

    assert {:ok, _} = release(server, lease.workspace_id, :retain)

    assert {:ok, reactivated} =
             acquire(server, repo, branch, tmp_dir, base, workspace_id: lease.workspace_id)

    assert reactivated.workspace_id == lease.workspace_id
    assert reactivated.active
    assert reactivated.ownership == "owned"
    assert File.read!(Path.join(reactivated.worktree_path, "untracked.txt")) == "preserve\n"
    assert git!(reactivated.worktree_path, ["rev-parse", "HEAD"]) == head
    assert git!(reactivated.worktree_path, ["show", "HEAD:committed.txt"]) == "commit"

    assert {:ok, _} = release(server, reactivated.workspace_id, :remove)
  end

  test "unauthorized exact-target acquisition does not mutate the retained worktree", %{
    tmp_dir: tmp_dir
  } do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    branch = "test/unauthorized-reactivation"
    base = Path.join(tmp_dir, "worktrees")
    server = start_registry(5_000)
    parent = self()

    assert {:ok, lease} =
             acquire(server, repo, branch, tmp_dir, base,
               task_id: "task-owner",
               principal_id: "agent-owner"
             )

    File.write!(Path.join(lease.worktree_path, "dirty.txt"), "must stay\n")
    before = git!(lease.worktree_path, ["rev-parse", "HEAD"])
    assert {:ok, _} = release(server, lease.workspace_id, :retain)

    spawn(fn ->
      result =
        WorkspaceLeaseRegistry.acquire(
          %{
            repo_path: repo,
            branch: branch,
            worktree_base_dir: base,
            task_id: "task-other",
            principal_id: "agent-other",
            create_worktree: fn _repo, _branch, _params ->
              send(parent, :create_must_not_run)
              {:error, :unexpected_create}
            end
          },
          server: server
        )

      send(parent, {:unauthorized_result, result})
    end)

    assert_receive {:unauthorized_result, {:error, :retained_workspace_not_authorized}}, 2_000
    refute_receive :create_must_not_run, 100
    assert File.read!(Path.join(lease.worktree_path, "dirty.txt")) == "must stay\n"
    assert git!(lease.worktree_path, ["rev-parse", "HEAD"]) == before
  end

  test "retained repo and branch cannot be bypassed with another target path", %{tmp_dir: tmp_dir} do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    branch = "test/retained-target-mismatch"
    base = Path.join(tmp_dir, "worktrees")
    server = start_registry(5_000)
    parent = self()

    assert {:ok, lease} = acquire(server, repo, branch, tmp_dir, base)
    assert {:ok, _} = release(server, lease.workspace_id, :retain)

    assert {:error, :retained_target_mismatch} =
             WorkspaceLeaseRegistry.acquire(
               %{
                 repo_path: repo,
                 branch: branch,
                 worktree_base_dir: Path.join(tmp_dir, "other")
               },
               server: server
             )

    spawn(fn ->
      result =
        WorkspaceLeaseRegistry.acquire(
          %{repo_path: repo, branch: branch, worktree_base_dir: Path.join(tmp_dir, "third")},
          server: server
        )

      send(parent, {:target_mismatch_unauthorized, result})
    end)

    assert_receive {:target_mismatch_unauthorized, {:error, :retained_workspace_not_authorized}},
                   2_000

    refute File.dir?(Path.join(tmp_dir, "other"))
    refute File.dir?(Path.join(tmp_dir, "third"))
  end

  test "identity mismatch fails closed and leaves retained state intact", %{tmp_dir: tmp_dir} do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    branch = "test/retained-identity-mismatch"
    base = Path.join(tmp_dir, "worktrees")
    server = start_registry(5_000)

    assert {:ok, lease} = acquire(server, repo, branch, tmp_dir, base)
    assert {:ok, _} = release(server, lease.workspace_id, :retain)
    File.rm_rf!(lease.worktree_path)
    File.mkdir_p!(lease.worktree_path)

    assert {:error, :retained_identity_mismatch} =
             acquire(server, repo, branch, tmp_dir, base, workspace_id: lease.workspace_id)

    assert retained_count(server) == 1
  end

  test "stale and malformed expiry messages cannot delete a reactivated lease", %{
    tmp_dir: tmp_dir
  } do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    branch = "test/stale-expiry"
    base = Path.join(tmp_dir, "worktrees")
    server = start_registry(5_000)

    assert {:ok, lease} = acquire(server, repo, branch, tmp_dir, base)
    assert {:ok, _} = release(server, lease.workspace_id, :retain)
    {target, generation} = retained_target_and_generation(server)

    assert {:ok, reactivated} =
             acquire(server, repo, branch, tmp_dir, base, workspace_id: lease.workspace_id)

    send(server_pid(server), {:retained_expire, target, generation})
    send(server_pid(server), {:retained_expire, target, make_ref()})
    send(server_pid(server), {:retained_expire, :bad, make_ref()})
    send(server_pid(server), {:retained_expire, target, :forged})
    Process.sleep(100)

    assert File.dir?(reactivated.worktree_path)
    assert active_count(server) == 1
    assert {:ok, _} = release(server, reactivated.workspace_id, :remove)
  end

  test "owner death after retain does not delete the retained worktree", %{tmp_dir: tmp_dir} do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    branch = "test/retained-owner-death"
    base = Path.join(tmp_dir, "worktrees")
    server = start_registry(5_000)
    parent = self()

    owner =
      spawn(fn ->
        {:ok, lease} = acquire(server, repo, branch, tmp_dir, base)
        {:ok, _} = release(server, lease.workspace_id, :retain)
        send(parent, {:retained, lease.worktree_path})
      end)

    assert_receive {:retained, path}, @owner_operation_timeout
    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}, 2_000
    assert File.dir?(path)
    assert retained_count(server) == 1

    {target, _generation} = retained_target_and_generation(server)
    {_repo, _branch, retained_path} = target_key_parts(target)
    assert retained_path == realpath!(path)
  end

  test "owner-death auto-retain of dirty work expires under the shared TTL cleanup path", %{
    tmp_dir: tmp_dir
  } do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    branch = "test/owner-death-ttl-cleanup"
    base = Path.join(tmp_dir, "worktrees")
    # Config clamps TTL to a 1s minimum.
    parent = self()
    task_id = "task-ttl-#{System.unique_integer([:positive])}"
    principal_id = "agent-ttl-#{System.unique_integer([:positive])}"

    archive = fn retained ->
      result =
        Git.archive_branch_evidence_ref(
          retained.repo_path,
          retained.branch,
          retained.task_id,
          retained.workspace_id,
          retained.settlement_tip
        )

      send(parent, {:owner_death_archive, result})
      result
    end

    server = start_registry(1_000, retained_archive: archive)

    owner =
      spawn(fn ->
        {:ok, lease} =
          acquire(server, repo, branch, tmp_dir, base,
            task_id: task_id,
            principal_id: principal_id
          )

        File.write!(Path.join(lease.worktree_path, "dirty.txt"), "expire me\n")
        send(parent, {:leased, lease.worktree_path})
        Process.sleep(:infinity)
      end)

    assert_receive {:leased, path}, @owner_operation_timeout
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 2_000

    assert_eventually(
      fn ->
        assert retained_count(server) == 1
        assert File.dir?(path)
        assert File.exists?(Path.join(path, "dirty.txt"))
      end,
      100
    )

    expected_tip = git!(repo, ["rev-parse", branch])

    # Force absolute deadline past and drive the same expire handler as the timer.
    force_retained_expired(server)
    {target, generation} = retained_target_and_generation(server)
    send(server_pid(server), {:retained_expire, target, generation})

    assert_receive {:owner_death_archive, {:ok, %{hidden_ref: hidden_ref}}}, 2_000

    assert_eventually(
      fn ->
        refute File.dir?(path)
        assert retained_state(server) == {[], []}
      end,
      100
    )

    assert git!(repo, ["rev-parse", hidden_ref]) == expected_tip
  end

  test "expiry cleanup failure retains and retries the exact record", %{tmp_dir: tmp_dir} do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    branch = "test/retained-retry"
    base = Path.join(tmp_dir, "worktrees")
    parent = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    cleanup = fn retained ->
      attempt = Agent.get_and_update(attempts, fn n -> {n + 1, n + 1} end)
      send(parent, {:cleanup_attempt, attempt})
      _ = retained
      {:error, :injected_cleanup_failure}
    end

    server = start_registry(50, retained_cleanup: cleanup)
    task_id = "task-retained-retry-#{System.unique_integer([:positive])}"
    principal_id = "agent-retained-retry"

    assert {:ok, lease} =
             acquire(server, repo, branch, tmp_dir, base,
               task_id: task_id,
               principal_id: principal_id
             )

    assert {:ok, _} = release(server, lease.workspace_id, :retain)
    force_retained_expired(server)
    {target, generation} = retained_target_and_generation(server)
    send(server_pid(server), {:retained_expire, target, generation})
    assert_receive {:cleanup_attempt, 1}, 2_000
    assert retained_count(server) == 1
    assert File.dir?(lease.worktree_path)
    assert_receive {:cleanup_attempt, 2}, 2_000
    assert retained_count(server) == 1
    assert File.dir?(lease.worktree_path)

    Enum.each(3..6, fn expected_retry_count ->
      {target, generation} = retained_target_and_generation(server)
      send(server_pid(server), {:retained_expire, target, generation})

      assert_eventually(
        fn -> assert retained_record(server).retry_count >= expected_retry_count end,
        20
      )
    end)

    assert is_reference(retained_record(server).expiry_ref)
  end

  test "throwing retained cleanup callback is contained and remains scheduled", %{
    tmp_dir: tmp_dir
  } do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    server = start_registry(50, retained_cleanup: fn _retained -> throw(:cleanup_boom) end)

    assert {:ok, lease} =
             acquire(server, repo, "test/throwing-cleanup", tmp_dir, nil,
               task_id: "task-throwing-cleanup",
               principal_id: "agent-throwing-cleanup"
             )

    assert {:ok, _} = release(server, lease.workspace_id, :retain)

    assert_eventually(fn -> assert retained_record(server).retry_count >= 1 end, 100)
    assert Process.alive?(server_pid(server))
    assert retained_count(server) == 1
  end

  test "duplicate release and reactivation are serialized and idempotent", %{tmp_dir: tmp_dir} do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    branch = "test/retained-duplicates"
    base = Path.join(tmp_dir, "worktrees")
    server = start_registry(5_000)

    assert {:ok, lease} = acquire(server, repo, branch, tmp_dir, base)
    assert {:ok, _} = release(server, lease.workspace_id, :retain)
    assert {:ok, %{status: "already_released"}} = release(server, lease.workspace_id, :retain)
    assert {:ok, active} = acquire(server, repo, branch, tmp_dir, base)
    assert {:error, :workspace_in_use} = acquire(server, repo, branch, tmp_dir, base)
    assert {:ok, _} = release(server, active.workspace_id, :remove)
  end

  test "injected create_worktree remains compatible with identity-bound remove", %{
    tmp_dir: tmp_dir
  } do
    # Keep production identity checks fail-closed: the inject still creates a
    # real registered worktree so remove can revalidate path/lstat/branch.
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    branch = "test/fake-callback"
    base = Path.join(tmp_dir, "worktrees")
    path = expected_worktree_path(base, branch)
    git!(repo, ["branch", branch])
    git!(repo, ["worktree", "add", path, branch])
    base_commit = git!(path, ["rev-parse", "HEAD"])

    server = start_registry(5_000)

    assert {:ok, lease} =
             WorkspaceLeaseRegistry.acquire(
               %{
                 repo_path: repo,
                 branch: branch,
                 worktree_base_dir: base,
                 worktree_path: path,
                 create_worktree: fn acquired_repo, acquired_branch, _params ->
                   assert acquired_repo == Path.expand(repo) or
                            acquired_repo == realpath!(repo)

                   assert acquired_branch == branch
                   {:ok, path, :owned, base_commit}
                 end
               },
               server: server
             )

    assert lease.ownership == "owned"
    assert File.dir?(path)
    assert {:ok, _} = release(server, lease.workspace_id, :remove)
    refute File.dir?(path)
  end

  test "both-absent retained marker settles without destructive work via settle_task_workspaces",
       %{tmp_dir: tmp_dir} do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    branch = "test/both-absent-settle"
    base = Path.join(tmp_dir, "worktrees")
    task_id = "task_both_absent_#{System.unique_integer([:positive])}"
    principal_id = "agent_both_absent"
    server = start_registry(60_000)

    assert {:ok, lease} =
             acquire(server, repo, branch, tmp_dir, base,
               task_id: task_id,
               principal_id: principal_id
             )

    assert {:ok, _} =
             WorkspaceLeaseRegistry.release(lease.workspace_id, :retain, %{
               server: server,
               task_id: task_id,
               principal_id: principal_id
             })

    assert retained_count(server) == 1

    # Simulate the benchmark bug: parent pair_root deleted under retained leases
    # so both the recorded repo clone and worktree path are positively absent.
    File.rm_rf!(lease.worktree_path)
    File.rm_rf!(repo)
    assert {:error, :enoent} = File.lstat(lease.worktree_path)
    assert {:error, :enoent} = File.lstat(repo)

    assert {:ok, receipt} =
             WorkspaceLeaseRegistry.settle_task_workspaces(task_id, principal_id, server: server)

    assert receipt["status"] == "settled"
    assert receipt["settled_count"] == 1
    assert lease.workspace_id in receipt["workspace_ids"]
    assert retained_count(server) == 0

    # Idempotent: second settle finds nothing and succeeds.
    assert {:ok, empty} =
             WorkspaceLeaseRegistry.settle_task_workspaces(task_id, principal_id, server: server)

    assert empty["settled_count"] == 0
  end

  test "security regression: present path with identity mismatch remains fail-closed on settle",
       %{tmp_dir: tmp_dir} do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    branch = "test/settle-identity-mismatch"
    base = Path.join(tmp_dir, "worktrees")
    task_id = "task_settle_mismatch_#{System.unique_integer([:positive])}"
    principal_id = "agent_settle_mismatch"
    server = start_registry(60_000)

    assert {:ok, lease} =
             acquire(server, repo, branch, tmp_dir, base,
               task_id: task_id,
               principal_id: principal_id
             )

    assert {:ok, _} =
             WorkspaceLeaseRegistry.release(lease.workspace_id, :retain, %{
               server: server,
               task_id: task_id,
               principal_id: principal_id
             })

    # Replace worktree contents so the path is present but identity mismatches.
    File.rm_rf!(lease.worktree_path)
    File.mkdir_p!(lease.worktree_path)
    File.write!(Path.join(lease.worktree_path, "forged.txt"), "forged\n")

    assert {:error, {:workspace_settlement_unconfirmed, failures}} =
             WorkspaceLeaseRegistry.settle_task_workspaces(task_id, principal_id, server: server)

    assert Enum.any?(failures, fn {id, _reason} -> id == lease.workspace_id end)
    assert retained_count(server) == 1
    assert File.dir?(lease.worktree_path)

    # Clean the retained record via both-absent settle so ActionCase on_exit
    # does not raw-delete under a live retained marker.
    File.rm_rf!(lease.worktree_path)
    File.rm_rf!(repo)

    assert {:ok, cleaned} =
             WorkspaceLeaseRegistry.settle_task_workspaces(task_id, principal_id, server: server)

    assert cleaned["settled_count"] == 1
    assert retained_count(server) == 0
  end

  test "active lease with both paths absent settles non-destructively via settle_task_workspaces",
       %{tmp_dir: tmp_dir} do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    branch = "test/active-both-absent"
    base = Path.join(tmp_dir, "worktrees")
    task_id = "task_active_both_absent_#{System.unique_integer([:positive])}"
    principal_id = "agent_active_both_absent"
    server = start_registry(60_000)

    assert {:ok, lease} =
             acquire(server, repo, branch, tmp_dir, base,
               task_id: task_id,
               principal_id: principal_id
             )

    assert active_count(server) == 1

    # Parent deleted while the lease is still active (owner process may be gone
    # or still alive — settle must drop without destructive work).
    File.rm_rf!(lease.worktree_path)
    File.rm_rf!(repo)
    assert {:error, :enoent} = File.lstat(lease.worktree_path)
    assert {:error, :enoent} = File.lstat(repo)

    assert {:ok, receipt} =
             WorkspaceLeaseRegistry.settle_task_workspaces(task_id, principal_id, server: server)

    assert receipt["status"] == "settled"
    assert receipt["settled_count"] == 1
    assert lease.workspace_id in receipt["workspace_ids"]
    assert active_count(server) == 0
    assert retained_count(server) == 0
  end

  test "public Actions facade settles task-scoped workspaces", %{tmp_dir: tmp_dir} do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    branch = "test/facade-settle"
    base = Path.join(tmp_dir, "worktrees")
    task_id = "task_facade_settle_#{System.unique_integer([:positive])}"
    principal_id = "agent_facade_settle"
    server = start_registry(5_000)

    assert {:ok, lease} =
             acquire(server, repo, branch, tmp_dir, base,
               task_id: task_id,
               principal_id: principal_id
             )

    assert {:ok, receipt} =
             Actions.settle_coding_workspaces(task_id, principal_id, server: server)

    assert receipt["status"] == "settled"
    assert receipt["settled_count"] == 1
    assert lease.workspace_id in receipt["workspace_ids"]
    refute File.dir?(lease.worktree_path)
    assert active_count(server) == 0
    assert retained_count(server) == 0
  end

  test "security regression: settle requires exact task and principal", %{tmp_dir: tmp_dir} do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    branch = "test/settle-auth"
    base = Path.join(tmp_dir, "worktrees")
    task_id = "task_settle_auth_#{System.unique_integer([:positive])}"
    principal_id = "agent_settle_auth"
    server = start_registry(60_000)

    assert {:error, :invalid_task_principal} =
             WorkspaceLeaseRegistry.settle_task_workspaces(" \t", principal_id, server: server)

    assert {:ok, lease} =
             acquire(server, repo, branch, tmp_dir, base,
               task_id: task_id,
               principal_id: principal_id
             )

    assert {:ok, _} =
             WorkspaceLeaseRegistry.release(lease.workspace_id, :retain, %{
               server: server,
               task_id: task_id,
               principal_id: principal_id
             })

    assert {:ok, empty} =
             WorkspaceLeaseRegistry.settle_task_workspaces("other_task", principal_id,
               server: server
             )

    assert empty["settled_count"] == 0
    assert retained_count(server) == 1

    assert {:ok, empty2} =
             WorkspaceLeaseRegistry.settle_task_workspaces(task_id, "other_principal",
               server: server
             )

    assert empty2["settled_count"] == 0
    assert retained_count(server) == 1
    assert File.dir?(lease.worktree_path)
  end

  defp start_registry(ttl_ms, opts \\ []) do
    name = String.to_atom("workspace_retention_#{System.unique_integer([:positive])}")

    start_supervised!(
      {WorkspaceLeaseRegistry, Keyword.merge([name: name, retention_ttl_ms: ttl_ms], opts)}
    )

    name
  end

  defp server_pid(server), do: Process.whereis(server)

  defp acquire(server, repo, branch, tmp_dir, base),
    do: acquire(server, repo, branch, tmp_dir, base, [])

  defp acquire(server, repo, branch, tmp_dir, base, opts) do
    attrs =
      %{
        repo_path: repo,
        branch: branch,
        worktree_base_dir: base || Path.join(tmp_dir, "worktrees")
      }
      |> Map.merge(Map.new(opts))

    WorkspaceLeaseRegistry.acquire(attrs, server: server)
  end

  defp release(server, workspace_id, mode),
    do: WorkspaceLeaseRegistry.release(workspace_id, mode, %{server: server})

  defp retained_state(server) do
    state = :sys.get_state(server_pid(server))
    {Map.keys(state.retained_by_id), Map.keys(state.retained_by_target)}
  end

  defp retained_count(server), do: map_size(:sys.get_state(server_pid(server)).retained_by_id)
  defp active_count(server), do: map_size(:sys.get_state(server_pid(server)).leases)

  defp retained_record(server) do
    [{_id, retained}] = Map.to_list(:sys.get_state(server_pid(server)).retained_by_id)
    retained
  end

  defp retained_target_and_generation(server) do
    [{target, retained}] = Map.to_list(:sys.get_state(server_pid(server)).retained_by_target)
    {target, retained.expiry_generation}
  end

  defp target_key_parts({:workspace_target, repo, branch, path}), do: {repo, branch, path}

  defp force_retained_expired(server) do
    pid = server_pid(server)
    now = System.monotonic_time(:millisecond)

    :sys.replace_state(pid, fn state ->
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

  defp assert_eventually(fun, attempts)
       when attempts > 0 do
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

  defp expected_worktree_path(base_dir, branch),
    do: Path.join(base_dir, Workspace.worktree_dir_name(branch))

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp realpath!(path) do
    {output, 0} = System.cmd("realpath", [path], stderr_to_stdout: true)
    String.trim(output)
  end
end
