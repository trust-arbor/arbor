defmodule Arbor.Actions.Coding.CandidateMaterialization.MaterializeTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions
  alias Arbor.Actions.Coding.BlobManifest
  alias Arbor.Actions.Coding.CandidateMaterialization.Materialize
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Git
  alias Arbor.Actions.Mix, as: MixAction
  alias Arbor.Actions.TestLinuxBaselineMaterializer
  alias Arbor.Contracts.Coding.CandidateMaterialization

  @moduletag :fast

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil -> {:ok, _} = Application.ensure_all_started(:arbor_shell)
      _pid -> :ok
    end

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    server = :"g5d_action_#{System.unique_integer([:positive])}"

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
    task_id = "task_g5d_#{System.unique_integer([:positive])}"
    principal_id = "agent_g5d_#{System.unique_integer([:positive])}"

    assert {:ok, lease} =
             WorkspaceLeaseRegistry.acquire(
               %{
                 repo_path: repo,
                 branch: "test/g5d-action",
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

  test "discovers the closed URI and pipeline-internal name" do
    assert Materialize in Actions.list_actions().coding
    assert Materialize.name() == "coding_candidate_materialize"

    assert Actions.canonical_uri_for(Materialize, %{}) ==
             "arbor://action/coding/candidate_materialization"
  end

  test "materializes from trusted context and returns string-keyed JSON", %{
    server: server,
    lease: lease,
    task_id: task_id,
    principal_id: principal_id,
    worktree: worktree
  } do
    {source, descriptor, before} =
      commit_regular_add(worktree, lease.repo_path, lease.base_commit)

    {:ok, digest} = CandidateMaterialization.digest(descriptor)

    assert {:ok, result} =
             Materialize.run(
               params(lease, descriptor, digest),
               context(task_id, principal_id, server)
             )

    assert Enum.all?(Map.keys(result), &is_binary/1)
    assert result["source_commit_oid"] == source
    assert result["expected_tree_oid"] == descriptor["expected_tree_oid"]
    assert result["descriptor_digest"] == digest
    assert result["workspace_id"] == lease.workspace_id
    assert String.starts_with?(result["hidden_ref"], "refs/arbor/evidence/")
    refute result["candidate_path"] == worktree
    assert_worktree_unchanged(worktree, before)

    assert {:ok, reused} =
             Materialize.run(
               params(lease, descriptor, digest),
               context(task_id, principal_id, server)
             )

    assert reused["resource_id"] == result["resource_id"]
    assert reused["hidden_ref"] == result["hidden_ref"]
    assert_worktree_unchanged(worktree, before)
  end

  test "idempotency regression: replaces an incomplete object snapshot before retrying", %{
    server: server,
    lease: lease,
    task_id: task_id,
    principal_id: principal_id,
    worktree: worktree
  } do
    {source, descriptor, before} =
      commit_regular_add(worktree, lease.repo_path, lease.base_commit)

    {:ok, digest} = CandidateMaterialization.digest(descriptor)
    {:ok, source_listing} = Git.ls_tree_z(lease.repo_path, source)
    {:ok, source_manifest} = BlobManifest.parse_ls_tree_z(source_listing)
    bounds = MixAction.snapshot_bounds()
    caller = %{task_id: task_id, principal_id: principal_id, server: server}

    assert {:ok, partial} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               lease.workspace_id,
               Map.merge(caller, %{
                 object_backed_snapshot: true,
                 snapshot_bounds: bounds
               })
             )

    assert {:ok, _binding} =
             WorkspaceLeaseRegistry.materialize_object_backed_snapshot(
               partial.resource_id,
               %{
                 expected_tree_oid: descriptor["expected_tree_oid"],
                 object_format: object_format(descriptor["expected_tree_oid"]),
                 blob_manifest: source_manifest,
                 max_entries: bounds.max_entries,
                 max_bytes: bounds.max_bytes,
                 max_depth: bounds.max_depth
               },
               caller
             )

    refute_evidence_ref(lease.repo_path, task_id, lease.workspace_id, source)

    assert {:ok, result} =
             Materialize.run(
               params(lease, descriptor, digest),
               context(task_id, principal_id, server)
             )

    refute result["resource_id"] == partial.resource_id
    refute File.exists?(partial.candidate_path)

    assert {:ok, %{hidden_ref: hidden_ref}} =
             Git.verify_archived_evidence_ref(
               lease.repo_path,
               task_id,
               lease.workspace_id,
               source
             )

    assert result["hidden_ref"] == hidden_ref
    assert_worktree_unchanged(worktree, before)
  end

  test "security regression: rejects untrusted principal and descriptor substitution", %{
    server: server,
    lease: lease,
    task_id: task_id,
    principal_id: principal_id,
    worktree: worktree
  } do
    {_source, descriptor, before} =
      commit_regular_add(worktree, lease.repo_path, lease.base_commit)

    {:ok, digest} = CandidateMaterialization.digest(descriptor)

    assert {:error, :invalid_task_principal} =
             Materialize.run(params(lease, descriptor, digest), %{})

    assert {:error, :workspace_unauthorized} =
             Materialize.run(
               params(lease, descriptor, digest),
               context(task_id, "agent_other", server)
             )

    assert {:error, :compiler_descriptor_mismatch} =
             Materialize.run(
               params(lease, descriptor, digest)
               |> Map.put(:pinned_descriptor_digest, digest <> "ff"),
               context(task_id, principal_id, server)
             )

    assert {:error, :invalid_materialization_params} =
             Materialize.run(
               params(lease, descriptor, digest) |> Map.put(:task_id, task_id),
               context(task_id, principal_id, server)
             )

    assert {:error, :invalid_materialization_params} =
             Materialize.run(
               params(lease, descriptor, digest) |> Map.put(:unrelated, "ignored-before-fix"),
               context(task_id, principal_id, server)
             )

    assert {:error, :invalid_materialization_params} =
             Materialize.run(
               params(lease, descriptor, digest)
               |> Map.put("workspace_id", lease.workspace_id),
               context(task_id, principal_id, server)
             )

    refute_evidence_ref(
      lease.repo_path,
      task_id,
      lease.workspace_id,
      descriptor["source_commit_oid"]
    )

    assert_worktree_unchanged(worktree, before)
  end

  defp params(lease, descriptor, digest) do
    %{
      workspace_id: lease.workspace_id,
      candidate_materialization: descriptor,
      pinned_descriptor_digest: digest,
      candidate_materialization_digest: digest,
      source_commit_oid: descriptor["source_commit_oid"],
      expected_tree_oid: descriptor["expected_tree_oid"],
      acquired_base_commit: lease.base_commit
    }
  end

  defp context(task_id, principal_id, server) do
    %{
      "session.task_id" => task_id,
      :agent_id => principal_id,
      :workspace_registry => server
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

  defp object_format(oid) when byte_size(oid) == 40, do: :sha1
  defp object_format(oid) when byte_size(oid) == 64, do: :sha256

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

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
