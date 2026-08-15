defmodule Arbor.Commands.PlatformInventoryTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.PlatformInventory
  alias Arbor.Commands.PlatformInventory.Core
  alias Arbor.Commands.SourceCoupling.GitInventory
  alias Arbor.Common.SafePath

  @moduletag :fast

  setup do
    root = temp_umbrella_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, inventory: inventory()}
  end

  test "production rejects every caller-supplied execution or data injection seam" do
    forbidden = [
      inventory: %{},
      classifications: [],
      run_git: fn _, _, _ -> {:ok, ""} end,
      parser: Jason,
      module: __MODULE__,
      function: :inventory
    ]

    for {key, value} <- forbidden do
      assert {:error, {:production_opts_forbid_synthetic, [^key]}} =
               PlatformInventory.run([{key, value}])
    end
  end

  test "strictly admits production option shape, keys, duplicates, values, and booleans" do
    assert {:error, :invalid_opts} = PlatformInventory.run(%{})
    assert {:error, :invalid_opts} = PlatformInventory.run([:mode])
    assert {:error, :invalid_opts} = PlatformInventory.run([{"mode", "check"}])

    assert {:error, {:duplicate_option, :mode}} =
             PlatformInventory.run(mode: "report", mode: "check")

    assert {:error, {:duplicate_option, :json}} =
             PlatformInventory.run(json: true, json: false)

    assert {:error, {:production_opts_forbid_synthetic, [:output]}} =
             PlatformInventory.run(output: "json")

    assert {:error, {:invalid_option, :mode}} = PlatformInventory.run(mode: :check)
    assert {:error, {:invalid_option, :mode}} = PlatformInventory.run(mode: "write")
    assert {:error, {:invalid_option, :json}} = PlatformInventory.run(json: 1)
    assert {:error, {:invalid_option, :root}} = PlatformInventory.run(root: 1)
    assert {:error, {:invalid_option, :review}} = PlatformInventory.run(review: false)
  end

  test "missing default review returns a valid unreviewed report", %{
    root: root,
    inventory: inventory
  } do
    refute File.exists?(Path.join(root, PlatformInventory.default_review_path()))

    assert {:ok, report} =
             PlatformInventory.run_for_test(
               root: root,
               inventory: inventory,
               mode: "check",
               json: true
             )

    assert report["status"] == "unreviewed"
    assert report["mode"] == "check"
    assert report["output"] == "json"
    assert report["classifications"] == []
  end

  test "an explicitly selected missing review is an error", %{root: root, inventory: inventory} do
    assert {:error, :review_missing} =
             PlatformInventory.run_for_test(
               root: root,
               inventory: inventory,
               review: "reviews/missing.json"
             )
  end

  test "review path rejects lexical escape, symlink redirection, and nonregular files", %{
    root: root,
    inventory: inventory
  } do
    assert {:error, :review_path_escape} =
             PlatformInventory.run_for_test(
               root: root,
               inventory: inventory,
               review: "../outside.json"
             )

    outside = Path.join(Path.dirname(root), "outside.json")

    assert {:error, :review_path_escape} =
             PlatformInventory.run_for_test(
               root: root,
               inventory: inventory,
               review: outside
             )

    target = write_review!(root, "reviews/target.json", [])
    link = Path.join(root, "reviews/link.json")
    :ok = File.ln_s(target, link)

    assert {:error, :review_symlink_redirection} =
             PlatformInventory.run_for_test(root: root, inventory: inventory, review: link)

    directory = Path.join(root, "reviews/directory.json")
    File.mkdir_p!(directory)

    assert {:error, :review_not_regular} =
             PlatformInventory.run_for_test(root: root, inventory: inventory, review: directory)
  end

  test "review file is size bounded before reading", %{root: root, inventory: inventory} do
    path = Path.join(root, "reviews/oversize.json")
    max_review_bytes = PlatformInventory.max_review_bytes()
    File.mkdir_p!(Path.dirname(path))
    {:ok, io} = File.open(path, [:write, :binary])

    try do
      assert {:ok, ^max_review_bytes} = :file.position(io, max_review_bytes)

      :ok = IO.binwrite(io, <<0>>)
    after
      File.close(io)
    end

    assert File.stat!(path).size == max_review_bytes + 1

    assert {:error, :review_too_large} =
             PlatformInventory.run_for_test(root: root, inventory: inventory, review: path)
  end

  test "review rejects malformed JSON, wrong shape, and extra fields through Encode", %{
    root: root,
    inventory: inventory
  } do
    path = write_bytes!(root, "reviews/review.json", "[")

    assert {:error, :review_invalid_json} =
             PlatformInventory.run_for_test(root: root, inventory: inventory, review: path)

    File.write!(path, Jason.encode!(%{"not" => "a list"}))

    assert {:error, {:review_invalid, :invalid_classifications}} =
             PlatformInventory.run_for_test(root: root, inventory: inventory, review: path)

    row = classification(file()) |> Map.put("extra", true)
    File.write!(path, Jason.encode!([row]))

    assert {:error, {:review_invalid, {:field_mismatch, _}}} =
             PlatformInventory.run_for_test(root: root, inventory: inventory, review: path)
  end

  test "valid reviewed input produces a match and test injection is separately bounded", %{
    root: root,
    inventory: inventory
  } do
    reviewed = classification(file())
    path = write_review!(root, "reviews/review.json", [reviewed])

    assert {:ok, report} =
             PlatformInventory.run_for_test(
               root: root,
               inventory: inventory,
               review: path,
               mode: "check"
             )

    assert report["status"] == "match"
    assert report["classifications"] == [reviewed]

    assert {:ok, injected} =
             PlatformInventory.run_for_test(
               root: root,
               inventory: inventory,
               classifications: [reviewed]
             )

    assert injected["status"] == "match"

    assert {:error, {:invalid_classifications, {:field_mismatch, _}}} =
             PlatformInventory.run_for_test(
               root: root,
               inventory: inventory,
               classifications: [Map.put(reviewed, "extra", true)]
             )

    assert {:error, :conflicting_classification_sources} =
             PlatformInventory.run_for_test(
               root: root,
               inventory: inventory,
               classifications: [reviewed],
               review: path
             )
  end

  defp temp_umbrella_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-platform-inventory-#{System.unique_integer([:positive, :monotonic])}"
      )

    for marker <- ["mix.exs", "apps/arbor_commands/mix.exs", "apps/arbor_kernel/mix.exs"] do
      path = Path.join(root, marker)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# marker\n")
    end

    {:ok, real_root} = SafePath.resolve_real(root)
    real_root
  end

  defp inventory do
    source = file()

    {:ok, digest} =
      GitInventory.selected_index_digest([{source.path, source.mode, source.blob_oid}])

    %{
      files: [source],
      head_tree_oid: String.duplicate("a", 40),
      object_format: "sha1",
      selected_index_digest: digest
    }
  end

  defp file do
    path = "apps/arbor_shell/lib/platform_inventory_fixture.ex"
    bytes = "defmodule Arbor.Shell.PlatformInventoryFixture do\nend\n"

    %{
      path: path,
      blob_oid: Core.git_blob_oid(bytes, "sha1"),
      mode: "100644",
      byte_size: byte_size(bytes),
      bytes: bytes
    }
  end

  defp classification(source) do
    %{
      "path" => source.path,
      "blob_oid" => source.blob_oid,
      "class" => "trusted_host",
      "rationale" => "reviewed fixture"
    }
  end

  defp write_review!(root, relative, classifications) do
    write_bytes!(root, relative, Jason.encode!(classifications))
  end

  defp write_bytes!(root, relative, bytes) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end
end
