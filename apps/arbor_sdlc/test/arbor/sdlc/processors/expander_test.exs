defmodule Arbor.SDLC.Processors.ExpanderTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Flow.Item
  alias Arbor.SDLC.Processors.Expander
  alias Arbor.SDLC.TestHelpers

  @moduletag :fast

  describe "processor_id/0" do
    test "returns expected processor ID" do
      assert Expander.processor_id() == "sdlc_expander"
    end
  end

  describe "can_handle?/1" do
    test "returns true for items in inbox directory" do
      item = %{path: "/roadmap/0-inbox/test.md"}
      assert Expander.can_handle?(item) == true
    end

    test "returns false for items in brainstorming directory" do
      item = %{path: "/roadmap/1-brainstorming/test.md"}
      assert Expander.can_handle?(item) == false
    end

    test "returns false for items in planned directory" do
      item = %{path: "/roadmap/2-planned/test.md"}
      assert Expander.can_handle?(item) == false
    end

    test "returns false for items without path" do
      item = %{title: "Test"}
      assert Expander.can_handle?(item) == false
    end

    test "returns false for nil path" do
      item = %{path: nil}
      assert Expander.can_handle?(item) == false
    end
  end

  describe "process_item/2 with dry_run" do
    setup do
      context = TestHelpers.setup_test_roadmap()
      on_exit(fn -> TestHelpers.cleanup_test_roadmap(context) end)
      context
    end

    test "dry_run returns no_action", %{temp_roadmap_root: root} do
      # Create a test item
      content = """
      # Test Feature

      A simple test item.
      """

      path = TestHelpers.create_test_item(root, :inbox, "test-feature.md", content)

      {:ok, item} = Item.new(title: "Test Feature", path: path)

      assert {:ok, :no_action} = Expander.process_item(item, dry_run: true)
    end
  end

  describe "process_item/2 with mock AI" do
    setup do
      context = TestHelpers.setup_test_roadmap()
      on_exit(fn -> TestHelpers.cleanup_test_roadmap(context) end)
      context
    end

    test "expands item with mock AI response", %{temp_roadmap_root: root} do
      # Create a minimal inbox item
      content = """
      # Add user authentication

      Need to add login/logout functionality.
      """

      path = TestHelpers.create_test_item(root, :inbox, "auth-feature.md", content)

      {:ok, item} = Item.new(title: "Add user authentication", path: path, raw_content: content)

      # Create a mock AI module
      mock_ai = MockAI.create_expansion_response()

      result = Expander.process_item(item, ai_module: mock_ai)

      assert {:ok, {:moved_and_updated, :brainstorming, expanded_item}} = result

      # Verify expansion filled in fields
      assert expanded_item.title == "Add user authentication"
      assert expanded_item.priority != nil
      assert expanded_item.category != nil
      assert expanded_item.summary != nil
      assert expanded_item.acceptance_criteria != []
    end

    test "preserves existing priority when set", %{temp_roadmap_root: root} do
      content = """
      # Critical security fix

      Must fix ASAP.
      """

      path = TestHelpers.create_test_item(root, :inbox, "security-fix.md", content)

      {:ok, item} =
        Item.new(
          title: "Critical security fix",
          path: path,
          raw_content: content,
          priority: :critical
        )

      mock_ai = MockAI.create_expansion_response(priority: "low")

      {:ok, {:moved_and_updated, :brainstorming, expanded_item}} =
        Expander.process_item(item, ai_module: mock_ai)

      # Original priority should be preserved
      assert expanded_item.priority == :critical
    end

    test "preserves existing category when set", %{temp_roadmap_root: root} do
      content = """
      # Documentation update

      Update the API docs.
      """

      path = TestHelpers.create_test_item(root, :inbox, "docs-update.md", content)

      {:ok, item} =
        Item.new(
          title: "Documentation update",
          path: path,
          raw_content: content,
          category: :documentation
        )

      mock_ai = MockAI.create_expansion_response()

      {:ok, {:moved_and_updated, :brainstorming, expanded_item}} =
        Expander.process_item(item, ai_module: mock_ai)

      # Original category should be preserved, AI-suggested "feature" ignored
      assert expanded_item.category == :documentation
      # But LLM-generated fields should still be filled in
      assert expanded_item.summary != nil
      assert expanded_item.acceptance_criteria != []
      assert expanded_item.definition_of_done != []
    end

    test "preserves both priority and category during re-expansion", %{temp_roadmap_root: root} do
      content = """
      # Critical infrastructure fix

      Must address immediately.
      """

      path = TestHelpers.create_test_item(root, :inbox, "critical-infra.md", content)

      {:ok, item} =
        Item.new(
          title: "Critical infrastructure fix",
          path: path,
          raw_content: content,
          priority: :critical,
          category: :infrastructure
        )

      mock_ai = MockAI.create_expansion_response()

      {:ok, {:moved_and_updated, :brainstorming, expanded_item}} =
        Expander.process_item(item, ai_module: mock_ai)

      # Both authoritative fields preserved
      assert expanded_item.priority == :critical
      assert expanded_item.category == :infrastructure
      # LLM fields filled
      assert expanded_item.summary != nil
      assert expanded_item.why_it_matters != nil
    end

    test "handles AI failure gracefully", %{temp_roadmap_root: root} do
      content = """
      # Test item

      Test.
      """

      path = TestHelpers.create_test_item(root, :inbox, "test.md", content)

      {:ok, item} = Item.new(title: "Test item", path: path, raw_content: content)

      mock_ai = MockAI.create_failure_response(:connection_error)

      result = Expander.process_item(item, ai_module: mock_ai)

      assert {:error, {:ai_call_failed, :connection_error}} = result
    end
  end

  describe "serialize_item/1" do
    test "serializes item to markdown" do
      {:ok, item} =
        Item.new(
          title: "Test Item",
          priority: :high,
          category: :feature,
          summary: "A test summary",
          acceptance_criteria: [%{text: "First criterion", completed: false}]
        )

      markdown = Expander.serialize_item(item)

      assert markdown =~ "# Test Item"
      assert markdown =~ "**Priority:** high"
      assert markdown =~ "**Category:** feature"
      assert markdown =~ "## Summary"
      assert markdown =~ "A test summary"
      assert markdown =~ "## Acceptance Criteria"
      assert markdown =~ "First criterion"
    end
  end
end
