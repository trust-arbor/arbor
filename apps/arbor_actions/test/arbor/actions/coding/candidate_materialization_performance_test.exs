defmodule Arbor.Actions.Coding.CandidateMaterializationPerformanceTest do
  use Arbor.Actions.ActionCase, async: false

  require Logger

  alias Arbor.Actions.Coding.BlobManifest
  alias Arbor.Actions.Coding.CandidateMaterializationShell
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Git
  alias Arbor.Actions.TestLinuxBaselineMaterializer

  @moduletag :integration
  @moduletag :slow
  @moduletag timeout: 180_000

  @minimum_entries 4_000
  @minimum_bytes 50 * 1024 * 1024

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil -> {:ok, _} = Application.ensure_all_started(:arbor_shell)
      _pid -> :ok
    end

    :ok
  end

  test "records full Arbor manifest materialization cost with bounded batching", %{
    tmp_dir: tmp_dir
  } do
    source_repo = Path.expand("../../../../../..", __DIR__)
    repo = Path.join(tmp_dir, "repo")

    prepare_source_repo!(source_repo, repo)

    server = :"g5d_performance_#{System.unique_integer([:positive])}"

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

    task_id = "task_g5d_performance_#{System.unique_integer([:positive])}"
    principal_id = "agent_g5d_performance_#{System.unique_integer([:positive])}"

    assert {:ok, lease} =
             WorkspaceLeaseRegistry.acquire(
               %{
                 repo_path: repo,
                 branch: "test/g5d-performance",
                 worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                 task_id: task_id,
                 principal_id: principal_id
               },
               server: server
             )

    on_exit(fn ->
      _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{server: server})
    end)

    marker = Path.join(lease.worktree_path, "g5d-materialization-measurement.txt")
    File.write!(marker, "candidate materialization measurement\n")
    git!(lease.worktree_path, ["add", Path.basename(marker)])
    git!(lease.worktree_path, ["commit", "-m", "Add materialization measurement marker"])
    source_commit = git!(lease.worktree_path, ["rev-parse", "HEAD"])
    descriptor = descriptor_between(repo, lease.base_commit, source_commit)

    started = System.monotonic_time(:millisecond)

    assert {:ok, result} =
             CandidateMaterializationShell.admit_and_materialize(%{
               workspace_id: lease.workspace_id,
               task_id: task_id,
               principal_id: principal_id,
               candidate_materialization: descriptor,
               server: server
             })

    wall_clock_ms = max(System.monotonic_time(:millisecond) - started, 0)
    stats = result.dest_verify

    measurement = %{
      wall_clock_ms: wall_clock_ms,
      entries: stats.held_entries,
      bytes: stats.dest_bytes,
      dest_verify: stats,
      batching: stats.source_stage.batching
    }

    assert length(descriptor["entries"]) == 1
    assert measurement.entries >= @minimum_entries
    assert measurement.bytes >= @minimum_bytes
    assert measurement.dest_verify.dest_files == measurement.entries
    assert measurement.dest_verify.dest_entries_visited >= measurement.entries
    assert measurement.dest_verify.git_invocations >= 1
    assert measurement.dest_verify.source_stage.entries == measurement.entries
    assert measurement.dest_verify.source_stage.bytes == measurement.bytes
    assert measurement.dest_verify.source_stage.git_invocations < measurement.entries
    assert measurement.batching

    Logger.info("candidate_materialization_full_manifest #{inspect(measurement)}")
  end

  test "prepares a repository fixture from immutable source bytes", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source")
    repo = Path.join(tmp_dir, "repo")

    File.mkdir_p!(source)
    File.write!(Path.join(source, ".gitignore"), "ignored.txt\n")
    File.write!(Path.join(source, "ignored.txt"), "retained source bytes\n")

    prepare_source_repo!(source, repo)

    refute File.exists?(Path.join(source, ".git"))
    assert File.exists?(Path.join(repo, ".git"))
    assert git!(repo, ["show", "HEAD:ignored.txt"]) == "retained source bytes"
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

  defp prepare_source_repo!(source, destination) do
    source_has_git_metadata? = File.exists?(Path.join(source, ".git"))

    if source_has_git_metadata? do
      {output, status} =
        System.cmd("git", ["clone", "--no-local", source, destination], stderr_to_stdout: true)

      assert status == 0, output
    else
      # Object-backed validation mounts source bytes without repository metadata.
      File.mkdir_p!(destination)

      source
      |> File.ls!()
      |> Enum.each(fn entry ->
        File.cp_r!(Path.join(source, entry), Path.join(destination, entry))
      end)

      git!(destination, ["init"])
    end

    git!(destination, ["config", "user.email", "test@example.com"])
    git!(destination, ["config", "user.name", "Test User"])

    unless source_has_git_metadata? do
      git!(destination, ["add", "--force", "--all"])
      git!(destination, ["commit", "-m", "Materialize source fixture"])
    end
  end

  defp git!(path, args) do
    {output, status} =
      System.cmd("git", ["-C", path | args], stderr_to_stdout: true)

    assert status == 0, output
    String.trim(output)
  end
end
