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

      File.write!(Path.join(lease.worktree_path, "dirty.txt"), "uncommitted\n")

      assert {:ok, dirty_view} =
               Workspace.Inspect.run(%{workspace_id: lease.workspace_id}, %{})

      assert dirty_view.dirty == true
      assert dirty_view.changed_from_base == true
      assert dirty_view.head_commit == base_commit
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

    test "owner death removes dirty owned worktrees", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/workspace-owner-death-owned"
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

          File.write!(Path.join(lease.worktree_path, "dirty.txt"), "uncommitted\n")
          send(parent, {:leased, lease})

          receive do
            :never -> :ok
          after
            5_000 -> :ok
          end
        end)

      assert_receive {:leased, lease}, 2_000
      assert File.dir?(lease.worktree_path)
      assert File.exists?(Path.join(lease.worktree_path, "dirty.txt"))
      assert lease.ownership == "owned"

      Process.exit(owner, :kill)

      assert_eventually(fn ->
        refute File.dir?(lease.worktree_path)
      end)
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
    test "caller death during acquire cleans the newly stored owned worktree", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      repo_root = git!(repo, ["rev-parse", "--show-toplevel"])
      branch = "test/workspace-acquire-cancel"
      worktree_base = Path.join(tmp_dir, "worktrees")
      parent = self()

      # Private registry so the blocked create does not stall the shared app registry.
      server = :"workspace_lease_acquire_cancel_#{System.unique_integer([:positive])}"
      start_supervised!({WorkspaceLeaseRegistry, name: server})

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

      # Dead caller's GenServer reply is dropped; worktree must still be cleaned.
      refute_receive {:acquire_result, _}, 200

      expected_path = expected_worktree_path(worktree_base, branch)

      assert_eventually(fn ->
        refute File.dir?(expected_path)
      end)

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
      start_supervised!({WorkspaceLeaseRegistry, name: server})

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
