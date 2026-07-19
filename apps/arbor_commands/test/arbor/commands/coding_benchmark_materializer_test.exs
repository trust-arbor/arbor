defmodule Arbor.Commands.CodingBenchmark.MaterializerTest do
  use ExUnit.Case, async: false

  @moduletag :slow
  @moduletag :integration

  alias Arbor.Commands.CodingBenchmark
  alias Arbor.Commands.CodingBenchmark.{Catalog, Git, Materializer}
  alias Arbor.Commands.CodingBenchmarkTempRoot
  alias Arbor.Common.SafePath
  alias Mix.Tasks.Arbor.Coding.Benchmark.Prepare, as: PrepareTask

  setup do
    root = CodingBenchmarkTempRoot.create!("coding-benchmark-materializer")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "prepare materializes standalone fixtures, manifest, and target evidence", %{root: root} do
    source = Path.join(root, "source")
    {base, target} = build_history!(source)
    catalog_path = write_catalog!(root, base, target)
    output = Path.join(root, "prepared")

    assert {:ok, result} =
             Materializer.prepare(catalog_path, output, root: root, source: "source")

    assert {:ok, canonical_output} = SafePath.resolve_real(output)
    assert result.output_path == canonical_output
    assert File.exists?(result.manifest_path)
    assert File.exists?(result.target_evidence_path)
    assert File.exists?(result.publication_path)
    assert private_mode?(result.output_path, 0o700)
    assert private_mode?(result.manifest_path, 0o600)
    assert private_mode?(result.target_evidence_path, 0o600)

    assert {:ok, manifest} = Jason.decode(File.read!(result.manifest_path))
    assert {:ok, normalized} = CodingBenchmark.validate_manifest(manifest)
    assert length(normalized["fixtures"]) == 1

    fixture_path = Path.join(output, hd(normalized["fixtures"])["fixture_path"])
    assert File.dir?(Path.join(fixture_path, ".git"))
    assert git!(fixture_path, ["rev-parse", "HEAD^{commit}"]) == base.commit
    assert git!(fixture_path, ["rev-parse", "HEAD^{tree}"]) == base.tree
    assert git!(fixture_path, ["status", "--porcelain=v1"]) == ""
    assert {:ok, "README.md"} = File.read_link(Path.join(fixture_path, "README.link"))
    refute File.exists?(Path.join(fixture_path, ".git/objects/info/alternates"))
    refute File.exists?(Path.join(fixture_path, ".git/worktrees"))

    assert {:error, _reason} =
             Git.run(fixture_path, ["cat-file", "-e", "#{target.commit}^{commit}"], 30_000)

    assert {:ok, evidence} = Jason.decode(File.read!(result.target_evidence_path))
    assert evidence["schema"] == "arbor.coding_benchmark.target_evidence.v1"
    assert evidence["catalog_digest"] == result.catalog_digest
    assert evidence["manifest_digest"] == Catalog.canonical_digest(manifest)
    assert evidence["source_repository_label"] == "arbor-test"

    assert evidence["fixtures"]["sample-task"] == %{
             "base_commit_oid" => base.commit,
             "base_tree_oid" => base.tree,
             "normalized_input_hash" => hd(normalized["fixtures"])["normalized_input_hash"],
             "target_commit_oid" => target.commit,
             "target_tree_oid" => target.tree
           }

    assert {:ok, publication} = Jason.decode(File.read!(result.publication_path))
    assert publication["schema"] == "arbor.coding_benchmark.publication.v1"
    assert publication["catalog_digest"] == result.catalog_digest
    assert publication["manifest_digest"] == evidence["manifest_digest"]

    assert publication["target_evidence_digest"] ==
             Catalog.canonical_digest(evidence)

    assert File.read!(result.publication_path) ==
             Catalog.canonical_encode(publication) <> "\n"

    assert private_mode?(result.publication_path, 0o600)

    refute Enum.any?(File.ls!(output), fn entry ->
             String.starts_with?(entry, ".publication-")
           end)

    # Standalone: source can be removed and HEAD still resolves.
    File.rm_rf!(source)
    assert git!(fixture_path, ["rev-parse", "HEAD^{tree}"]) == base.tree
  end

  test "repeated preparation yields equivalent manifest, evidence, and fixture identity", %{
    root: root
  } do
    source = Path.join(root, "source")
    {base, target} = build_history!(source)
    catalog_path = write_catalog!(root, base, target)
    out_a = Path.join(root, "prepared-a")
    out_b = Path.join(root, "prepared-b")

    assert {:ok, a} = Materializer.prepare(catalog_path, out_a, root: root, source: "source")
    assert {:ok, b} = Materializer.prepare(catalog_path, out_b, root: root, source: "source")

    assert File.read!(a.manifest_path) == File.read!(b.manifest_path)
    assert File.read!(a.target_evidence_path) == File.read!(b.target_evidence_path)
    assert a.catalog_digest == b.catalog_digest

    fixture_a = Path.join(out_a, "fixtures/sample-task")
    fixture_b = Path.join(out_b, "fixtures/sample-task")
    assert git!(fixture_a, ["rev-parse", "HEAD"]) == git!(fixture_b, ["rev-parse", "HEAD"])

    assert git!(fixture_a, ["rev-parse", "HEAD^{tree}"]) ==
             git!(fixture_b, ["rev-parse", "HEAD^{tree}"])
  end

  test "pinned OID mismatch fails before publication", %{root: root} do
    source = Path.join(root, "source")
    {base, target} = build_history!(source)

    catalog_path =
      write_catalog!(root, base, target, base_tree_oid: String.duplicate("a", 40))

    output = Path.join(root, "prepared")
    marker = Path.join(root, "marker.txt")
    File.write!(marker, "keep\n")

    assert {:error, %{"reason" => "pinned_oid_mismatch"}} =
             Materializer.prepare(catalog_path, output, root: root, source: "source")

    refute File.exists?(output)
    assert File.read!(marker) == "keep\n"
    assert staging_dirs(root) == []
  end

  test "target must be the direct child of the declared base", %{root: root} do
    source = Path.join(root, "source")
    {base, target} = build_history!(source)

    File.write!(Path.join(source, "README.md"), "third\n")
    git!(source, ["add", "--", "README.md"])
    git!(source, ["commit", "--quiet", "-m", "third"])

    later = %{
      commit: git!(source, ["rev-parse", "HEAD"]),
      tree: git!(source, ["rev-parse", "HEAD^{tree}"])
    }

    refute later.commit == target.commit
    catalog_path = write_catalog!(root, base, later)
    output = Path.join(root, "prepared")

    assert {:error, %{"reason" => "target_not_direct_child_of_base"}} =
             Materializer.prepare(catalog_path, output, root: root, source: "source")

    refute File.exists?(output)
    assert staging_dirs(root) == []
  end

  test "fixture symlinks must remain inside the reconstructed repository", %{root: root} do
    for {target_path, index} <- [{"../../outside", 1}, {".git/config", 2}] do
      source = Path.join(root, "source-#{index}")
      {base, target} = build_history!(source, symlink_target: target_path)
      catalog_root = Path.join(root, "catalog-#{index}")
      File.mkdir!(catalog_root)
      catalog_path = write_catalog!(catalog_root, base, target)
      output = Path.join(root, "prepared-#{index}")

      assert {:error, %{"reason" => "unsafe_fixture_symlink"}} =
               Materializer.prepare(catalog_path, output,
                 root: root,
                 source: "source-#{index}"
               )

      refute File.exists?(output)
    end
  end

  test "existing destination is preserved and partial failure leaves no published output", %{
    root: root
  } do
    source = Path.join(root, "source")
    {base, target} = build_history!(source)
    catalog_path = write_catalog!(root, base, target)
    output = Path.join(root, "prepared")
    File.mkdir_p!(output)
    File.write!(Path.join(output, "sentinel"), "existing\n")

    assert {:error, %{"reason" => "destination_exists"}} =
             Materializer.prepare(catalog_path, output, root: root, source: "source")

    assert File.read!(Path.join(output, "sentinel")) == "existing\n"
    assert staging_dirs(root) == []
  end

  test "concurrent preparation reserves the destination without clobber", %{root: root} do
    source = Path.join(root, "source")
    {base, target} = build_history!(source)
    catalog_path = write_catalog!(root, base, target)
    output = Path.join(root, "prepared")

    tasks =
      for _index <- 1..2 do
        Task.async(fn ->
          Materializer.prepare(catalog_path, output, root: root, source: "source")
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 30_000))

    assert Enum.count(results, &match?({:ok, _result}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, %{"reason" => "destination_exists"}}, &1)
           ) == 1

    assert File.exists?(Path.join(output, "publication.json"))
  end

  test "mix task accepts the current repository root and source dot", %{root: root} do
    {base, target} = build_history!(root)
    _catalog_path = write_catalog!(root, base, target)

    result =
      File.cd!(root, fn ->
        PrepareTask.execute([
          "--catalog",
          "catalog-v1.json",
          "--output",
          "prepared-default",
          "--source",
          "."
        ])
      end)

    assert {:ok, prepared} = result
    assert File.exists?(prepared.publication_path)
  end

  test "Git execution clears ambient repository redirects", %{root: root} do
    source = Path.join(root, "source")
    {base, target} = build_history!(source)
    catalog_path = write_catalog!(root, base, target)
    output = Path.join(root, "prepared")
    redirected = Path.join(root, "redirected-git-dir")
    File.mkdir_p!(redirected)
    File.write!(Path.join(redirected, "sentinel"), "keep\n")

    previous_git_dir = System.get_env("GIT_DIR")
    previous_work_tree = System.get_env("GIT_WORK_TREE")
    System.put_env("GIT_DIR", redirected)
    System.put_env("GIT_WORK_TREE", root)

    on_exit(fn ->
      restore_env("GIT_DIR", previous_git_dir)
      restore_env("GIT_WORK_TREE", previous_work_tree)
    end)

    assert {:ok, _result} =
             Materializer.prepare(catalog_path, output, root: root, source: "source")

    assert File.read!(Path.join(redirected, "sentinel")) == "keep\n"
    refute File.exists?(Path.join(redirected, "HEAD"))
  end

  test "Git deadline is absolute across calls", %{root: root} do
    deadline = Git.deadline(1)
    Process.sleep(5)
    assert {:error, "git_timeout:deadline_exceeded"} = Git.run(root, ["version"], deadline)
  end

  test "mix task prepare delegates to materializer", %{root: root} do
    source = Path.join(root, "source")
    {base, target} = build_history!(source)
    catalog_path = write_catalog!(root, base, target)
    output = Path.join(root, "prepared-mix")

    assert {:ok, result} =
             PrepareTask.execute(
               [
                 "--catalog",
                 catalog_path,
                 "--output",
                 output,
                 "--source",
                 "source"
               ],
               root: root
             )

    assert File.exists?(result.manifest_path)
    assert {:ok, catalog} = Catalog.validate(Jason.decode!(File.read!(catalog_path)))
    assert result.catalog_digest == Catalog.digest(catalog)
  end

  test "reconstruct_fixture_repository rejects existing destination", %{root: root} do
    source = Path.join(root, "source")
    {base, _target} = build_history!(source)
    dest = Path.join(root, "already")
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "x"), "1")

    assert {:error, "invalid_reconstruct_request"} =
             CodingBenchmark.reconstruct_fixture_repository(
               source,
               dest,
               base.commit,
               base.tree
             )
  end

  test "multi-file reconstruction uses bounded git object batches", %{root: root} do
    source = Path.join(root, "source-multi")
    # More than the 64-object cat-file ceiling so reconstruction is multi-process.
    file_count = 80
    {base, _target} = build_history!(source, file_count: file_count)
    dest = Path.join(root, "reconstructed-multi")

    parent = self()
    handler_id = "coding-benchmark-git-object-batch-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:arbor, :commands, :coding_benchmark, :git_object_batch],
      fn _event, measurements, _metadata, _config ->
        send(parent, {:git_object_batch, measurements})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             CodingBenchmark.reconstruct_fixture_repository(
               source,
               dest,
               base.commit,
               base.tree
             )

    assert_receive {:git_object_batch, measurements}, 5_000

    max_batch = Git.max_cat_file_batch_objects()
    assert max_batch == 64

    # Unique objects: commit + trees + blobs. Far more than one process/object.
    assert measurements.object_count >= file_count
    assert measurements.object_count > max_batch

    # Check + content each chunk at most 64 objects, so process count is bounded
    # multi-process (not 1-per-object) once cardinality forces more than one batch.
    expected_chunks = div(measurements.object_count + max_batch - 1, max_batch)
    assert expected_chunks >= 2
    assert measurements.process_count >= expected_chunks
    assert measurements.process_count <= 2 * expected_chunks + 2
    assert measurements.process_count < measurements.object_count
    assert measurements.batch_count <= measurements.process_count
    # Still a large reduction versus one process per object.
    assert measurements.process_count * 4 <= measurements.object_count

    assert git!(dest, ["rev-parse", "HEAD^{commit}"]) == base.commit
    assert git!(dest, ["rev-parse", "HEAD^{tree}"]) == base.tree
    assert git!(dest, ["status", "--porcelain=v1"]) == ""
    assert File.read!(Path.join(dest, "files/file-0001.txt")) == "content-1\n"
  end

  defp build_history!(repo, opts \\ []) do
    File.mkdir_p!(repo)
    git!(repo, ["init", "--quiet", "--initial-branch=main"])
    git!(repo, ["config", "user.email", "benchmark@example.com"])
    git!(repo, ["config", "user.name", "Benchmark"])
    git!(repo, ["config", "core.hooksPath", "/dev/null"])

    File.write!(Path.join(repo, "README.md"), "base\n")
    File.ln_s!(Keyword.get(opts, :symlink_target, "README.md"), Path.join(repo, "README.link"))
    git!(repo, ["add", "--", "README.md", "README.link"])

    file_count = Keyword.get(opts, :file_count, 0)

    if file_count > 0 do
      files_dir = Path.join(repo, "files")
      File.mkdir_p!(files_dir)

      for index <- 1..file_count do
        name = "file-" <> String.pad_leading(Integer.to_string(index), 4, "0") <> ".txt"
        File.write!(Path.join(files_dir, name), "content-#{index}\n")
      end

      git!(repo, ["add", "--", "files"])
    end

    git!(repo, ["commit", "--quiet", "-m", "base"])
    base_commit = git!(repo, ["rev-parse", "HEAD"])
    base_tree = git!(repo, ["rev-parse", "HEAD^{tree}"])

    File.write!(Path.join(repo, "README.md"), "target\n")
    git!(repo, ["add", "--", "README.md"])
    git!(repo, ["commit", "--quiet", "-m", "target"])
    target_commit = git!(repo, ["rev-parse", "HEAD"])
    target_tree = git!(repo, ["rev-parse", "HEAD^{tree}"])

    {%{commit: base_commit, tree: base_tree}, %{commit: target_commit, tree: target_tree}}
  end

  defp write_catalog!(root, base, target, overrides \\ []) do
    fixture = %{
      "fixture_id" => "sample-task",
      "base_commit_oid" => Keyword.get(overrides, :base_commit_oid, base.commit),
      "base_tree_oid" => Keyword.get(overrides, :base_tree_oid, base.tree),
      "target_commit_oid" => Keyword.get(overrides, :target_commit_oid, target.commit),
      "target_tree_oid" => Keyword.get(overrides, :target_tree_oid, target.tree),
      "input" => %{
        "objective" => "Change README from base to target.",
        "acceptance_criteria" => ["README content becomes target."]
      },
      "verifier_id" => "exact_target_tree"
    }

    catalog = %{
      "schema" => Catalog.schema(),
      "seed" => 3,
      "source_repository_label" => "arbor-test",
      "fixtures" => [fixture]
    }

    path = Path.join(root, "catalog-v1.json")
    File.write!(path, Jason.encode!(catalog, pretty: true) <> "\n")
    path
  end

  defp git!(workdir, args) do
    case Git.run(workdir, args, 30_000) do
      {:ok, output} -> String.trim(output)
      {:error, reason} -> flunk("git failed: #{reason}")
    end
  end

  defp staging_dirs(root) do
    case File.ls(root) do
      {:ok, entries} ->
        Enum.filter(entries, &String.starts_with?(&1, ".coding-benchmark-prepare-"))

      _other ->
        []
    end
  end

  defp private_mode?(path, expected) do
    case File.stat(path) do
      {:ok, stat} -> Bitwise.band(stat.mode, 0o777) == expected
      _other -> false
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
