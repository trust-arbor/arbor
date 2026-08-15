defmodule Arbor.Common.SkillLibrary.FabricAdapterTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.SkillLibrary.FabricAdapter

  @fixtures_dir Path.expand("../../../fixtures/skills", __DIR__)

  describe "parse/1" do
    test "parses a Fabric system.md file" do
      path = Path.join([@fixtures_dir, "patterns", "extract_wisdom", "system.md"])
      assert {:ok, skill} = FabricAdapter.parse(path)

      assert skill_field(skill, :name) == "extract_wisdom"
      assert skill_field(skill, :source) == :fabric
      assert skill_field(skill, :category) == "fabric"
      assert skill_field(skill, :path) == path
      assert skill_field(skill, :body) =~ "IDENTITY and PURPOSE"
    end

    test "extracts description from first heading" do
      path = Path.join([@fixtures_dir, "patterns", "extract_wisdom", "system.md"])
      assert {:ok, skill} = FabricAdapter.parse(path)

      assert skill_field(skill, :description) == "IDENTITY and PURPOSE"
    end

    test "derives tags from path segments after patterns directory" do
      path = Path.join([@fixtures_dir, "patterns", "extract_wisdom", "system.md"])
      assert {:ok, skill} = FabricAdapter.parse(path)

      tags = skill_field(skill, :tags)
      assert is_list(tags)
      assert "extract_wisdom" in tags
    end

    test "returns error for non-existent file" do
      path = Path.join([@fixtures_dir, "nonexistent", "system.md"])
      assert {:error, :enoent} = FabricAdapter.parse(path)
    end
  end

  describe "list/1" do
    test "finds all system.md files" do
      files = FabricAdapter.list(@fixtures_dir)

      assert is_list(files)
      assert files != []
      assert Enum.all?(files, &String.ends_with?(&1, "system.md"))
    end

    test "returns empty list for directory without system.md files" do
      docs_dir = Path.join(@fixtures_dir, "docs")
      files = FabricAdapter.list(docs_dir)
      assert files == []
    end
  end

  defp skill_field(%{} = skill, field) when is_atom(field) do
    Map.get(skill, field)
  end
end
