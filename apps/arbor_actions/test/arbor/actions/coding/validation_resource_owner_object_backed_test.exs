defmodule Arbor.Actions.Coding.ValidationResourceOwnerObjectBackedTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.BlobManifest
  alias Arbor.Actions.Coding.CandidateMaterializationShell
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Git
  alias Arbor.Actions.TestLinuxBaselineMaterializer

  @moduletag :fast

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil -> {:ok, _} = Application.ensure_all_started(:arbor_shell)
      _pid -> :ok
    end

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    fixture = leased_repo(tmp_dir, "repo", "test/g5b2a-owner")
    {source, descriptor, snapshot} = commit_add(fixture)
    Map.merge(fixture, %{source: source, descriptor: descriptor, snapshot: snapshot})
  end

  test "reconstructs the SHA-1 tree into the private dest and leaves the task worktree untouched",
       %{
         server: server,
         lease: lease,
         task_id: task_id,
         principal_id: principal_id,
         worktree: worktree,
         descriptor: descriptor,
         snapshot: snapshot
       } do
    assert {:ok, result} =
             CandidateMaterializationShell.admit_and_materialize(
               input(lease, task_id, principal_id, descriptor, server)
             )

    assert File.read!(Path.join(result.candidate_path, "lib/a.ex")) == "defmodule A do\nend\n"
    refute result.candidate_path == worktree
    assert result.tree_oid == descriptor["expected_tree_oid"]
    assert is_map(result.dest_verify)
    assert_worktree_unchanged(worktree, snapshot)

    _ = release_resource(result.resource_id, task_id, principal_id, server)
  end

  test "SHA-256 object format reconstructs when git init supports it, otherwise fails closed", %{
    tmp_dir: tmp_dir
  } do
    probe = Path.join(tmp_dir, "sha256-probe")
    File.mkdir_p!(probe)

    {_, status} =
      System.cmd("git", ["init", "--bare", "--object-format=sha256", probe],
        stderr_to_stdout: true
      )

    if status != 0 do
      fixture =
        leased_repo(Path.join(tmp_dir, "sha256-unsup"), "sha1-repo", "test/g5b2a-sha256-unsup")

      {source, descriptor, snapshot} = commit_add(fixture)

      assert {:ok, resource} =
               WorkspaceLeaseRegistry.acquire_validation_resource(
                 fixture.lease.workspace_id,
                 %{
                   task_id: fixture.task_id,
                   principal_id: fixture.principal_id,
                   object_backed_snapshot: true,
                   server: fixture.server
                 }
               )

      {:ok, listing} = Git.ls_tree_z(fixture.repo, source)
      {:ok, manifest} = BlobManifest.parse_ls_tree_z(listing)

      assert {:error, :sha256_object_format_unsupported} =
               WorkspaceLeaseRegistry.materialize_object_backed_snapshot(
                 resource.resource_id,
                 %{
                   expected_tree_oid: descriptor["expected_tree_oid"],
                   object_format: :sha256,
                   blob_manifest: manifest
                 },
                 %{
                   task_id: fixture.task_id,
                   principal_id: fixture.principal_id,
                   server: fixture.server
                 }
               )

      assert_worktree_unchanged(fixture.worktree, snapshot)

      _ =
        release_resource(
          resource.resource_id,
          fixture.task_id,
          fixture.principal_id,
          fixture.server
        )
    else
      repo = Path.join(tmp_dir, "sha256-repo")
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "--object-format=sha256", repo], stderr_to_stdout: true)
      git!(repo, ["config", "user.email", "test@example.com"])
      git!(repo, ["config", "user.name", "Test User"])
      File.write!(Path.join(repo, "README.md"), "# Test Repository\n")
      git!(repo, ["add", "README.md"])
      git!(repo, ["commit", "-m", "Initial commit"])

      fixture =
        acquire_lease(repo, Path.join(tmp_dir, "sha256-worktrees"), "test/g5b2a-sha256")

      {source, descriptor, snapshot} = commit_add(fixture)
      assert byte_size(source) == 64
      assert byte_size(descriptor["expected_tree_oid"]) == 64

      assert {:ok, result} =
               CandidateMaterializationShell.admit_and_materialize(
                 input(
                   fixture.lease,
                   fixture.task_id,
                   fixture.principal_id,
                   descriptor,
                   fixture.server
                 )
               )

      assert result.object_format == "sha256"
      assert File.read!(Path.join(result.candidate_path, "lib/a.ex")) == "defmodule A do\nend\n"
      refute result.candidate_path == fixture.worktree
      assert is_map(result.dest_verify)
      assert_worktree_unchanged(fixture.worktree, snapshot)

      _ =
        release_resource(
          result.resource_id,
          fixture.task_id,
          fixture.principal_id,
          fixture.server
        )
    end
  end

  test "aggregate dest depth, entry, and byte ceilings fail closed without pinning", ctx do
    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               ctx.lease.workspace_id,
               %{
                 task_id: ctx.task_id,
                 principal_id: ctx.principal_id,
                 object_backed_snapshot: true,
                 server: ctx.server
               }
             )

    {:ok, listing} = Git.ls_tree_z(ctx.repo, ctx.source)
    {:ok, manifest} = BlobManifest.parse_ls_tree_z(listing)
    total = manifest_bytes(ctx.repo, manifest)

    assert {:error, :snapshot_budget_exceeded} =
             WorkspaceLeaseRegistry.materialize_object_backed_snapshot(
               resource.resource_id,
               %{
                 expected_tree_oid: ctx.descriptor["expected_tree_oid"],
                 object_format: :sha1,
                 blob_manifest: manifest,
                 max_depth: 0
               },
               %{task_id: ctx.task_id, principal_id: ctx.principal_id, server: ctx.server}
             )

    assert {:error, :snapshot_budget_exceeded} =
             WorkspaceLeaseRegistry.materialize_object_backed_snapshot(
               resource.resource_id,
               %{
                 expected_tree_oid: ctx.descriptor["expected_tree_oid"],
                 object_format: :sha1,
                 blob_manifest: manifest,
                 max_entries: 1
               },
               %{task_id: ctx.task_id, principal_id: ctx.principal_id, server: ctx.server}
             )

    assert {:error, :snapshot_budget_exceeded} =
             WorkspaceLeaseRegistry.materialize_object_backed_snapshot(
               resource.resource_id,
               %{
                 expected_tree_oid: ctx.descriptor["expected_tree_oid"],
                 object_format: :sha1,
                 blob_manifest: manifest,
                 max_bytes: max(total - 1, 0)
               },
               %{task_id: ctx.task_id, principal_id: ctx.principal_id, server: ctx.server}
             )

    refute_evidence_ref(ctx.repo, ctx.task_id, ctx.lease.workspace_id, ctx.source)
    assert_worktree_unchanged(ctx.worktree, ctx.snapshot)
    _ = release_resource(resource.resource_id, ctx.task_id, ctx.principal_id, ctx.server)
  end

  test "exact-at-ceiling bytes succeed, including a trailing zero-byte entry", ctx do
    File.write!(Path.join(ctx.worktree, "z_empty"), "")
    git!(ctx.worktree, ["add", "z_empty"])
    git!(ctx.worktree, ["commit", "-m", "empty blob"])
    source = git!(ctx.worktree, ["rev-parse", "HEAD"])
    {:ok, tree} = Git.commit_tree_oid(ctx.repo, source)
    {:ok, listing} = Git.ls_tree_z(ctx.repo, source)
    {:ok, manifest} = BlobManifest.parse_ls_tree_z(listing)
    snapshot = worktree_snapshot(ctx.worktree)

    nonempty =
      Enum.reject(manifest, fn entry ->
        match?({:ok, 0}, Git.blob_byte_size(ctx.repo, entry.oid))
      end)

    total_nonempty = manifest_bytes(ctx.repo, nonempty)
    total_all = manifest_bytes(ctx.repo, manifest)
    assert total_all == total_nonempty

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               ctx.lease.workspace_id,
               %{
                 task_id: ctx.task_id,
                 principal_id: ctx.principal_id,
                 object_backed_snapshot: true,
                 server: ctx.server
               }
             )

    assert {:ok, binding} =
             WorkspaceLeaseRegistry.materialize_object_backed_snapshot(
               resource.resource_id,
               %{
                 expected_tree_oid: tree,
                 object_format: :sha1,
                 blob_manifest: manifest,
                 max_bytes: total_nonempty
               },
               %{task_id: ctx.task_id, principal_id: ctx.principal_id, server: ctx.server}
             )

    assert binding.tree_oid == tree
    assert File.read!(Path.join(resource.candidate_path, "z_empty")) == ""
    assert_worktree_unchanged(ctx.worktree, snapshot)

    _ = release_resource(resource.resource_id, ctx.task_id, ctx.principal_id, ctx.server)
  end

  test "empty-only tree succeeds at max_bytes 0", %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "empty-blob-repo")
    File.mkdir_p!(repo)
    git!(repo, ["init"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["config", "user.name", "Test User"])
    File.write!(Path.join(repo, "empty"), "")
    git!(repo, ["add", "empty"])
    git!(repo, ["commit", "-m", "empty only"])

    fixture =
      acquire_lease(repo, Path.join(tmp_dir, "empty-blob-worktrees"), "test/g5b2a-empty-blob")

    source = git!(fixture.worktree, ["rev-parse", "HEAD"])
    {:ok, tree} = Git.commit_tree_oid(fixture.repo, source)
    {:ok, listing} = Git.ls_tree_z(fixture.repo, source)
    {:ok, manifest} = BlobManifest.parse_ls_tree_z(listing)
    snapshot = worktree_snapshot(fixture.worktree)

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               %{
                 task_id: fixture.task_id,
                 principal_id: fixture.principal_id,
                 object_backed_snapshot: true,
                 server: fixture.server
               }
             )

    assert {:ok, binding} =
             WorkspaceLeaseRegistry.materialize_object_backed_snapshot(
               resource.resource_id,
               %{
                 expected_tree_oid: tree,
                 object_format: :sha1,
                 blob_manifest: manifest,
                 max_bytes: 0
               },
               %{
                 task_id: fixture.task_id,
                 principal_id: fixture.principal_id,
                 server: fixture.server
               }
             )

    assert binding.tree_oid == tree
    assert File.read!(Path.join(resource.candidate_path, "empty")) == ""
    assert_worktree_unchanged(fixture.worktree, snapshot)

    _ =
      release_resource(
        resource.resource_id,
        fixture.task_id,
        fixture.principal_id,
        fixture.server
      )
  end

  test "missing blob OID fails closed and does not write the task index", ctx do
    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               ctx.lease.workspace_id,
               %{
                 task_id: ctx.task_id,
                 principal_id: ctx.principal_id,
                 object_backed_snapshot: true,
                 server: ctx.server
               }
             )

    bogus = [
      %{path: "lib/a.ex", mode: "100644", oid: String.duplicate("e", 40)}
    ]

    assert {:error, :snapshot_blob_read_failed} =
             WorkspaceLeaseRegistry.materialize_object_backed_snapshot(
               resource.resource_id,
               %{
                 expected_tree_oid: ctx.descriptor["expected_tree_oid"],
                 object_format: :sha1,
                 blob_manifest: bogus
               },
               %{task_id: ctx.task_id, principal_id: ctx.principal_id, server: ctx.server}
             )

    assert_worktree_unchanged(ctx.worktree, ctx.snapshot)
    _ = release_resource(resource.resource_id, ctx.task_id, ctx.principal_id, ctx.server)
  end

  test "write-tree mismatch against expected_tree_oid fails closed", ctx do
    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               ctx.lease.workspace_id,
               %{
                 task_id: ctx.task_id,
                 principal_id: ctx.principal_id,
                 object_backed_snapshot: true,
                 server: ctx.server
               }
             )

    {:ok, listing} = Git.ls_tree_z(ctx.repo, ctx.source)
    {:ok, manifest} = BlobManifest.parse_ls_tree_z(listing)

    assert {:error, :admitted_tree_mismatch} =
             WorkspaceLeaseRegistry.materialize_object_backed_snapshot(
               resource.resource_id,
               %{
                 expected_tree_oid: ctx.lease.base_commit,
                 object_format: :sha1,
                 blob_manifest: manifest
               },
               %{task_id: ctx.task_id, principal_id: ctx.principal_id, server: ctx.server}
             )

    assert_worktree_unchanged(ctx.worktree, ctx.snapshot)
    _ = release_resource(resource.resource_id, ctx.task_id, ctx.principal_id, ctx.server)
  end

  defp leased_repo(tmp_dir, repo_name, branch) do
    repo = create_git_repo(Path.join(tmp_dir, repo_name))
    acquire_lease(repo, Path.join(tmp_dir, repo_name <> "-worktrees"), branch)
  end

  defp acquire_lease(repo, worktree_base, branch) do
    server = :"g5b2a_owner_#{System.unique_integer([:positive])}"

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

    task_id = "task_owner_#{System.unique_integer([:positive])}"
    principal_id = "agent_owner_#{System.unique_integer([:positive])}"

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

    on_exit(fn ->
      _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{server: server})
    end)

    %{
      server: server,
      repo: lease.repo_path,
      lease: lease,
      task_id: task_id,
      principal_id: principal_id,
      worktree: lease.worktree_path
    }
  end

  defp commit_add(%{worktree: worktree, repo: repo, lease: lease}) do
    File.mkdir_p!(Path.join(worktree, "lib"))
    File.write!(Path.join(worktree, "lib/a.ex"), "defmodule A do\nend\n")
    git!(worktree, ["add", "lib/a.ex"])
    git!(worktree, ["commit", "-m", "add a"])
    source = git!(worktree, ["rev-parse", "HEAD"])
    descriptor = descriptor_between(repo, lease.base_commit, source)
    {source, descriptor, worktree_snapshot(worktree)}
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

  defp input(lease, task_id, principal_id, descriptor, server) do
    %{
      workspace_id: lease.workspace_id,
      task_id: task_id,
      principal_id: principal_id,
      candidate_materialization: descriptor,
      server: server
    }
  end

  defp release_resource(resource_id, task_id, principal_id, server) do
    WorkspaceLeaseRegistry.release_validation_resource(resource_id, %{
      task_id: task_id,
      principal_id: principal_id,
      server: server
    })
  end

  defp worktree_snapshot(worktree) do
    %{
      head: git!(worktree, ["rev-parse", "HEAD"]),
      status: git!(worktree, ["status", "--porcelain", "-z"]),
      index: git!(worktree, ["write-tree"])
    }
  end

  defp assert_worktree_unchanged(worktree, before) do
    after_snap = worktree_snapshot(worktree)
    assert after_snap.head == before.head
    assert after_snap.status == before.status
    assert after_snap.index == before.index
  end

  defp refute_evidence_ref(repo, task_id, workspace_id, oid) do
    assert match?(
             {:error, _},
             Git.verify_archived_evidence_ref(repo, task_id, workspace_id, oid)
           )
  end

  defp manifest_bytes(repo, manifest) do
    Enum.reduce(manifest, 0, fn entry, acc ->
      {:ok, size} = Git.blob_byte_size(repo, entry.oid)
      acc + size
    end)
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
