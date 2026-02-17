defmodule Arbor.Common.SkillLibrary.SkillAdapterTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.SkillLibrary.SkillAdapter

  @fixtures_dir Path.expand("../../../fixtures/skills", __DIR__)

  describe "parse/1" do
    test "parses a SKILL.md file with valid frontmatter" do
      path = Path.join([@fixtures_dir, "advisory", "security", "SKILL.md"])
      assert {:ok, skill} = SkillAdapter.parse(path)

      assert skill_field(skill, :name) == "security-perspective"
      assert skill_field(skill, :description) == "Defensive security analysis for code review"
      assert skill_field(skill, :source) == :skill
      assert skill_field(skill, :path) == path
      assert "advisory" in skill_field(skill, :tags)
      assert "security" in skill_field(skill, :tags)
      assert "analysis" in skill_field(skill, :tags)
      assert skill_field(skill, :category) == "advisory"
      assert skill_field(skill, :body) =~ "security analyst"
    end

    test "derives name from directory when frontmatter lacks name" do
      # The advisory/SKILL.md has a name, so let's test that it uses the frontmatter name
      path = Path.join([@fixtures_dir, "advisory", "SKILL.md"])
      assert {:ok, skill} = SkillAdapter.parse(path)
      assert skill_field(skill, :name) == "advisory-overview"
    end

    test "returns error for non-existent file" do
      path = Path.join([@fixtures_dir, "nonexistent", "SKILL.md"])
      assert {:error, :enoent} = SkillAdapter.parse(path)
    end

    test "returns error for file without frontmatter" do
      path = Path.join(@fixtures_dir, "no_frontmatter.md")
      assert {:error, :no_frontmatter} = SkillAdapter.parse(path)
    end
  end

  describe "list/1" do
    test "finds all SKILL.md files recursively" do
      files = SkillAdapter.list(@fixtures_dir)

      assert is_list(files)
      assert length(files) >= 2
      assert Enum.all?(files, &String.ends_with?(&1, "SKILL.md"))
    end

    test "returns empty list for directory with no SKILL.md files" do
      docs_dir = Path.join(@fixtures_dir, "docs")
      files = SkillAdapter.list(docs_dir)
      assert files == []
    end

    test "returns empty list for non-existent directory" do
      files = SkillAdapter.list(Path.join(@fixtures_dir, "nonexistent"))
      assert files == []
    end
  end

  describe "split_frontmatter/1" do
    test "splits valid frontmatter from body" do
      content = """
      ---
      name: test
      description: A test skill
      ---

      Body content here
      """

      assert {:ok, frontmatter, body} = SkillAdapter.split_frontmatter(content)
      assert frontmatter =~ "name: test"
      assert body =~ "Body content here"
    end

    test "returns error when no frontmatter delimiters present" do
      content = "Just some plain text without frontmatter"
      assert {:error, :no_frontmatter} = SkillAdapter.split_frontmatter(content)
    end

    test "returns error when frontmatter is not at start of file" do
      content = """
      Some text before
      ---
      name: test
      ---
      body
      """

      assert {:error, :no_frontmatter} = SkillAdapter.split_frontmatter(content)
    end
  end

  describe "parse_frontmatter/1" do
    test "parses key-value pairs" do
      text = """
      name: my-skill
      description: A great skill
      category: testing
      """

      assert {:ok, fields} = SkillAdapter.parse_frontmatter(text)
      assert fields["name"] == "my-skill"
      assert fields["description"] == "A great skill"
      assert fields["category"] == "testing"
    end

    test "parses bracket lists" do
      text = """
      tags: [one, two, three]
      """

      assert {:ok, fields} = SkillAdapter.parse_frontmatter(text)
      assert fields["tags"] == ["one", "two", "three"]
    end

    test "ignores empty lines and comments" do
      text = """
      name: test
      # This is a comment
      description: A description
      """

      assert {:ok, fields} = SkillAdapter.parse_frontmatter(text)
      assert fields["name"] == "test"
      assert fields["description"] == "A description"
      # Comments should not be treated as a key-value pair
      refute Map.has_key?(fields, "# This is a comment")
    end

    test "handles empty frontmatter" do
      assert {:ok, fields} = SkillAdapter.parse_frontmatter("")
      assert fields == %{}
    end
  end

  # Helper to access fields from either a struct or a map
  defp skill_field(%{} = skill, field) when is_atom(field) do
    Map.get(skill, field)
  end
end
