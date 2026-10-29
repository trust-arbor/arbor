defmodule Arbor.Contracts.Coding.SourceInventoryTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.SourceInventory

  @moduletag :fast

  @tree_oid String.duplicate("a", 40)
  @paths ["apps/arbor_contracts/mix.exs", "mix.exs"]

  # Fully hardcoded golden wire bytes for the admitted @paths/@tree_oid fixture.
  # One literal JSON binary (fixed key order). paths_sha256 is the hardcoded
  # framed digest for @paths — not computed or interpolated in this fixture.
  #
  # Offline: SHA-256( domain_tag || be32(28) || "apps/arbor_contracts/mix.exs"
  #                  || be32(7) || "mix.exs" )
  # where domain_tag = "arbor.source_inventory.paths.v1\0"
  @canonical_encode_fixture ~s({"schema":"arbor.source_inventory.v1","tree_oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","path_count":2,"paths_sha256":"b0c78e231f1acdfcdcb4e1f894b5c9d3a7a68621df601423fd73ce24a25ea4c9","paths":["apps/arbor_contracts/mix.exs","mix.exs"]})

  defp valid_attrs(overrides \\ %{}) do
    paths = Map.get(overrides, "paths", @paths)
    sorted = Enum.sort(paths)

    %{
      "schema" => SourceInventory.schema(),
      "tree_oid" => @tree_oid,
      "path_count" => length(sorted),
      "paths_sha256" => SourceInventory.paths_digest(sorted),
      "paths" => sorted
    }
    |> Map.merge(overrides)
    |> then(fn attrs ->
      # Recompute digest/count when paths overridden without explicit digest.
      if Map.has_key?(overrides, "paths") and not Map.has_key?(overrides, "paths_sha256") do
        sorted = Enum.sort(attrs["paths"])

        attrs
        |> Map.put("paths", sorted)
        |> Map.put("path_count", length(sorted))
        |> Map.put("paths_sha256", SourceInventory.paths_digest(sorted))
      else
        attrs
      end
    end)
  end

  test "accepts a canonical inventory and round-trips encode" do
    assert {:ok, inventory} = SourceInventory.new(valid_attrs())
    assert SourceInventory.tree_oid(inventory) == @tree_oid
    assert SourceInventory.paths(inventory) == @paths
    assert SourceInventory.path_count(inventory) == 2
    assert {:ok, bytes} = SourceInventory.encode(inventory)
    assert is_binary(bytes)
    assert {:ok, decoded} = Jason.decode(bytes)
    assert {:ok, ^inventory} = SourceInventory.new(decoded)
  end

  test "encode/1 emits exact canonical bytes with stable OrderedObject key order" do
    assert {:ok, inventory} = SourceInventory.new(valid_attrs())
    assert {:ok, bytes} = SourceInventory.encode(inventory)

    # Literal golden pin — not rebuilt via Jason/OrderedObject.
    assert bytes == @canonical_encode_fixture
    assert byte_size(bytes) <= SourceInventory.max_encoded_bytes()
    # Key order is fixed — not dependent on map enumeration.
    assert String.starts_with?(bytes, ~s({"schema":))
    assert bytes =~ ~s("schema":"arbor.source_inventory.v1","tree_oid":)
    assert bytes =~ ~s("tree_oid":"#{@tree_oid}","path_count":2,"paths_sha256":)
  end

  test "max_encoded_bytes/0 exposes the encoded ceiling" do
    assert SourceInventory.max_encoded_bytes() == 8 * 1024 * 1024
  end

  test "build/2 constructs an admitted inventory" do
    assert {:ok, inventory} = SourceInventory.build(@tree_oid, ["b.txt", "a.txt"])
    assert SourceInventory.paths(inventory) == ["a.txt", "b.txt"]
  end

  test "rejects malformed and wrong schema" do
    assert {:error, _} = SourceInventory.new(%{})
    assert {:error, _} = SourceInventory.new("not a map")

    assert {:error, {:invalid_source_inventory, :schema}} =
             SourceInventory.new(valid_attrs(%{"schema" => "other.v1"}))
  end

  test "rejects duplicate paths" do
    paths = ["a.ex", "a.ex"]

    assert {:error, {:invalid_source_inventory, :duplicate_path}} =
             SourceInventory.new(
               valid_attrs(%{
                 "paths" => paths,
                 "path_count" => 2,
                 "paths_sha256" => SourceInventory.paths_digest(paths)
               })
             )
  end

  test "rejects unsorted paths" do
    paths = ["z.ex", "a.ex"]

    assert {:error, {:invalid_source_inventory, :unsorted}} =
             SourceInventory.new(
               valid_attrs(%{
                 "paths" => paths,
                 "path_count" => 2,
                 "paths_sha256" => SourceInventory.paths_digest(paths)
               })
             )
  end

  test "rejects oversized path_count" do
    assert {:error, {:invalid_source_inventory, :oversized}} =
             SourceInventory.new(
               valid_attrs(%{
                 "path_count" => 50_001,
                 "paths" => [],
                 "paths_sha256" => SourceInventory.paths_digest([])
               })
             )
  end

  test "rejects traversal and absolute paths" do
    for bad <- ["../escape.ex", "foo/../bar.ex", "/abs.ex", "foo//bar.ex", "foo/./bar.ex"] do
      assert {:error, reason} =
               SourceInventory.new(
                 valid_attrs(%{
                   "paths" => [bad],
                   "path_count" => 1,
                   "paths_sha256" => SourceInventory.paths_digest([bad])
                 })
               )

      assert match?({:invalid_source_inventory, _}, reason)
    end
  end

  test "rejects digest and count mismatches" do
    assert {:error, {:invalid_source_inventory, :digest_mismatch}} =
             SourceInventory.new(valid_attrs(%{"paths_sha256" => String.duplicate("0", 64)}))

    assert {:error, {:invalid_source_inventory, :count_mismatch}} =
             SourceInventory.new(valid_attrs(%{"path_count" => 99}))
  end

  test "rejects bad tree_oid" do
    assert {:error, {:invalid_source_inventory, :tree_oid}} =
             SourceInventory.new(valid_attrs(%{"tree_oid" => "not-hex"}))

    assert {:error, {:invalid_source_inventory, :tree_oid}} =
             SourceInventory.new(valid_attrs(%{"tree_oid" => String.duplicate("g", 40)}))
  end

  test "accepts 64-hex tree_oid" do
    oid = String.duplicate("b", 64)
    assert {:ok, inventory} = SourceInventory.new(valid_attrs(%{"tree_oid" => oid}))
    assert SourceInventory.tree_oid(inventory) == oid
  end
end
