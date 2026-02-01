defmodule Arbor.SDLC.PersistentFileTrackerTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Store.ETS, as: ETSStore
  alias Arbor.SDLC.{Config, PersistentFileTracker}

  @moduletag :fast

  setup do
    # Use a unique reference-based approach to avoid atom creation
    # The store and tracker will use registered name based on test module
    store_name = :test_tracker_store
    tracker_name = :test_file_tracker

    # Clean up any existing processes
    cleanup_process(store_name)
    cleanup_process(tracker_name)

    config = %Config{
      persistence_backend: ETSStore,
      persistence_name: store_name
    }

    # Start the ETS store
    {:ok, _store} = ETSStore.start_link(name: store_name)

    # Start the tracker
    {:ok, tracker} =
      PersistentFileTracker.start_link(
        name: tracker_name,
        config: config
      )

    on_exit(fn ->
      cleanup_process(tracker_name)
      cleanup_process(store_name)
    end)

    %{tracker: tracker, store_name: store_name}
  end

  defp cleanup_process(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        try do
          GenServer.stop(pid, :normal, 100)
        catch
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end
  end

  describe "mark_processed/4" do
    test "marks a file as processed", %{tracker: tracker} do
      assert :ok = PersistentFileTracker.mark_processed(tracker, "/test/file.md", "expander", "hash123")
    end

    test "handles atom and string processors", %{tracker: tracker} do
      assert :ok = PersistentFileTracker.mark_processed(tracker, "/file1.md", :expander, "hash1")
      assert :ok = PersistentFileTracker.mark_processed(tracker, "/file2.md", "expander", "hash2")
    end
  end

  describe "mark_failed/4" do
    test "marks a file as failed", %{tracker: tracker} do
      assert :ok = PersistentFileTracker.mark_failed(tracker, "/test/file.md", "expander", "timeout")
    end
  end

  describe "mark_skipped/4" do
    test "marks a file as skipped", %{tracker: tracker} do
      assert :ok = PersistentFileTracker.mark_skipped(tracker, "/test/file.md", "expander", "invalid format")
    end
  end

  describe "mark_moved/5" do
    test "marks file as moved and creates new record", %{tracker: tracker} do
      old_path = "/inbox/file.md"
      new_path = "/brainstorming/file.md"

      assert :ok = PersistentFileTracker.mark_moved(tracker, old_path, new_path, "expander", "hash123")

      # Old path should be marked as moved
      {:ok, old_record} = PersistentFileTracker.get_record(tracker, old_path, "expander")
      assert old_record.status == :moved
      assert old_record.metadata[:moved_to] == new_path

      # New path should be marked as processed
      {:ok, new_record} = PersistentFileTracker.get_record(tracker, new_path, "expander")
      assert new_record.status == :processed
      assert new_record.metadata[:moved_from] == old_path
    end
  end

  describe "needs_processing?/4" do
    test "returns true for unknown file", %{tracker: tracker} do
      assert PersistentFileTracker.needs_processing?(tracker, "/unknown/file.md", "expander", "hash")
    end

    test "returns false for processed file with same hash", %{tracker: tracker} do
      path = "/test/file.md"
      hash = "same_hash"

      :ok = PersistentFileTracker.mark_processed(tracker, path, "expander", hash)

      refute PersistentFileTracker.needs_processing?(tracker, path, "expander", hash)
    end

    test "returns true for processed file with different hash", %{tracker: tracker} do
      path = "/test/file.md"

      :ok = PersistentFileTracker.mark_processed(tracker, path, "expander", "old_hash")

      assert PersistentFileTracker.needs_processing?(tracker, path, "expander", "new_hash")
    end

    test "returns true for failed file", %{tracker: tracker} do
      path = "/test/file.md"

      :ok = PersistentFileTracker.mark_failed(tracker, path, "expander", "error")

      assert PersistentFileTracker.needs_processing?(tracker, path, "expander", "any_hash")
    end

    test "returns false for skipped file", %{tracker: tracker} do
      path = "/test/file.md"

      :ok = PersistentFileTracker.mark_skipped(tracker, path, "expander", "reason")

      refute PersistentFileTracker.needs_processing?(tracker, path, "expander", "any_hash")
    end

    test "returns false for moved file", %{tracker: tracker} do
      old_path = "/inbox/file.md"
      new_path = "/brainstorming/file.md"

      :ok = PersistentFileTracker.mark_moved(tracker, old_path, new_path, "expander", "hash")

      refute PersistentFileTracker.needs_processing?(tracker, old_path, "expander", "any_hash")
    end
  end

  describe "get_record/3" do
    test "returns record for existing file", %{tracker: tracker} do
      path = "/test/file.md"
      :ok = PersistentFileTracker.mark_processed(tracker, path, "expander", "hash123")

      {:ok, record} = PersistentFileTracker.get_record(tracker, path, "expander")

      assert record.path == path
      assert record.processor == "expander"
      assert record.status == :processed
      assert record.content_hash == "hash123"
    end

    test "returns error for unknown file", %{tracker: tracker} do
      assert {:error, :not_found} =
               PersistentFileTracker.get_record(tracker, "/unknown.md", "expander")
    end
  end

  describe "remove/3" do
    test "removes a record", %{tracker: tracker} do
      path = "/test/file.md"
      :ok = PersistentFileTracker.mark_processed(tracker, path, "expander", "hash")

      assert :ok = PersistentFileTracker.remove(tracker, path, "expander")
      assert {:error, :not_found} = PersistentFileTracker.get_record(tracker, path, "expander")
    end
  end

  describe "load_known_files/2" do
    test "returns empty set when no files tracked", %{tracker: tracker} do
      files = PersistentFileTracker.load_known_files(tracker, "expander")

      assert MapSet.size(files) == 0
    end

    test "returns paths of processed files", %{tracker: tracker} do
      :ok = PersistentFileTracker.mark_processed(tracker, "/file1.md", "expander", "h1")
      :ok = PersistentFileTracker.mark_processed(tracker, "/file2.md", "expander", "h2")

      files = PersistentFileTracker.load_known_files(tracker, "expander")

      assert MapSet.member?(files, "/file1.md")
      assert MapSet.member?(files, "/file2.md")
    end

    test "includes skipped and moved files", %{tracker: tracker} do
      :ok = PersistentFileTracker.mark_processed(tracker, "/processed.md", "expander", "h1")
      :ok = PersistentFileTracker.mark_skipped(tracker, "/skipped.md", "expander", "reason")
      :ok = PersistentFileTracker.mark_moved(tracker, "/old.md", "/new.md", "expander", "h2")

      files = PersistentFileTracker.load_known_files(tracker, "expander")

      assert MapSet.member?(files, "/processed.md")
      assert MapSet.member?(files, "/skipped.md")
      assert MapSet.member?(files, "/old.md")
      assert MapSet.member?(files, "/new.md")
    end

    test "excludes failed files", %{tracker: tracker} do
      :ok = PersistentFileTracker.mark_processed(tracker, "/processed.md", "expander", "h1")
      :ok = PersistentFileTracker.mark_failed(tracker, "/failed.md", "expander", "error")

      files = PersistentFileTracker.load_known_files(tracker, "expander")

      assert MapSet.member?(files, "/processed.md")
      refute MapSet.member?(files, "/failed.md")
    end

    test "separates files by processor", %{tracker: tracker} do
      :ok = PersistentFileTracker.mark_processed(tracker, "/file1.md", "expander", "h1")
      :ok = PersistentFileTracker.mark_processed(tracker, "/file2.md", "deliberator", "h2")

      expander_files = PersistentFileTracker.load_known_files(tracker, "expander")
      deliberator_files = PersistentFileTracker.load_known_files(tracker, "deliberator")

      assert MapSet.member?(expander_files, "/file1.md")
      refute MapSet.member?(expander_files, "/file2.md")

      assert MapSet.member?(deliberator_files, "/file2.md")
      refute MapSet.member?(deliberator_files, "/file1.md")
    end
  end

  describe "stats/2" do
    test "returns stats for processor", %{tracker: tracker} do
      :ok = PersistentFileTracker.mark_processed(tracker, "/file1.md", "expander", "h1")
      :ok = PersistentFileTracker.mark_processed(tracker, "/file2.md", "expander", "h2")
      :ok = PersistentFileTracker.mark_failed(tracker, "/file3.md", "expander", "error")
      :ok = PersistentFileTracker.mark_skipped(tracker, "/file4.md", "expander", "reason")

      stats = PersistentFileTracker.stats(tracker, "expander")

      assert stats.total == 4
      assert stats.by_status[:processed] == 2
      assert stats.by_status[:failed] == 1
      assert stats.by_status[:skipped] == 1
    end

    test "returns zero stats for unknown processor", %{tracker: tracker} do
      stats = PersistentFileTracker.stats(tracker, "unknown")

      assert stats.total == 0
      assert stats.by_status == %{}
    end
  end
end
