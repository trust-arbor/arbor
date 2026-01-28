defmodule Arbor.Checkpoint.RetryTest do
  use ExUnit.Case, async: false

  alias Arbor.Checkpoint
  alias Arbor.Checkpoint.Test.{DelayedStorage, FailingStorage}

  import Arbor.Checkpoint.TestHelpers, only: [safe_stop: 1]

  @moduletag :fast

  describe "load with retry - eventually consistent storage" do
    setup do
      # Storage that fails 2 times before succeeding
      {:ok, _pid} = DelayedStorage.start_link(failures: 2)
      on_exit(fn -> safe_stop(DelayedStorage) end)
      :ok
    end

    test "succeeds after retries for eventually consistent storage" do
      # Save directly - this always works
      checkpoint = %{data: %{counter: 42}, timestamp: 123, node: node(), version: "1.0.0"}
      :ok = DelayedStorage.put("test_id", checkpoint)

      # Load should fail twice then succeed on third attempt
      assert {:ok, %{counter: 42}} = Checkpoint.load("test_id", DelayedStorage,
        retries: 5,
        retry_delay: 1
      )

      # Verify 3 attempts were made (2 failures + 1 success)
      assert DelayedStorage.get_attempt_count("test_id") == 3
    end

    test "fails if retries exhausted before storage becomes consistent" do
      checkpoint = %{data: %{counter: 42}, timestamp: 123, node: node(), version: "1.0.0"}
      :ok = DelayedStorage.put("test_id", checkpoint)

      # Only 1 retry (2 total attempts) - not enough for storage that needs 3
      assert {:error, :not_found} = Checkpoint.load("test_id", DelayedStorage,
        retries: 1,
        retry_delay: 1
      )
    end
  end

  describe "load with retry - failing storage" do
    test "returns error immediately for non-retryable failures" do
      # FailingStorage returns :storage_unavailable, not :not_found
      # This should NOT trigger retries
      assert {:error, :storage_unavailable} = Checkpoint.load("test_id", FailingStorage,
        retries: 5,
        retry_delay: 1
      )
    end
  end

  describe "save with failing storage" do
    test "returns error from storage backend" do
      assert {:error, :storage_unavailable} = Checkpoint.save("test_id", %{}, FailingStorage)
    end
  end

  describe "remove with failing storage" do
    test "returns error from storage backend" do
      assert {:error, :storage_unavailable} = Checkpoint.remove("test_id", FailingStorage)
    end
  end

  describe "list with failing storage" do
    test "returns error from storage backend" do
      assert {:error, :storage_unavailable} = Checkpoint.list(FailingStorage)
    end
  end

  describe "get_info with failing storage" do
    test "returns error from storage backend" do
      assert {:error, :storage_unavailable} = Checkpoint.get_info("test_id", FailingStorage)
    end
  end
end
