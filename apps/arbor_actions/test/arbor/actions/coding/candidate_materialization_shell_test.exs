defmodule Arbor.Actions.Coding.CandidateMaterializationShellTest do
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
    server = :"g5b2a_shell_#{System.unique_integer([:positive])}"

    start_registry!(server)

    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    task_id = "task_g5b2a_#{System.unique_integer([:positive])}"
    principal_id = "agent_g5b2a_#{System.unique_integer([:positive])}"

    assert {:ok, lease} =
             WorkspaceLeaseRegistry.acquire(
               %{
                 repo_path: repo,
                 branch: "test/g5b2a-shell",
                 worktree_base_dir: Path.join(tmp_dir, "worktrees"),
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

  test "admits a descendant commit, pins the evidence ref, and is idempotent", %{
    server: server,
    repo: repo,
    lease: lease,
    task_id: task_id,
    principal_id: principal_id,
    worktree: worktree
  } do
    {source, descriptor, before} = commit_regular_add(worktree, repo, lease.base_commit)

    assert {:ok, view} =
             WorkspaceLeaseRegistry.inspect_lease_by_lineage(
               lease.workspace_id,
               task_id,
               principal_id,
               server: server
             )

    assert view.task_id == task_id
    assert view.principal_id == principal_id

    assert {:ok, first} =
             CandidateMaterializationShell.admit_and_materialize(
               input(lease, task_id, principal_id, descriptor, server)
             )

    assert first.source_commit_oid == source
    assert first.expected_tree_oid == descriptor["expected_tree_oid"]
    assert first.object_format == "sha1"
    assert String.starts_with?(first.hidden_ref, "refs/arbor/evidence/")
    assert File.dir?(first.candidate_path)
    refute first.candidate_path == worktree
    assert_worktree_unchanged(worktree, before)

    assert {:ok, %{hidden_ref: hidden}} =
             Git.verify_archived_evidence_ref(repo, task_id, lease.workspace_id, source)

    assert hidden == first.hidden_ref

    assert {:ok, _} =
             WorkspaceLeaseRegistry.release_validation_resource(first.resource_id, %{
               task_id: task_id,
               principal_id: principal_id,
               server: server
             })

    assert {:ok, second} =
             CandidateMaterializationShell.admit_and_materialize(
               input(lease, task_id, principal_id, descriptor, server)
             )

    assert second.hidden_ref == first.hidden_ref
    assert second.source_commit_oid == source
    assert_worktree_unchanged(worktree, before)

    _ =
      WorkspaceLeaseRegistry.release_validation_resource(second.resource_id, %{
        task_id: task_id,
        principal_id: principal_id,
        server: server
      })
  end

  test "rejects wrong caller and wrong lease without pinning", %{
    server: server,
    repo: repo,
    lease: lease,
    task_id: task_id,
    principal_id: principal_id,
    worktree: worktree
  } do
    {_source, descriptor, before} = commit_regular_add(worktree, repo, lease.base_commit)

    assert {:error, :workspace_unauthorized} =
             CandidateMaterializationShell.admit_and_materialize(
               input(lease, task_id, "agent_other", descriptor, server)
             )

    assert {:error, :workspace_not_found} =
             CandidateMaterializationShell.admit_and_materialize(%{
               workspace_id: "ws_missing",
               task_id: task_id,
               principal_id: principal_id,
               candidate_materialization: descriptor,
               server: server
             })

    refute_evidence_ref(repo, task_id, lease.workspace_id, descriptor["source_commit_oid"])
    assert_worktree_unchanged(worktree, before)
  end

  test "rejects non-descendant, missing source, and tree mismatch before pin", %{
    server: server,
    repo: repo,
    lease: lease,
    task_id: task_id,
    principal_id: principal_id,
    worktree: worktree
  } do
    {source, descriptor, _before} = commit_regular_add(worktree, repo, lease.base_commit)

    orphan = orphan_commit(worktree)
    after_setup = worktree_snapshot(worktree)

    assert {:error, :source_not_descendant} =
             CandidateMaterializationShell.admit_and_materialize(
               input(
                 lease,
                 task_id,
                 principal_id,
                 Map.put(descriptor, "source_commit_oid", orphan),
                 server
               )
             )

    missing = String.duplicate("f", 40)

    assert {:error, :source_commit_missing} =
             CandidateMaterializationShell.admit_and_materialize(
               input(
                 lease,
                 task_id,
                 principal_id,
                 Map.put(descriptor, "source_commit_oid", missing),
                 server
               )
             )

    assert {:error, :admitted_tree_mismatch} =
             CandidateMaterializationShell.admit_and_materialize(
               input(
                 lease,
                 task_id,
                 principal_id,
                 Map.put(descriptor, "expected_tree_oid", lease.base_commit),
                 server
               )
             )

    refute_evidence_ref(repo, task_id, lease.workspace_id, source)
    assert_worktree_unchanged(worktree, after_setup)
  end

  test "rejects extra, missing, and deleted descriptor deltas", %{
    server: server,
    repo: repo,
    lease: lease,
    task_id: task_id,
    principal_id: principal_id,
    worktree: worktree
  } do
    {_source, descriptor, _before} = commit_regular_add(worktree, repo, lease.base_commit)
    [entry] = descriptor["entries"]

    extra_entry = %{
      "path" => "lib/zzz.ex",
      "blob_oid" => entry["blob_oid"],
      "mode" => 100_644
    }

    extra = Map.put(descriptor, "entries", Enum.sort_by([entry, extra_entry], & &1["path"]))

    assert {:error, :extra_descriptor_path} =
             CandidateMaterializationShell.admit_and_materialize(
               input(lease, task_id, principal_id, extra, server)
             )

    File.write!(Path.join(worktree, "lib/b.ex"), "defmodule B do\nend\n")
    git!(worktree, ["add", "lib/b.ex"])
    git!(worktree, ["commit", "-m", "add b"])
    two_source = git!(worktree, ["rev-parse", "HEAD"])
    two_descriptor = descriptor_between(repo, lease.base_commit, two_source)
    [_first, second | _] = two_descriptor["entries"]
    missing = Map.put(two_descriptor, "entries", [second])

    assert {:error, :missing_descriptor_path} =
             CandidateMaterializationShell.admit_and_materialize(
               input(lease, task_id, principal_id, missing, server)
             )

    readme = Path.join(worktree, "README.md")
    File.rm!(readme)
    git!(worktree, ["add", "-u", "README.md"])
    git!(worktree, ["commit", "-m", "delete readme"])
    deleted_source = git!(worktree, ["rev-parse", "HEAD"])
    {:ok, base_listing} = Git.ls_tree_z(repo, lease.base_commit)
    {:ok, base_manifest} = BlobManifest.parse_ls_tree_z(base_listing)
    readme_entry = Enum.find(base_manifest, &(&1.path == "README.md"))

    deleted =
      Map.put(descriptor, "entries", [
        %{"path" => "README.md", "blob_oid" => readme_entry.oid, "mode" => 100_644}
      ])

    assert {:error, :descriptor_deletion} =
             CandidateMaterializationShell.admit_and_materialize(
               input(
                 lease,
                 task_id,
                 principal_id,
                 Map.put(deleted, "source_commit_oid", deleted_source)
                 |> Map.put(
                   "expected_tree_oid",
                   elem(Git.commit_tree_oid(repo, deleted_source), 1)
                 ),
                 server
               )
             )

    refute_evidence_ref(repo, task_id, lease.workspace_id, descriptor["source_commit_oid"])
    refute_evidence_ref(repo, task_id, lease.workspace_id, two_source)
    refute_evidence_ref(repo, task_id, lease.workspace_id, deleted_source)
  end

  test "rejects a non-regular symlink delta in isolation", %{
    server: server,
    repo: repo,
    lease: lease,
    task_id: task_id,
    principal_id: principal_id,
    worktree: worktree
  } do
    File.mkdir_p!(Path.join(worktree, "lib"))
    File.ln_s!("target.ex", Path.join(worktree, "lib/link"))
    git!(worktree, ["add", "lib/link"])
    git!(worktree, ["commit", "-m", "add symlink"])
    source = git!(worktree, ["rev-parse", "HEAD"])
    {:ok, tree} = Git.commit_tree_oid(repo, source)
    {:ok, listing} = Git.ls_tree_z(repo, source)
    {:ok, manifest} = BlobManifest.parse_ls_tree_z(listing)
    link = Enum.find(manifest, &(&1.path == "lib/link"))

    descriptor = %{
      "source_commit_oid" => source,
      "expected_tree_oid" => tree,
      "entries" => [%{"path" => "lib/link", "blob_oid" => link.oid, "mode" => 100_644}]
    }

    assert {:error, :non_regular_changed_entry} =
             CandidateMaterializationShell.admit_and_materialize(
               input(lease, task_id, principal_id, descriptor, server)
             )

    refute_evidence_ref(repo, task_id, lease.workspace_id, source)
  end

  test "rejects mode/OID mismatch and conflicting evidence refs", %{
    server: server,
    repo: repo,
    lease: lease,
    task_id: task_id,
    principal_id: principal_id,
    worktree: worktree
  } do
    {source, descriptor, before} = commit_regular_add(worktree, repo, lease.base_commit)
    [entry] = descriptor["entries"]

    wrong_oid = Map.put(entry, "blob_oid", lease.base_commit)
    wrong = Map.put(descriptor, "entries", [wrong_oid])

    assert {:error, :descriptor_mode_oid_mismatch} =
             CandidateMaterializationShell.admit_and_materialize(
               input(lease, task_id, principal_id, wrong, server)
             )

    other_oid = git!(repo, ["rev-parse", lease.base_commit])

    assert {:ok, %{hidden_ref: hidden}} =
             Git.pin_task_workspace_commit(repo, task_id, lease.workspace_id, other_oid)

    assert {:error, :evidence_ref_oid_mismatch} =
             CandidateMaterializationShell.admit_and_materialize(
               input(lease, task_id, principal_id, descriptor, server)
             )

    assert {:ok, %{hidden_ref: ^hidden}} =
             Git.verify_archived_evidence_ref(repo, task_id, lease.workspace_id, other_oid)

    refute match?(
             {:ok, _},
             Git.verify_archived_evidence_ref(repo, task_id, lease.workspace_id, source)
           )

    assert_worktree_unchanged(worktree, before)
  end

  test "replacement-ref security regression: source facts, bytes, and pin ignore refs/replace", %{
    server: server,
    repo: repo,
    lease: lease,
    task_id: task_id,
    principal_id: principal_id,
    worktree: worktree
  } do
    {source, descriptor, _before} = commit_regular_add(worktree, repo, lease.base_commit)

    assert {:ok, source_type_before} = Git.object_type(repo, source)
    assert {:ok, descendant_before} = Git.commit_descendant?(repo, lease.base_commit, source)
    assert {:ok, replacement_tree} = Git.commit_tree_oid(repo, source)
    assert {:ok, source_listing_before} = Git.ls_tree_z(repo, source)

    File.write!(Path.join(worktree, "lib/replaced.ex"), "replaced\n")
    git!(worktree, ["add", "lib/replaced.ex"])
    git!(worktree, ["commit", "-m", "replacement decoy"])
    decoy = git!(worktree, ["rev-parse", "HEAD"])
    decoy_tree = git!(worktree, ["rev-parse", decoy <> "^{tree}"])
    refute decoy_tree == replacement_tree

    {_, 0} = System.cmd("git", ["-C", repo, "replace", source, decoy], stderr_to_stdout: true)
    after_replace = worktree_snapshot(worktree)

    assert Git.object_type(repo, source) == {:ok, source_type_before}
    assert Git.commit_descendant?(repo, lease.base_commit, source) == {:ok, descendant_before}
    assert Git.commit_tree_oid(repo, source) == {:ok, replacement_tree}
    assert Git.ls_tree_z(repo, source) == {:ok, source_listing_before}

    replaced_descriptor = Map.put(descriptor, "expected_tree_oid", decoy_tree)

    assert {:error, :admitted_tree_mismatch} =
             CandidateMaterializationShell.admit_and_materialize(
               input(lease, task_id, principal_id, replaced_descriptor, server)
             )

    refute_evidence_ref(repo, task_id, lease.workspace_id, source)
    assert_worktree_unchanged(worktree, after_replace)

    assert {:ok, result} =
             CandidateMaterializationShell.admit_and_materialize(
               input(lease, task_id, principal_id, descriptor, server)
             )

    assert result.source_commit_oid == source
    assert result.expected_tree_oid == descriptor["expected_tree_oid"]
    assert File.read!(Path.join(result.candidate_path, "lib/a.ex")) == "defmodule A do\nend\n"
    refute File.exists?(Path.join(result.candidate_path, "lib/replaced.ex"))

    assert {:ok, %{hidden_ref: hidden_ref}} =
             Git.verify_archived_evidence_ref(repo, task_id, lease.workspace_id, source)

    assert hidden_ref == result.hidden_ref

    _ =
      WorkspaceLeaseRegistry.release_validation_resource(result.resource_id, %{
        task_id: task_id,
        principal_id: principal_id,
        server: server
      })
  end

  test "empty-base same-format add succeeds", %{tmp_dir: tmp_dir} do
    server = :"g5b2a_empty_#{System.unique_integer([:positive])}"

    start_registry!(server)

    repo = Path.join(tmp_dir, "empty-repo")
    File.mkdir_p!(repo)
    git!(repo, ["init"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["commit", "--allow-empty", "-m", "empty base"])

    task_id = "task_empty_#{System.unique_integer([:positive])}"
    principal_id = "agent_empty_#{System.unique_integer([:positive])}"

    assert {:ok, lease} =
             WorkspaceLeaseRegistry.acquire(
               %{
                 repo_path: repo,
                 branch: "test/g5b2a-empty",
                 worktree_base_dir: Path.join(tmp_dir, "empty-worktrees"),
                 task_id: task_id,
                 principal_id: principal_id
               },
               server: server
             )

    added_path = Path.join(lease.worktree_path, "only-addition.txt")
    File.write!(added_path, "only described addition\n")
    git!(lease.worktree_path, ["add", "only-addition.txt"])
    git!(lease.worktree_path, ["commit", "-m", "single addition"])
    source = git!(lease.worktree_path, ["rev-parse", "HEAD"])
    descriptor = descriptor_between(lease.repo_path, lease.base_commit, source)

    assert [%{"path" => "only-addition.txt"}] = descriptor["entries"]

    {:ok, source_listing} = Git.ls_tree_z(lease.repo_path, source)
    {:ok, source_manifest} = BlobManifest.parse_ls_tree_z(source_listing)
    assert Enum.map(source_manifest, & &1.path) == ["only-addition.txt"]

    assert {:ok, result} =
             CandidateMaterializationShell.admit_and_materialize(
               input(lease, task_id, principal_id, descriptor, server)
             )

    assert result.object_format == "sha1"

    _ =
      WorkspaceLeaseRegistry.release_validation_resource(result.resource_id, %{
        task_id: task_id,
        principal_id: principal_id,
        server: server
      })

    _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{server: server})
  end

  defp start_registry!(server) do
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

  defp commit_regular_add(worktree, repo, base) do
    File.mkdir_p!(Path.join(worktree, "lib"))
    File.write!(Path.join(worktree, "lib/a.ex"), "defmodule A do\nend\n")
    git!(worktree, ["add", "lib/a.ex"])
    git!(worktree, ["commit", "-m", "add a"])
    source = git!(worktree, ["rev-parse", "HEAD"])
    descriptor = descriptor_between(repo, base, source)
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
        %{"path" => entry.path, "blob_oid" => entry.oid, "mode" => mode_int(entry.mode)}
      end)

    %{
      "source_commit_oid" => source,
      "expected_tree_oid" => tree,
      "entries" => entries
    }
  end

  defp mode_int("100644"), do: 100_644
  defp mode_int("100755"), do: 100_755

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

  defp orphan_commit(worktree) do
    branch = git!(worktree, ["rev-parse", "--abbrev-ref", "HEAD"])
    git!(worktree, ["checkout", "--orphan", "g5b2a-orphan"])
    git!(worktree, ["commit", "--allow-empty", "-m", "orphan"])
    orphan = git!(worktree, ["rev-parse", "HEAD"])
    git!(worktree, ["checkout", branch])
    orphan
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
