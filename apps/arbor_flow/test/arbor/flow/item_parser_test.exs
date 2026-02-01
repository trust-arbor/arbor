defmodule Arbor.Flow.ItemParserTest do
  use ExUnit.Case, async: true

  alias Arbor.Flow.ItemParser

  @moduletag :fast

  @sample_markdown """
  # Test Feature

  **Created:** 2026-02-01
  **Priority:** high
  **Category:** feature
  **Type:** research
  **Effort:** medium
  **Depends On:** item_abc123.md, item_def456.md
  **Blocks:** item_xyz789.md

  ## Summary

  This is a test feature for the workflow system.

  ## Why It Matters

  It demonstrates the parser functionality.

  ## Acceptance Criteria

  - [x] Parse title correctly
  - [ ] Parse metadata correctly
  - [ ] Handle missing sections

  ## Definition of Done

  - [ ] All tests pass
  - [x] Code reviewed

  ## Related Files

  - `lib/arbor/flow/item_parser.ex`
  - `test/arbor/flow/item_parser_test.exs`

  ## Notes

  Some additional notes here.
  """

  describe "parse/1" do
    test "parses title" do
      item = ItemParser.parse(@sample_markdown)
      assert item.title == "Test Feature"
    end

    test "parses created date" do
      item = ItemParser.parse(@sample_markdown)
      assert item.created_at == ~D[2026-02-01]
    end

    test "parses priority" do
      item = ItemParser.parse(@sample_markdown)
      assert item.priority == :high
    end

    test "parses category" do
      item = ItemParser.parse(@sample_markdown)
      assert item.category == :feature
    end

    test "parses type" do
      item = ItemParser.parse(@sample_markdown)
      assert item.type == "research"
    end

    test "parses effort" do
      item = ItemParser.parse(@sample_markdown)
      assert item.effort == :medium
    end

    test "parses summary" do
      item = ItemParser.parse(@sample_markdown)
      assert item.summary == "This is a test feature for the workflow system."
    end

    test "parses why_it_matters" do
      item = ItemParser.parse(@sample_markdown)
      assert item.why_it_matters == "It demonstrates the parser functionality."
    end

    test "parses acceptance criteria" do
      item = ItemParser.parse(@sample_markdown)

      [first, second, third] = item.acceptance_criteria
      assert first.text == "Parse title correctly"
      assert first.completed == true
      assert second.text == "Parse metadata correctly"
      assert second.completed == false
      assert third.completed == false
    end

    test "parses definition of done" do
      item = ItemParser.parse(@sample_markdown)

      [first, second] = item.definition_of_done
      assert first.text == "All tests pass"
      assert first.completed == false
      assert second.text == "Code reviewed"
      assert second.completed == true
    end

    test "parses depends_on from frontmatter" do
      item = ItemParser.parse(@sample_markdown)
      assert item.depends_on == ["item_abc123.md", "item_def456.md"]
    end

    test "parses blocks from frontmatter" do
      item = ItemParser.parse(@sample_markdown)
      assert item.blocks == ["item_xyz789.md"]
    end

    test "parses related files" do
      item = ItemParser.parse(@sample_markdown)
      assert "lib/arbor/flow/item_parser.ex" in item.related_files
      assert "test/arbor/flow/item_parser_test.exs" in item.related_files
    end

    test "parses notes" do
      item = ItemParser.parse(@sample_markdown)
      assert item.notes == "Some additional notes here."
    end

    test "stores raw content" do
      item = ItemParser.parse(@sample_markdown)
      assert item.raw_content == @sample_markdown
    end

    test "computes content hash" do
      item = ItemParser.parse(@sample_markdown)
      assert is_binary(item.content_hash)
      assert String.length(item.content_hash) == 16
    end

    test "captures unknown frontmatter as metadata" do
      md = """
      # With Custom Fields

      **Created:** 2026-02-01
      **Priority:** high
      **Source:** github-issue-42
      **Session:** abc123

      ## Summary

      Has custom fields.
      """

      item = ItemParser.parse(md)
      assert item.metadata["source"] == "github-issue-42"
      assert item.metadata["session"] == "abc123"
    end

    test "metadata excludes known frontmatter keys" do
      item = ItemParser.parse(@sample_markdown)
      refute Map.has_key?(item.metadata, "created")
      refute Map.has_key?(item.metadata, "priority")
      refute Map.has_key?(item.metadata, "category")
      refute Map.has_key?(item.metadata, "type")
      refute Map.has_key?(item.metadata, "effort")
      refute Map.has_key?(item.metadata, "depends on")
      refute Map.has_key?(item.metadata, "blocks")
    end

    test "handles missing title" do
      item = ItemParser.parse("No title here\n\nJust content.")
      assert item.title == nil
    end

    test "handles missing sections" do
      minimal = """
      # Minimal Item

      Just a title, nothing else.
      """

      item = ItemParser.parse(minimal)
      assert item.title == "Minimal Item"
      assert item.priority == nil
      assert item.category == nil
      assert item.type == nil
      assert item.effort == nil
      assert item.summary == nil
      assert item.acceptance_criteria == []
      assert item.depends_on == []
      assert item.blocks == []
      assert item.metadata == %{}
    end

    test "handles missing metadata" do
      no_meta = """
      # No Metadata Item

      ## Summary

      Just a summary.
      """

      item = ItemParser.parse(no_meta)
      assert item.title == "No Metadata Item"
      assert item.created_at == nil
      assert item.priority == nil
      assert item.category == nil
    end

    test "handles invalid priority gracefully" do
      invalid = """
      # Invalid Priority

      **Priority:** urgent

      ## Summary

      Has invalid priority.
      """

      item = ItemParser.parse(invalid)
      assert item.priority == nil
    end

    test "handles invalid category gracefully" do
      invalid = """
      # Invalid Category

      **Category:** unknown

      ## Summary

      Has invalid category.
      """

      item = ItemParser.parse(invalid)
      assert item.category == nil
    end

    test "handles invalid effort gracefully" do
      invalid = """
      # Invalid Effort

      **Effort:** enormous

      ## Summary

      Has invalid effort.
      """

      item = ItemParser.parse(invalid)
      assert item.effort == nil
    end

    test "parses all valid priorities" do
      for priority <- ~w(critical high medium low someday) do
        md = """
        # Test

        **Priority:** #{priority}
        """

        item = ItemParser.parse(md)
        assert item.priority == String.to_existing_atom(priority)
      end
    end

    test "parses all valid categories" do
      for category <- ~w(feature refactor bug infrastructure idea research documentation content) do
        md = """
        # Test

        **Category:** #{category}
        """

        item = ItemParser.parse(md)
        assert item.category == String.to_existing_atom(category)
      end
    end

    test "parses all valid efforts" do
      for effort <- ~w(small medium large ongoing) do
        md = """
        # Test

        **Effort:** #{effort}
        """

        item = ItemParser.parse(md)
        assert item.effort == String.to_existing_atom(effort)
      end
    end

    test "type is a free-form string" do
      md = """
      # Test

      **Type:** custom_workflow_type
      """

      item = ItemParser.parse(md)
      assert item.type == "custom_workflow_type"
    end

    test "single depends_on item" do
      md = """
      # Test

      **Depends On:** single-item.md
      """

      item = ItemParser.parse(md)
      assert item.depends_on == ["single-item.md"]
    end

    test "empty depends_on when not present" do
      md = """
      # Test

      **Priority:** high
      """

      item = ItemParser.parse(md)
      assert item.depends_on == []
    end
  end

  describe "parse_file/1" do
    setup do
      # Create a temp directory and file
      tmp_dir = Path.join(System.tmp_dir!(), "arbor_flow_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      file_path = Path.join(tmp_dir, "test_item.md")

      File.write!(file_path, @sample_markdown)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, tmp_dir: tmp_dir, file_path: file_path}
    end

    test "parses file and includes path", %{file_path: file_path} do
      assert {:ok, item} = ItemParser.parse_file(file_path)
      assert item.title == "Test Feature"
      assert item.path == file_path
    end

    test "returns error for missing file" do
      assert {:error, :enoent} = ItemParser.parse_file("/nonexistent/file.md")
    end
  end

  describe "serialize/1" do
    test "serializes basic item" do
      item = %{
        title: "Serialized Item",
        priority: :high,
        category: :feature,
        summary: "A test summary.",
        created_at: ~D[2026-02-01]
      }

      md = ItemParser.serialize(item)

      assert md =~ "# Serialized Item"
      assert md =~ "**Created:** 2026-02-01"
      assert md =~ "**Priority:** high"
      assert md =~ "**Category:** feature"
      assert md =~ "## Summary"
      assert md =~ "A test summary."
    end

    test "serializes type and effort" do
      item = %{
        title: "With Type",
        type: "research",
        effort: :large,
        created_at: ~D[2026-02-01]
      }

      md = ItemParser.serialize(item)

      assert md =~ "**Type:** research"
      assert md =~ "**Effort:** large"
    end

    test "serializes depends_on and blocks as frontmatter" do
      item = %{
        title: "With Deps",
        depends_on: ["item_123.md", "item_456.md"],
        blocks: ["item_789.md"]
      }

      md = ItemParser.serialize(item)

      assert md =~ "**Depends On:** item_123.md, item_456.md"
      assert md =~ "**Blocks:** item_789.md"
      # Should NOT have a Dependencies section
      refute md =~ "## Dependencies"
    end

    test "serializes acceptance criteria" do
      item = %{
        title: "With Criteria",
        acceptance_criteria: [
          %{text: "First item", completed: true},
          %{text: "Second item", completed: false}
        ]
      }

      md = ItemParser.serialize(item)

      assert md =~ "## Acceptance Criteria"
      assert md =~ "- [x] First item"
      assert md =~ "- [ ] Second item"
    end

    test "serializes definition of done" do
      item = %{
        title: "With Done List",
        definition_of_done: [
          %{text: "Tests pass", completed: false}
        ]
      }

      md = ItemParser.serialize(item)

      assert md =~ "## Definition of Done"
      assert md =~ "- [ ] Tests pass"
    end

    test "serializes related files" do
      item = %{
        title: "With Files",
        related_files: ["lib/foo.ex", "test/foo_test.exs"]
      }

      md = ItemParser.serialize(item)

      assert md =~ "## Related Files"
      assert md =~ "- `lib/foo.ex`"
      assert md =~ "- `test/foo_test.exs`"
    end

    test "serializes notes" do
      item = %{
        title: "With Notes",
        notes: "Some important notes\nwith multiple lines."
      }

      md = ItemParser.serialize(item)

      assert md =~ "## Notes"
      assert md =~ "Some important notes"
    end

    test "serializes unknown metadata as frontmatter" do
      item = %{
        title: "With Metadata",
        metadata: %{"source" => "github-42", "session" => "abc123"},
        created_at: ~D[2026-02-01]
      }

      md = ItemParser.serialize(item)

      assert md =~ "**Source:** github-42"
      assert md =~ "**Session:** abc123"
    end

    test "handles nil title" do
      item = %{title: nil}
      md = ItemParser.serialize(item)
      assert md =~ "# [Untitled]"
    end

    test "omits empty sections" do
      item = %{
        title: "Minimal",
        acceptance_criteria: [],
        related_files: [],
        depends_on: [],
        blocks: [],
        notes: nil
      }

      md = ItemParser.serialize(item)

      refute md =~ "## Acceptance Criteria"
      refute md =~ "## Related Files"
      refute md =~ "## Notes"
      refute md =~ "**Depends On:**"
      refute md =~ "**Blocks:**"
    end

    test "adds current date if created_at is nil" do
      item = %{title: "No Date"}
      md = ItemParser.serialize(item)

      today = Date.to_iso8601(Date.utc_today())
      assert md =~ "**Created:** #{today}"
    end
  end

  describe "round-trip" do
    test "parse -> serialize -> parse produces same data" do
      original = ItemParser.parse(@sample_markdown)
      serialized = ItemParser.serialize(original)
      reparsed = ItemParser.parse(serialized)

      # Core fields should match
      assert reparsed.title == original.title
      assert reparsed.priority == original.priority
      assert reparsed.category == original.category
      assert reparsed.type == original.type
      assert reparsed.effort == original.effort
      assert reparsed.summary == original.summary
      assert reparsed.why_it_matters == original.why_it_matters
      assert reparsed.acceptance_criteria == original.acceptance_criteria
      assert reparsed.definition_of_done == original.definition_of_done
      assert reparsed.depends_on == original.depends_on
      assert reparsed.blocks == original.blocks
      assert reparsed.related_files == original.related_files
      assert String.trim(reparsed.notes || "") == String.trim(original.notes || "")
    end

    test "minimal item round-trips" do
      minimal = %{
        title: "Minimal Round Trip"
      }

      serialized = ItemParser.serialize(minimal)
      reparsed = ItemParser.parse(serialized)

      assert reparsed.title == "Minimal Round Trip"
    end

    test "full item round-trips" do
      full = %{
        title: "Full Round Trip",
        priority: :critical,
        category: :bug,
        type: "hotfix",
        effort: :small,
        summary: "A critical bug fix.",
        why_it_matters: "Users are affected.",
        acceptance_criteria: [
          %{text: "Bug is fixed", completed: false},
          %{text: "Regression test added", completed: true}
        ],
        definition_of_done: [
          %{text: "PR approved", completed: false}
        ],
        depends_on: ["item_dep1.md"],
        blocks: ["item_block1.md"],
        related_files: ["lib/buggy.ex"],
        notes: "Found by QA.",
        created_at: ~D[2026-01-15]
      }

      serialized = ItemParser.serialize(full)
      reparsed = ItemParser.parse(serialized)

      assert reparsed.title == full.title
      assert reparsed.priority == full.priority
      assert reparsed.category == full.category
      assert reparsed.type == full.type
      assert reparsed.effort == full.effort
      assert reparsed.summary == full.summary
      assert reparsed.acceptance_criteria == full.acceptance_criteria
      assert reparsed.definition_of_done == full.definition_of_done
      assert reparsed.depends_on == full.depends_on
      assert reparsed.blocks == full.blocks
      assert reparsed.related_files == full.related_files
    end

    test "metadata round-trips" do
      item = %{
        title: "Metadata Round Trip",
        metadata: %{"source" => "github-42"},
        created_at: ~D[2026-02-01]
      }

      serialized = ItemParser.serialize(item)
      reparsed = ItemParser.parse(serialized)

      assert reparsed.metadata["source"] == "github-42"
    end
  end
end
