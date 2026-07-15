defmodule Arbor.Actions.Coding.WorkspaceLeaseTest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Contracts.Security.AuthContext

  @moduletag :fast

  describe "discovery and canonical URIs" do
    test "workspace lease actions are discoverable under the coding category" do
      coding = Actions.list_actions().coding

      assert Workspace.Acquire in coding
      assert Workspace.Inspect in coding
      assert Workspace.Release in coding
      assert Workspace.CommittedChange in coding

      assert {:ok, Workspace.Acquire} = Actions.name_to_module("coding.workspace.acquire")
      assert {:ok, Workspace.Inspect} = Actions.name_to_module("coding.workspace.inspect")
      assert {:ok, Workspace.Release} = Actions.name_to_module("coding.workspace.release")

      assert {:ok, Workspace.CommittedChange} =
               Actions.name_to_module("coding.workspace.committed_change")

      assert {:ok, Workspace.CommittedChange} =
               Actions.name_to_module("coding_workspace_committed_change")

      assert Actions.canonical_uri_for(Workspace.Acquire, %{}) ==
               "arbor://action/coding/workspace/acquire"

      assert Actions.canonical_uri_for(Workspace.Inspect, %{}) ==
               "arbor://action/coding/workspace/inspect"

      assert Actions.canonical_uri_for(Workspace.Release, %{}) ==
               "arbor://action/coding/workspace/release"

      assert Actions.canonical_uri_for(Workspace.CommittedChange, %{}) ==
               "arbor://action/coding/workspace/committed_change"

      assert Workspace.Acquire.name() == "coding_workspace_acquire"
      assert Workspace.Inspect.name() == "coding_workspace_inspect"
      assert Workspace.Release.name() == "coding_workspace_release"
      assert Workspace.CommittedChange.name() == "coding_workspace_committed_change"
      assert Workspace.Acquire.category() == "coding"
    end
  end

  describe "Workspace.Acquire / Inspect / Release" do
    test "acquire returns JSON-clean lease metadata and inspect sees live workspace state", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      base_commit = git!(repo, ["rev-parse", "HEAD"])
      branch = "test/workspace-acquire"
      worktree_base = Path.join(tmp_dir, "worktrees")

      assert {:ok, lease} =
               Workspace.Acquire.run(
                 %{
                   repo_path: repo,
                   branch_name: branch,
                   worktree_base_dir: worktree_base,
                   base_ref: "HEAD"
                 },
                 %{}
               )

      assert Workspace.json_clean?(lease)
      refute_pid_like(lease)

      assert is_binary(lease.workspace_id)
      assert String.starts_with?(lease.workspace_id, "ws_")
      # git resolves the canonical toplevel (may differ from the input path on macOS).
      assert lease.repo_path == git!(repo, ["rev-parse", "--show-toplevel"])
      assert File.dir?(lease.worktree_path)
      assert lease.branch == branch
      assert lease.base_commit == base_commit
      assert lease.ownership == "owned"
      assert lease.active == true

      assert {:ok, inspected} =
               Workspace.Inspect.run(%{workspace_id: lease.workspace_id}, %{})

      assert Workspace.json_clean?(inspected)
      refute_pid_like(inspected)
      assert inspected.workspace_id == lease.workspace_id
      assert inspected.worktree_path == lease.worktree_path
      assert inspected.ownership == "owned"
      assert inspected.active == true
      assert inspected.exists == true
      assert inspected.dirty == false
      assert inspected.head_commit == base_commit
      assert inspected.changed_from_base == false
      assert is_binary(inspected.fingerprint)
      assert String.starts_with?(inspected.fingerprint, "sha256:")
      assert inspected.turn_progressed == true

      File.write!(Path.join(lease.worktree_path, "dirty.txt"), "uncommitted\n")

      assert {:ok, dirty_view} =
               Workspace.Inspect.run(%{workspace_id: lease.workspace_id}, %{})

      assert dirty_view.dirty == true
      assert dirty_view.changed_from_base == true
      assert dirty_view.head_commit == base_commit
      assert dirty_view.fingerprint != inspected.fingerprint

      assert {:ok, compared} =
               Workspace.Inspect.run(
                 %{
                   workspace_id: lease.workspace_id,
                   baseline_fingerprint: inspected.fingerprint
                 },
                 %{}
               )

      assert compared.turn_progressed == true
      assert compared.fingerprint == dirty_view.fingerprint

      assert {:ok, no_progress} =
               Workspace.Inspect.run(
                 %{
                   workspace_id: lease.workspace_id,
                   baseline_fingerprint: dirty_view.fingerprint
                 },
                 %{}
               )

      assert no_progress.turn_progressed == false
      assert no_progress.fingerprint == dirty_view.fingerprint

      File.write!(Path.join(lease.worktree_path, "dirty.txt"), "different content\n")

      assert {:ok, edited_dirty_view} =
               Workspace.Inspect.run(
                 %{
                   workspace_id: lease.workspace_id,
                   baseline_fingerprint: dirty_view.fingerprint
                 },
                 %{}
               )

      assert edited_dirty_view.turn_progressed == true
      assert edited_dirty_view.fingerprint != dirty_view.fingerprint

      git!(lease.worktree_path, ["add", "dirty.txt"])

      assert {:ok, staged_view} =
               Workspace.Inspect.run(
                 %{
                   workspace_id: lease.workspace_id,
                   baseline_fingerprint: edited_dirty_view.fingerprint
                 },
                 %{}
               )

      assert staged_view.turn_progressed == true
      assert staged_view.fingerprint != edited_dirty_view.fingerprint

      File.write!(Path.join(lease.worktree_path, "dirty.txt"), "staged plus unstaged\n")

      assert {:ok, staged_and_edited_view} =
               Workspace.Inspect.run(
                 %{
                   workspace_id: lease.workspace_id,
                   baseline_fingerprint: staged_view.fingerprint
                 },
                 %{}
               )

      assert staged_and_edited_view.turn_progressed == true
      assert staged_and_edited_view.fingerprint != staged_view.fingerprint
    end

    test "inspect_worktree reports missing path without treating it as no_changes", %{
      tmp_dir: tmp_dir
    } do
      missing = Path.join(tmp_dir, "gone-worktree")
      view = Workspace.inspect_worktree(missing, "basecommit")

      assert view.exists == false
      assert view.changed_from_base == false
      assert view.fingerprint == "sha256:missing-worktree"
      assert is_binary(view.fingerprint)
    end

    test "retain disarms cleanup, preserves worktree, and is idempotent", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/workspace-retain"
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

      File.write!(Path.join(lease.worktree_path, "keep.txt"), "kept\n")

      assert {:ok, retained} =
               Workspace.Release.run(
                 %{workspace_id: lease.workspace_id, mode: "retain"},
                 %{}
               )

      assert Workspace.json_clean?(retained)
      assert retained.status == "retained"
      assert retained.active == false
      assert File.dir?(lease.worktree_path)
      assert File.exists?(Path.join(lease.worktree_path, "keep.txt"))

      # After retain, inspect no longer finds an active lease.
      assert {:error, :not_found} =
               Workspace.Inspect.run(%{workspace_id: lease.workspace_id}, %{})

      assert {:ok, again} =
               Workspace.Release.run(
                 %{workspace_id: lease.workspace_id, mode: "retain"},
                 %{}
               )

      assert again.status == "already_released"
      assert again.active == false
      assert File.dir?(lease.worktree_path)
    end

    test "explicit remove deletes owned worktrees and is idempotent", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/workspace-remove"
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
      assert File.dir?(worktree_path)

      assert {:ok, removed} =
               Workspace.Release.run(
                 %{workspace_id: lease.workspace_id, mode: "remove"},
                 %{}
               )

      assert removed.status == "removed"
      assert removed.active == false
      refute File.dir?(worktree_path)

      assert {:ok, again} =
               Workspace.Release.run(
                 %{workspace_id: lease.workspace_id, mode: "remove"},
                 %{}
               )

      assert again.status == "already_released"
    end

    test "remove preserves reused worktrees", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/workspace-remove-reused"
      worktree_base = Path.join(tmp_dir, "worktrees")
      File.mkdir_p!(worktree_base)

      worktree_path = expected_worktree_path(worktree_base, branch)
      git!(repo, ["branch", branch])
      git!(repo, ["worktree", "add", worktree_path, branch])
      # Commit a tracked marker so acquire's reset/clean does not erase evidence
      # that the path itself must survive an explicit remove of a reused lease.
      File.write!(Path.join(worktree_path, "preexisting.txt"), "keep\n")
      git!(worktree_path, ["add", "preexisting.txt"])
      git!(worktree_path, ["commit", "-m", "preexisting marker"])

      assert {:ok, lease} =
               Workspace.Acquire.run(
                 %{
                   repo_path: repo,
                   branch_name: branch,
                   worktree_base_dir: worktree_base
                 },
                 %{}
               )

      assert lease.ownership == "reused"
      assert lease.worktree_path == worktree_path

      assert {:ok, removed} =
               Workspace.Release.run(
                 %{workspace_id: lease.workspace_id, mode: "remove"},
                 %{}
               )

      assert removed.status == "removed"
      assert File.dir?(worktree_path)
      assert worktree_registered?(repo, worktree_path)
      assert git!(worktree_path, ["rev-parse", "--is-inside-work-tree"]) == "true"
      assert git!(worktree_path, ["branch", "--show-current"]) == branch
    end

    test "inspect and release are scoped to the lease owner", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/workspace-owner-scope"
      parent = self()

      owner =
        spawn(fn ->
          {:ok, lease} =
            Workspace.Acquire.run(
              %{
                repo_path: repo,
                branch_name: branch,
                worktree_base_dir: Path.join(tmp_dir, "worktrees")
              },
              %{}
            )

          send(parent, {:leased, lease})

          receive do
            :hold -> :ok
          after
            5_000 -> :ok
          end
        end)

      assert_receive {:leased, lease}, 2_000

      # Different process without matching task+principal cannot inspect or release.
      assert {:error, :not_authorized} =
               Workspace.Inspect.run(%{workspace_id: lease.workspace_id}, %{})

      assert {:error, :not_authorized} =
               Workspace.Release.run(
                 %{workspace_id: lease.workspace_id, mode: "retain"},
                 %{}
               )

      # Matching non-empty task_id AND principal_id authorizes resume.
      task_id = "task_resume_#{System.unique_integer([:positive])}"
      principal_id = "agent_resume_#{System.unique_integer([:positive])}"

      resume_owner =
        spawn(fn ->
          {:ok, lease2} =
            Workspace.Acquire.run(
              %{
                repo_path: repo,
                branch_name: "test/workspace-task-scope",
                worktree_base_dir: Path.join(tmp_dir, "worktrees-task")
              },
              %{task_id: task_id, agent_id: principal_id}
            )

          send(parent, {:task_leased, lease2})

          receive do
            :hold -> :ok
          after
            5_000 -> :ok
          end
        end)

      assert_receive {:task_leased, task_lease}, 2_000

      assert {:ok, inspected} =
               Workspace.Inspect.run(%{workspace_id: task_lease.workspace_id}, %{
                 task_id: task_id,
                 agent_id: principal_id
               })

      assert inspected.workspace_id == task_lease.workspace_id

      assert {:ok, retained} =
               Workspace.Release.run(
                 %{workspace_id: task_lease.workspace_id, mode: "retain"},
                 %{task_id: task_id, agent_id: principal_id}
               )

      assert retained.status == "retained"

      # Opaque id alone is never enough (empty task_id must not match).
      assert {:error, :not_authorized} =
               Workspace.Inspect.run(%{workspace_id: lease.workspace_id}, %{task_id: ""})

      # Keep owners alive until assertions complete.
      send(owner, :hold)
      send(resume_owner, :hold)
    end

    test "security regression: task_id alone without principal does not authorize resume", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()
      task_id = "task_predictable_#{System.unique_integer([:positive])}"
      principal_id = "agent_owner_#{System.unique_integer([:positive])}"

      owner =
        spawn(fn ->
          {:ok, lease} =
            Workspace.Acquire.run(
              %{
                repo_path: repo,
                branch_name: "test/workspace-principal-auth",
                worktree_base_dir: Path.join(tmp_dir, "worktrees")
              },
              %{task_id: task_id, agent_id: principal_id}
            )

          send(parent, {:leased, lease})

          receive do
            :hold -> :ok
          after
            5_000 -> :ok
          end
        end)

      assert_receive {:leased, lease}, 2_000

      # Matching task_id with missing principal must be denied.
      assert {:error, :not_authorized} =
               Workspace.Inspect.run(%{workspace_id: lease.workspace_id}, %{task_id: task_id})

      # Matching task_id with a different principal must be denied.
      assert {:error, :not_authorized} =
               Workspace.Inspect.run(%{workspace_id: lease.workspace_id}, %{
                 task_id: task_id,
                 agent_id: "agent_other"
               })

      assert {:error, :not_authorized} =
               Workspace.Release.run(
                 %{workspace_id: lease.workspace_id, mode: "retain"},
                 %{task_id: task_id}
               )

      # Both non-empty ids matching the lease authorizes resume.
      assert {:ok, inspected} =
               Workspace.Inspect.run(%{workspace_id: lease.workspace_id}, %{
                 task_id: task_id,
                 agent_id: principal_id
               })

      assert inspected.workspace_id == lease.workspace_id

      send(owner, :hold)
    end

    test "production AuthContext principal authorizes cross-process inspect/release", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()
      task_id = "task_authctx_#{System.unique_integer([:positive])}"
      principal_id = "agent_authctx_#{System.unique_integer([:positive])}"
      auth_context = AuthContext.new(principal_id)

      owner =
        spawn(fn ->
          {:ok, lease} =
            Workspace.Acquire.run(
              %{
                repo_path: repo,
                branch_name: "test/workspace-auth-context",
                worktree_base_dir: Path.join(tmp_dir, "worktrees")
              },
              %{auth_context: auth_context, task_id: task_id}
            )

          send(parent, {:leased, lease})

          receive do
            :hold -> :ok
          after
            5_000 -> :ok
          end
        end)

      assert_receive {:leased, lease}, 2_000

      # Same AuthContext principal + task (production ActionsExecutor shape).
      resume_context = %{auth_context: AuthContext.new(principal_id), task_id: task_id}

      assert {:ok, inspected} =
               Workspace.Inspect.run(%{workspace_id: lease.workspace_id}, resume_context)

      assert inspected.workspace_id == lease.workspace_id

      # Different principal with matching task is denied.
      assert {:error, :not_authorized} =
               Workspace.Inspect.run(%{workspace_id: lease.workspace_id}, %{
                 auth_context: AuthContext.new("agent_other"),
                 task_id: task_id
               })

      assert {:error, :not_authorized} =
               Workspace.Release.run(
                 %{workspace_id: lease.workspace_id, mode: "retain"},
                 %{auth_context: AuthContext.new("agent_other"), task_id: task_id}
               )

      assert {:ok, retained} =
               Workspace.Release.run(
                 %{workspace_id: lease.workspace_id, mode: "retain"},
                 resume_context
               )

      assert retained.status == "retained"

      send(owner, :hold)
    end

    test "owner death retains dirty owned work and reactivates for exact task+principal", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/workspace-owner-death-dirty"
      worktree_base = Path.join(tmp_dir, "worktrees")
      task_id = "task-owner-death-dirty-#{System.unique_integer([:positive])}"
      principal_id = "agent-owner-death-dirty-#{System.unique_integer([:positive])}"
      parent = self()

      server = :"workspace_owner_death_dirty_#{System.unique_integer([:positive])}"

      start_supervised!(
        {WorkspaceLeaseRegistry,
         name: server,
         retention_ttl_ms: 5_000,
         linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer}
      )

      owner =
        spawn(fn ->
          {:ok, lease} =
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

          File.write!(Path.join(lease.worktree_path, "dirty.txt"), "uncommitted\n")
          send(parent, {:leased, lease})
          Process.sleep(:infinity)
        end)

      assert_receive {:leased, lease}, 2_000
      assert File.dir?(lease.worktree_path)
      assert File.exists?(Path.join(lease.worktree_path, "dirty.txt"))
      assert lease.ownership == "owned"

      owner_ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 2_000

      assert_eventually(
        fn ->
          assert File.dir?(lease.worktree_path)
          assert File.exists?(Path.join(lease.worktree_path, "dirty.txt"))
          assert map_size(:sys.get_state(server).retained_by_id) == 1
          assert map_size(:sys.get_state(server).leases) == 0
        end,
        250
      )

      assert {:error, :retained_workspace_not_authorized} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: branch,
                   worktree_base_dir: worktree_base,
                   task_id: "task-other",
                   principal_id: "agent-other"
                 },
                 server: server
               )

      assert File.exists?(Path.join(lease.worktree_path, "dirty.txt"))

      assert {:ok, reactivated} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: branch,
                   worktree_base_dir: worktree_base,
                   task_id: task_id,
                   principal_id: principal_id,
                   workspace_id: lease.workspace_id
                 },
                 server: server
               )

      assert reactivated.ownership == "owned"
      assert File.read!(Path.join(reactivated.worktree_path, "dirty.txt")) == "uncommitted\n"

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(reactivated.workspace_id, :remove, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      refute File.dir?(lease.worktree_path)
    end

    test "owner death sees untracked work even when repository status config hides it", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/workspace-owner-death-hidden-untracked"
      worktree_base = Path.join(tmp_dir, "worktrees")
      task_id = "task-hidden-untracked-#{System.unique_integer([:positive])}"
      principal_id = "agent-hidden-untracked-#{System.unique_integer([:positive])}"
      parent = self()
      server = :"workspace_hidden_untracked_#{System.unique_integer([:positive])}"

      start_supervised!(
        {WorkspaceLeaseRegistry,
         name: server,
         retention_ttl_ms: 5_000,
         linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer}
      )

      owner =
        spawn(fn ->
          {:ok, lease} =
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

          git!(lease.worktree_path, ["config", "status.showUntrackedFiles", "no"])
          File.write!(Path.join(lease.worktree_path, "hidden-by-config.txt"), "keep me\n")
          assert git!(lease.worktree_path, ["status", "--porcelain"]) == ""
          send(parent, {:leased, lease})
          Process.sleep(:infinity)
        end)

      assert_receive {:leased, lease}, 2_000
      assert Workspace.inspect_worktree(lease.worktree_path, lease.base_commit).dirty
      Process.exit(owner, :kill)

      assert_eventually(fn ->
        assert File.read!(Path.join(lease.worktree_path, "hidden-by-config.txt")) == "keep me\n"
        assert map_size(:sys.get_state(server).retained_by_id) == 1
      end)

      assert {:ok, reactivated} =
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

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(reactivated.workspace_id, :remove, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })
    end

    test "security regression: reactivated identity-invalid quarantine cannot force-remove and survives another owner death",
         %{
           tmp_dir: tmp_dir
         } do
      fake_repo = Path.join(tmp_dir, "fake-repo")
      fake_worktree = Path.join(tmp_dir, "fake-worktree")
      File.mkdir_p!(fake_repo)
      File.mkdir_p!(fake_worktree)
      File.write!(Path.join(fake_worktree, "partial.txt"), "recoverable\n")

      branch = "test/workspace-owner-death-quarantine"
      workspace_id = "ws_quarantine_#{System.unique_integer([:positive])}"
      task_id = "task-quarantine-#{System.unique_integer([:positive])}"
      principal_id = "agent-quarantine-#{System.unique_integer([:positive])}"
      parent = self()
      server = :"workspace_quarantine_#{System.unique_integer([:positive])}"

      start_supervised!(
        {WorkspaceLeaseRegistry,
         name: server,
         retention_ttl_ms: 50,
         owner_death_retry_base_ms: 100,
         linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer}
      )

      create_worktree = fn _repo, _branch, _params ->
        {:ok, fake_worktree, :owned, String.duplicate("a", 40)}
      end

      owner =
        spawn(fn ->
          result =
            WorkspaceLeaseRegistry.acquire(
              %{
                workspace_id: workspace_id,
                repo_path: fake_repo,
                branch: branch,
                worktree_path: fake_worktree,
                task_id: task_id,
                principal_id: principal_id,
                create_worktree: create_worktree
              },
              server: server
            )

          send(parent, {:leased, result})
          Process.sleep(:infinity)
        end)

      assert_receive {:leased, {:ok, lease}}, 2_000
      Process.exit(owner, :kill)

      assert_eventually(fn ->
        state = :sys.get_state(server)
        quarantined = Map.fetch!(state.leases, workspace_id)
        assert quarantined.cleanup_armed == false
        assert is_reference(quarantined.owner_death_retry_ref)
        assert map_size(state.retained_by_id) == 0
        assert File.read!(Path.join(fake_worktree, "partial.txt")) == "recoverable\n"
      end)

      quarantined = Map.fetch!(:sys.get_state(server).leases, workspace_id)
      assert quarantined.owner_death_policy == :retention_identity_unavailable
      assert quarantined.task_id == task_id
      assert quarantined.principal_id == principal_id
      assert quarantined.repo_path == Path.expand(fake_repo)
      assert quarantined.branch == branch
      assert Path.expand(quarantined.worktree_path) == Path.expand(fake_worktree)
      refute Process.alive?(quarantined.owner_pid)

      assert {:error, :workspace_in_use} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   workspace_id: workspace_id,
                   repo_path: fake_repo,
                   branch: branch,
                   worktree_path: fake_worktree,
                   task_id: "task-other",
                   principal_id: "agent-other",
                   create_worktree: create_worktree
                 },
                 server: server
               )

      recovery_owner =
        spawn(fn ->
          result =
            WorkspaceLeaseRegistry.acquire(
              %{
                workspace_id: workspace_id,
                repo_path: fake_repo,
                branch: branch,
                worktree_path: fake_worktree,
                task_id: task_id,
                principal_id: principal_id,
                create_worktree: create_worktree
              },
              server: server
            )

          send(parent, {:reactivated, result})
          Process.sleep(:infinity)
        end)

      assert_receive {:reactivated, {:ok, reactivated}}, 2_000

      state = :sys.get_state(server)
      active = Map.fetch!(state.leases, workspace_id)
      assert active.cleanup_armed == true
      assert active.owner_death_deletion_disabled == true
      assert Map.has_key?(state.by_ref, active.owner_ref)
      assert active.owner_death_retry_ref == nil
      assert reactivated.workspace_id == lease.workspace_id

      assert {:error, :quarantine_identity_unavailable} =
               WorkspaceLeaseRegistry.release(workspace_id, :remove, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert File.read!(Path.join(fake_worktree, "partial.txt")) == "recoverable\n"

      Process.exit(recovery_owner, :kill)

      assert_eventually(fn ->
        again = Map.fetch!(:sys.get_state(server).leases, workspace_id)
        assert again.cleanup_armed == false
        assert again.owner_death_deletion_disabled == true
        assert is_reference(again.owner_death_retry_ref)
      end)

      assert {:ok, recovered} =
               WorkspaceLeaseRegistry.inspect_lease(workspace_id, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert recovered.workspace_id == workspace_id
    end

    test "identity quarantine retry captures a newly provable worktree and enters bounded retention",
         %{
           tmp_dir: tmp_dir
         } do
      fake_repo = Path.join(tmp_dir, "retry-fake-repo")
      fake_worktree = Path.join(tmp_dir, "retry-fake-worktree")
      File.mkdir_p!(fake_repo)
      File.mkdir_p!(fake_worktree)

      branch = "test/workspace-owner-death-retry"
      workspace_id = "ws_retry_#{System.unique_integer([:positive])}"
      task_id = "task-retry-#{System.unique_integer([:positive])}"
      principal_id = "agent-retry-#{System.unique_integer([:positive])}"
      parent = self()
      server = :"workspace_quarantine_retry_#{System.unique_integer([:positive])}"

      start_supervised!(
        {WorkspaceLeaseRegistry,
         name: server,
         retention_ttl_ms: 5_000,
         owner_death_retry_base_ms: 100,
         owner_death_retry_limit: 3,
         linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer}
      )

      create_worktree = fn _repo, _branch, _params ->
        {:ok, fake_worktree, :owned, String.duplicate("a", 40)}
      end

      owner =
        spawn(fn ->
          result =
            WorkspaceLeaseRegistry.acquire(
              %{
                workspace_id: workspace_id,
                repo_path: fake_repo,
                branch: branch,
                worktree_path: fake_worktree,
                task_id: task_id,
                principal_id: principal_id,
                create_worktree: create_worktree
              },
              server: server
            )

          send(parent, {:leased, result})
          Process.sleep(:infinity)
        end)

      assert_receive {:leased, {:ok, _lease}}, 2_000
      Process.exit(owner, :kill)

      assert_eventually(fn ->
        quarantined = Map.get(:sys.get_state(server).leases, workspace_id)
        assert quarantined.cleanup_armed == false
        assert quarantined.owner_death_retry_count == 1
        assert is_reference(quarantined.owner_death_retry_ref)
      end)

      {:ok, _removed} = File.rm_rf(fake_worktree)
      create_git_repo(fake_repo)
      git!(fake_repo, ["worktree", "add", "-b", branch, fake_worktree])

      assert_eventually(fn ->
        state = :sys.get_state(server)
        assert map_size(state.leases) == 0
        assert map_size(state.retained_by_id) == 1
      end)

      assert {:ok, reactivated} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: fake_repo,
                   branch: branch,
                   worktree_path: fake_worktree,
                   task_id: task_id,
                   principal_id: principal_id,
                   create_worktree: create_worktree
                 },
                 server: server
               )

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(reactivated.workspace_id, :remove, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })
    end

    test "security regression: reactivated quarantine pins deletion identity against path replacement",
         %{
           tmp_dir: tmp_dir
         } do
      fake_repo = Path.join(tmp_dir, "pinned-fake-repo")
      fake_worktree = Path.join(tmp_dir, "pinned-fake-worktree")
      original_copy = fake_worktree <> "-original"
      create_git_repo(fake_repo)
      File.mkdir_p!(fake_worktree)

      branch = "test/workspace-owner-death-pinned"
      workspace_id = "ws_pinned_#{System.unique_integer([:positive])}"
      task_id = "task-pinned-#{System.unique_integer([:positive])}"
      principal_id = "agent-pinned-#{System.unique_integer([:positive])}"
      parent = self()
      server = :"workspace_quarantine_pinned_#{System.unique_integer([:positive])}"

      start_supervised!(
        {WorkspaceLeaseRegistry,
         name: server,
         owner_death_retry_limit: 0,
         linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer}
      )

      create_worktree = fn _repo, _branch, _params ->
        {:ok, fake_worktree, :owned, String.duplicate("a", 40)}
      end

      owner =
        spawn(fn ->
          result =
            WorkspaceLeaseRegistry.acquire(
              %{
                workspace_id: workspace_id,
                repo_path: fake_repo,
                branch: branch,
                worktree_path: fake_worktree,
                task_id: task_id,
                principal_id: principal_id,
                create_worktree: create_worktree
              },
              server: server
            )

          send(parent, {:leased, result})
          Process.sleep(:infinity)
        end)

      assert_receive {:leased, {:ok, _lease}}, 2_000
      Process.exit(owner, :kill)

      assert_eventually(fn ->
        dormant = Map.get(:sys.get_state(server).leases, workspace_id)
        assert is_map(dormant)
        assert Map.get(dormant, :owner_death_quarantine_state) == :dormant
      end)

      {:ok, _removed} = File.rm_rf(fake_worktree)
      git!(fake_repo, ["worktree", "add", "-b", branch, fake_worktree])

      recovery_owner =
        spawn(fn ->
          result =
            WorkspaceLeaseRegistry.acquire(
              %{
                workspace_id: workspace_id,
                repo_path: fake_repo,
                branch: branch,
                worktree_path: fake_worktree,
                task_id: task_id,
                principal_id: principal_id,
                create_worktree: create_worktree
              },
              server: server
            )

          send(parent, {:reactivated, result})
          Process.sleep(:infinity)
        end)

      assert_receive {:reactivated, {:ok, _reactivated}}, 2_000

      active = Map.fetch!(:sys.get_state(server).leases, workspace_id)
      assert is_map(active.owner_death_deletion_identity)

      File.rename!(fake_worktree, original_copy)
      File.cp_r!(original_copy, fake_worktree)
      assert git!(fake_worktree, ["branch", "--show-current"]) == branch

      assert {:error, :quarantine_identity_unavailable} =
               WorkspaceLeaseRegistry.release(workspace_id, :remove, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert File.dir?(fake_worktree)

      Process.exit(recovery_owner, :kill)
      _ = System.cmd("git", ["-C", fake_repo, "worktree", "remove", "--force", fake_worktree])
      {:ok, _removed} = File.rm_rf(original_copy)
    end

    test "identity-invalid quarantine becomes dormant after bounded retries without losing exact authority",
         %{
           tmp_dir: tmp_dir
         } do
      fake_repo = Path.join(tmp_dir, "dormant-fake-repo")
      fake_worktree = Path.join(tmp_dir, "dormant-fake-worktree")
      File.mkdir_p!(fake_repo)
      File.mkdir_p!(fake_worktree)
      File.write!(Path.join(fake_worktree, "preserve.txt"), "do not delete\n")

      branch = "test/workspace-owner-death-dormant"
      workspace_id = "ws_dormant_#{System.unique_integer([:positive])}"
      task_id = "task-dormant-#{System.unique_integer([:positive])}"
      principal_id = "agent-dormant-#{System.unique_integer([:positive])}"
      parent = self()
      server = :"workspace_quarantine_dormant_#{System.unique_integer([:positive])}"

      start_supervised!(
        {WorkspaceLeaseRegistry,
         name: server,
         owner_death_retry_base_ms: 10,
         owner_death_retry_limit: 2,
         linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer}
      )

      create_worktree = fn _repo, _branch, _params ->
        {:ok, fake_worktree, :owned, String.duplicate("a", 40)}
      end

      owner =
        spawn(fn ->
          result =
            WorkspaceLeaseRegistry.acquire(
              %{
                workspace_id: workspace_id,
                repo_path: fake_repo,
                branch: branch,
                worktree_path: fake_worktree,
                task_id: task_id,
                principal_id: principal_id,
                create_worktree: create_worktree
              },
              server: server
            )

          send(parent, {:leased, result})
          Process.sleep(:infinity)
        end)

      assert_receive {:leased, {:ok, _lease}}, 2_000
      Process.exit(owner, :kill)

      assert_eventually(fn ->
        dormant = Map.get(:sys.get_state(server).leases, workspace_id)
        assert dormant.cleanup_armed == false
        assert dormant.owner_death_quarantine_state == :dormant
        assert dormant.owner_death_retry_exhausted == true
        assert dormant.owner_death_retry_count == 2
        assert dormant.owner_death_retry_ref == nil
        assert dormant.owner_death_retry_generation == nil
      end)

      assert File.read!(Path.join(fake_worktree, "preserve.txt")) == "do not delete\n"

      assert {:ok, inspected} =
               WorkspaceLeaseRegistry.inspect_lease(workspace_id, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert inspected.workspace_id == workspace_id

      assert {:error, :quarantine_identity_unavailable} =
               WorkspaceLeaseRegistry.release(workspace_id, :remove, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert File.read!(Path.join(fake_worktree, "preserve.txt")) == "do not delete\n"
    end

    test "owner death retains clean committed HEAD ahead of base for exact task+principal", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/workspace-owner-death-committed"
      worktree_base = Path.join(tmp_dir, "worktrees")
      task_id = "task-owner-death-committed-#{System.unique_integer([:positive])}"
      principal_id = "agent-owner-death-committed-#{System.unique_integer([:positive])}"
      parent = self()

      server = :"workspace_owner_death_committed_#{System.unique_integer([:positive])}"

      start_supervised!(
        {WorkspaceLeaseRegistry,
         name: server,
         retention_ttl_ms: 5_000,
         linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer}
      )

      owner =
        spawn(fn ->
          {:ok, lease} =
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

          File.write!(Path.join(lease.worktree_path, "committed.txt"), "committed progress\n")
          git!(lease.worktree_path, ["add", "committed.txt"])
          git!(lease.worktree_path, ["commit", "-m", "useful committed progress"])
          head = git!(lease.worktree_path, ["rev-parse", "HEAD"])
          send(parent, {:leased, lease, head})
          Process.sleep(:infinity)
        end)

      assert_receive {:leased, lease, head}, 2_000
      assert head != lease.base_commit
      assert File.dir?(lease.worktree_path)

      owner_ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 2_000

      assert_eventually(
        fn ->
          assert File.dir?(lease.worktree_path)
          assert git!(lease.worktree_path, ["rev-parse", "HEAD"]) == head
          assert map_size(:sys.get_state(server).retained_by_id) == 1
        end,
        250
      )

      assert {:ok, reactivated} =
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

      assert git!(reactivated.worktree_path, ["rev-parse", "HEAD"]) == head

      assert git!(reactivated.worktree_path, ["show", "HEAD:committed.txt"]) ==
               "committed progress"

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(reactivated.workspace_id, :remove, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })
    end

    test "owner death retains pristine owned worktrees until recovery or expiry", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/workspace-owner-death-pristine"
      worktree_base = Path.join(tmp_dir, "worktrees")
      task_id = "task-pristine-#{System.unique_integer([:positive])}"
      principal_id = "agent-pristine-#{System.unique_integer([:positive])}"
      parent = self()

      server = :"workspace_owner_death_pristine_#{System.unique_integer([:positive])}"

      start_supervised!(
        {WorkspaceLeaseRegistry,
         name: server,
         retention_ttl_ms: 5_000,
         linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer}
      )

      owner =
        spawn(fn ->
          {:ok, lease} =
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

          send(parent, {:leased, lease})
          Process.sleep(:infinity)
        end)

      assert_receive {:leased, lease}, 2_000
      assert File.dir?(lease.worktree_path)
      assert lease.ownership == "owned"
      assert git!(lease.worktree_path, ["rev-parse", "HEAD"]) == lease.base_commit
      assert git!(lease.worktree_path, ["status", "--porcelain"]) == ""

      owner_ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 2_000

      assert_eventually(fn ->
        assert File.dir?(lease.worktree_path)
        assert map_size(:sys.get_state(server).leases) == 0
        assert map_size(:sys.get_state(server).retained_by_id) == 1
      end)

      assert {:ok, reactivated} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   workspace_id: lease.workspace_id,
                   repo_path: repo,
                   branch: branch,
                   worktree_base_dir: worktree_base,
                   task_id: task_id,
                   principal_id: principal_id
                 },
                 server: server
               )

      assert reactivated.workspace_id == lease.workspace_id

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(reactivated.workspace_id, :remove, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      refute File.dir?(lease.worktree_path)
    end

    test "owner death preserves reused worktrees", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/workspace-owner-death-reused"
      worktree_base = Path.join(tmp_dir, "worktrees")
      File.mkdir_p!(worktree_base)

      worktree_path = expected_worktree_path(worktree_base, branch)
      git!(repo, ["branch", branch])
      git!(repo, ["worktree", "add", worktree_path, branch])
      File.write!(Path.join(worktree_path, "preexisting.txt"), "keep\n")
      git!(worktree_path, ["add", "preexisting.txt"])
      git!(worktree_path, ["commit", "-m", "preexisting marker"])

      parent = self()

      owner =
        spawn(fn ->
          {:ok, lease} =
            Workspace.Acquire.run(
              %{
                repo_path: repo,
                branch_name: branch,
                worktree_base_dir: worktree_base
              },
              %{}
            )

          File.write!(Path.join(lease.worktree_path, "dirty.txt"), "uncommitted\n")
          send(parent, {:leased, lease})

          receive do
            :never -> :ok
          after
            5_000 -> :ok
          end
        end)

      assert_receive {:leased, lease}, 2_000
      assert lease.ownership == "reused"
      assert lease.worktree_path == worktree_path

      Process.exit(owner, :kill)
      Process.sleep(150)

      # Reused path must survive owner death even with dirty uncommitted files.
      assert File.dir?(worktree_path)
      assert worktree_registered?(repo, worktree_path)
      assert git!(worktree_path, ["rev-parse", "--is-inside-work-tree"]) == "true"
      assert git!(worktree_path, ["branch", "--show-current"]) == branch
    end
  end

  describe "registry-owned acquisition boundary" do
    test "caller death during acquire defers owned cleanup to bounded retention expiry", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      repo_root = git!(repo, ["rev-parse", "--show-toplevel"])
      branch = "test/workspace-acquire-cancel"
      worktree_base = Path.join(tmp_dir, "worktrees")
      parent = self()

      # Private registry so the blocked create does not stall the shared app registry.
      server = :"workspace_lease_acquire_cancel_#{System.unique_integer([:positive])}"

      start_supervised!(
        {WorkspaceLeaseRegistry,
         name: server,
         retention_ttl_ms: 300,
         linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer}
      )

      create_fun = fn repo_path, branch_name, params ->
        send(parent, {:create_started, self()})

        receive do
          :proceed ->
            Workspace.create_worktree(repo_path, branch_name, params)
        after
          5_000 ->
            {:error, :create_timeout}
        end
      end

      owner =
        spawn(fn ->
          result =
            WorkspaceLeaseRegistry.acquire(
              %{
                repo_path: repo_root,
                branch: branch,
                worktree_base_dir: worktree_base,
                create_worktree: create_fun
              },
              server: server
            )

          send(parent, {:acquire_result, result})
        end)

      assert_receive {:create_started, registry_pid}, 2_000
      # Owner dies while create is in progress (monitor already armed).
      Process.exit(owner, :kill)
      send(registry_pid, :proceed)

      # Dead caller's GenServer reply is dropped. The newly created tree enters
      # bounded retention instead of being deleted in the owner-DOWN callback.
      refute_receive {:acquire_result, _}, 200

      expected_path = expected_worktree_path(worktree_base, branch)

      assert_eventually(fn ->
        assert File.dir?(expected_path)
        assert map_size(:sys.get_state(server).retained_by_id) == 1
      end)

      assert_eventually(
        fn ->
          refute File.dir?(expected_path)
          assert map_size(:sys.get_state(server).retained_by_id) == 0
        end,
        150
      )

      assert is_pid(registry_pid)
      assert Process.alive?(registry_pid)
    end

    test "workspace_id collision is rejected before create", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      repo_root = git!(repo, ["rev-parse", "--show-toplevel"])
      branch = "test/workspace-id-collision"
      worktree_base = Path.join(tmp_dir, "worktrees")
      workspace_id = "ws_collision_#{System.unique_integer([:positive])}"
      parent = self()

      assert {:ok, first} =
               WorkspaceLeaseRegistry.acquire(%{
                 workspace_id: workspace_id,
                 repo_path: repo_root,
                 branch: branch,
                 worktree_base_dir: worktree_base
               })

      assert first.workspace_id == workspace_id
      assert File.dir?(first.worktree_path)

      assert {:error, :workspace_id_collision} =
               WorkspaceLeaseRegistry.acquire(%{
                 workspace_id: workspace_id,
                 repo_path: repo_root,
                 branch: "test/workspace-id-collision-2",
                 worktree_base_dir: Path.join(tmp_dir, "worktrees-other"),
                 create_worktree: fn _repo, _branch, _params ->
                   send(parent, :create_should_not_run)
                   {:error, :should_not_run}
                 end
               })

      refute_receive :create_should_not_run, 100
      assert File.dir?(first.worktree_path)

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(workspace_id, :remove, %{})
    end

    test "post-create finalization failure removes owned worktree and keeps registry alive", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      repo_root = git!(repo, ["rev-parse", "--show-toplevel"])
      branch = "test/workspace-post-create-fail"
      worktree_base = Path.join(tmp_dir, "worktrees")
      workspace_id = "ws_post_create_fail_#{System.unique_integer([:positive])}"
      server = :"workspace_lease_post_create_#{System.unique_integer([:positive])}"

      start_supervised!(
        {WorkspaceLeaseRegistry,
         name: server,
         linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer}
      )

      assert {:error, {:invalid, :base_commit}} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   workspace_id: workspace_id,
                   repo_path: repo_root,
                   branch: branch,
                   worktree_base_dir: worktree_base,
                   create_worktree: fn repo_path, branch_name, params ->
                     {:ok, path, :owned, _base_commit} =
                       Workspace.create_worktree(repo_path, branch_name, params)

                     # Real owned worktree exists; fail finalization after its
                     # ownership is known so cleanup is authorized.
                     {:ok, path, :owned, nil}
                   end
                 },
                 server: server
               )

      expected_path = expected_worktree_path(worktree_base, branch)
      refute File.dir?(expected_path)
      refute worktree_registered?(repo_root, expected_path)

      assert {:error, :not_found} =
               WorkspaceLeaseRegistry.inspect_lease(workspace_id, %{server: server})

      # Registry survives and accepts a subsequent acquire.
      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo_root,
                   branch: branch,
                   worktree_base_dir: worktree_base
                 },
                 server: server
               )

      assert File.dir?(lease.worktree_path)

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{server: server})
    end

    test "security regression: invalid ownership never deletes a pre-existing worktree", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      repo_root = git!(repo, ["rev-parse", "--show-toplevel"])
      base_commit = git!(repo, ["rev-parse", "HEAD"])
      branch = "test/workspace-invalid-ownership-reused"
      worktree_path = Path.join(tmp_dir, "preexisting-worktree")
      workspace_id = "ws_invalid_ownership_#{System.unique_integer([:positive])}"

      git!(repo, ["branch", branch])
      git!(repo, ["worktree", "add", worktree_path, branch])

      assert {:error, :invalid_ownership} =
               WorkspaceLeaseRegistry.acquire(%{
                 workspace_id: workspace_id,
                 repo_path: repo_root,
                 branch: branch,
                 create_worktree: fn _repo_path, _branch_name, _params ->
                   {:ok, worktree_path, :bogus_ownership, base_commit}
                 end
               })

      assert File.dir?(worktree_path)
      assert worktree_registered?(repo_root, worktree_path)
      assert git!(worktree_path, ["branch", "--show-current"]) == branch

      assert {:error, :not_found} =
               WorkspaceLeaseRegistry.inspect_lease(workspace_id, %{})
    end

    test "raising create callback demonitors cleanly and leaves registry alive", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      repo_root = git!(repo, ["rev-parse", "--show-toplevel"])
      workspace_id = "ws_raise_#{System.unique_integer([:positive])}"
      server = :"workspace_lease_raise_#{System.unique_integer([:positive])}"
      {:ok, registry_pid} = start_supervised({WorkspaceLeaseRegistry, name: server})

      assert {:error, {:create_worktree_raised, _message}} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   workspace_id: workspace_id,
                   repo_path: repo_root,
                   branch: "test/create-raise",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                   create_worktree: fn _repo, _branch, _params ->
                     raise "injected create boom"
                   end
                 },
                 server: server
               )

      assert Process.alive?(registry_pid)

      assert {:error, :not_found} =
               WorkspaceLeaseRegistry.inspect_lease(workspace_id, %{server: server})

      # Subsequent acquire still works (monitor state was cleaned).
      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo_root,
                   branch: "test/create-raise-ok",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees-ok")
                 },
                 server: server
               )

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{server: server})
    end

    test "second acquire for same repo+branch is rejected before create", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      repo_root = git!(repo, ["rev-parse", "--show-toplevel"])
      branch = "test/workspace-in-use"
      worktree_base = Path.join(tmp_dir, "worktrees")
      parent = self()

      assert {:ok, first} =
               WorkspaceLeaseRegistry.acquire(%{
                 repo_path: repo_root,
                 branch: branch,
                 worktree_base_dir: worktree_base
               })

      assert first.branch == branch
      assert File.dir?(first.worktree_path)

      assert {:error, :workspace_in_use} =
               WorkspaceLeaseRegistry.acquire(%{
                 repo_path: repo_root,
                 branch: branch,
                 worktree_base_dir: Path.join(tmp_dir, "worktrees-other"),
                 create_worktree: fn _repo, _branch, _params ->
                   send(parent, :second_create_ran)
                   {:error, :should_not_run}
                 end
               })

      refute_receive :second_create_ran, 100

      # First lease remains intact and inspectable by owner.
      assert {:ok, inspected} =
               WorkspaceLeaseRegistry.inspect_lease(first.workspace_id, %{})

      assert inspected.workspace_id == first.workspace_id
      assert File.dir?(first.worktree_path)

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(first.workspace_id, :remove, %{})

      # After release, the target is free again.
      assert {:ok, second} =
               WorkspaceLeaseRegistry.acquire(%{
                 repo_path: repo_root,
                 branch: branch,
                 worktree_base_dir: worktree_base
               })

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(second.workspace_id, :remove, %{})
    end

    test "create failure after monitor does not leave a lease", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      repo_root = git!(repo, ["rev-parse", "--show-toplevel"])
      workspace_id = "ws_create_fail_#{System.unique_integer([:positive])}"

      assert {:error, :injected_create_failure} =
               WorkspaceLeaseRegistry.acquire(%{
                 workspace_id: workspace_id,
                 repo_path: repo_root,
                 branch: "test/create-fail",
                 worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                 create_worktree: fn _repo, _branch, _params ->
                   {:error, :injected_create_failure}
                 end
               })

      assert {:error, :not_found} =
               WorkspaceLeaseRegistry.inspect_lease(workspace_id, %{})
    end
  end

  describe "Workspace.CommittedChange" do
    test "returns cumulative base..HEAD diff and files for an authorized lease", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/workspace-committed-change"
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

      File.write!(Path.join(lease.worktree_path, "feature.ex"), "defmodule Feature do\nend\n")
      git!(lease.worktree_path, ["add", "feature.ex"])
      git!(lease.worktree_path, ["commit", "-m", "add feature"])
      head = git!(lease.worktree_path, ["rev-parse", "HEAD"])

      assert {:ok, change} =
               Workspace.CommittedChange.run(
                 %{workspace_id: lease.workspace_id, commit: head},
                 %{}
               )

      assert Workspace.json_clean?(change)
      refute_pid_like(change)
      assert change.workspace_id == lease.workspace_id
      assert change.commit_hash == head
      assert change.base_ref == lease.base_commit
      assert is_binary(change.diff)
      assert change.diff != ""
      assert "feature.ex" in change.files

      _ = Workspace.Release.run(%{workspace_id: lease.workspace_id, mode: "retain"}, %{})
    end

    test "defaults to HEAD when commit is omitted", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/workspace-committed-head"
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

      File.write!(Path.join(lease.worktree_path, "head_only.ex"), "defmodule HeadOnly do\nend\n")
      git!(lease.worktree_path, ["add", "head_only.ex"])
      git!(lease.worktree_path, ["commit", "-m", "head only"])
      head = git!(lease.worktree_path, ["rev-parse", "HEAD"])

      assert {:ok, change} =
               Workspace.CommittedChange.run(%{workspace_id: lease.workspace_id}, %{})

      assert change.commit_hash == head
      assert change.base_ref == lease.base_commit
      assert "head_only.ex" in change.files
      refute Map.has_key?(change, :prior_candidate_commit)
      refute Map.has_key?(change, :delta_diff)
      refute Map.has_key?(change, :delta_files)
      refute Map.has_key?(change, :delta_ranges)

      _ = Workspace.Release.run(%{workspace_id: lease.workspace_id, mode: "retain"}, %{})
    end

    test "adds review-cycle delta evidence from an exact ancestor commit", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))

      assert {:ok, lease} =
               Workspace.Acquire.run(
                 %{
                   repo_path: repo,
                   branch_name: "test/workspace-delta-evidence",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees")
                 },
                 %{}
               )

      File.write!(Path.join(lease.worktree_path, "existing.ex"), "one\ntwo\n")
      git!(lease.worktree_path, ["add", "existing.ex"])
      git!(lease.worktree_path, ["commit", "-m", "add existing file"])
      prior = git!(lease.worktree_path, ["rev-parse", "HEAD"])

      File.write!(Path.join(lease.worktree_path, "existing.ex"), "one\nchanged\nadded\n")
      File.write!(Path.join(lease.worktree_path, "new_file.ex"), "new\n")
      git!(lease.worktree_path, ["add", "existing.ex", "new_file.ex"])
      git!(lease.worktree_path, ["commit", "-m", "change review cycle"])
      head = git!(lease.worktree_path, ["rev-parse", "HEAD"])

      assert {:ok, change} =
               Workspace.CommittedChange.run(
                 %{workspace_id: lease.workspace_id, prior_commit: prior},
                 %{}
               )

      assert Workspace.json_clean?(change)
      assert change.commit_hash == head
      assert change.prior_candidate_commit == prior
      assert change.diff =~ "existing.ex"
      assert "existing.ex" in change.files
      assert "new_file.ex" in change.files
      assert change.delta_diff =~ "new_file.ex"
      assert change.delta_files == ["existing.ex", "new_file.ex"]
      assert change.delta_ranges["existing.ex"] == [[1, 3]]
      assert change.delta_ranges["new_file.ex"] == [[1, 1]]

      _ = Workspace.Release.run(%{workspace_id: lease.workspace_id, mode: "retain"}, %{})
    end

    test "rejects missing, invalid, equal, and non-ancestor prior commits", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))

      assert {:ok, lease} =
               Workspace.Acquire.run(
                 %{
                   repo_path: repo,
                   branch_name: "test/workspace-invalid-prior",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees")
                 },
                 %{}
               )

      File.write!(Path.join(lease.worktree_path, "candidate.ex"), "candidate\n")
      git!(lease.worktree_path, ["add", "candidate.ex"])
      git!(lease.worktree_path, ["commit", "-m", "candidate"])
      head = git!(lease.worktree_path, ["rev-parse", "HEAD"])

      assert {:error, :invalid_prior_commit} =
               Workspace.CommittedChange.run(
                 %{workspace_id: lease.workspace_id, prior_commit: "HEAD~1"},
                 %{}
               )

      assert {:error, :prior_commit_missing} =
               Workspace.CommittedChange.run(
                 %{
                   workspace_id: lease.workspace_id,
                   prior_commit: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
                 },
                 %{}
               )

      assert {:error, :prior_commit_equal_candidate} =
               Workspace.CommittedChange.run(
                 %{workspace_id: lease.workspace_id, prior_commit: head},
                 %{}
               )

      File.write!(Path.join(repo, "other_branch.ex"), "other\n")
      git!(repo, ["add", "other_branch.ex"])
      git!(repo, ["commit", "-m", "unrelated candidate sibling"])
      non_ancestor = git!(repo, ["rev-parse", "HEAD"])

      assert {:error, :prior_commit_not_ancestor} =
               Workspace.CommittedChange.run(
                 %{workspace_id: lease.workspace_id, prior_commit: non_ancestor},
                 %{}
               )

      _ = Workspace.Release.run(%{workspace_id: lease.workspace_id, mode: "retain"}, %{})
    end

    test "security regression: rejects a non-HEAD candidate before probing prior commit", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))

      assert {:ok, lease} =
               Workspace.Acquire.run(
                 %{
                   repo_path: repo,
                   branch_name: "test/workspace-prior-candidate-order",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees")
                 },
                 %{}
               )

      File.write!(Path.join(lease.worktree_path, "first.ex"), "first\n")
      git!(lease.worktree_path, ["add", "first.ex"])
      git!(lease.worktree_path, ["commit", "-m", "first candidate"])
      non_head = git!(lease.worktree_path, ["rev-parse", "HEAD"])

      File.write!(Path.join(lease.worktree_path, "second.ex"), "second\n")
      git!(lease.worktree_path, ["add", "second.ex"])
      git!(lease.worktree_path, ["commit", "-m", "advance candidate"])

      # The missing prior object is syntactically valid, so this proves the
      # candidate gate runs before any prior-object lookup.
      assert {:error, :commit_not_head} =
               Workspace.CommittedChange.run(
                 %{
                   workspace_id: lease.workspace_id,
                   commit: non_head,
                   prior_commit: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
                 },
                 %{}
               )

      _ = Workspace.Release.run(%{workspace_id: lease.workspace_id, mode: "retain"}, %{})
    end

    test "reports deletion-only, rename, and new-file delta evidence", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))

      assert {:ok, lease} =
               Workspace.Acquire.run(
                 %{
                   repo_path: repo,
                   branch_name: "test/workspace-delta-file-kinds",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees")
                 },
                 %{}
               )

      File.write!(Path.join(lease.worktree_path, "removed.ex"), "remove me\n")
      File.write!(Path.join(lease.worktree_path, "old_name.ex"), "keep contents\n")
      git!(lease.worktree_path, ["add", "removed.ex", "old_name.ex"])
      git!(lease.worktree_path, ["commit", "-m", "seed delta files"])
      prior = git!(lease.worktree_path, ["rev-parse", "HEAD"])

      git!(lease.worktree_path, ["rm", "removed.ex"])
      git!(lease.worktree_path, ["mv", "old_name.ex", "renamed.ex"])
      File.write!(Path.join(lease.worktree_path, "new_file.ex"), "new line\n")
      git!(lease.worktree_path, ["add", "new_file.ex"])
      git!(lease.worktree_path, ["commit", "-m", "replace delta files"])

      assert {:ok, change} =
               Workspace.CommittedChange.run(
                 %{workspace_id: lease.workspace_id, prior_commit: prior},
                 %{}
               )

      assert change.delta_files == ["new_file.ex", "removed.ex", "renamed.ex"]
      assert change.delta_ranges == %{"new_file.ex" => [[1, 1]]}

      _ = Workspace.Release.run(%{workspace_id: lease.workspace_id, mode: "retain"}, %{})
    end

    test "two-commit cumulative diff includes all leased changes", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/workspace-cumulative-diff"
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

      File.write!(Path.join(lease.worktree_path, "one.ex"), "defmodule One do\nend\n")
      git!(lease.worktree_path, ["add", "one.ex"])
      git!(lease.worktree_path, ["commit", "-m", "first"])

      File.write!(Path.join(lease.worktree_path, "two.ex"), "defmodule Two do\nend\n")
      git!(lease.worktree_path, ["add", "two.ex"])
      git!(lease.worktree_path, ["commit", "-m", "second"])
      head = git!(lease.worktree_path, ["rev-parse", "HEAD"])

      assert {:ok, change} =
               Workspace.CommittedChange.run(%{workspace_id: lease.workspace_id}, %{})

      assert change.commit_hash == head
      assert change.base_ref == lease.base_commit
      assert "one.ex" in change.files
      assert "two.ex" in change.files
      assert change.diff =~ "one.ex"
      assert change.diff =~ "two.ex"

      _ = Workspace.Release.run(%{workspace_id: lease.workspace_id, mode: "retain"}, %{})
    end

    test "rejects dirty workspace before materializing review input", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/workspace-dirty-reject"
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

      File.write!(Path.join(lease.worktree_path, "dirty.ex"), "defmodule Dirty do\nend\n")

      assert {:error, :dirty_workspace} =
               Workspace.CommittedChange.run(%{workspace_id: lease.workspace_id}, %{})

      _ = Workspace.Release.run(%{workspace_id: lease.workspace_id, mode: "retain"}, %{})
    end

    test "security regression: lease owner cannot inspect arbitrary non-HEAD commit", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/workspace-non-head"
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

      File.write!(Path.join(lease.worktree_path, "first.ex"), "defmodule First do\nend\n")
      git!(lease.worktree_path, ["add", "first.ex"])
      git!(lease.worktree_path, ["commit", "-m", "first"])
      first = git!(lease.worktree_path, ["rev-parse", "HEAD"])

      File.write!(Path.join(lease.worktree_path, "second.ex"), "defmodule Second do\nend\n")
      git!(lease.worktree_path, ["add", "second.ex"])
      git!(lease.worktree_path, ["commit", "-m", "second"])
      head = git!(lease.worktree_path, ["rev-parse", "HEAD"])

      # Ancestor of HEAD is rejected before any git read of that commit.
      assert first != head

      assert {:error, :commit_not_head} =
               Workspace.CommittedChange.run(
                 %{workspace_id: lease.workspace_id, commit: first},
                 %{}
               )

      # Revision expressions and foreign hashes are rejected (exact HEAD only).
      assert {:error, :commit_not_head} =
               Workspace.CommittedChange.run(
                 %{workspace_id: lease.workspace_id, commit: "HEAD~1"},
                 %{}
               )

      assert {:error, :commit_not_head} =
               Workspace.CommittedChange.run(
                 %{
                   workspace_id: lease.workspace_id,
                   commit: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
                 },
                 %{}
               )

      assert {:ok, change} =
               Workspace.CommittedChange.run(
                 %{workspace_id: lease.workspace_id, commit: head},
                 %{}
               )

      assert change.commit_hash == head
      assert "first.ex" in change.files
      assert "second.ex" in change.files

      _ = Workspace.Release.run(%{workspace_id: lease.workspace_id, mode: "retain"}, %{})
    end

    test "security regression: opaque workspace_id alone cannot read committed change", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()
      task_id = "task_committed_#{System.unique_integer([:positive])}"
      principal_id = "agent_committed_#{System.unique_integer([:positive])}"

      owner =
        spawn(fn ->
          {:ok, lease} =
            Workspace.Acquire.run(
              %{
                repo_path: repo,
                branch_name: "test/committed-auth",
                worktree_base_dir: Path.join(tmp_dir, "worktrees")
              },
              %{task_id: task_id, agent_id: principal_id}
            )

          File.write!(Path.join(lease.worktree_path, "secret.ex"), "defmodule Secret do\nend\n")
          git!(lease.worktree_path, ["add", "secret.ex"])
          git!(lease.worktree_path, ["commit", "-m", "secret"])
          send(parent, {:leased, lease})

          receive do
            :hold -> :ok
          after
            5_000 -> :ok
          end
        end)

      assert_receive {:leased, lease}, 2_000

      assert {:error, :not_authorized} =
               Workspace.CommittedChange.run(%{workspace_id: lease.workspace_id}, %{})

      assert {:error, :not_authorized} =
               Workspace.CommittedChange.run(%{workspace_id: lease.workspace_id}, %{
                 task_id: task_id
               })

      assert {:ok, change} =
               Workspace.CommittedChange.run(%{workspace_id: lease.workspace_id}, %{
                 task_id: task_id,
                 agent_id: principal_id
               })

      assert "secret.ex" in change.files
      send(owner, :hold)
    end

    test "fails closed for missing workspace and empty lease range", %{tmp_dir: tmp_dir} do
      assert {:error, :not_found} =
               Workspace.CommittedChange.run(%{workspace_id: "ws_missing"}, %{})

      repo = create_git_repo(Path.join(tmp_dir, "repo"))

      assert {:ok, lease} =
               Workspace.Acquire.run(
                 %{
                   repo_path: repo,
                   branch_name: "test/committed-empty",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees")
                 },
                 %{}
               )

      # HEAD still equals base_commit: no committed change to review.
      assert {:error, reason} =
               Workspace.CommittedChange.run(%{workspace_id: lease.workspace_id}, %{})

      assert reason in [:empty_commit_diff, :empty_commit_file_list]

      _ = Workspace.Release.run(%{workspace_id: lease.workspace_id, mode: "retain"}, %{})
    end
  end

  defp refute_pid_like(map) when is_map(map) do
    Enum.each(map, fn {_k, v} ->
      refute is_pid(v)
      refute is_reference(v)
      refute is_function(v)
      refute is_struct(v)
    end)
  end

  defp assert_eventually(fun, attempts \\ 50)

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

  defp expected_worktree_path(base_dir, branch_name) do
    Path.join(base_dir, Workspace.worktree_dir_name(branch_name))
  end

  defp worktree_registered?(repo_root, worktree_path) do
    git!(repo_root, ["worktree", "list", "--porcelain"])
    |> String.contains?(worktree_path)
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
