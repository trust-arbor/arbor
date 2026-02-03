defmodule Arbor.SDLC.Processors.DeliberatorTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Flow.Item
  alias Arbor.SDLC.Processors.Deliberator
  alias Arbor.SDLC.TestHelpers

  @moduletag :fast

  describe "processor_id/0" do
    test "returns expected processor ID" do
      assert Deliberator.processor_id() == "sdlc_deliberator"
    end
  end

  describe "can_handle?/1" do
    test "returns true for items in brainstorming directory" do
      item = %{path: "/roadmap/1-brainstorming/test.md"}
      assert Deliberator.can_handle?(item) == true
    end

    test "returns false for items in inbox directory" do
      item = %{path: "/roadmap/0-inbox/test.md"}
      assert Deliberator.can_handle?(item) == false
    end

    test "returns false for items in planned directory" do
      item = %{path: "/roadmap/2-planned/test.md"}
      assert Deliberator.can_handle?(item) == false
    end

    test "returns false for items without path" do
      item = %{title: "Test"}
      assert Deliberator.can_handle?(item) == false
    end
  end

  describe "process_item/2 with dry_run" do
    setup do
      context = TestHelpers.setup_test_roadmap()
      on_exit(fn -> TestHelpers.cleanup_test_roadmap(context) end)
      context
    end

    test "dry_run returns no_action", %{temp_roadmap_root: root} do
      content = TestHelpers.expanded_item_content("Test Deliberation Item")
      path = TestHelpers.create_test_item(root, :brainstorming, "test-deliberation.md", content)

      {:ok, item} =
        Item.new(
          title: "Test Deliberation Item",
          path: path,
          summary: "A test item",
          acceptance_criteria: [%{text: "Criterion", completed: false}]
        )

      assert {:ok, :no_action} = Deliberator.process_item(item, dry_run: true)
    end
  end

  describe "process_item/2 with mock AI for well-specified items" do
    setup do
      context = TestHelpers.setup_test_roadmap()

      # Start consensus infrastructure — all paths now go through council
      prev_ai = TestHelpers.ensure_consensus_started()

      on_exit(fn ->
        TestHelpers.cleanup_test_roadmap(context)
        TestHelpers.restore_ai_module(prev_ai)
      end)

      context
    end

    test "well-specified item goes through council and is approved", %{
      temp_roadmap_root: root
    } do
      content = TestHelpers.expanded_item_content("Well Specified Feature")
      path = TestHelpers.create_test_item(root, :brainstorming, "well-specified.md", content)

      {:ok, item} =
        Item.new(
          title: "Well Specified Feature",
          path: path,
          summary: "A well-defined feature with clear requirements",
          priority: :high,
          category: :feature,
          acceptance_criteria: [
            %{text: "First clear criterion", completed: false},
            %{text: "Second clear criterion", completed: false}
          ],
          definition_of_done: [
            %{text: "Tests pass", completed: false},
            %{text: "Code reviewed", completed: false}
          ]
        )

      # Mock AI that says item is well-specified (for Deliberator analysis)
      # Council then evaluates and approves via EvaluatorMockAI.StandardApprove
      mock_ai = DeliberatorMockAI.well_specified()

      result = Deliberator.process_item(item, ai_module: mock_ai)

      # Council may return moved (no changes) or moved_and_updated (with decision notes)
      assert {:ok, outcome} = result
      assert elem(outcome, 1) == :planned
      assert elem(outcome, 0) in [:moved, :moved_and_updated]
    end
  end

  describe "serialize_item/1" do
    test "serializes item to markdown" do
      {:ok, item} =
        Item.new(
          title: "Deliberated Item",
          priority: :medium,
          category: :refactor,
          summary: "A test summary after deliberation",
          notes: "Some notes from deliberation"
        )

      markdown = Deliberator.serialize_item(item)

      assert markdown =~ "# Deliberated Item"
      assert markdown =~ "**Priority:** medium"
      assert markdown =~ "**Category:** refactor"
      assert markdown =~ "## Summary"
      assert markdown =~ "## Notes"
    end
  end
end
