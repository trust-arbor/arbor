defmodule Arbor.SDLC.Processors.ConsistencyCheckerTest do
  use ExUnit.Case, async: true

  alias Arbor.SDLC.{Config, Processors.ConsistencyChecker}
  alias Arbor.SDLC.TestHelpers

  @moduletag :fast

  describe "processor_id/0" do
    test "returns expected processor ID" do
      assert ConsistencyChecker.processor_id() == "sdlc_consistency_checker"
    end
  end

  describe "can_handle?/1" do
    test "always returns false (checker doesn't process individual items)" do
      assert ConsistencyChecker.can_handle?(%{path: "/any/path.md"}) == false
      assert ConsistencyChecker.can_handle?(%{title: "Test"}) == false
      assert ConsistencyChecker.can_handle?(nil) == false
    end
  end

  describe "available_checks/0" do
    test "returns list of available checks" do
      checks = ConsistencyChecker.available_checks()

      assert :completion_detection in checks
      assert :index_refresh in checks
      assert :stale_detection in checks
      assert :health_check in checks
      assert length(checks) == 4
    end
  end

  describe "run/1 with dry_run" do
    setup do
      context = TestHelpers.setup_test_roadmap()
      on_exit(fn -> TestHelpers.cleanup_test_roadmap(context) end)
      context
    end

    test "runs all checks in dry_run mode", %{temp_roadmap_root: root} do
      config = %Config{Config.new() | roadmap_root: root}

      result = ConsistencyChecker.run(config: config, dry_run: true)

      assert {:ok, summary} = result
      assert is_list(summary.checks_run)
      assert length(summary.checks_run) == 4
      assert is_integer(summary.issues_found)
      assert is_list(summary.items_flagged)
      assert is_map(summary.details)
    end

    test "runs specific checks only", %{temp_roadmap_root: root} do
      config = %Config{Config.new() | roadmap_root: root}

      result = ConsistencyChecker.run(config: config, checks: [:health_check], dry_run: true)

      assert {:ok, summary} = result
      assert summary.checks_run == [:health_check]
    end
  end

  describe "health_check" do
    setup do
      context = TestHelpers.setup_test_roadmap()
      on_exit(fn -> TestHelpers.cleanup_test_roadmap(context) end)
      context
    end

    test "detects items missing required fields", %{temp_roadmap_root: root} do
      # Create an item missing priority in brainstorming
      content = """
      # Test Item Without Priority

      **Created:** 2026-02-01
      **Category:** feature

      ## Summary

      Missing priority field.
      """

      TestHelpers.create_test_item(root, :brainstorming, "missing-priority.md", content)

      config = %Config{Config.new() | roadmap_root: root}

      {:ok, summary} =
        ConsistencyChecker.run(config: config, checks: [:health_check], dry_run: true)

      # Should detect the missing priority
      assert summary.issues_found > 0
      health_result = summary.details[:health_check]
      assert health_result.issues != []
    end

    test "passes items with all required fields", %{temp_roadmap_root: root} do
      # Create a properly formed item
      content = TestHelpers.expanded_item_content("Complete Item")
      TestHelpers.create_test_item(root, :brainstorming, "complete-item.md", content)

      config = %Config{Config.new() | roadmap_root: root}

      {:ok, summary} =
        ConsistencyChecker.run(config: config, checks: [:health_check], dry_run: true)

      health_result = summary.details[:health_check]

      # Should have no issues for this item (may have issues from missing fields on items without priority/category)
      issues_for_item =
        Enum.filter(health_result.issues, fn {path, _, _} ->
          String.contains?(path, "complete-item.md")
        end)

      assert issues_for_item == []
    end
  end

  describe "index_refresh" do
    setup do
      context = TestHelpers.setup_test_roadmap()
      on_exit(fn -> TestHelpers.cleanup_test_roadmap(context) end)
      context
    end

    test "creates INDEX.md when missing", %{temp_roadmap_root: root} do
      # Add some items
      content1 = TestHelpers.simple_item_content("Item One")
      content2 = TestHelpers.simple_item_content("Item Two")

      TestHelpers.create_test_item(root, :inbox, "item-one.md", content1)
      TestHelpers.create_test_item(root, :inbox, "item-two.md", content2)

      config = %Config{Config.new() | roadmap_root: root}

      # Dry run first to check what would happen
      {:ok, summary} =
        ConsistencyChecker.run(config: config, checks: [:index_refresh], dry_run: true)

      index_result = summary.details[:index_refresh]
      inbox_result = index_result.results[:inbox]

      assert inbox_result.would_update == true
      assert inbox_result.items_count == 2
    end

    test "updates INDEX.md when content changes", %{temp_roadmap_root: root} do
      # Create initial index
      index_path = Path.join([root, "0-inbox", "INDEX.md"])
      File.write!(index_path, "# Index\n\nOld content\n")

      # Add an item
      content = TestHelpers.simple_item_content("New Item")
      TestHelpers.create_test_item(root, :inbox, "new-item.md", content)

      config = %Config{Config.new() | roadmap_root: root}

      {:ok, summary} =
        ConsistencyChecker.run(config: config, checks: [:index_refresh], dry_run: true)

      index_result = summary.details[:index_refresh]
      inbox_result = index_result.results[:inbox]

      # Should want to update because the index is stale
      assert inbox_result.would_update == true
    end
  end

  describe "stale_detection" do
    setup do
      context = TestHelpers.setup_test_roadmap()
      on_exit(fn -> TestHelpers.cleanup_test_roadmap(context) end)
      context
    end

    test "detects stale items past threshold", %{temp_roadmap_root: root} do
      # Create an item
      content = TestHelpers.simple_item_content("Potentially Stale Item")
      path = TestHelpers.create_test_item(root, :inbox, "stale-item.md", content)

      # Set modification time to 30 days ago
      thirty_days_ago = System.os_time(:second) - 30 * 24 * 60 * 60
      File.touch!(path, thirty_days_ago)

      config = %Config{Config.new() | roadmap_root: root}

      {:ok, summary} =
        ConsistencyChecker.run(
          config: config,
          checks: [:stale_detection],
          stale_threshold_days: 14,
          dry_run: true
        )

      stale_result = summary.details[:stale_detection]

      assert stale_result.stale_count > 0
      assert Enum.any?(stale_result.items, &String.contains?(&1, "stale-item.md"))
    end

    test "does not flag recent items", %{temp_roadmap_root: root} do
      # Create a fresh item (today's date)
      content = TestHelpers.simple_item_content("Fresh Item")
      TestHelpers.create_test_item(root, :inbox, "fresh-item.md", content)

      config = %Config{Config.new() | roadmap_root: root}

      {:ok, summary} =
        ConsistencyChecker.run(
          config: config,
          checks: [:stale_detection],
          stale_threshold_days: 14,
          dry_run: true
        )

      stale_result = summary.details[:stale_detection]

      # Fresh item should not be flagged
      refute Enum.any?(stale_result.items, &String.contains?(&1, "fresh-item.md"))
    end
  end
end
