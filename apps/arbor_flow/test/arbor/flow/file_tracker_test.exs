defmodule Arbor.Flow.FileTrackerTest do
  use ExUnit.Case, async: true

  alias Arbor.Flow.FileTracker.ETS

  @moduletag :fast

  setup do
    # Start a unique tracker for each test
    tracker_name = :"tracker_#{:rand.uniform(100_000)}"
    {:ok, _pid} = ETS.start_link(name: tracker_name)

    {:ok, tracker: tracker_name}
  end

  describe "mark_processed/4" do
    test "marks a file as processed", %{tracker: tracker} do
      assert :ok = ETS.mark_processed(tracker, "/path/to/file.md", "processor_1", "hash123")
    end

    test "can mark same file for different processors", %{tracker: tracker} do
      assert :ok = ETS.mark_processed(tracker, "/path/to/file.md", "processor_1", "hash123")
      assert :ok = ETS.mark_processed(tracker, "/path/to/file.md", "processor_2", "hash456")
    end

    test "updates existing record", %{tracker: tracker} do
      :ok = ETS.mark_processed(tracker, "/path/to/file.md", "processor_1", "hash123")
      :ok = ETS.mark_processed(tracker, "/path/to/file.md", "processor_1", "hash456")

      {:ok, record} = ETS.get_record(tracker, "/path/to/file.md", "processor_1")
      assert record.content_hash == "hash456"
    end
  end

  describe "mark_failed/4" do
    test "marks a file as failed", %{tracker: tracker} do
      assert :ok = ETS.mark_failed(tracker, "/path/to/file.md", "processor_1", "some error")

      {:ok, record} = ETS.get_record(tracker, "/path/to/file.md", "processor_1")
      assert record.status == :failed
      assert record.metadata.error == "some error"
    end
  end

  describe "mark_skipped/4" do
    test "marks a file as skipped", %{tracker: tracker} do
      assert :ok = ETS.mark_skipped(tracker, "/path/to/file.md", "processor_1", "not applicable")

      {:ok, record} = ETS.get_record(tracker, "/path/to/file.md", "processor_1")
      assert record.status == :skipped
      assert record.metadata.reason == "not applicable"
    end
  end

  describe "needs_processing?/4" do
    test "returns true for unknown file", %{tracker: tracker} do
      assert ETS.needs_processing?(tracker, "/new/file.md", "processor_1", "hash123")
    end

    test "returns true for failed file", %{tracker: tracker} do
      :ok = ETS.mark_failed(tracker, "/path/to/file.md", "processor_1", "error")
      assert ETS.needs_processing?(tracker, "/path/to/file.md", "processor_1", "hash123")
    end

    test "returns true when hash changed", %{tracker: tracker} do
      :ok = ETS.mark_processed(tracker, "/path/to/file.md", "processor_1", "hash123")
      assert ETS.needs_processing?(tracker, "/path/to/file.md", "processor_1", "hash456")
    end

    test "returns false when hash unchanged", %{tracker: tracker} do
      :ok = ETS.mark_processed(tracker, "/path/to/file.md", "processor_1", "hash123")
      refute ETS.needs_processing?(tracker, "/path/to/file.md", "processor_1", "hash123")
    end

    test "returns false for skipped file with same hash", %{tracker: tracker} do
      :ok = ETS.mark_skipped(tracker, "/path/to/file.md", "processor_1", "reason")
      refute ETS.needs_processing?(tracker, "/path/to/file.md", "processor_1", "anything")
    end
  end

  describe "get_record/3" do
    test "returns record when exists", %{tracker: tracker} do
      :ok = ETS.mark_processed(tracker, "/path/to/file.md", "processor_1", "hash123")

      assert {:ok, record} = ETS.get_record(tracker, "/path/to/file.md", "processor_1")
      assert record.path == "/path/to/file.md"
      assert record.processor == "processor_1"
      assert record.status == :processed
      assert record.content_hash == "hash123"
      assert %DateTime{} = record.processed_at
    end

    test "returns error when not found", %{tracker: tracker} do
      assert {:error, :not_found} = ETS.get_record(tracker, "/unknown.md", "processor_1")
    end
  end

  describe "remove/3" do
    test "removes a record", %{tracker: tracker} do
      :ok = ETS.mark_processed(tracker, "/path/to/file.md", "processor_1", "hash123")
      assert {:ok, _} = ETS.get_record(tracker, "/path/to/file.md", "processor_1")

      :ok = ETS.remove(tracker, "/path/to/file.md", "processor_1")
      assert {:error, :not_found} = ETS.get_record(tracker, "/path/to/file.md", "processor_1")
    end

    test "succeeds even if record doesn't exist", %{tracker: tracker} do
      assert :ok = ETS.remove(tracker, "/nonexistent.md", "processor_1")
    end

    test "only removes specific processor's record", %{tracker: tracker} do
      :ok = ETS.mark_processed(tracker, "/path/to/file.md", "processor_1", "hash123")
      :ok = ETS.mark_processed(tracker, "/path/to/file.md", "processor_2", "hash456")

      :ok = ETS.remove(tracker, "/path/to/file.md", "processor_1")

      assert {:error, :not_found} = ETS.get_record(tracker, "/path/to/file.md", "processor_1")
      assert {:ok, _} = ETS.get_record(tracker, "/path/to/file.md", "processor_2")
    end
  end

  describe "load_known_files/2" do
    test "returns empty set for unknown processor", %{tracker: tracker} do
      result = ETS.load_known_files(tracker, "unknown_processor")
      assert MapSet.size(result) == 0
    end

    test "returns paths of processed files", %{tracker: tracker} do
      :ok = ETS.mark_processed(tracker, "/path/one.md", "processor_1", "hash1")
      :ok = ETS.mark_processed(tracker, "/path/two.md", "processor_1", "hash2")

      result = ETS.load_known_files(tracker, "processor_1")
      assert MapSet.size(result) == 2
      assert "/path/one.md" in result
      assert "/path/two.md" in result
    end

    test "includes skipped files", %{tracker: tracker} do
      :ok = ETS.mark_processed(tracker, "/path/one.md", "processor_1", "hash1")
      :ok = ETS.mark_skipped(tracker, "/path/two.md", "processor_1", "reason")

      result = ETS.load_known_files(tracker, "processor_1")
      assert MapSet.size(result) == 2
    end

    test "excludes failed files", %{tracker: tracker} do
      :ok = ETS.mark_processed(tracker, "/path/one.md", "processor_1", "hash1")
      :ok = ETS.mark_failed(tracker, "/path/two.md", "processor_1", "error")

      result = ETS.load_known_files(tracker, "processor_1")
      assert MapSet.size(result) == 1
      assert "/path/one.md" in result
      refute "/path/two.md" in result
    end

    test "only returns files for specified processor", %{tracker: tracker} do
      :ok = ETS.mark_processed(tracker, "/path/one.md", "processor_1", "hash1")
      :ok = ETS.mark_processed(tracker, "/path/two.md", "processor_2", "hash2")

      result = ETS.load_known_files(tracker, "processor_1")
      assert MapSet.size(result) == 1
      assert "/path/one.md" in result
    end
  end

  describe "stats/2" do
    test "returns zero stats for unknown processor", %{tracker: tracker} do
      stats = ETS.stats(tracker, "unknown")
      assert stats.total == 0
      assert stats.by_status == %{}
    end

    test "counts files by status", %{tracker: tracker} do
      :ok = ETS.mark_processed(tracker, "/path/one.md", "processor_1", "hash1")
      :ok = ETS.mark_processed(tracker, "/path/two.md", "processor_1", "hash2")
      :ok = ETS.mark_failed(tracker, "/path/three.md", "processor_1", "error")
      :ok = ETS.mark_skipped(tracker, "/path/four.md", "processor_1", "reason")

      stats = ETS.stats(tracker, "processor_1")
      assert stats.total == 4
      assert stats.by_status[:processed] == 2
      assert stats.by_status[:failed] == 1
      assert stats.by_status[:skipped] == 1
    end
  end

  describe "processor name normalization" do
    test "handles atom processor names", %{tracker: tracker} do
      :ok = ETS.mark_processed(tracker, "/path/file.md", MyProcessor, "hash123")
      assert {:ok, record} = ETS.get_record(tracker, "/path/file.md", MyProcessor)
      assert record.processor == "MyProcessor"
    end

    test "handles module atom processor names", %{tracker: tracker} do
      :ok = ETS.mark_processed(tracker, "/path/file.md", Arbor.Flow.FileTrackerTest, "hash123")

      assert {:ok, record} =
               ETS.get_record(tracker, "/path/file.md", Arbor.Flow.FileTrackerTest)

      assert record.processor == "Arbor.Flow.FileTrackerTest"
    end

    test "handles string processor names", %{tracker: tracker} do
      :ok = ETS.mark_processed(tracker, "/path/file.md", "my_processor", "hash123")
      assert {:ok, record} = ETS.get_record(tracker, "/path/file.md", "my_processor")
      assert record.processor == "my_processor"
    end
  end
end
