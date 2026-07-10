defmodule Arbor.Orchestrator.CodingPlan.ArtifactStoreTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Arbor.Orchestrator.CodingPlan.ArtifactStore

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "coding_plan_artifact_store_#{System.unique_integer([:positive])}"
      )

    root = Path.join([base, "nested", "task-root"])
    on_exit(fn -> File.rm_rf(base) end)

    %{base: base, root: root}
  end

  test "archives exact DOT bytes and JSON-clean plan and manifest", %{root: root} do
    plan = plan_fixture()
    manifest = manifest_fixture()
    dot_source = "digraph coding {\n  start -> done;\n}\n"

    assert {:ok, descriptor} = ArtifactStore.archive(root, plan, dot_source, manifest)

    expanded_root = Path.expand(root)

    assert descriptor == %{
             "coding_plan_path" => Path.join(expanded_root, "coding-plan.json"),
             "coding_pipeline_path" => Path.join(expanded_root, "coding-pipeline.dot"),
             "compile_manifest_path" => Path.join(expanded_root, "coding-compile-manifest.json"),
             "graph_hash" => manifest["graph_hash"],
             "compiler_version" => manifest["compiler_version"]
           }

    assert File.read!(descriptor["coding_pipeline_path"]) == dot_source
    assert Jason.decode!(File.read!(descriptor["coding_plan_path"])) == plan
    assert Jason.decode!(File.read!(descriptor["compile_manifest_path"])) == manifest
    assert {:ok, _encoded_descriptor} = Jason.encode(descriptor)

    assert Enum.sort(File.ls!(expanded_root)) == [
             "coding-compile-manifest.json",
             "coding-pipeline.dot",
             "coding-plan.json"
           ]
  end

  test "creates mode-0600 files", %{root: root} do
    assert {:ok, descriptor} =
             ArtifactStore.archive(root, plan_fixture(), "digraph G {}", manifest_fixture())

    for key <- ["coding_plan_path", "coding_pipeline_path", "compile_manifest_path"] do
      assert {:ok, stat} = File.stat(descriptor[key])
      assert (stat.mode &&& 0o777) == 0o600
    end
  end

  test "overwrites deterministically through fixed artifact paths", %{root: root} do
    plan = plan_fixture()
    manifest = manifest_fixture()
    dot_source = "digraph G { start -> validate -> done }"

    assert {:ok, first_descriptor} =
             ArtifactStore.archive(root, plan, dot_source, manifest)

    first_bytes = read_artifacts(first_descriptor)

    for {_name, path} <- artifact_paths(first_descriptor) do
      File.chmod!(path, 0o644)
    end

    assert {:ok, second_descriptor} =
             ArtifactStore.archive(root, plan, dot_source, manifest)

    assert second_descriptor == first_descriptor
    assert read_artifacts(second_descriptor) == first_bytes

    for {_name, path} <- artifact_paths(second_descriptor) do
      assert {:ok, stat} = File.stat(path)
      assert (stat.mode &&& 0o777) == 0o600
    end

    refute Enum.any?(File.ls!(root), &String.contains?(&1, ".tmp-"))
  end

  test "rejects malformed arguments with tagged errors before creating files", %{root: root} do
    manifest = manifest_fixture()

    assert {:error, {:invalid_root, :expected_string}} =
             ArtifactStore.archive(nil, plan_fixture(), "digraph G {}", manifest)

    assert {:error, {:invalid_root, :empty}} =
             ArtifactStore.archive("  ", plan_fixture(), "digraph G {}", manifest)

    assert {:error, {:invalid_plan, :expected_string_keyed_map}} =
             ArtifactStore.archive(root, [], "digraph G {}", manifest)

    assert {:error, {:invalid_plan, {:non_string_key, []}}} =
             ArtifactStore.archive(root, %{version: 1}, "digraph G {}", manifest)

    assert {:error, {:invalid_plan, {:non_json_value, ["worker", "pid"]}}} =
             ArtifactStore.archive(
               root,
               %{"worker" => %{"pid" => self()}},
               "digraph G {}",
               manifest
             )

    assert {:error, {:invalid_dot_source, :expected_non_empty_binary}} =
             ArtifactStore.archive(root, plan_fixture(), "", manifest)

    assert {:error, {:invalid_manifest, {:non_string_key, []}}} =
             ArtifactStore.archive(
               root,
               plan_fixture(),
               "digraph G {}",
               %{graph_hash: "abc", compiler_version: "v1"}
             )

    assert {:error, {:invalid_manifest_field, "graph_hash"}} =
             ArtifactStore.archive(
               root,
               plan_fixture(),
               "digraph G {}",
               %{"compiler_version" => "v1"}
             )

    assert {:error, {:invalid_manifest_field, "compiler_version"}} =
             ArtifactStore.archive(
               root,
               plan_fixture(),
               "digraph G {}",
               %{"graph_hash" => "abc", "compiler_version" => " "}
             )

    refute File.exists?(root)
  end

  test "returns a tagged filesystem error when the root is not a directory", %{
    base: base
  } do
    root_file = Path.join(base, "not-a-directory")
    File.mkdir_p!(base)
    File.write!(root_file, "occupied")

    assert {:error, {:create_artifact_root_failed, reason}} =
             ArtifactStore.archive(
               root_file,
               plan_fixture(),
               "digraph G {}",
               manifest_fixture()
             )

    assert reason in [:eexist, :enotdir]
  end

  defp plan_fixture do
    %{
      "version" => 1,
      "task" => "Add a focused regression test",
      "worker" => %{"provider" => "grok", "permission_mode" => "default"},
      "requested_paths" => ["apps/arbor_orchestrator/test/example_test.exs"]
    }
  end

  defp manifest_fixture do
    %{
      "compiler_version" => "coding-plan-1",
      "graph_hash" => String.duplicate("a", 64),
      "template_version" => "coding-change-v1"
    }
  end

  defp read_artifacts(descriptor) do
    Map.new(artifact_paths(descriptor), fn {name, path} -> {name, File.read!(path)} end)
  end

  defp artifact_paths(descriptor) do
    Map.take(descriptor, [
      "coding_plan_path",
      "coding_pipeline_path",
      "compile_manifest_path"
    ])
  end
end
