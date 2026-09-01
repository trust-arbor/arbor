defmodule Arbor.Actions.Coding.CandidateMaterializationSecurityRegressionTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.BlobManifest
  alias Arbor.Actions.Coding.CandidateMaterializationShell
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Git
  alias Arbor.Actions.TestLinuxBaselineMaterializer
  alias Arbor.Shell.ExecutionRegistry

  @moduletag :fast

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil -> {:ok, _} = Application.ensure_all_started(:arbor_shell)
      _pid -> :ok
    end

    :ok
  end

  test "security regression: failed admission and snapshot create no evidence ref and launch no Mix child",
       %{tmp_dir: tmp_dir} do
    server = :"g5b2a_sec_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: {WorkspaceLeaseRegistry, server},
      start:
        {WorkspaceLeaseRegistry, :start_link,
         [
           [
             name: server,
             retention_journal: :disabled,
             linux_dependency_baseline_materializer: TestLinuxBaselineMaterializer
           ]
         ]}
    })

    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    task_id = "task_sec_#{System.unique_integer([:positive])}"
    principal_id = "agent_sec_#{System.unique_integer([:positive])}"

    {:ok, lease} =
      WorkspaceLeaseRegistry.acquire(
        %{
          repo_path: repo,
          branch: "test/g5b2a-sec",
          worktree_base_dir: Path.join(tmp_dir, "worktrees"),
          task_id: task_id,
          principal_id: principal_id
        },
        server: server
      )

    File.mkdir_p!(Path.join(lease.worktree_path, "lib"))
    File.write!(Path.join(lease.worktree_path, "lib/a.ex"), "defmodule A do\nend\n")
    git!(lease.worktree_path, ["add", "lib/a.ex"])
    git!(lease.worktree_path, ["commit", "-m", "add a"])
    source = git!(lease.worktree_path, ["rev-parse", "HEAD"])
    descriptor = descriptor_between(lease.repo_path, lease.base_commit, source)

    on_exit(fn ->
      _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{server: server})
    end)

    {:ok, before_execs} = ExecutionRegistry.list()
    before_ids = MapSet.new(Enum.map(before_execs, & &1.id))

    assert {:error, :workspace_unauthorized} =
             CandidateMaterializationShell.admit_and_materialize(%{
               workspace_id: lease.workspace_id,
               task_id: task_id,
               principal_id: "agent_other",
               candidate_materialization: descriptor,
               server: server
             })

    extra = %{
      "path" => "lib/zzz.ex",
      "blob_oid" => hd(descriptor["entries"])["blob_oid"],
      "mode" => 100_644
    }

    bad_delta =
      Map.put(
        descriptor,
        "entries",
        Enum.sort_by([hd(descriptor["entries"]), extra], & &1["path"])
      )

    assert {:error, :extra_descriptor_path} =
             CandidateMaterializationShell.admit_and_materialize(%{
               workspace_id: lease.workspace_id,
               task_id: task_id,
               principal_id: principal_id,
               candidate_materialization: bad_delta,
               server: server
             })

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               lease.workspace_id,
               %{
                 task_id: task_id,
                 principal_id: principal_id,
                 object_backed_snapshot: true,
                 server: server
               }
             )

    {:ok, listing} = Git.ls_tree_z(lease.repo_path, source)
    {:ok, manifest} = BlobManifest.parse_ls_tree_z(listing)

    assert {:error, :admitted_tree_mismatch} =
             WorkspaceLeaseRegistry.materialize_object_backed_snapshot(
               resource.resource_id,
               %{
                 expected_tree_oid: lease.base_commit,
                 object_format: :sha1,
                 blob_manifest: manifest
               },
               %{task_id: task_id, principal_id: principal_id, server: server}
             )

    refute match?(
             {:ok, _},
             Git.verify_archived_evidence_ref(
               lease.repo_path,
               task_id,
               lease.workspace_id,
               source
             )
           )

    {:ok, after_execs} = ExecutionRegistry.list()

    new_mix? =
      Enum.any?(after_execs, fn exec ->
        exec.id not in before_ids and mix_validation_child?(exec)
      end)

    refute new_mix?

    _ =
      WorkspaceLeaseRegistry.release_validation_resource(resource.resource_id, %{
        task_id: task_id,
        principal_id: principal_id,
        server: server
      })
  end

  test "security regression: object-backed materialization rejects an ordinary resource without mutation",
       %{tmp_dir: tmp_dir} do
    server = :"g5b2a_cross_mode_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: {WorkspaceLeaseRegistry, server},
      start:
        {WorkspaceLeaseRegistry, :start_link,
         [
           [
             name: server,
             retention_journal: :disabled,
             linux_dependency_baseline_materializer: TestLinuxBaselineMaterializer
           ]
         ]}
    })

    repo = create_git_repo(Path.join(tmp_dir, "cross-mode-repo"))
    task_id = "task_cross_mode_#{System.unique_integer([:positive])}"
    principal_id = "agent_cross_mode_#{System.unique_integer([:positive])}"

    {:ok, lease} =
      WorkspaceLeaseRegistry.acquire(
        %{
          repo_path: repo,
          branch: "test/g5b2a-cross-mode",
          worktree_base_dir: Path.join(tmp_dir, "cross-mode-worktrees"),
          task_id: task_id,
          principal_id: principal_id
        },
        server: server
      )

    on_exit(fn ->
      _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{server: server})
    end)

    candidate_file = Path.join(lease.worktree_path, "README.md")
    File.write!(candidate_file, "committed candidate\n")
    git!(lease.worktree_path, ["add", "README.md"])
    git!(lease.worktree_path, ["commit", "-m", "candidate source"])
    source = git!(lease.worktree_path, ["rev-parse", "HEAD"])
    {:ok, tree} = Git.commit_tree_oid(repo, source)
    {:ok, listing} = Git.ls_tree_z(repo, source)
    {:ok, manifest} = BlobManifest.parse_ls_tree_z(listing)

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               lease.workspace_id,
               %{task_id: task_id, principal_id: principal_id, server: server}
             )

    assert resource.candidate_path == lease.worktree_path

    File.write!(candidate_file, "uncommitted operator draft\n")
    before = ordinary_resource_snapshot(resource, lease.worktree_path)
    {:ok, before_execs} = ExecutionRegistry.list()
    before_ids = MapSet.new(Enum.map(before_execs, & &1.id))

    refute match?(
             {:ok, _},
             Git.verify_archived_evidence_ref(repo, task_id, lease.workspace_id, source)
           )

    assert {:error, :invalid_validation_resource_request} =
             WorkspaceLeaseRegistry.materialize_object_backed_snapshot(
               resource.resource_id,
               %{
                 expected_tree_oid: tree,
                 object_format: :sha1,
                 blob_manifest: manifest
               },
               %{task_id: task_id, principal_id: principal_id, server: server}
             )

    assert ordinary_resource_snapshot(resource, lease.worktree_path) == before
    refute File.exists?(Path.join(resource.root_path, "candidate-objects"))
    refute File.exists?(Path.join(resource.root_path, "candidate.index"))

    refute match?(
             {:ok, _},
             Git.verify_archived_evidence_ref(repo, task_id, lease.workspace_id, source)
           )

    {:ok, after_execs} = ExecutionRegistry.list()

    refute Enum.any?(after_execs, fn exec ->
             exec.id not in before_ids and mix_validation_child?(exec)
           end)

    _ =
      WorkspaceLeaseRegistry.release_validation_resource(resource.resource_id, %{
        task_id: task_id,
        principal_id: principal_id,
        server: server
      })
  end

  defp ordinary_resource_snapshot(resource, worktree) do
    %{
      candidate_bytes: File.read!(Path.join(worktree, "README.md")),
      candidate_entries: File.ls!(worktree) |> Enum.sort(),
      status: git!(worktree, ["status", "--porcelain", "-z"]),
      index: git!(worktree, ["write-tree"]),
      branch: git!(worktree, ["branch", "--show-current"]),
      head: git!(worktree, ["rev-parse", "HEAD"]),
      root_entries: File.ls!(resource.root_path) |> Enum.sort()
    }
  end

  defp mix_validation_child?(exec) when is_map(exec) do
    command = Map.get(exec, :command) || ""
    base = Path.basename(command)
    base in ["mix", "elixir"] or String.contains?(command, "/mix")
  end

  defp descriptor_between(repo, base, source) do
    {:ok, base_listing} = Git.ls_tree_z(repo, base)
    {:ok, source_listing} = Git.ls_tree_z(repo, source)
    {:ok, base_manifest} = BlobManifest.parse_ls_tree_z(base_listing)
    {:ok, source_manifest} = BlobManifest.parse_ls_tree_z(source_listing)
    {:ok, changed} = BlobManifest.diff_blob_manifests(base_manifest, source_manifest)
    {:ok, tree} = Git.commit_tree_oid(repo, source)
    by_path = Map.new(source_manifest, &{&1.path, &1})

    entries =
      Enum.map(changed, fn path ->
        entry = Map.fetch!(by_path, path)
        %{"path" => entry.path, "blob_oid" => entry.oid, "mode" => 100_644}
      end)

    %{
      "source_commit_oid" => source,
      "expected_tree_oid" => tree,
      "entries" => entries
    }
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
