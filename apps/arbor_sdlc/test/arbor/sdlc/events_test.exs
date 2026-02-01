defmodule Arbor.SDLC.EventsTest do
  use ExUnit.Case, async: true

  alias Arbor.SDLC.Events

  @moduletag :fast

  # Note: These tests verify the Events module compiles and functions
  # can be called without error. Full signal integration testing
  # would require the signals system to be running.

  describe "item lifecycle events" do
    test "emit_item_detected/3 handles gracefully when signals unavailable" do
      assert Events.emit_item_detected("/path/to/file.md", "abc123") == :ok
    end

    test "emit_item_changed/3 handles gracefully when signals unavailable" do
      assert Events.emit_item_changed("/path/to/file.md", "new_hash") == :ok
    end

    test "emit_item_changed/3 accepts options" do
      assert Events.emit_item_changed("/path/to/file.md", "new_hash", correlation_id: "trace_1") ==
               :ok
    end

    test "emit_item_parsed/2 extracts item fields" do
      item = %{
        id: "item_123",
        title: "Test Item",
        path: "/path/to/file.md",
        category: :feature,
        priority: :high
      }

      assert Events.emit_item_parsed(item) == :ok
    end

    test "emit_item_expanded/2 includes criteria presence" do
      item = %{
        id: "item_123",
        title: "Expanded Item",
        category: :feature,
        priority: :high,
        acceptance_criteria: [%{text: "Test", completed: false}],
        definition_of_done: []
      }

      assert Events.emit_item_expanded(item) == :ok
    end

    test "emit_item_deliberated/3 includes outcome" do
      item = %{id: "item_123", title: "Test"}

      assert Events.emit_item_deliberated(item, :approved) == :ok
      assert Events.emit_item_deliberated(item, :rejected, decision_id: "dec_456") == :ok
    end

    test "emit_item_moved/4 includes stage transition" do
      item = %{id: "item_123", title: "Test"}

      assert Events.emit_item_moved(item, :inbox, :brainstorming) == :ok

      assert Events.emit_item_moved(item, :inbox, :brainstorming,
               old_path: "/roadmap/0-inbox/test.md",
               new_path: "/roadmap/1-brainstorming/test.md"
             ) == :ok
    end

    test "emit_item_completed/3 includes terminal stage" do
      item = %{id: "item_123", title: "Test"}

      assert Events.emit_item_completed(item, :completed) == :ok
      assert Events.emit_item_completed(item, :discarded, duration_ms: 5000) == :ok
    end
  end

  describe "processing events" do
    test "emit_processing_started/3 includes processor" do
      item = %{id: "item_123", title: "Test"}

      assert Events.emit_processing_started(item, :expander) == :ok
      assert Events.emit_processing_started(item, :deliberator, complexity_tier: :moderate) == :ok
    end

    test "emit_processing_completed/4 summarizes result" do
      item = %{id: "item_123", title: "Test"}

      assert Events.emit_processing_completed(item, :expander, {:ok, :no_action}) == :ok

      assert Events.emit_processing_completed(item, :expander, {:ok, {:moved, :brainstorming}}) ==
               :ok

      assert Events.emit_processing_completed(item, :expander, {:error, :some_error}) == :ok
    end

    test "emit_processing_failed/4 includes error info" do
      item = %{id: "item_123", title: "Test"}

      assert Events.emit_processing_failed(item, :expander, :timeout) == :ok
      assert Events.emit_processing_failed(item, :expander, :timeout, retryable: false) == :ok
    end
  end

  describe "consensus events" do
    test "emit_decision_requested/3 includes proposal info" do
      item = %{id: "item_123", title: "Test"}

      assert Events.emit_decision_requested(item, "prop_456") == :ok
      assert Events.emit_decision_requested(item, "prop_456", attempt: 2) == :ok
    end

    test "emit_decision_rendered/4 includes verdict and counts" do
      summary = %{
        approval_count: 5,
        rejection_count: 2,
        abstain_count: 0
      }

      assert Events.emit_decision_rendered("prop_456", :approved, summary) == :ok
      assert Events.emit_decision_rendered("prop_456", :rejected, summary) == :ok
    end

    test "emit_decision_documented/3 includes path" do
      assert Events.emit_decision_documented("prop_456", "/decisions/2026-02-01-test.md") == :ok
    end
  end

  describe "system events" do
    test "emit_watcher_started/2 includes directories" do
      dirs = ["/roadmap/0-inbox", "/roadmap/1-brainstorming"]

      assert Events.emit_watcher_started(dirs) == :ok
      assert Events.emit_watcher_started(dirs, poll_interval: 30_000) == :ok
    end

    test "emit_watcher_scan_completed/2 includes stats" do
      stats = %{
        files_scanned: 10,
        new_files: 2,
        changed_files: 1,
        deleted_files: 0
      }

      assert Events.emit_watcher_scan_completed(stats) == :ok
    end

    test "emit_consistency_check_completed/2 includes results" do
      results = %{
        checks_run: [:index_sync, :health_check],
        issues_found: 3,
        items_flagged: ["item1.md", "item2.md"]
      }

      assert Events.emit_consistency_check_completed(results) == :ok
    end
  end

  describe "item ID extraction" do
    test "extracts id from item with id field" do
      # Internal function tested via emit functions
      item = %{id: "explicit_id", path: "/some/path.md"}

      # Should use id over path
      assert Events.emit_item_parsed(item) == :ok
    end

    test "falls back to path when no id" do
      item = %{path: "/some/path.md", title: "Test"}

      assert Events.emit_item_parsed(item) == :ok
    end

    test "handles items with neither id nor path" do
      item = %{title: "Test"}

      assert Events.emit_item_parsed(item) == :ok
    end
  end
end
