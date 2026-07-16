defmodule Arbor.Shell.OwnedTreeTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell
  alias Arbor.Shell.OwnedTree

  @moduletag :fast

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "owned-tree-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    %{test_root: root}
  end

  test "security regression: cleanup unlinks symlinks without following them", %{test_root: root} do
    owned_path = Path.join(root, "owned")
    outside_path = Path.join(root, "outside")
    outside_marker = Path.join(outside_path, "keep.txt")

    File.mkdir!(outside_path)
    File.write!(outside_marker, "keep")

    assert {:ok, identity} = Shell.create_private_owned_tree(owned_path)
    assert File.stat!(owned_path).mode |> Bitwise.band(0o777) == 0o700

    File.mkdir_p!(Path.join(owned_path, "nested"))
    File.write!(Path.join(owned_path, "nested/file.txt"), "remove")
    File.ln_s!(outside_path, Path.join(owned_path, "outside-link"))

    assert :ok = Shell.remove_owned_tree(identity)
    refute File.exists?(owned_path)
    assert File.read!(outside_marker) == "keep"
    assert :ok = Shell.remove_owned_tree(identity)
  end

  test "security regression: replacement root never inherits deletion authority", %{
    test_root: root
  } do
    owned_path = Path.join(root, "owned")
    original_path = Path.join(root, "owned-original")

    assert {:ok, identity} = Shell.create_private_owned_tree(owned_path)
    File.write!(Path.join(owned_path, "original.txt"), "original")

    File.rename!(owned_path, original_path)
    File.mkdir!(owned_path)
    replacement_marker = Path.join(owned_path, "replacement.txt")
    File.write!(replacement_marker, "replacement")

    assert {:error, :cleanup_identity_mismatch} = Shell.remove_owned_tree(identity)
    assert File.read!(replacement_marker) == "replacement"

    File.rm_rf!(owned_path)
    File.rename!(original_path, owned_path)
    assert :ok = Shell.remove_owned_tree(identity)
  end

  test "security regression: minor-device mismatch never inherits deletion authority", %{
    test_root: root
  } do
    owned_path = Path.join(root, "owned")
    assert {:ok, identity} = Shell.create_private_owned_tree(owned_path)
    marker = Path.join(owned_path, "keep.txt")
    File.write!(marker, "keep")

    wrong_identity = Map.update!(identity, :minor_device, &(&1 + 1))
    assert {:error, :cleanup_identity_mismatch} = Shell.remove_owned_tree(wrong_identity)
    assert File.read!(marker) == "keep"

    assert :ok = Shell.remove_owned_tree(identity)
  end

  test "exclusive creation rejects an existing path", %{test_root: root} do
    owned_path = Path.join(root, "owned")
    File.mkdir!(owned_path)

    assert {:error, :root_exists} = Shell.create_private_owned_tree(owned_path)
  end

  test "cleanup is entry-bounded and makes progressive retry progress", %{test_root: root} do
    owned_path = Path.join(root, "owned")
    assert {:ok, identity} = Shell.create_private_owned_tree(owned_path)

    for index <- 1..3 do
      File.write!(Path.join(owned_path, "file-#{index}"), "remove")
    end

    assert {:error, :cleanup_entry_budget_exceeded} =
             OwnedTree.remove(identity, max_entries: 1)

    assert File.dir?(owned_path)
    assert length(File.ls!(owned_path)) < 3

    assert_eventually_removed(identity, 4)
    refute File.exists?(owned_path)
  end

  test "cleanup traverses paths deeper than the retired fixed depth ceiling", %{
    test_root: root
  } do
    owned_path = Path.join(root, "owned")
    assert {:ok, identity} = Shell.create_private_owned_tree(owned_path)

    deepest =
      Enum.reduce(1..300, owned_path, fn _index, parent ->
        child = Path.join(parent, "d")
        File.mkdir!(child)
        child
      end)

    File.write!(Path.join(deepest, "remove.txt"), "remove")

    assert :ok = OwnedTree.remove(identity, max_entries: 1_000, timeout_ms: 10_000)
    refute File.exists?(owned_path)
  end

  test "directory enumeration is isolated by a hard listing-memory budget", %{
    test_root: root
  } do
    owned_path = Path.join(root, "owned")
    assert {:ok, identity} = Shell.create_private_owned_tree(owned_path)

    for index <- 1..500 do
      name =
        "#{String.pad_leading(Integer.to_string(index), 4, "0")}-#{String.duplicate("x", 120)}"

      File.write!(Path.join(owned_path, name), "remove")
    end

    assert {:error, :cleanup_listing_memory_budget_exceeded} =
             OwnedTree.remove(identity, listing_heap_words: 512)

    assert File.dir?(owned_path)
    assert :ok = OwnedTree.remove(identity, timeout_ms: 10_000)
  end

  defp assert_eventually_removed(_identity, 0), do: flunk("owned tree remained after retries")

  defp assert_eventually_removed(identity, attempts) do
    case OwnedTree.remove(identity, max_entries: 1) do
      :ok ->
        :ok

      {:error, :cleanup_entry_budget_exceeded} ->
        assert_eventually_removed(identity, attempts - 1)
    end
  end
end
