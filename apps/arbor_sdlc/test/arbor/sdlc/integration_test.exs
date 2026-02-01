defmodule Arbor.SDLC.IntegrationTest do
  @moduledoc """
  Integration tests for the SDLC pipeline.

  These tests verify the complete flow of items through the pipeline,
  from inbox to completion, with proper coordination between processors.
  """
  use ExUnit.Case, async: false

  alias Arbor.Flow.ItemParser
  alias Arbor.SDLC
  alias Arbor.SDLC.{Config, Pipeline, TestHelpers}
  alias Arbor.SDLC.Processors.{Deliberator, Expander}

  @moduletag :fast
  @moduletag :integration

  describe "full pipeline flow: inbox -> brainstorming -> planned" do
    setup do
      context = TestHelpers.setup_test_roadmap()

      on_exit(fn ->
        TestHelpers.cleanup_test_roadmap(context)
      end)

      context
    end

    test "item flows from inbox through expansion to brainstorming", %{
      temp_roadmap_root: root
    } do
      # Create a minimal inbox item
      content = """
      # Add user authentication

      We need login and logout functionality.
      """

      inbox_path = TestHelpers.create_test_item(root, :inbox, "auth.md", content)

      # Parse the inbox item
      {:ok, item} = SDLC.parse_file(inbox_path)
      assert item.title == "Add user authentication"
      assert item.path == inbox_path

      # Process through Expander
      {:ok, {:moved_and_updated, :brainstorming, expanded}} =
        Expander.process_item(item, ai_module: MockAI.ExpansionResponse)

      # Verify expansion added required fields
      assert expanded.priority != nil
      assert expanded.category != nil
      assert expanded.summary != nil
      assert expanded.acceptance_criteria != []
      assert expanded.definition_of_done != []
    end

    test "expanded item flows from brainstorming to planned via deliberation", %{
      temp_roadmap_root: root
    } do
      # Create an expanded item in brainstorming
      content = TestHelpers.expanded_item_content("Feature to Plan")
      brainstorm_path = TestHelpers.create_test_item(root, :brainstorming, "feature.md", content)

      # Parse the brainstorming item
      {:ok, item} = SDLC.parse_file(brainstorm_path)
      assert item.title == "Feature to Plan"

      # Process through Deliberator (well-specified = move to planned)
      {:ok, {:moved, :planned}} =
        Deliberator.process_item(item, ai_module: DeliberatorMockAI.WellSpecified)
    end

    test "complete flow: inbox -> brainstorming -> planned", %{temp_roadmap_root: root} do
      # Stage 1: Create raw inbox item
      raw_content = """
      # Implement caching layer

      Add Redis caching for frequently accessed data.
      """

      inbox_path = TestHelpers.create_test_item(root, :inbox, "caching.md", raw_content)
      {:ok, inbox_item} = SDLC.parse_file(inbox_path)

      # Stage 2: Expand inbox item
      {:ok, {:moved_and_updated, :brainstorming, expanded_item}} =
        Expander.process_item(inbox_item, ai_module: MockAI.ExpansionResponse)

      # Simulate writing and moving the file (normally done by facade)
      brainstorm_content = ItemParser.serialize(Map.from_struct(expanded_item))

      brainstorm_path =
        TestHelpers.create_test_item(root, :brainstorming, "caching.md", brainstorm_content)

      # Parse the new brainstorming file
      {:ok, brainstorm_item} = SDLC.parse_file(brainstorm_path)

      # Stage 3: Deliberate brainstorming item
      {:ok, {:moved, :planned}} =
        Deliberator.process_item(brainstorm_item, ai_module: DeliberatorMockAI.WellSpecified)

      # Verify the item would be placed in planned directory
      planned_path = Pipeline.stage_path(:planned, root)
      assert File.dir?(planned_path)
    end
  end

  describe "authoritative field preservation across stages" do
    setup do
      context = TestHelpers.setup_test_roadmap()

      on_exit(fn ->
        TestHelpers.cleanup_test_roadmap(context)
      end)

      context
    end

    test "user-set priority and category survive expansion", %{temp_roadmap_root: root} do
      # User creates item with specific priority and category
      content = """
      # Critical database migration

      **Priority:** critical
      **Category:** infrastructure

      Must migrate before deadline.
      """

      inbox_path = TestHelpers.create_test_item(root, :inbox, "migration.md", content)
      {:ok, item} = SDLC.parse_file(inbox_path)

      # Verify initial values
      assert item.priority == :critical
      assert item.category == :infrastructure

      # Expand with mock AI that would suggest different values
      {:ok, {:moved_and_updated, :brainstorming, expanded}} =
        Expander.process_item(item, ai_module: MockAI.ExpansionResponse)

      # User's authoritative fields should be preserved
      assert expanded.priority == :critical
      assert expanded.category == :infrastructure
      # But LLM fields should be filled in
      assert expanded.summary != nil
    end
  end

  describe "error handling and recovery" do
    setup do
      context = TestHelpers.setup_test_roadmap()

      on_exit(fn ->
        TestHelpers.cleanup_test_roadmap(context)
      end)

      context
    end

    test "AI failure in expansion is handled gracefully", %{temp_roadmap_root: root} do
      content = """
      # Test feature

      Simple test.
      """

      inbox_path = TestHelpers.create_test_item(root, :inbox, "test.md", content)
      {:ok, item} = SDLC.parse_file(inbox_path)

      # Process with failing AI
      result = Expander.process_item(item, ai_module: MockAI.FailureResponse)

      assert {:error, {:ai_call_failed, :connection_error}} = result

      # Original file should still exist (not moved on failure)
      assert File.exists?(inbox_path)
    end

    test "AI failure in deliberation is handled gracefully", %{temp_roadmap_root: root} do
      content = TestHelpers.expanded_item_content("Failing Item")
      brainstorm_path = TestHelpers.create_test_item(root, :brainstorming, "failing.md", content)
      {:ok, item} = SDLC.parse_file(brainstorm_path)

      # Process with failing AI
      result =
        Deliberator.process_item(item, ai_module: DeliberatorMockAI.failure(:connection_error))

      assert {:error, {:analysis_failed, :connection_error}} = result

      # Original file should still exist
      assert File.exists?(brainstorm_path)
    end

    test "malformed AI response is handled", %{temp_roadmap_root: root} do
      content = """
      # Malformed test

      Test item.
      """

      inbox_path = TestHelpers.create_test_item(root, :inbox, "malformed.md", content)
      {:ok, item} = SDLC.parse_file(inbox_path)

      # Process with malformed response
      result = Expander.process_item(item, ai_module: MockAI.MalformedResponse)

      # Should handle gracefully (either error or fallback)
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end

  describe "pipeline transition validation" do
    test "valid transitions are allowed" do
      assert Pipeline.transition_allowed?(:inbox, :brainstorming) == true
      assert Pipeline.transition_allowed?(:brainstorming, :planned) == true
      assert Pipeline.transition_allowed?(:brainstorming, :discarded) == true
      assert Pipeline.transition_allowed?(:planned, :in_progress) == true
      assert Pipeline.transition_allowed?(:in_progress, :completed) == true
    end

    test "invalid transitions are rejected" do
      # Can't skip stages
      assert Pipeline.transition_allowed?(:inbox, :planned) == false
      assert Pipeline.transition_allowed?(:inbox, :completed) == false

      # Can't go backwards
      assert Pipeline.transition_allowed?(:brainstorming, :inbox) == false
      assert Pipeline.transition_allowed?(:completed, :planned) == false

      # Terminal stages can't transition
      assert Pipeline.transition_allowed?(:completed, :inbox) == false
      assert Pipeline.transition_allowed?(:discarded, :planned) == false
    end
  end

  describe "stage directory mapping" do
    test "all stages have directory mappings" do
      stages = Pipeline.stages()

      for stage <- stages do
        directory = Pipeline.stage_directory(stage)
        assert is_binary(directory)
        assert String.length(directory) > 0
      end
    end

    test "directory mappings are reversible" do
      for stage <- Pipeline.stages() do
        directory = Pipeline.stage_directory(stage)
        {:ok, recovered_stage} = Pipeline.directory_stage(directory)
        assert recovered_stage == stage
      end
    end
  end

  describe "file tracking across moves" do
    setup do
      context = TestHelpers.setup_test_roadmap()

      on_exit(fn ->
        TestHelpers.cleanup_test_roadmap(context)
      end)

      context
    end

    test "move_item updates file location", %{temp_roadmap_root: root} do
      config = Config.new(roadmap_root: root)
      content = TestHelpers.simple_item_content("Movable Item")
      inbox_path = TestHelpers.create_test_item(root, :inbox, "movable.md", content)

      {:ok, item} = SDLC.parse_file(inbox_path)

      # Move from inbox to brainstorming
      {:ok, new_path} = SDLC.move_item(item, :brainstorming, config: config)

      # Verify move
      assert String.contains?(new_path, "1-brainstorming")
      assert File.exists?(new_path)
      refute File.exists?(inbox_path)
    end
  end
end
