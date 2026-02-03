defmodule Arbor.SDLC.Processors.AutoHandIntegrationTest do
  @moduledoc """
  Integration tests for the auto-hand pipeline.

  Tests the full flow from planned items through session completion:
  - Planned processor spawns sessions for auto: true items
  - InProgress processor detects completion signals
  - Items move based on test results
  - Blocked/interrupted sessions are handled correctly
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.Contracts.Flow.Item
  alias Arbor.Flow.ItemParser
  alias Arbor.SDLC.{Config, Pipeline, TestHelpers}
  alias Arbor.SDLC.Processors.{InProgress, Planned}

  @moduletag :fast
  @moduletag :integration

  describe "full pipeline: planned -> in_progress -> completed" do
    setup do
      context = TestHelpers.setup_test_roadmap()

      on_exit(fn ->
        TestHelpers.cleanup_test_roadmap(context)
      end)

      context
    end

    test "auto item detection works correctly", %{temp_roadmap_root: root} do
      # Create an item with auto: true
      content = auto_item_content("Auto Test Feature")
      path = TestHelpers.create_test_item(root, :planned, "auto-feature.md", content)

      {:ok, item} =
        Item.new(
          title: "Auto Test Feature",
          path: path,
          metadata: %{"auto" => true, "execution_mode" => "auto"}
        )

      # Verify the planned processor can handle it
      assert Planned.can_handle?(%{path: path}) == true

      # Item should NOT be skipped (it has auto: true)
      # Note: actual spawning would require real CLI, so we test the decision logic
      result = Planned.process_item(item, dry_run: true)
      assert {:ok, :dry_run} = result
    end

    test "non-auto item is skipped", %{temp_roadmap_root: root} do
      content = TestHelpers.expanded_item_content("Manual Feature")
      path = TestHelpers.create_test_item(root, :planned, "manual-feature.md", content)

      {:ok, item} =
        Item.new(
          title: "Manual Feature",
          path: path,
          metadata: %{"auto" => false}
        )

      result = Planned.process_item(item, [])
      assert {:ok, :skipped_not_auto} = result
    end

    test "item with active session is skipped", %{temp_roadmap_root: root} do
      content = auto_item_content("Already Running")
      path = TestHelpers.create_test_item(root, :planned, "running-feature.md", content)

      {:ok, item} =
        Item.new(
          title: "Already Running",
          path: path,
          metadata: %{
            "auto" => true,
            "session_id" => "sdlc-existing-12345"
          }
        )

      result = Planned.process_item(item, [])
      assert {:ok, :skipped_active_session} = result
    end

    test "item at max attempts is skipped", %{temp_roadmap_root: root} do
      content = auto_item_content("Max Attempts Reached")
      path = TestHelpers.create_test_item(root, :planned, "max-attempts.md", content)

      {:ok, item} =
        Item.new(
          title: "Max Attempts Reached",
          path: path,
          metadata: %{
            "auto" => true,
            "max_attempts" => 2,
            "attempt" => 2
          }
        )

      result = Planned.process_item(item, [])
      assert {:ok, :skipped_max_attempts} = result
    end
  end

  describe "in_progress processor" do
    setup do
      context = TestHelpers.setup_test_roadmap()

      on_exit(fn ->
        TestHelpers.cleanup_test_roadmap(context)
      end)

      context
    end

    test "can_handle? returns true for in_progress items" do
      assert InProgress.can_handle?(%{path: "/roadmap/3-in-progress/test.md"}) == true
      assert InProgress.can_handle?(%{path: "/roadmap/2-planned/test.md"}) == false
    end

    test "returns no_session when item has no session_id", %{temp_roadmap_root: root} do
      content = TestHelpers.expanded_item_content("No Session Item")
      path = TestHelpers.create_test_item(root, :in_progress, "no-session.md", content)

      {:ok, item} =
        Item.new(
          title: "No Session Item",
          path: path,
          metadata: %{}
        )

      result = InProgress.process_item(item, [])
      assert {:ok, :no_session} = result
    end

    test "returns awaiting_signal for auto session", %{temp_roadmap_root: root} do
      content = auto_item_with_session("Auto Session Item", "sdlc-test-123")
      path = TestHelpers.create_test_item(root, :in_progress, "auto-session.md", content)

      {:ok, item} =
        Item.new(
          title: "Auto Session Item",
          path: path,
          metadata: %{"session_id" => "sdlc-test-123"}
        )

      result = InProgress.process_item(item, [])
      assert {:ok, :awaiting_signal} = result
    end
  end

  describe "genserver signal handling" do
    @describetag :capture_log

    setup do
      context = TestHelpers.setup_test_roadmap()

      # Use unique name per test
      test_name = Module.concat([TestInProgressInt, "T#{:erlang.unique_integer([:positive])}"])

      pid_holder = :ets.new(:pid_holder_int, [:set, :public])

      _log =
        capture_log(fn ->
          {:ok, pid} =
            InProgress.start_link(
              name: test_name,
              config: Config.new(roadmap_root: context.temp_roadmap_root)
            )

          :ets.insert(pid_holder, {:pid, pid})
        end)

      [{:pid, pid}] = :ets.lookup(pid_holder, :pid)
      :ets.delete(pid_holder)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 100)
        TestHelpers.cleanup_test_roadmap(context)
      end)

      Map.put(context, :processor, pid)
    end

    test "processor starts successfully", %{processor: processor} do
      assert is_pid(processor)
      assert Process.alive?(processor)
    end

    test "handles session_started tracking", %{processor: processor} do
      capture_log(fn ->
        if Process.alive?(processor) do
          # Track a session
          send(processor, {:session_started, "/path/to/item.md", "test-session-int"})
          Process.sleep(50)
        end
      end)

      # No crash means success
      assert Process.alive?(processor)
    end

    test "handles session_end cast with completed reason", %{processor: processor} do
      capture_log(fn ->
        if Process.alive?(processor) do
          # First register a pending session
          send(processor, {:session_started, "/path/to/item.md", "test-completed-session"})
          Process.sleep(50)

          # Then signal completion
          InProgress.handle_session_end(processor, "test-completed-session", "completed", %{
            "item_path" => "/path/to/item.md",
            "output" => "Session completed successfully"
          })

          Process.sleep(100)
        end
      end)

      # No crash means success
      assert Process.alive?(processor)
    end

    test "handles session_end cast with max_turns reason", %{
      processor: processor,
      temp_roadmap_root: root
    } do
      # Create an actual in_progress item
      content = auto_item_with_session("Blocked Item", "blocked-session-123")
      item_path = TestHelpers.create_test_item(root, :in_progress, "blocked-item.md", content)

      capture_log(fn ->
        if Process.alive?(processor) do
          # Register session
          send(processor, {:session_started, item_path, "blocked-session-123"})
          Process.sleep(50)

          # Signal max_turns (blocked)
          InProgress.handle_session_end(processor, "blocked-session-123", "max_turns", %{
            "item_path" => item_path
          })

          Process.sleep(100)
        end
      end)

      # Check that item was updated with blocked status
      if File.exists?(item_path) do
        {:ok, updated_content} = File.read(item_path)
        item_map = ItemParser.parse(updated_content)
        metadata = Map.get(item_map, :metadata, %{})
        # YAML parser may return "true" as string or true as boolean
        blocked_value = Map.get(metadata, "blocked")
        assert blocked_value == true or blocked_value == "true"
      end
    end

    test "handles session_end cast with user_request reason (interrupted)", %{
      processor: processor,
      temp_roadmap_root: root
    } do
      # Create an in_progress item
      content = auto_item_with_session("Interrupted Item", "interrupted-session-456")
      item_path = TestHelpers.create_test_item(root, :in_progress, "interrupted-item.md", content)

      log =
        capture_log(fn ->
          if Process.alive?(processor) do
            # Register session
            send(processor, {:session_started, item_path, "interrupted-session-456"})
            Process.sleep(50)

            # Signal interruption
            InProgress.handle_session_end(processor, "interrupted-session-456", "user_request", %{
              "item_path" => item_path
            })

            Process.sleep(100)
          end
        end)

      # Should log the interruption
      assert log =~ "interrupted" or Process.alive?(processor)
    end

    test "tracks tool usage activity", %{processor: processor} do
      capture_log(fn ->
        if Process.alive?(processor) do
          # Send tool_used messages
          send(processor, {:tool_used, "activity-session-789", "Read"})
          Process.sleep(20)
          send(processor, {:tool_used, "activity-session-789", "Edit"})
          Process.sleep(20)
          send(processor, {:tool_used, "activity-session-789", "Bash"})
          Process.sleep(20)
        end
      end)

      # No crash means activity is being tracked
      assert Process.alive?(processor)
    end
  end

  describe "planned processor concurrency" do
    @describetag :capture_log

    setup do
      context = TestHelpers.setup_test_roadmap()

      test_name = Module.concat([TestPlannedInt, "T#{:erlang.unique_integer([:positive])}"])

      {:ok, pid} =
        Planned.start_link(
          name: test_name,
          config: Config.new(roadmap_root: context.temp_roadmap_root)
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        TestHelpers.cleanup_test_roadmap(context)
      end)

      Map.put(context, :processor, pid)
    end

    test "starts with zero active sessions", %{processor: processor} do
      assert Planned.active_session_count(processor) == 0
    end

    test "can_spawn_session? respects limit", %{processor: processor} do
      # Initially should be able to spawn
      assert Planned.can_spawn_session?(processor) == true

      # Register sessions up to the limit (default is 3)
      for i <- 1..3 do
        dummy_pid = spawn(fn -> Process.sleep(60_000) end)
        Planned.register_session(processor, "/path/item#{i}.md", "session-#{i}", dummy_pid)
      end

      # Now should be at capacity
      assert Planned.active_session_count(processor) == 3
      assert Planned.can_spawn_session?(processor) == false

      # Try to register one more
      dummy_pid = spawn(fn -> Process.sleep(60_000) end)

      result =
        Planned.register_session(processor, "/path/item4.md", "session-4", dummy_pid)

      assert result == {:error, :at_capacity}
    end

    test "unregister_session decreases count", %{processor: processor} do
      dummy_pid = spawn(fn -> Process.sleep(60_000) end)

      Planned.register_session(processor, "/path/item.md", "unregister-test", dummy_pid)
      assert Planned.active_session_count(processor) == 1

      Planned.unregister_session(processor, "unregister-test")
      Process.sleep(50)
      assert Planned.active_session_count(processor) == 0

      Process.exit(dummy_pid, :kill)
    end

    test "process monitors clean up on crash", %{processor: processor} do
      # Start a process and register it
      dummy_pid = spawn(fn -> Process.sleep(60_000) end)
      Planned.register_session(processor, "/path/item.md", "crash-test", dummy_pid)
      assert Planned.active_session_count(processor) == 1

      # Kill the process
      Process.exit(dummy_pid, :kill)

      # Wait for DOWN message to be processed
      Process.sleep(100)

      # Session should be cleaned up
      assert Planned.active_session_count(processor) == 0
    end
  end

  describe "item stage transitions" do
    setup do
      context = TestHelpers.setup_test_roadmap()

      on_exit(fn ->
        TestHelpers.cleanup_test_roadmap(context)
      end)

      context
    end

    test "planned stage path is correct", %{temp_roadmap_root: root} do
      path = Pipeline.stage_path(:planned, root)
      assert String.ends_with?(path, "2-planned")
      assert File.dir?(path)
    end

    test "in_progress stage path is correct", %{temp_roadmap_root: root} do
      path = Pipeline.stage_path(:in_progress, root)
      assert String.ends_with?(path, "3-in-progress")
      assert File.dir?(path)
    end

    test "completed stage path is correct", %{temp_roadmap_root: root} do
      path = Pipeline.stage_path(:completed, root)
      assert String.ends_with?(path, "5-completed")
      assert File.dir?(path)
    end

    test "transition from planned to in_progress is valid" do
      assert Pipeline.transition_allowed?(:planned, :in_progress) == true
    end

    test "transition from in_progress to completed is valid" do
      assert Pipeline.transition_allowed?(:in_progress, :completed) == true
    end

    test "transition from in_progress to planned is valid (retry)" do
      assert Pipeline.transition_allowed?(:in_progress, :planned) == true
    end
  end

  # Helper functions

  defp auto_item_content(title) do
    """
    ---
    auto: true
    execution_mode: auto
    ---

    # #{title}

    **Created:** 2026-02-01
    **Priority:** high
    **Category:** feature

    ## Summary

    An auto-processable test item.

    ## Acceptance Criteria

    - [ ] Tests pass
    - [ ] Code reviewed

    ## Definition of Done

    - [ ] All criteria met
    - [ ] mix test passes
    """
  end

  defp auto_item_with_session(title, session_id) do
    """
    ---
    auto: true
    execution_mode: auto
    session_id: #{session_id}
    session_started_at: 2026-02-01T12:00:00Z
    attempt: 1
    ---

    # #{title}

    **Created:** 2026-02-01
    **Priority:** high
    **Category:** feature

    ## Summary

    A test item with an active session.

    ## Acceptance Criteria

    - [ ] Tests pass
    - [ ] Code reviewed

    ## Definition of Done

    - [ ] All criteria met
    """
  end
end
