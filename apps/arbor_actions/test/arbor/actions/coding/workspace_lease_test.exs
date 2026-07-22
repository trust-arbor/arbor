defmodule Arbor.Actions.Coding.WorkspaceLeaseTest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Git
  alias Arbor.Contracts.Security.AuthContext

  @moduletag :fast
  @owner_operation_timeout 10_000
  @owner_hold_timeout 30_000

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

  test "security regression: public workspace view closes lowercase failure strings" do
    sensitive = "private_secret_token"

    view =
      WorkspaceLeaseRegistry.public_view(%{
        workspace_id: "workspace",
        repo_path: "/private/repo",
        worktree_path: "/private/worktree",
        branch: "test/branch",
        base_commit: "0123456789abcdef0123456789abcdef01234567",
        ownership: :owned,
        branch_provenance: :created,
        active: false,
        cleanup_failure: sensitive
      })

    encoded = Jason.encode!(view)

    refute String.contains?(encoded, sensitive)
    assert view.cleanup_failure_category == "cleanup_failed"
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

    test "inspect opt-in returns the exact Git add -A committable tree", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))

      assert {:ok, lease} =
               Workspace.Acquire.run(
                 %{
                   repo_path: repo,
                   branch_name: "test/workspace-committable-tree",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees")
                 },
                 %{}
               )

      assert {:ok, ordinary} =
               Workspace.Inspect.run(%{workspace_id: lease.workspace_id}, %{})

      refute Map.has_key?(ordinary, :committable_tree_oid)
      refute Map.has_key?(ordinary, :committable_tree_observed_at)

      assert {:ok, baseline} =
               Workspace.Inspect.run(
                 %{workspace_id: lease.workspace_id, include_committable_tree: true},
                 %{}
               )

      assert baseline.committable_tree_oid ==
               git!(lease.worktree_path, ["rev-parse", "HEAD^{tree}"])

      assert {:ok, baseline_observed_at, 0} =
               DateTime.from_iso8601(baseline.committable_tree_observed_at)

      assert baseline_observed_at.time_zone == "Etc/UTC"

      File.write!(Path.join(lease.worktree_path, "README.md"), "unstaged change\n")

      assert {:ok, unstaged} =
               Workspace.Inspect.run(
                 %{workspace_id: lease.workspace_id, include_committable_tree: true},
                 %{}
               )

      refute unstaged.committable_tree_oid == baseline.committable_tree_oid

      git!(lease.worktree_path, ["add", "-A"])
      assert unstaged.committable_tree_oid == git!(lease.worktree_path, ["write-tree"])

      assert {:ok, staged} =
               Workspace.Inspect.run(
                 %{workspace_id: lease.workspace_id, include_committable_tree: true},
                 %{}
               )

      assert staged.committable_tree_oid == unstaged.committable_tree_oid

      File.write!(Path.join(lease.worktree_path, "README.md"), "staged plus unstaged\n")

      assert {:ok, staged_and_unstaged} =
               Workspace.Inspect.run(
                 %{workspace_id: lease.workspace_id, include_committable_tree: true},
                 %{}
               )

      refute staged_and_unstaged.committable_tree_oid == staged.committable_tree_oid

      File.write!(Path.join(lease.worktree_path, "untracked.txt"), "untracked\n")

      assert {:ok, untracked} =
               Workspace.Inspect.run(
                 %{workspace_id: lease.workspace_id, include_committable_tree: true},
                 %{}
               )

      refute untracked.committable_tree_oid == staged_and_unstaged.committable_tree_oid

      git!(lease.worktree_path, ["add", "-A"])
      assert untracked.committable_tree_oid == git!(lease.worktree_path, ["write-tree"])
    end

    test "security regression: committable tree inspection fails closed and only canonical true activates it",
         %{
           tmp_dir: tmp_dir
         } do
      assert {:error, :not_found} =
               Workspace.Inspect.run(
                 %{workspace_id: "ws_missing", include_committable_tree: true},
                 %{}
               )

      assert {:error, "workspace_id is required"} =
               Workspace.Inspect.run(%{include_committable_tree: true}, %{})

      repo = create_git_repo(Path.join(tmp_dir, "repo"))

      assert {:ok, lease} =
               Workspace.Acquire.run(
                 %{
                   repo_path: repo,
                   branch_name: "test/workspace-missing-committable-tree",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees")
                 },
                 %{}
               )

      git!(repo, ["worktree", "remove", "--force", lease.worktree_path])

      assert {:ok, ordinary} =
               Workspace.Inspect.run(%{workspace_id: lease.workspace_id}, %{})

      assert ordinary.exists == false
      refute Map.has_key?(ordinary, :committable_tree_oid)
      refute Map.has_key?(ordinary, :committable_tree_observed_at)

      assert {:ok, direct_string_input} =
               Workspace.Inspect.run(
                 %{workspace_id: lease.workspace_id, include_committable_tree: "true"},
                 %{}
               )

      assert direct_string_input.exists == false
      refute Map.has_key?(direct_string_input, :committable_tree_oid)
      refute Map.has_key?(direct_string_input, :committable_tree_observed_at)

      assert {:error, :committable_tree_binding_failed} =
               Workspace.Inspect.run(
                 %{workspace_id: lease.workspace_id, include_committable_tree: true},
                 %{}
               )
    end

    test "security regression: detached cleanup is idempotent after path and registration absence",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      worktree_path = Path.join(tmp_dir, "detached-worktree")
      commit = git!(repo, ["rev-parse", "HEAD"])

      assert {:ok, ^worktree_path} =
               Workspace.create_detached_worktree(repo, worktree_path, commit)

      git!(repo, ["worktree", "remove", "--force", worktree_path])
      assert {:error, :enoent} = File.lstat(worktree_path)
      refute worktree_registered?(repo, worktree_path)

      assert :ok = Workspace.remove_detached_worktree(repo, worktree_path)
    end

    test "security regression: newline worktree path cannot hide a surviving registration",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      worktree_path = Path.join(tmp_dir, "detached\nworktree")
      commit = git!(repo, ["rev-parse", "HEAD"])

      assert {:ok, %{path: ^worktree_path}} =
               Workspace.create_detached_worktree_with_identity(repo, worktree_path, commit)

      File.rm_rf!(worktree_path)

      try do
        assert {:ok, %{detached: true}} = Git.worktree_registration(repo, worktree_path)
        assert {:error, :enoent} = File.lstat(worktree_path)

        assert {:error, :detached_snapshot_cleanup_identity_required} =
                 Workspace.remove_detached_worktree(repo, worktree_path)
      after
        _ = System.cmd("git", ["-C", repo, "worktree", "prune", "--expire", "now"])
      end
    end

    test "security regression: failed detached finalization returns its cleanup identity", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      worktree_path = Path.join(tmp_dir, "detached-worktree")
      preserved_path = Path.join(tmp_dir, "detached-worktree-preserved")
      replacement_marker = Path.join(worktree_path, "replacement-marker")
      commit = git!(repo, ["rev-parse", "HEAD"])
      hook_key = {Workspace, :test_after_detached_snapshot_identity}

      Process.put(hook_key, fn ^worktree_path, _identity ->
        File.rename!(worktree_path, preserved_path)
        File.mkdir!(worktree_path)
        File.write!(replacement_marker, "replacement survives\n")
      end)

      try do
        assert {:error,
                {:detached_snapshot_cleanup_retained, _reason, _cleanup_reason, removal_identity}} =
                 Workspace.create_detached_worktree_with_identity(
                   repo,
                   worktree_path,
                   commit
                 )

        assert is_map(removal_identity)
        assert File.read!(replacement_marker) == "replacement survives\n"

        File.rm_rf!(worktree_path)
        File.rename!(preserved_path, worktree_path)
        assert :ok = Workspace.remove_detached_worktree(repo, worktree_path, removal_identity)
      after
        Process.delete(hook_key)
        File.rm_rf(worktree_path)
        File.rm_rf(preserved_path)
        _ = System.cmd("git", ["-C", repo, "worktree", "prune", "--expire", "now"])
      end
    end

    test "security regression: partial failed add recovers and retains its cleanup identity", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      worktree_path = Path.join(tmp_dir, "partial-detached-worktree")
      preserved_path = Path.join(tmp_dir, "partial-detached-worktree-preserved")
      commit = git!(repo, ["rev-parse", "HEAD"])
      add_hook = {Workspace, :test_force_detached_add_failure}
      identity_hook = {Workspace, :test_after_detached_snapshot_identity}

      Process.put(add_hook, true)

      Process.put(identity_hook, fn ^worktree_path, _identity ->
        File.rename!(worktree_path, preserved_path)
        File.mkdir!(worktree_path)
      end)

      try do
        assert {:error,
                {:detached_snapshot_cleanup_retained, :detached_snapshot_create_failed,
                 _cleanup_reason, removal_identity}} =
                 Workspace.create_detached_worktree_with_identity(
                   repo,
                   worktree_path,
                   commit
                 )

        File.rmdir!(worktree_path)
        File.rename!(preserved_path, worktree_path)
        assert :ok = Workspace.remove_detached_worktree(repo, worktree_path, removal_identity)
      after
        Process.delete(add_hook)
        Process.delete(identity_hook)
        File.rm_rf(worktree_path)
        File.rm_rf(preserved_path)
        _ = System.cmd("git", ["-C", repo, "worktree", "prune", "--expire", "now"])
      end
    end

    test "security regression: identity capture exhaustion retains unidentified snapshot", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      worktree_path = Path.join(tmp_dir, "unidentified-detached-worktree")
      commit = git!(repo, ["rev-parse", "HEAD"])
      hook_key = {Workspace, :test_force_detached_identity_capture_failure}
      Process.put(hook_key, true)

      try do
        assert {:error,
                {:detached_snapshot_cleanup_identity_unavailable,
                 :detached_snapshot_create_failed, _reason}} =
                 Workspace.create_detached_worktree_with_identity(
                   repo,
                   worktree_path,
                   commit
                 )

        assert File.dir?(worktree_path)

        assert {:error, :detached_snapshot_cleanup_identity_required} =
                 Workspace.remove_detached_worktree(repo, worktree_path)
      after
        Process.delete(hook_key)

        case Workspace.capture_worktree_removal_identity(repo, worktree_path) do
          {:ok, identity} ->
            _ = Workspace.remove_detached_worktree(repo, worktree_path, identity)

          {:error, _reason} ->
            _ = System.cmd("git", ["-C", repo, "worktree", "remove", "--force", worktree_path])
        end
      end
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
      canonical_worktree_path = git!(worktree_path, ["rev-parse", "--show-toplevel"])
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
      assert lease.worktree_path == canonical_worktree_path

      assert {:ok, removed} =
               Workspace.Release.run(
                 %{workspace_id: lease.workspace_id, mode: "remove"},
                 %{}
               )

      assert removed.status == "removed"
      assert File.dir?(canonical_worktree_path)
      assert worktree_registered?(repo, canonical_worktree_path)
      assert git!(canonical_worktree_path, ["rev-parse", "--is-inside-work-tree"]) == "true"
      assert git!(canonical_worktree_path, ["branch", "--show-current"]) == branch
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
            @owner_hold_timeout -> :ok
          end
        end)

      assert_receive {:leased, lease}, @owner_operation_timeout

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
            @owner_hold_timeout -> :ok
          end
        end)

      assert_receive {:task_leased, task_lease}, @owner_operation_timeout

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

    test "principal-only action context keeps lease authority process-local", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      principal_id = "agent_owner_only_#{System.unique_integer([:positive])}"

      assert {:ok, lease} =
               Workspace.Acquire.run(
                 %{
                   repo_path: repo,
                   branch_name: "test/workspace-principal-only-context",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees")
                 },
                 %{agent_id: principal_id}
               )

      assert {:ok, inspected} =
               Workspace.Inspect.run(
                 %{workspace_id: lease.workspace_id},
                 %{agent_id: principal_id}
               )

      assert inspected.workspace_id == lease.workspace_id

      cross_process_result =
        Task.async(fn ->
          Workspace.Inspect.run(
            %{workspace_id: lease.workspace_id},
            %{agent_id: principal_id}
          )
        end)
        |> Task.await()

      assert {:error, :not_authorized} = cross_process_result

      assert {:ok, removed} =
               Workspace.Release.run(
                 %{workspace_id: lease.workspace_id, mode: "remove"},
                 %{agent_id: principal_id}
               )

      assert removed.status == "removed"

      assert {:error, :incomplete_task_principal} =
               WorkspaceLeaseRegistry.acquire(%{
                 repo_path: repo,
                 branch: "test/workspace-direct-principal-only",
                 worktree_base_dir: Path.join(tmp_dir, "direct-worktrees"),
                 principal_id: principal_id
               })
    end

    test "security regression: inspect_lease_by_lineage ignores owner PID and requires exact task+principal",
         %{tmp_dir: tmp_dir} do
      # Even the live owner process is denied when either lineage value mismatches;
      # the exact pair succeeds without relying on owner-PID authority.
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      task_id = "task_lineage_inspect_#{System.unique_integer([:positive])}"
      principal_id = "agent_lineage_inspect_#{System.unique_integer([:positive])}"
      other_principal = "agent_other_#{System.unique_integer([:positive])}"
      other_task = "task_other_#{System.unique_integer([:positive])}"
      server = :"workspace_lineage_inspect_#{System.unique_integer([:positive])}"

      start_supervised!(
        {WorkspaceLeaseRegistry,
         name: server, retention_journal: :disabled, retention_runtime_id: "lineage-inspect-test"}
      )

      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: "test/lineage-only-inspect",
                   worktree_base_dir: Path.join(tmp_dir, "lineage-worktrees"),
                   task_id: task_id,
                   principal_id: principal_id
                 },
                 server: server
               )

      # Live owner is this test process; mismatched principal still denied.
      assert {:error, :not_authorized} =
               WorkspaceLeaseRegistry.inspect_lease_by_lineage(
                 lease.workspace_id,
                 task_id,
                 other_principal,
                 server: server
               )

      # Mismatched task_id denied even as the live owner.
      assert {:error, :not_authorized} =
               WorkspaceLeaseRegistry.inspect_lease_by_lineage(
                 lease.workspace_id,
                 other_task,
                 principal_id,
                 server: server
               )

      # Exact pair succeeds without owner-PID authority.
      assert {:ok, inspected} =
               WorkspaceLeaseRegistry.inspect_lease_by_lineage(
                 lease.workspace_id,
                 task_id,
                 principal_id,
                 server: server
               )

      assert inspected.workspace_id == lease.workspace_id
      assert inspected.worktree_path == lease.worktree_path

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })
    end

    test "security regression: inspect_lease_by_lineage preserves opaque whitespace identities",
         %{tmp_dir: tmp_dir} do
      # Whitespace is significant after validation. Trimming before comparison
      # would let " agent_x " authorize a lease bound to "agent_x".
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      task_id = "task_opaque_ws_#{System.unique_integer([:positive])}"
      principal_id = "agent_opaque_ws_#{System.unique_integer([:positive])}"
      spaced_task = task_id <> " "
      spaced_principal = " " <> principal_id
      server = :"workspace_opaque_ws_#{System.unique_integer([:positive])}"

      start_supervised!(
        {WorkspaceLeaseRegistry,
         name: server, retention_journal: :disabled, retention_runtime_id: "opaque-ws-test"}
      )

      assert {:ok, lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: "test/opaque-whitespace-lineage",
                   worktree_base_dir: Path.join(tmp_dir, "opaque-ws-worktrees"),
                   task_id: task_id,
                   principal_id: principal_id
                 },
                 server: server
               )

      # All-whitespace is blank and must reject without rewriting.
      assert {:error, :invalid_task_principal} =
               WorkspaceLeaseRegistry.inspect_lease_by_lineage(
                 lease.workspace_id,
                 "   ",
                 principal_id,
                 server: server
               )

      assert {:error, :invalid_task_principal} =
               WorkspaceLeaseRegistry.inspect_lease_by_lineage(
                 lease.workspace_id,
                 task_id,
                 "\t\n",
                 server: server
               )

      # workspace_id itself is opaque: leading/trailing whitespace must not trim
      # into a valid lookup of the real lease.
      assert {:error, :not_found} =
               WorkspaceLeaseRegistry.inspect_lease_by_lineage(
                 lease.workspace_id <> " ",
                 task_id,
                 principal_id,
                 server: server
               )

      assert {:error, :not_found} =
               WorkspaceLeaseRegistry.inspect_lease_by_lineage(
                 " " <> lease.workspace_id,
                 task_id,
                 principal_id,
                 server: server
               )

      # Whitespace-bearing aliases must not authorize the exact stored lineage.
      assert {:error, :not_authorized} =
               WorkspaceLeaseRegistry.inspect_lease_by_lineage(
                 lease.workspace_id,
                 spaced_task,
                 principal_id,
                 server: server
               )

      assert {:error, :not_authorized} =
               WorkspaceLeaseRegistry.inspect_lease_by_lineage(
                 lease.workspace_id,
                 task_id,
                 spaced_principal,
                 server: server
               )

      # Exact opaque pair still succeeds.
      assert {:ok, inspected} =
               WorkspaceLeaseRegistry.inspect_lease_by_lineage(
                 lease.workspace_id,
                 task_id,
                 principal_id,
                 server: server
               )

      assert inspected.workspace_id == lease.workspace_id

      # Acquire with whitespace-bearing lineage; exact spaced form matches, trimmed does not.
      assert {:ok, spaced_lease} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: "test/opaque-whitespace-stored",
                   worktree_base_dir: Path.join(tmp_dir, "opaque-ws-stored-worktrees"),
                   task_id: spaced_task,
                   principal_id: spaced_principal
                 },
                 server: server
               )

      assert {:ok, _} =
               WorkspaceLeaseRegistry.inspect_lease_by_lineage(
                 spaced_lease.workspace_id,
                 spaced_task,
                 spaced_principal,
                 server: server
               )

      assert {:error, :not_authorized} =
               WorkspaceLeaseRegistry.inspect_lease_by_lineage(
                 spaced_lease.workspace_id,
                 String.trim(spaced_task),
                 String.trim(spaced_principal),
                 server: server
               )

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(spaced_lease.workspace_id, :remove, %{
                 server: server,
                 task_id: spaced_task,
                 principal_id: spaced_principal
               })
    end

    test "security regression: inspect_lease_by_lineage never returns retention blockers as active",
         %{tmp_dir: tmp_dir} do
      # A creation/retention blocker with matching lineage must not be inspectable
      # as an active lease — missing active lease is always :not_found.
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      task_id = "task_blocker_lineage_#{System.unique_integer([:positive])}"
      principal_id = "agent_blocker_lineage_#{System.unique_integer([:positive])}"
      workspace_id = "ws_blocker_lineage_#{System.unique_integer([:positive])}"
      server = :"workspace_blocker_lineage_#{System.unique_integer([:positive])}"

      start_supervised!(
        {WorkspaceLeaseRegistry,
         name: server, retention_journal: :disabled, retention_runtime_id: "blocker-lineage-test"}
      )

      server_pid = Process.whereis(server)
      assert is_pid(server_pid)

      worktree_path = Path.join(tmp_dir, "blocker-lineage-worktree")
      File.mkdir_p!(worktree_path)

      # Inject a retention/creation blocker with exact matching lineage. Ordinary
      # inspect_lease may surface blockers; lineage-only inspect must not.
      :sys.replace_state(server_pid, fn state ->
        blocker = %{
          workspace_id: workspace_id,
          repo_path: repo,
          worktree_path: worktree_path,
          branch: "test/blocker-lineage",
          task_id: task_id,
          principal_id: principal_id,
          target: {repo, "test/blocker-lineage"},
          ownership: :pending,
          lifecycle: :creating,
          active: false,
          dormant: true,
          status: :creating_blocked
        }

        %{
          state
          | retention_blockers: Map.put(state.retention_blockers, workspace_id, blocker),
            retention_blockers_by_target:
              Map.put(state.retention_blockers_by_target, blocker.target, blocker)
        }
      end)

      assert map_size(:sys.get_state(server_pid).retention_blockers) == 1

      # Ordinary inspect may still expose the blocker to authorized lineage.
      assert {:ok, blocker_view} =
               WorkspaceLeaseRegistry.inspect_lease(workspace_id, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert blocker_view.active == false
      assert blocker_view.status == "creating_blocked" or blocker_view.lifecycle == "creating"

      # Lineage-only inspect authorizes and returns active leases only.
      assert {:error, :not_found} =
               WorkspaceLeaseRegistry.inspect_lease_by_lineage(
                 workspace_id,
                 task_id,
                 principal_id,
                 server: server
               )
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
            @owner_hold_timeout -> :ok
          end
        end)

      assert_receive {:leased, lease}, @owner_operation_timeout

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
            @owner_hold_timeout -> :ok
          end
        end)

      assert_receive {:leased, lease}, @owner_operation_timeout

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

      assert_receive {:leased, lease}, @owner_operation_timeout
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

      assert_receive {:leased, lease}, @owner_operation_timeout
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

    test "security regression: disabled journal keeps identity-invalid quarantine across reactivation and owner death",
         %{
           tmp_dir: tmp_dir
         } do
      fake_repo = Path.join(tmp_dir, "fake-repo")
      fake_worktree = Path.join(tmp_dir, "fake-worktree")
      branch = "test/workspace-owner-death-quarantine"
      create_git_repo(fake_repo)
      base_commit = git!(fake_repo, ["rev-parse", "HEAD"])
      git!(fake_repo, ["worktree", "add", "-b", branch, fake_worktree])
      File.write!(Path.join(fake_worktree, "partial.txt"), "recoverable\n")

      workspace_id = "ws_quarantine_#{System.unique_integer([:positive])}"
      task_id = "task-quarantine-#{System.unique_integer([:positive])}"
      principal_id = "agent-quarantine-#{System.unique_integer([:positive])}"
      parent = self()
      server = :"workspace_quarantine_#{System.unique_integer([:positive])}"

      start_supervised!(
        {WorkspaceLeaseRegistry,
         name: server,
         retention_ttl_ms: 50,
         retention_journal: :disabled,
         owner_death_retry_base_ms: 100,
         linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer}
      )

      create_worktree = fn _repo, _branch, _params ->
        {:ok, fake_worktree, :owned, base_commit}
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

      assert_receive {:leased, {:ok, lease}}, @owner_operation_timeout

      fresh = Map.fetch!(:sys.get_state(server).leases, workspace_id)
      refute Map.has_key?(fresh, :retention_marker_active)
      refute Map.has_key?(fresh, :retention_lstat_identity)

      unregister_worktree_preserving_path(fake_repo, fake_worktree)
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
      assert quarantined.repo_path == Workspace.canonical_path_or_expanded(fake_repo)
      assert quarantined.branch == branch
      assert quarantined.worktree_path == lease.worktree_path
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

      assert_receive {:reactivated, {:ok, reactivated}}, @owner_operation_timeout

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
      branch = "test/workspace-owner-death-retry"
      create_git_repo(fake_repo)
      base_commit = git!(fake_repo, ["rev-parse", "HEAD"])
      git!(fake_repo, ["worktree", "add", "-b", branch, fake_worktree])

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
        {:ok, fake_worktree, :owned, base_commit}
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

      assert_receive {:leased, {:ok, _lease}}, @owner_operation_timeout
      unregister_worktree_preserving_path(fake_repo, fake_worktree)
      Process.exit(owner, :kill)

      assert_eventually(fn ->
        quarantined = Map.get(:sys.get_state(server).leases, workspace_id)
        assert quarantined.cleanup_armed == false
        assert quarantined.owner_death_retry_count == 1
        assert is_reference(quarantined.owner_death_retry_ref)
      end)

      {:ok, _removed} = File.rm_rf(fake_worktree)
      git!(fake_repo, ["worktree", "add", fake_worktree, branch])

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
      branch = "test/workspace-owner-death-pinned"
      create_git_repo(fake_repo)
      base_commit = git!(fake_repo, ["rev-parse", "HEAD"])
      git!(fake_repo, ["worktree", "add", "-b", branch, fake_worktree])

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
        {:ok, fake_worktree, :owned, base_commit}
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

      assert_receive {:leased, {:ok, _lease}}, @owner_operation_timeout
      unregister_worktree_preserving_path(fake_repo, fake_worktree)
      Process.exit(owner, :kill)

      assert_eventually(fn ->
        dormant = Map.get(:sys.get_state(server).leases, workspace_id)
        assert is_map(dormant)
        assert Map.get(dormant, :owner_death_quarantine_state) == :dormant
      end)

      {:ok, _removed} = File.rm_rf(fake_worktree)
      git!(fake_repo, ["worktree", "add", fake_worktree, branch])

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

      assert_receive {:reactivated, {:ok, _reactivated}}, @owner_operation_timeout

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
      branch = "test/workspace-owner-death-dormant"
      create_git_repo(fake_repo)
      base_commit = git!(fake_repo, ["rev-parse", "HEAD"])
      git!(fake_repo, ["worktree", "add", "-b", branch, fake_worktree])
      File.write!(Path.join(fake_worktree, "preserve.txt"), "do not delete\n")

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
        {:ok, fake_worktree, :owned, base_commit}
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

      assert_receive {:leased, {:ok, _lease}}, @owner_operation_timeout
      unregister_worktree_preserving_path(fake_repo, fake_worktree)
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

      assert_receive {:leased, lease, head}, @owner_operation_timeout
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

      assert_receive {:leased, lease}, @owner_operation_timeout
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
      canonical_worktree_path = git!(worktree_path, ["rev-parse", "--show-toplevel"])
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
            @owner_hold_timeout -> :ok
          end
        end)

      assert_receive {:leased, lease}, @owner_operation_timeout
      assert lease.ownership == "reused"
      assert lease.worktree_path == canonical_worktree_path

      Process.exit(owner, :kill)
      Process.sleep(150)

      # Reused path must survive owner death even with dirty uncommitted files.
      assert File.dir?(canonical_worktree_path)
      assert worktree_registered?(repo, canonical_worktree_path)
      assert git!(canonical_worktree_path, ["rev-parse", "--is-inside-work-tree"]) == "true"
      assert git!(canonical_worktree_path, ["branch", "--show-current"]) == branch
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
      task_id = "task-acquire-cancel-#{System.unique_integer([:positive])}"
      principal_id = "agent-acquire-cancel"
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
                task_id: task_id,
                principal_id: principal_id,
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
        300
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

    test "security regression: post-create failure retires its created branch", %{
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
                     {:ok, path, :owned, _base_commit, provenance} =
                       Workspace.create_worktree(repo_path, branch_name, params)

                     # A freshly created branch carries :created provenance.
                     assert provenance == :created

                     # Real owned worktree exists; fail finalization after its
                     # ownership is known so cleanup is authorized.
                     {:ok, path, :owned, nil, :created}
                   end
                 },
                 server: server
               )

      expected_path = expected_worktree_path(worktree_base, branch)
      refute File.dir?(expected_path)
      refute worktree_registered?(repo_root, expected_path)
      assert {:ok, :absent} = Git.observe_branch_ref(repo_root, branch)

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
      assert lease.branch_provenance == "created"

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{server: server})
    end

    test "security regression: post-create failure preserves a reused branch", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      repo_root = git!(repo, ["rev-parse", "--show-toplevel"])
      branch = "test/workspace-post-create-reused"
      worktree_base = Path.join(tmp_dir, "worktrees")
      workspace_id = "ws_post_create_reused_#{System.unique_integer([:positive])}"
      server = :"workspace_lease_post_create_reused_#{System.unique_integer([:positive])}"

      git!(repo_root, ["branch", branch])
      expected_tip = git!(repo_root, ["rev-parse", branch])

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
                     {:ok, path, :owned, _base_commit, provenance} =
                       Workspace.create_worktree(repo_path, branch_name, params)

                     assert provenance == :reused
                     {:ok, path, :owned, nil, :reused}
                   end
                 },
                 server: server
               )

      expected_path = expected_worktree_path(worktree_base, branch)
      refute File.dir?(expected_path)
      refute worktree_registered?(repo_root, expected_path)
      assert {:ok, {:present, ^expected_tip}} = Git.observe_branch_ref(repo_root, branch)

      assert {:error, :not_found} =
               WorkspaceLeaseRegistry.inspect_lease(workspace_id, %{server: server})
    end

    test "security regression: post-create failure preserves unknown branch provenance", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      repo_root = git!(repo, ["rev-parse", "--show-toplevel"])
      branch = "test/workspace-post-create-unknown"
      worktree_base = Path.join(tmp_dir, "worktrees")
      workspace_id = "ws_post_create_unknown_#{System.unique_integer([:positive])}"
      server = :"workspace_lease_post_create_unknown_#{System.unique_integer([:positive])}"

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
                     {:ok, path, :owned, _expected_tip, :created} =
                       Workspace.create_worktree(repo_path, branch_name, params)

                     # Legacy four-tuples carry no provenance. Cleanup may
                     # remove the owned worktree but must preserve the branch.
                     {:ok, path, :owned, nil}
                   end
                 },
                 server: server
               )

      expected_path = expected_worktree_path(worktree_base, branch)
      refute File.dir?(expected_path)
      refute worktree_registered?(repo_root, expected_path)

      assert {:ok, {:present, _expected_tip}} = Git.observe_branch_ref(repo_root, branch)

      assert {:error, :not_found} =
               WorkspaceLeaseRegistry.inspect_lease(workspace_id, %{server: server})
    end

    test "security regression: post-create branch tip race preserves durable residue", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      repo_root = git!(repo, ["rev-parse", "--show-toplevel"])
      expected_tip = git!(repo_root, ["rev-parse", "HEAD"])

      File.write!(Path.join(repo_root, "alternate.txt"), "alternate\n")
      git!(repo_root, ["add", "alternate.txt"])
      git!(repo_root, ["commit", "-m", "alternate tip"])
      replacement_tip = git!(repo_root, ["rev-parse", "HEAD"])

      branch = "test/workspace-post-create-tip-race"
      worktree_base = Path.join(tmp_dir, "worktrees")
      workspace_id = "ws_post_create_tip_race_#{System.unique_integer([:positive])}"
      server = :"workspace_lease_post_create_tip_race_#{System.unique_integer([:positive])}"

      cleanup = fn retained ->
        result = WorkspaceLeaseRegistry.remove_owned_retained_worktree(retained)

        if result == :ok do
          git!(repo_root, [
            "update-ref",
            "refs/heads/#{branch}",
            replacement_tip,
            expected_tip
          ])
        end

        result
      end

      start_supervised!(
        {WorkspaceLeaseRegistry,
         name: server,
         retention_journal: :disabled,
         retained_cleanup: cleanup,
         linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer}
      )

      assert {:error, {:invalid, :base_commit}} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   workspace_id: workspace_id,
                   repo_path: repo_root,
                   branch: branch,
                   base_ref: expected_tip,
                   worktree_base_dir: worktree_base,
                   create_worktree: fn repo_path, branch_name, params ->
                     {:ok, path, :owned, ^expected_tip, :created} =
                       Workspace.create_worktree(repo_path, branch_name, params)

                     {:ok, path, :owned, nil, :created}
                   end
                 },
                 server: server
               )

      expected_path = expected_worktree_path(worktree_base, branch)
      refute File.dir?(expected_path)
      refute worktree_registered?(repo_root, expected_path)

      assert {:ok, {:present, ^replacement_tip}} = Git.observe_branch_ref(repo_root, branch)

      state = :sys.get_state(server)
      assert %{^workspace_id => retained} = state.retained_by_id
      assert retained.lifecycle == :discarding
      assert retained.discard_phase == :branch
      assert retained.dormant == true
      assert inspect(retained.cleanup_failure) =~ "branch_tip_diverged"
    end

    test "security regression: Workspace cleanup refuses a replacement inode", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      repo_root = git!(repo, ["rev-parse", "--show-toplevel"])
      branch = "test/workspace-cleanup-replacement"
      worktree_path = Path.join(tmp_dir, Workspace.worktree_dir_name(branch))
      base_commit = git!(repo_root, ["rev-parse", "HEAD"])

      assert {:ok, ^worktree_path, :owned, ^base_commit, :created} =
               Workspace.create_worktree(repo_root, branch, %{
                 worktree_base_dir: tmp_dir,
                 base_ref: base_commit
               })

      assert {:ok, identity} = Workspace.worktree_lstat_identity(worktree_path)
      File.rm_rf!(worktree_path)
      File.mkdir_p!(worktree_path)
      File.write!(Path.join(worktree_path, "survivor.txt"), "must-live\n")

      assert {:error, _reason} =
               Workspace.remove_owned_worktree(repo_root, worktree_path, identity)

      assert File.read!(Path.join(worktree_path, "survivor.txt")) == "must-live\n"
      assert worktree_registered?(repo_root, worktree_path)
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
            @owner_hold_timeout -> :ok
          end
        end)

      assert_receive {:leased, lease}, @owner_operation_timeout

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

  defp unregister_worktree_preserving_path(repo_root, worktree_path) do
    parked_path = worktree_path <> "-unregistered"
    File.rename!(worktree_path, parked_path)
    git!(repo_root, ["worktree", "prune", "--expire", "now"])
    File.rename!(parked_path, worktree_path)
    assert {:ok, nil} = Git.worktree_registration(repo_root, worktree_path)
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
