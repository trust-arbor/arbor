defmodule Arbor.SDLCTest do
  use ExUnit.Case, async: false

  alias Arbor.SDLC
  alias Arbor.SDLC.{Config, Pipeline, TestHelpers}

  @moduletag :fast

  setup do
    # Start consensus infrastructure — Deliberator always convenes council
    prev_ai = TestHelpers.ensure_consensus_started()

    context = TestHelpers.setup_test_roadmap()

    on_exit(fn ->
      TestHelpers.cleanup_test_roadmap(context)
      TestHelpers.restore_ai_module(prev_ai)
    end)

    context
  end

  describe "healthy?/0" do
    test "returns true when application supervisor is running" do
      # The SDLC application starts the supervisor automatically
      assert SDLC.healthy?()
    end
  end

  describe "status/0" do
    test "returns status map" do
      status = SDLC.status()

      assert Map.has_key?(status, :healthy)
      assert Map.has_key?(status, :roadmap_root)
      assert Map.has_key?(status, :watcher_enabled)
    end
  end

  describe "parse_file/1" do
    test "parses a valid item file", %{temp_roadmap_root: root} do
      content = TestHelpers.simple_item_content("Test Feature")
      path = TestHelpers.create_test_item(root, :inbox, "test-feature.md", content)

      {:ok, item} = SDLC.parse_file(path)

      assert item.title == "Test Feature"
      assert item.priority == :medium
      assert item.category == :feature
      assert item.path == path
      assert item.content_hash != nil
    end

    test "returns error for non-existent file" do
      assert {:error, :enoent} = SDLC.parse_file("/nonexistent/file.md")
    end

    test "parses expanded item with criteria", %{temp_roadmap_root: root} do
      content = TestHelpers.expanded_item_content("Expanded Feature")
      path = TestHelpers.create_test_item(root, :brainstorming, "expanded.md", content)

      {:ok, item} = SDLC.parse_file(path)

      assert item.title == "Expanded Feature"
      assert item.priority == :high
      assert item.acceptance_criteria != []
      assert item.definition_of_done != []
    end
  end

  describe "move_item/3" do
    test "moves item between valid stages", %{temp_roadmap_root: root} do
      content = TestHelpers.simple_item_content("Moveable Item")
      path = TestHelpers.create_test_item(root, :inbox, "moveable.md", content)

      {:ok, item} = SDLC.parse_file(path)
      config = Config.new(roadmap_root: root)

      {:ok, new_path} = SDLC.move_item(item, :brainstorming, config: config)

      assert String.contains?(new_path, "1-brainstorming")
      assert File.exists?(new_path)
      refute File.exists?(path)
    end

    test "rejects invalid transition", %{temp_roadmap_root: root} do
      content = TestHelpers.simple_item_content("Skip Stage Item")
      path = TestHelpers.create_test_item(root, :inbox, "skip.md", content)

      {:ok, item} = SDLC.parse_file(path)
      config = Config.new(roadmap_root: root)

      # Trying to skip from inbox directly to planned
      assert {:error, {:invalid_transition, :inbox, :planned}} =
               SDLC.move_item(item, :planned, config: config)
    end
  end

  describe "process_file/2" do
    test "processes inbox file via Expander", %{temp_roadmap_root: root} do
      content = TestHelpers.simple_item_content("Process Me")
      path = TestHelpers.create_test_item(root, :inbox, "process.md", content)

      # Use mock AI to avoid real LLM calls
      {:ok, result} = SDLC.process_file(path, ai_module: MockAI.ExpansionResponse)

      # Phase 3: Expander processes and returns expanded item ready for brainstorming
      assert {:moved_and_updated, :brainstorming, expanded_item} = result
      assert expanded_item.title == "Process Me"
      assert expanded_item.priority != nil
      assert expanded_item.category != nil
    end

    test "processes brainstorming file via Deliberator", %{temp_roadmap_root: root} do
      content = TestHelpers.expanded_item_content("Deliberate Me")
      path = TestHelpers.create_test_item(root, :brainstorming, "deliberate.md", content)

      # Use mock AI that says item is well-specified
      {:ok, result} = SDLC.process_file(path, ai_module: DeliberatorMockAI.WellSpecified)

      # Phase 3: Deliberator processes and moves to planned
      assert result == {:moved, :planned}
    end

    test "returns no_action for completed item", %{temp_roadmap_root: root} do
      content = TestHelpers.simple_item_content("Done Item")
      path = TestHelpers.create_test_item(root, :completed, "done.md", content)

      {:ok, result} = SDLC.process_file(path)

      assert result == :no_action
    end

    test "returns dry_run result when option set", %{temp_roadmap_root: root} do
      content = TestHelpers.simple_item_content("Dry Run")
      path = TestHelpers.create_test_item(root, :planned, "dryrun.md", content)

      {:ok, result} = SDLC.process_file(path, dry_run: true)

      assert result == :dry_run
    end
  end

  describe "handle_new_file/3" do
    test "handles new file callback without crashing", %{temp_roadmap_root: root} do
      # Item in a non-processing stage (completed) so no processor is invoked
      content = TestHelpers.simple_item_content("New File")
      path = TestHelpers.create_test_item(root, :completed, "new.md", content)
      hash = Arbor.Flow.compute_hash(content)

      assert :ok = SDLC.handle_new_file(path, content, hash)
    end

    test "handles invalid content gracefully" do
      # Content that won't parse as valid markdown item
      content = "Not valid markdown item format"
      hash = Arbor.Flow.compute_hash(content)

      assert {:error, _} = SDLC.handle_new_file("/fake/path.md", content, hash)
    end
  end

  describe "handle_changed_file/3" do
    test "re-processes changed file without crashing", %{temp_roadmap_root: root} do
      # Use a terminal stage so no LLM call is triggered
      content = TestHelpers.simple_item_content("Changed File")
      path = TestHelpers.create_test_item(root, :completed, "changed.md", content)
      hash = Arbor.Flow.compute_hash(content)

      assert :ok = SDLC.handle_changed_file(path, content, hash)
    end

    test "re-processes file when content changes", %{temp_roadmap_root: root} do
      original = TestHelpers.simple_item_content("Evolving Item")
      path = TestHelpers.create_test_item(root, :completed, "evolving.md", original)

      # Simulate content change
      updated = TestHelpers.simple_item_content("Evolving Item Updated")
      File.write!(path, updated)
      new_hash = Arbor.Flow.compute_hash(updated)

      # Changed file in a terminal stage should not crash
      assert :ok = SDLC.handle_changed_file(path, updated, new_hash)
    end

    test "handles invalid content gracefully on change" do
      content = "Not valid markdown item format"
      hash = Arbor.Flow.compute_hash(content)

      assert {:error, _} = SDLC.handle_changed_file("/fake/path.md", content, hash)
    end

    test "preserves authoritative fields during re-expansion", %{temp_roadmap_root: root} do
      # Create an item that already has priority and category set by the user
      content = """
      # Re-expand Me

      **Priority:** critical
      **Category:** bug

      ## Summary

      An existing item that the user edited.
      """

      path = TestHelpers.create_test_item(root, :inbox, "re-expand.md", content)

      # Process via Expander with mock AI (returns priority: high, category: feature)
      result = SDLC.process_file(path, ai_module: MockAI.ExpansionResponse)

      assert {:ok, {:moved_and_updated, :brainstorming, expanded}} = result
      # Authoritative fields from the file should be preserved over AI suggestions
      assert expanded.priority == :critical
      assert expanded.category == :bug
    end
  end

  describe "handle_deleted_file/1" do
    test "handles deleted file callback" do
      assert :ok = SDLC.handle_deleted_file("/roadmap/0-inbox/deleted.md")
    end
  end

  describe "pipeline delegations" do
    test "stages/0 delegates to Pipeline" do
      assert SDLC.stages() == Pipeline.stages()
    end

    test "stage_directory/1 delegates to Pipeline" do
      assert SDLC.stage_directory(:inbox) == Pipeline.stage_directory(:inbox)
    end

    test "transition_allowed?/2 delegates to Pipeline" do
      assert SDLC.transition_allowed?(:inbox, :brainstorming) ==
               Pipeline.transition_allowed?(:inbox, :brainstorming)
    end

    test "stage_path/2 delegates to Pipeline" do
      assert SDLC.stage_path(:inbox, "/roadmap") == Pipeline.stage_path(:inbox, "/roadmap")
    end
  end

  describe "ensure_directories!/1" do
    test "creates all stage directories", %{temp_roadmap_root: root} do
      # Remove one directory to test recreation
      File.rm_rf!(Pipeline.stage_path(:completed, root))

      assert :ok = SDLC.ensure_directories!(root)

      assert File.dir?(Pipeline.stage_path(:completed, root))
    end
  end
end
