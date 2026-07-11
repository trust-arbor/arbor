defmodule Arbor.Actions.Coding.ReviewTreeTest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions
  alias Arbor.Actions.Coding.ReviewTree
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

  @moduletag :fast

  describe "discovery and canonical URIs" do
    test "review tree actions are registered under coding with precise URIs" do
      coding = Actions.list_actions().coding

      assert ReviewTree.Read in coding
      assert ReviewTree.Search in coding

      assert {:ok, ReviewTree.Read} = Actions.name_to_module("coding_review_tree_read")
      assert {:ok, ReviewTree.Search} = Actions.name_to_module("coding_review_tree_search")
      assert {:ok, ReviewTree.Read} = Actions.name_to_module("coding.review_tree.read")
      assert {:ok, ReviewTree.Search} = Actions.name_to_module("coding.review_tree.search")

      assert Actions.canonical_uri_for(ReviewTree.Read, %{}) ==
               "arbor://action/coding/review_tree/read"

      assert Actions.canonical_uri_for(ReviewTree.Search, %{}) ==
               "arbor://action/coding/review_tree/search"

      assert ReviewTree.Read.name() == "coding_review_tree_read"
      assert ReviewTree.Search.name() == "coding_review_tree_search"
      assert ReviewTree.Read.category() == "coding"
      assert ReviewTree.Search.category() == "coding"
    end
  end

  describe "review snapshot + tree read/search" do
    test "candidate and base reads cover unchanged related files; search finds them", %{
      tmp_dir: tmp_dir
    } do
      fixture = build_review_fixture(tmp_dir)

      assert {:ok, snap} =
               WorkspaceLeaseRegistry.open_review_snapshot(
                 fixture.lease.workspace_id,
                 fixture.candidate_commit,
                 fixture.context
               )

      assert Workspace.json_clean?(snap)
      refute_pid_like(snap)
      assert is_binary(snap.review_snapshot_id)
      assert String.starts_with?(snap.review_snapshot_id, "review_snap_")
      assert snap.candidate_commit == fixture.candidate_commit
      assert snap.base_commit == fixture.base_commit
      assert snap.candidate_tree_oid == fixture.candidate_tree_oid
      assert snap.base_tree_oid == fixture.base_tree_oid
      assert snap.active == true

      # Candidate sees the changed module.
      assert {:ok, candidate_read} =
               ReviewTree.Read.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "candidate",
                   path: "lib/changed.ex"
                 },
                 fixture.context
               )

      assert candidate_read.content == "defmodule Changed do\n  def v, do: :candidate\nend\n"
      assert candidate_read.commit == fixture.candidate_commit
      assert candidate_read.revision == "candidate"
      assert candidate_read.size == byte_size(candidate_read.content)
      assert Workspace.json_clean?(candidate_read)

      # Base sees the pre-change content.
      assert {:ok, base_read} =
               ReviewTree.Read.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "base",
                   path: "lib/changed.ex"
                 },
                 fixture.context
               )

      assert base_read.content == "defmodule Changed do\n  def v, do: :base\nend\n"
      assert base_read.commit == fixture.base_commit

      # Unchanged related file is readable from both trees.
      assert {:ok, related_candidate} =
               ReviewTree.Read.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "candidate",
                   path: "lib/related.ex"
                 },
                 fixture.context
               )

      assert related_candidate.content =~ "RELATED_TOKEN_ALPHA"

      assert {:ok, related_base} =
               ReviewTree.Read.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "base",
                   path: "lib/related.ex"
                 },
                 fixture.context
               )

      assert related_base.content == related_candidate.content

      # Search across the full candidate tree finds the unchanged related file.
      assert {:ok, search} =
               ReviewTree.Search.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "candidate",
                   query: "RELATED_TOKEN_ALPHA",
                   limit: 10
                 },
                 fixture.context
               )

      assert search.match_count >= 1
      assert Enum.any?(search.matches, fn m -> m.path == "lib/related.ex" end)
      assert Workspace.json_clean?(search)
      assert search.truncated == false
    end

    test "snapshot is immutable after live worktree and HEAD change", %{tmp_dir: tmp_dir} do
      fixture = build_review_fixture(tmp_dir)

      assert {:ok, snap} =
               WorkspaceLeaseRegistry.open_review_snapshot(
                 fixture.lease.workspace_id,
                 fixture.candidate_commit,
                 fixture.context
               )

      # Mutate the live worktree and advance HEAD after the snapshot is bound.
      File.write!(
        Path.join(fixture.lease.worktree_path, "lib/changed.ex"),
        "defmodule Changed do\n  def v, do: :live_dirty\nend\n"
      )

      git!(fixture.lease.worktree_path, ["add", "lib/changed.ex"])
      git!(fixture.lease.worktree_path, ["commit", "-m", "post-snapshot mutation"])
      File.write!(Path.join(fixture.lease.worktree_path, "untracked_live.txt"), "live only\n")

      new_head = git!(fixture.lease.worktree_path, ["rev-parse", "HEAD"])
      refute new_head == fixture.candidate_commit

      assert {:ok, candidate_read} =
               ReviewTree.Read.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "candidate",
                   path: "lib/changed.ex"
                 },
                 fixture.context
               )

      assert candidate_read.content == "defmodule Changed do\n  def v, do: :candidate\nend\n"
      assert candidate_read.commit == fixture.candidate_commit

      assert {:ok, resolved} =
               WorkspaceLeaseRegistry.resolve_review_snapshot(
                 snap.review_snapshot_id,
                 fixture.context
               )

      assert resolved.candidate_commit == fixture.candidate_commit
      assert resolved.candidate_tree_oid == fixture.candidate_tree_oid
    end

    test "excludes untracked and .git content by construction", %{tmp_dir: tmp_dir} do
      fixture = build_review_fixture(tmp_dir)

      assert {:ok, snap} =
               WorkspaceLeaseRegistry.open_review_snapshot(
                 fixture.lease.workspace_id,
                 fixture.candidate_commit,
                 fixture.context
               )

      # Untracked content added after the snapshot must not become readable.
      File.write!(
        Path.join(fixture.lease.worktree_path, "secret_untracked.ex"),
        "UNTRACKED_SECRET\n"
      )

      assert {:error, :missing_path} =
               ReviewTree.Read.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "candidate",
                   path: "secret_untracked.ex"
                 },
                 fixture.context
               )

      assert {:error, :path_traversal} =
               ReviewTree.Read.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "candidate",
                   path: ".git/config"
                 },
                 fixture.context
               )

      assert {:ok, search} =
               ReviewTree.Search.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "candidate",
                   query: "UNTRACKED_SECRET"
                 },
                 fixture.context
               )

      assert search.matches == []
      assert search.match_count == 0
    end

    test "rejects traversal, absolute paths, bad revision, and unsupported inputs", %{
      tmp_dir: tmp_dir
    } do
      fixture = build_review_fixture(tmp_dir)

      assert {:ok, snap} =
               WorkspaceLeaseRegistry.open_review_snapshot(
                 fixture.lease.workspace_id,
                 fixture.candidate_commit,
                 fixture.context
               )

      assert {:error, :absolute_path} =
               ReviewTree.Read.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "candidate",
                   path: "/etc/passwd"
                 },
                 fixture.context
               )

      assert {:error, :path_traversal} =
               ReviewTree.Read.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "candidate",
                   path: "../outside.ex"
                 },
                 fixture.context
               )

      assert {:error, :path_traversal} =
               ReviewTree.Read.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "candidate",
                   path: "lib/../../etc/passwd"
                 },
                 fixture.context
               )

      assert {:error, :unsupported_revision} =
               ReviewTree.Read.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "HEAD",
                   path: "lib/related.ex"
                 },
                 fixture.context
               )

      assert {:error, :unsupported_revision} =
               ReviewTree.Search.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: fixture.candidate_commit,
                   query: "RELATED"
                 },
                 fixture.context
               )

      assert {:error, :invalid_query} =
               ReviewTree.Search.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "candidate",
                   query: ""
                 },
                 fixture.context
               )

      assert {:error, :query_too_long} =
               ReviewTree.Search.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "candidate",
                   query: String.duplicate("a", ReviewTree.max_query_bytes() + 1)
                 },
                 fixture.context
               )

      assert {:error, :invalid_limit} =
               ReviewTree.Search.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "candidate",
                   query: "RELATED",
                   limit: 0
                 },
                 fixture.context
               )

      assert {:error, :invalid_limit} =
               ReviewTree.Search.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "candidate",
                   query: "RELATED",
                   limit: ReviewTree.max_search_limit() + 1
                 },
                 fixture.context
               )
    end

    test "authority isolation: opaque id alone and cross-task/principal are denied", %{
      tmp_dir: tmp_dir
    } do
      # Acquire + open in a foreign owner process so this test process is not the owner.
      parent = self()
      task_id = "task_auth_#{System.unique_integer([:positive])}"
      principal_id = "agent_auth_#{System.unique_integer([:positive])}"
      context = %{task_id: task_id, agent_id: principal_id}
      repo = create_git_repo(Path.join(tmp_dir, "auth_repo"))

      File.mkdir_p!(Path.join(repo, "lib"))
      File.write!(Path.join(repo, "lib/related.ex"), "RELATED_TOKEN_AUTH\n")
      git!(repo, ["add", "lib/related.ex"])
      git!(repo, ["commit", "-m", "auth base"])
      base = git!(repo, ["rev-parse", "HEAD"])

      owner =
        spawn(fn ->
          {:ok, lease} =
            Workspace.Acquire.run(
              %{
                repo_path: repo,
                branch_name: "test/auth-#{System.unique_integer([:positive])}",
                worktree_base_dir: Path.join(tmp_dir, "auth_worktrees"),
                base_ref: base
              },
              context
            )

          File.write!(Path.join(lease.worktree_path, "lib/changed.ex"), "CHANGED\n")
          git!(lease.worktree_path, ["add", "lib/changed.ex"])
          git!(lease.worktree_path, ["commit", "-m", "candidate"])
          candidate = git!(lease.worktree_path, ["rev-parse", "HEAD"])

          {:ok, snap} =
            WorkspaceLeaseRegistry.open_review_snapshot(
              lease.workspace_id,
              candidate,
              context
            )

          send(parent, {:auth_snap, snap.review_snapshot_id})

          receive do
            :hold -> :ok
          after
            5_000 -> :ok
          end
        end)

      assert_receive {:auth_snap, snap_id}, 3_000

      # Opaque snapshot id alone is never authority (this process is not owner).
      assert {:error, :not_authorized} =
               WorkspaceLeaseRegistry.resolve_review_snapshot(snap_id, %{})

      assert {:error, :not_authorized} =
               ReviewTree.Read.run(
                 %{
                   review_snapshot_id: snap_id,
                   revision: "candidate",
                   path: "lib/related.ex"
                 },
                 %{}
               )

      assert {:error, :not_authorized} =
               ReviewTree.Search.run(
                 %{
                   review_snapshot_id: snap_id,
                   revision: "candidate",
                   query: "RELATED"
                 },
                 %{}
               )

      # Cross-task denied.
      assert {:error, :not_authorized} =
               WorkspaceLeaseRegistry.resolve_review_snapshot(snap_id, %{
                 task_id: "other_task",
                 principal_id: principal_id
               })

      # Cross-principal denied.
      assert {:error, :not_authorized} =
               WorkspaceLeaseRegistry.resolve_review_snapshot(snap_id, %{
                 task_id: task_id,
                 principal_id: "agent_other"
               })

      # Task without principal denied.
      assert {:error, :not_authorized} =
               WorkspaceLeaseRegistry.resolve_review_snapshot(snap_id, %{
                 task_id: task_id
               })

      # Matching task+principal authorizes resume from this process.
      assert {:ok, _} =
               WorkspaceLeaseRegistry.resolve_review_snapshot(snap_id, %{
                 task_id: task_id,
                 principal_id: principal_id
               })

      send(owner, :hold)
    end

    test "close is idempotent; release and owner-death clean snapshots", %{tmp_dir: tmp_dir} do
      fixture = build_review_fixture(tmp_dir)

      assert {:ok, snap} =
               WorkspaceLeaseRegistry.open_review_snapshot(
                 fixture.lease.workspace_id,
                 fixture.candidate_commit,
                 fixture.context
               )

      assert {:ok, closed} =
               WorkspaceLeaseRegistry.close_review_snapshot(
                 snap.review_snapshot_id,
                 fixture.context
               )

      assert closed.status == "closed"
      assert closed.active == false

      assert {:ok, again} =
               WorkspaceLeaseRegistry.close_review_snapshot(
                 snap.review_snapshot_id,
                 fixture.context
               )

      assert again.status == "already_closed"
      assert again.active == false

      # Closed snapshot is not resolvable.
      assert {:error, :not_found} =
               WorkspaceLeaseRegistry.resolve_review_snapshot(
                 snap.review_snapshot_id,
                 fixture.context
               )

      # Re-open and prove workspace release cleans snapshots.
      assert {:ok, snap2} =
               WorkspaceLeaseRegistry.open_review_snapshot(
                 fixture.lease.workspace_id,
                 fixture.candidate_commit,
                 fixture.context
               )

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(
                 fixture.lease.workspace_id,
                 :retain,
                 fixture.context
               )

      assert {:error, :not_found} =
               WorkspaceLeaseRegistry.resolve_review_snapshot(
                 snap2.review_snapshot_id,
                 fixture.context
               )

      # Owner-death cleanup removes snapshots with the lease.
      parent = self()
      task_id = "task_owner_death_#{System.unique_integer([:positive])}"
      principal_id = "agent_owner_death_#{System.unique_integer([:positive])}"
      context = %{task_id: task_id, agent_id: principal_id}
      repo = create_git_repo(Path.join(tmp_dir, "owner_death_repo"))
      base = git!(repo, ["rev-parse", "HEAD"])

      owner =
        spawn(fn ->
          {:ok, lease} =
            Workspace.Acquire.run(
              %{
                repo_path: repo,
                branch_name: "test/owner-death-#{System.unique_integer([:positive])}",
                worktree_base_dir: Path.join(tmp_dir, "owner_death_worktrees"),
                base_ref: base
              },
              context
            )

          File.write!(Path.join(lease.worktree_path, "note.txt"), "owned\n")
          git!(lease.worktree_path, ["add", "note.txt"])
          git!(lease.worktree_path, ["commit", "-m", "candidate"])
          candidate = git!(lease.worktree_path, ["rev-parse", "HEAD"])

          {:ok, s} =
            WorkspaceLeaseRegistry.open_review_snapshot(
              lease.workspace_id,
              candidate,
              context
            )

          send(parent, {:owner_snap, s.review_snapshot_id})

          receive do
            :hold -> :ok
          after
            5_000 -> :ok
          end
        end)

      assert_receive {:owner_snap, owner_snap_id}, 3_000

      Process.exit(owner, :kill)

      assert_eventually(fn ->
        assert {:error, :not_found} =
                 WorkspaceLeaseRegistry.resolve_review_snapshot(owner_snap_id, context)
      end)
    end

    test "open rejects dirty worktree, HEAD mismatch, and short/non-hash commits", %{
      tmp_dir: tmp_dir
    } do
      fixture = build_review_fixture(tmp_dir)

      File.write!(Path.join(fixture.lease.worktree_path, "dirty.txt"), "x\n")

      assert {:error, :dirty_workspace} =
               WorkspaceLeaseRegistry.open_review_snapshot(
                 fixture.lease.workspace_id,
                 fixture.candidate_commit,
                 fixture.context
               )

      File.rm!(Path.join(fixture.lease.worktree_path, "dirty.txt"))

      assert {:error, :invalid_candidate_commit} =
               WorkspaceLeaseRegistry.open_review_snapshot(
                 fixture.lease.workspace_id,
                 "HEAD",
                 fixture.context
               )

      assert {:error, :invalid_candidate_commit} =
               WorkspaceLeaseRegistry.open_review_snapshot(
                 fixture.lease.workspace_id,
                 String.slice(fixture.candidate_commit, 0, 7),
                 fixture.context
               )

      other = String.duplicate("a", 40)

      assert {:error, :head_commit_mismatch} =
               WorkspaceLeaseRegistry.open_review_snapshot(
                 fixture.lease.workspace_id,
                 other,
                 fixture.context
               )
    end

    test "search result limit bounds and truncates", %{tmp_dir: tmp_dir} do
      fixture = build_review_fixture(tmp_dir)

      # Add multiple matching lines in the candidate tree.
      content =
        Enum.map_join(1..30, "\n", fn i -> "MATCH_TOKEN line #{i}" end) <> "\n"

      File.write!(Path.join(fixture.lease.worktree_path, "lib/many.ex"), content)
      git!(fixture.lease.worktree_path, ["add", "lib/many.ex"])
      git!(fixture.lease.worktree_path, ["commit", "-m", "many matches"])
      candidate = git!(fixture.lease.worktree_path, ["rev-parse", "HEAD"])

      assert {:ok, snap} =
               WorkspaceLeaseRegistry.open_review_snapshot(
                 fixture.lease.workspace_id,
                 candidate,
                 fixture.context
               )

      assert {:ok, search} =
               ReviewTree.Search.run(
                 %{
                   review_snapshot_id: snap.review_snapshot_id,
                   revision: "candidate",
                   query: "MATCH_TOKEN",
                   limit: 5
                 },
                 fixture.context
               )

      assert search.match_count == 5
      assert search.truncated == true
      assert length(search.matches) == 5
    end
  end

  # -- fixtures -------------------------------------------------------

  defp build_review_fixture(tmp_dir, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "review")

    repo =
      create_git_repo(Path.join(tmp_dir, "#{prefix}_repo_#{System.unique_integer([:positive])}"))

    File.mkdir_p!(Path.join(repo, "lib"))

    File.write!(Path.join(repo, "lib/related.ex"), """
    defmodule Related do
      def token, do: :RELATED_TOKEN_ALPHA
    end
    """)

    File.write!(Path.join(repo, "lib/changed.ex"), """
    defmodule Changed do
      def v, do: :base
    end
    """)

    git!(repo, ["add", "lib/related.ex", "lib/changed.ex"])
    git!(repo, ["commit", "-m", "base tree"])
    base_commit = git!(repo, ["rev-parse", "HEAD"])
    base_tree_oid = git!(repo, ["rev-parse", "#{base_commit}^{tree}"])

    task_id = "task_#{prefix}_#{System.unique_integer([:positive])}"
    principal_id = "agent_#{prefix}_#{System.unique_integer([:positive])}"
    context = %{task_id: task_id, agent_id: principal_id}

    assert {:ok, lease} =
             Workspace.Acquire.run(
               %{
                 repo_path: repo,
                 branch_name: "test/#{prefix}-#{System.unique_integer([:positive])}",
                 worktree_base_dir: Path.join(tmp_dir, "#{prefix}_worktrees"),
                 base_ref: base_commit
               },
               context
             )

    File.write!(Path.join(lease.worktree_path, "lib/changed.ex"), """
    defmodule Changed do
      def v, do: :candidate
    end
    """)

    git!(lease.worktree_path, ["add", "lib/changed.ex"])
    git!(lease.worktree_path, ["commit", "-m", "candidate change"])
    candidate_commit = git!(lease.worktree_path, ["rev-parse", "HEAD"])
    candidate_tree_oid = git!(lease.worktree_path, ["rev-parse", "#{candidate_commit}^{tree}"])

    %{
      repo: repo,
      lease: lease,
      context: context,
      task_id: task_id,
      principal_id: principal_id,
      base_commit: base_commit,
      base_tree_oid: base_tree_oid,
      candidate_commit: candidate_commit,
      candidate_tree_oid: candidate_tree_oid
    }
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

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
