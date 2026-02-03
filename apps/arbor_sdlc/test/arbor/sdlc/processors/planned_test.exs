defmodule Arbor.SDLC.Processors.PlannedTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Flow.Item
  alias Arbor.SDLC.Config
  alias Arbor.SDLC.Processors.Planned
  alias Arbor.SDLC.TestHelpers

  @moduletag :fast

  describe "processor_id/0" do
    test "returns expected processor ID" do
      assert Planned.processor_id() == "sdlc_planned"
    end
  end

  describe "can_handle?/1" do
    test "returns true for items in planned directory" do
      item = %{path: "/roadmap/2-planned/test.md"}
      assert Planned.can_handle?(item) == true
    end

    test "returns false for items in inbox directory" do
      item = %{path: "/roadmap/0-inbox/test.md"}
      assert Planned.can_handle?(item) == false
    end

    test "returns false for items in brainstorming directory" do
      item = %{path: "/roadmap/1-brainstorming/test.md"}
      assert Planned.can_handle?(item) == false
    end

    test "returns false for items in in_progress directory" do
      item = %{path: "/roadmap/3-in-progress/test.md"}
      assert Planned.can_handle?(item) == false
    end

    test "returns false for items without path" do
      item = %{title: "Test"}
      assert Planned.can_handle?(item) == false
    end

    test "returns false for nil path" do
      item = %{path: nil}
      assert Planned.can_handle?(item) == false
    end
  end

  describe "process_item/2 with dry_run" do
    setup do
      context = TestHelpers.setup_test_roadmap()
      on_exit(fn -> TestHelpers.cleanup_test_roadmap(context) end)
      context
    end

    test "dry_run returns :dry_run", %{temp_roadmap_root: root} do
      content = TestHelpers.expanded_item_content("Test Feature")
      path = TestHelpers.create_test_item(root, :planned, "test-feature.md", content)

      {:ok, item} = Item.new(title: "Test Feature", path: path)

      assert {:ok, :dry_run} = Planned.process_item(item, dry_run: true)
    end
  end

  describe "auto check" do
    setup do
      context = TestHelpers.setup_test_roadmap()
      on_exit(fn -> TestHelpers.cleanup_test_roadmap(context) end)
      context
    end

    test "skips items without auto: true", %{temp_roadmap_root: root} do
      content = TestHelpers.expanded_item_content("Test Feature")
      path = TestHelpers.create_test_item(root, :planned, "test-feature.md", content)

      {:ok, item} = Item.new(title: "Test Feature", path: path, metadata: %{})

      assert {:ok, :skipped_not_auto} = Planned.process_item(item, [])
    end

    test "skips items with auto: false", %{temp_roadmap_root: root} do
      content = TestHelpers.expanded_item_content("Test Feature")
      path = TestHelpers.create_test_item(root, :planned, "test-feature.md", content)

      {:ok, item} = Item.new(title: "Test Feature", path: path, metadata: %{"auto" => false})

      assert {:ok, :skipped_not_auto} = Planned.process_item(item, [])
    end

    test "skips items with execution_mode: manual", %{temp_roadmap_root: root} do
      content = TestHelpers.expanded_item_content("Test Feature")
      path = TestHelpers.create_test_item(root, :planned, "test-feature.md", content)

      {:ok, item} =
        Item.new(
          title: "Test Feature",
          path: path,
          metadata: %{"auto" => true, "execution_mode" => "manual"}
        )

      assert {:ok, :skipped_manual} = Planned.process_item(item, [])
    end

    test "skips items that already have session_id", %{temp_roadmap_root: root} do
      content = TestHelpers.expanded_item_content("Test Feature")
      path = TestHelpers.create_test_item(root, :planned, "test-feature.md", content)

      {:ok, item} =
        Item.new(
          title: "Test Feature",
          path: path,
          metadata: %{"auto" => true, "session_id" => "sdlc-test-123"}
        )

      assert {:ok, :skipped_active_session} = Planned.process_item(item, [])
    end

    test "skips items that have reached max_attempts", %{temp_roadmap_root: root} do
      content = TestHelpers.expanded_item_content("Test Feature")
      path = TestHelpers.create_test_item(root, :planned, "test-feature.md", content)

      {:ok, item} =
        Item.new(
          title: "Test Feature",
          path: path,
          metadata: %{"auto" => true, "max_attempts" => 2, "attempt" => 2}
        )

      assert {:ok, :skipped_max_attempts} = Planned.process_item(item, [])
    end
  end

  describe "GenServer functionality" do
    # Run these tests serially since they use a shared process name
    @describetag :capture_log

    setup do
      # Use a unique name per test to avoid conflicts
      # This is test code with trusted input (unique_integer), so safe
      test_name = Module.concat([TestPlannedProcessor, "T#{:erlang.unique_integer([:positive])}"])

      {:ok, pid} =
        Planned.start_link(
          name: test_name,
          config: Config.new()
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      %{processor: pid}
    end

    test "starts with zero active sessions", %{processor: processor} do
      assert Planned.active_session_count(processor) == 0
    end

    test "can_spawn_session? returns true when under limit", %{processor: processor} do
      assert Planned.can_spawn_session?(processor) == true
    end

    test "register_session increases count", %{processor: processor} do
      # Start a dummy process to monitor
      dummy_pid = spawn(fn -> Process.sleep(60_000) end)

      assert :ok =
               Planned.register_session(
                 processor,
                 "/path/to/item.md",
                 "test-session-1",
                 dummy_pid
               )

      assert Planned.active_session_count(processor) == 1

      # Clean up
      Process.exit(dummy_pid, :kill)
    end

    test "unregister_session decreases count", %{processor: processor} do
      dummy_pid = spawn(fn -> Process.sleep(60_000) end)

      Planned.register_session(processor, "/path/to/item.md", "test-session-2", dummy_pid)
      assert Planned.active_session_count(processor) == 1

      Planned.unregister_session(processor, "test-session-2")
      # Give the cast time to process
      Process.sleep(50)
      assert Planned.active_session_count(processor) == 0

      Process.exit(dummy_pid, :kill)
    end
  end

  describe "execution mode detection" do
    setup do
      context = TestHelpers.setup_test_roadmap()
      on_exit(fn -> TestHelpers.cleanup_test_roadmap(context) end)
      context
    end

    test "detects auto execution mode from metadata", %{temp_roadmap_root: root} do
      content = TestHelpers.expanded_item_content("Test Feature")
      path = TestHelpers.create_test_item(root, :planned, "auto-item.md", content)

      {:ok, item} =
        Item.new(
          title: "Test Feature",
          path: path,
          metadata: %{"auto" => true, "execution_mode" => "auto"}
        )

      # Process would try to spawn, but we're just checking the skip logic
      # Items with auto: true and execution_mode: auto should proceed
      # (unless at capacity or other limits)
      result = Planned.process_item(item, dry_run: true)
      assert {:ok, :dry_run} = result
    end

    test "detects hand execution mode from metadata", %{temp_roadmap_root: root} do
      content = TestHelpers.expanded_item_content("Test Feature")
      path = TestHelpers.create_test_item(root, :planned, "hand-item.md", content)

      {:ok, item} =
        Item.new(
          title: "Test Feature",
          path: path,
          metadata: %{"auto" => true, "execution_mode" => "hand"}
        )

      result = Planned.process_item(item, dry_run: true)
      assert {:ok, :dry_run} = result
    end
  end
end
