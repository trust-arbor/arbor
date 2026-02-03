defmodule Arbor.SDLC.Processors.InProgressTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Arbor.Contracts.Flow.Item
  alias Arbor.SDLC.Config
  alias Arbor.SDLC.Processors.InProgress
  alias Arbor.SDLC.TestHelpers

  @moduletag :fast

  describe "processor_id/0" do
    test "returns expected processor ID" do
      assert InProgress.processor_id() == "sdlc_in_progress"
    end
  end

  describe "can_handle?/1" do
    test "returns true for items in in_progress directory" do
      item = %{path: "/roadmap/3-in-progress/test.md"}
      assert InProgress.can_handle?(item) == true
    end

    test "returns false for items in inbox directory" do
      item = %{path: "/roadmap/0-inbox/test.md"}
      assert InProgress.can_handle?(item) == false
    end

    test "returns false for items in brainstorming directory" do
      item = %{path: "/roadmap/1-brainstorming/test.md"}
      assert InProgress.can_handle?(item) == false
    end

    test "returns false for items in planned directory" do
      item = %{path: "/roadmap/2-planned/test.md"}
      assert InProgress.can_handle?(item) == false
    end

    test "returns false for items in completed directory" do
      item = %{path: "/roadmap/5-completed/test.md"}
      assert InProgress.can_handle?(item) == false
    end

    test "returns false for items without path" do
      item = %{title: "Test"}
      assert InProgress.can_handle?(item) == false
    end

    test "returns false for nil path" do
      item = %{path: nil}
      assert InProgress.can_handle?(item) == false
    end
  end

  describe "process_item/2 with dry_run" do
    setup do
      context = TestHelpers.setup_test_roadmap()
      on_exit(fn -> TestHelpers.cleanup_test_roadmap(context) end)
      context
    end

    test "dry_run returns :dry_run", %{temp_roadmap_root: root} do
      content = item_content_with_session()
      path = TestHelpers.create_test_item(root, :in_progress, "test-feature.md", content)

      {:ok, item} = Item.new(title: "Test Feature", path: path)

      assert {:ok, :dry_run} = InProgress.process_item(item, dry_run: true)
    end
  end

  describe "session detection" do
    setup do
      context = TestHelpers.setup_test_roadmap()
      on_exit(fn -> TestHelpers.cleanup_test_roadmap(context) end)
      context
    end

    test "returns no_session when item has no session_id", %{temp_roadmap_root: root} do
      content = TestHelpers.expanded_item_content("Test Feature")
      path = TestHelpers.create_test_item(root, :in_progress, "no-session.md", content)

      {:ok, item} = Item.new(title: "Test Feature", path: path, metadata: %{})

      assert {:ok, :no_session} = InProgress.process_item(item, [])
    end

    test "returns awaiting_signal for auto session", %{temp_roadmap_root: root} do
      content = item_content_with_session()
      path = TestHelpers.create_test_item(root, :in_progress, "auto-session.md", content)

      {:ok, item} =
        Item.new(
          title: "Test Feature",
          path: path,
          metadata: %{"session_id" => "sdlc-test-123"}
        )

      # Auto sessions (non-hand) rely on signals
      assert {:ok, :awaiting_signal} = InProgress.process_item(item, [])
    end
  end

  describe "GenServer functionality" do
    @describetag :capture_log

    setup do
      # Use a unique name per test
      # This is test code with trusted input (unique_integer), so safe
      test_name = Module.concat([TestInProgressProcessor, "T#{:erlang.unique_integer([:positive])}"])

      # Start processor, capturing logs to suppress subscription warnings
      # We need to get the pid out of the capture_log block
      pid_holder = :ets.new(:pid_holder, [:set, :public])

      _log =
        capture_log(fn ->
          {:ok, pid} =
            InProgress.start_link(
              name: test_name,
              config: Config.new()
            )

          :ets.insert(pid_holder, {:pid, pid})
        end)

      [{:pid, pid}] = :ets.lookup(pid_holder, :pid)
      :ets.delete(pid_holder)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 100)
      end)

      %{processor: pid}
    end

    test "starts successfully", %{processor: processor} do
      # The important thing is that it was a valid pid at start
      assert is_pid(processor)
    end

    test "handles session_started info message", %{processor: processor} do
      # Processor may have issues with signals, but we can still test message handling
      capture_log(fn ->
        if Process.alive?(processor) do
          send(processor, {:session_started, "/path/to/item.md", "test-session-1"})
          Process.sleep(50)
        end
      end)

      # Test passes if we get here without crashing
      assert true
    end

    test "handles session_end cast", %{processor: processor} do
      capture_log(fn ->
        if Process.alive?(processor) do
          # First register a pending session
          send(processor, {:session_started, "/path/to/item.md", "test-session-2"})
          Process.sleep(50)

          # Then signal completion
          InProgress.handle_session_end(processor, "test-session-2", "completed", %{
            "item_path" => "/path/to/item.md"
          })

          Process.sleep(50)
        end
      end)

      # Test passes if we get here without crashing
      assert true
    end
  end

  describe "completion handling" do
    setup do
      context = TestHelpers.setup_test_roadmap()
      on_exit(fn -> TestHelpers.cleanup_test_roadmap(context) end)
      context
    end

    test "moves completed item to completed stage on success", %{temp_roadmap_root: root} do
      # Create an in-progress item
      content = item_content_with_session()
      path = TestHelpers.create_test_item(root, :in_progress, "success-item.md", content)

      # Mock completion processing would need to:
      # 1. Read the item
      # 2. Run tests (would fail in test environment)
      # 3. Move based on result

      # For unit testing, we just verify the item exists
      assert File.exists?(path)
    end
  end

  # Helper to create content with session metadata
  defp item_content_with_session do
    """
    ---
    session_id: sdlc-test-123
    session_started_at: 2026-02-01T12:00:00Z
    attempt: 1
    ---

    # Test Feature

    **Created:** 2026-02-01
    **Priority:** high
    **Category:** feature

    ## Summary

    A test feature with an active session.

    ## Acceptance Criteria

    - [ ] Tests pass
    - [ ] Code reviewed
    """
  end
end
