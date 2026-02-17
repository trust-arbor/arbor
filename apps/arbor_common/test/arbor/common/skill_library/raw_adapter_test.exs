defmodule Arbor.Common.SkillLibrary.RawAdapterTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.SkillLibrary.RawAdapter

  @fixtures_dir Path.expand("../../../fixtures/skills", __DIR__)

  describe "parse/1" do
    test "parses a markdown file" do
      path = Path.join([@fixtures_dir, "docs", "architecture-overview.md"])
      assert {:ok, skill} = RawAdapter.parse(path)

      assert skill_field(skill, :name) == "architecture-overview"
      assert skill_field(skill, :source) == :raw
      assert skill_field(skill, :path) == path
      assert skill_field(skill, :body) =~ "Architecture Overview"
      assert skill_field(skill, :tags) == []
      assert skill_field(skill, :category) == nil
    end

    test "parses a txt file" do
      path = Path.join([@fixtures_dir, "docs", "coding-guidelines.txt"])
      assert {:ok, skill} = RawAdapter.parse(path)

      assert skill_field(skill, :name) == "coding-guidelines"
      assert skill_field(skill, :source) == :raw
      assert skill_field(skill, :body) =~ "Coding Guidelines"
    end

    test "extracts description from first heading" do
      path = Path.join([@fixtures_dir, "docs", "architecture-overview.md"])
      assert {:ok, skill} = RawAdapter.parse(path)

      assert skill_field(skill, :description) == "Architecture Overview"
    end

    test "extracts description from first line when no heading" do
      path = Path.join([@fixtures_dir, "docs", "coding-guidelines.txt"])
      assert {:ok, skill} = RawAdapter.parse(path)

      assert skill_field(skill, :description) == "Coding Guidelines"
    end

    test "returns error for non-existent file" do
      path = Path.join(@fixtures_dir, "nonexistent.md")
      assert {:error, :enoent} = RawAdapter.parse(path)
    end
  end

  describe "list/1" do
    test "finds .md and .txt files in a directory" do
      docs_dir = Path.join(@fixtures_dir, "docs")
      files = RawAdapter.list(docs_dir)

      assert is_list(files)
      assert length(files) == 2

      extensions = Enum.map(files, &Path.extname/1)
      assert ".md" in extensions
      assert ".txt" in extensions
    end

    test "excludes directories that have SKILL.md" do
      # The advisory/ dir has SKILL.md, so its files should be excluded
      files = RawAdapter.list(@fixtures_dir)

      # Should NOT include files from advisory/ since it has SKILL.md
      refute Enum.any?(files, fn f ->
        String.contains?(f, "advisory") and String.ends_with?(f, "SKILL.md")
      end)
    end

    test "includes top-level raw files" do
      files = RawAdapter.list(@fixtures_dir)

      # Should include no_frontmatter.md at the top level
      assert Enum.any?(files, &String.ends_with?(&1, "no_frontmatter.md"))
    end

    test "returns empty list for non-existent directory" do
      files = RawAdapter.list(Path.join(@fixtures_dir, "nonexistent"))
      assert files == []
    end
  end

  defp skill_field(%{} = skill, field) when is_atom(field) do
    Map.get(skill, field)
  end
end
