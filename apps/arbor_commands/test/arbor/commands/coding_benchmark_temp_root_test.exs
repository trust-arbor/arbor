defmodule Arbor.Commands.CodingBenchmarkTempRootTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Commands.CodingBenchmarkTempRoot
  alias Arbor.Common.SafePath

  test "create! allocates distinct exclusive canonical directories under the tmp parent" do
    parent = CodingBenchmarkTempRoot.parent_path()
    {:ok, expected_parent} = SafePath.resolve_real(ensure_parent!(parent))

    roots =
      for _ <- 1..3 do
        CodingBenchmarkTempRoot.create!("coding-benchmark-temp-root")
      end

    on_exit(fn -> Enum.each(roots, &File.rm_rf/1) end)

    assert length(Enum.uniq(roots)) == 3

    for root <- roots do
      assert File.dir?(root)
      # create/2 contract: returned path is SafePath-canonical (no expand fallback).
      assert {:ok, ^root} = SafePath.resolve_real(root)
      assert Path.dirname(root) == expected_parent
      assert String.starts_with?(Path.basename(root), "coding-benchmark-temp-root-")
      # Exclusive creation: recreating the exact leaf must fail.
      assert {:error, :eexist} = File.mkdir(root)
    end
  end

  test "create rejects path-like and invalid prefixes without allocating" do
    parent = CodingBenchmarkTempRoot.parent_path()
    parent_before = list_parent(parent)

    invalid_prefixes = [
      "",
      ".",
      "..",
      "foo/bar",
      "foo\\bar",
      "../escape",
      "/tmp/abs",
      "rel/../path",
      "has space",
      "bad.prefix!",
      String.duplicate("a", 65),
      nil,
      :atom
    ]

    for prefix <- invalid_prefixes do
      assert {:error, :invalid_prefix} = CodingBenchmarkTempRoot.create(prefix)

      assert_raise ArgumentError, fn ->
        CodingBenchmarkTempRoot.create!(prefix)
      end
    end

    assert list_parent(parent) == parent_before
  end

  test "create retries exclusive collision and returns a canonical distinct leaf" do
    # First token collides with a pre-created leaf; second token succeeds.
    # Default create!/1 still uses strong_rand_bytes (no token_fun).
    parent = ensure_parent!(CodingBenchmarkTempRoot.parent_path())
    {:ok, expected_parent} = SafePath.resolve_real(parent)
    collision_token = String.duplicate("a", 22)
    success_token = String.duplicate("b", 22)
    collision_path = Path.join(parent, "coding-benchmark-collision-" <> collision_token)
    assert :ok = File.mkdir(collision_path)
    on_exit(fn -> File.rm_rf(collision_path) end)

    {:ok, agent} =
      Agent.start_link(fn ->
        [collision_token, success_token]
      end)

    on_exit(fn ->
      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    assert {:ok, path} =
             CodingBenchmarkTempRoot.create("coding-benchmark-collision",
               token_fun: fn ->
                 Agent.get_and_update(agent, fn
                   [next | rest] -> {next, rest}
                   [] -> raise "token_fun exhausted"
                 end)
               end
             )

    on_exit(fn -> File.rm_rf(path) end)

    assert Path.basename(path) == "coding-benchmark-collision-" <> success_token
    assert Path.dirname(path) == expected_parent
    assert {:ok, ^path} = SafePath.resolve_real(path)
    assert File.dir?(path)
    assert File.dir?(collision_path)
    assert path != Path.expand(collision_path)
    # Both leaves remain exclusive directories.
    assert {:error, :eexist} = File.mkdir(path)
    assert {:error, :eexist} = File.mkdir(collision_path)
  end

  defp ensure_parent!(parent) do
    File.mkdir_p!(parent)
    parent
  end

  defp list_parent(parent) do
    case File.ls(parent) do
      {:ok, entries} -> Enum.sort(entries)
      {:error, :enoent} -> :absent
      {:error, reason} -> flunk("unexpected parent listing error: #{inspect(reason)}")
    end
  end
end
