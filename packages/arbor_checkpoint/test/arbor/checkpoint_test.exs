defmodule Arbor.CheckpointTest do
  use ExUnit.Case, async: false

  alias Arbor.Checkpoint
  alias Arbor.Checkpoint.Storage.Agent, as: AgentStorage
  alias Arbor.Checkpoint.Test.{StatefulModule, NoCheckpointModule, FailingRestoreModule}

  @moduletag :fast

  setup do
    {:ok, pid} = AgentStorage.start_link()
    on_exit(fn -> if Process.alive?(pid), do: AgentStorage.stop() end)
    :ok
  end

  describe "save/4" do
    test "saves checkpoint with default options" do
      state = %{counter: 42, data: "test"}

      assert :ok = Checkpoint.save("test_id", state, AgentStorage)
      assert AgentStorage.count() == 1
    end

    test "saves checkpoint with custom version" do
      state = %{counter: 42}

      assert :ok = Checkpoint.save("test_id", state, AgentStorage, version: "2.0.0")

      {:ok, info} = Checkpoint.get_info("test_id", AgentStorage)
      assert info.version == "2.0.0"
    end

    test "saves checkpoint with additional metadata" do
      state = %{counter: 42}
      metadata = %{source: "test", reason: "manual"}

      assert :ok = Checkpoint.save("test_id", state, AgentStorage, metadata: metadata)

      {:ok, info} = Checkpoint.get_info("test_id", AgentStorage)
      assert info.metadata == metadata
    end

    test "saves checkpoint using module's extract_checkpoint_data" do
      state = %{counter: 42, important_data: "keep", transient_data: "discard"}

      assert :ok = Checkpoint.save("test_id", state, AgentStorage, module: StatefulModule)

      {:ok, data} = Checkpoint.load("test_id", AgentStorage)
      assert data.counter == 42
      assert data.important_data == "keep"
      refute Map.has_key?(data, :transient_data)
    end

    test "includes timestamp and node in checkpoint" do
      state = %{counter: 42}
      before_save = System.system_time(:millisecond)

      assert :ok = Checkpoint.save("test_id", state, AgentStorage)

      {:ok, info} = Checkpoint.get_info("test_id", AgentStorage)
      assert info.timestamp >= before_save
      assert info.node == node()
    end

    test "overwrites existing checkpoint" do
      assert :ok = Checkpoint.save("test_id", %{version: 1}, AgentStorage)
      assert :ok = Checkpoint.save("test_id", %{version: 2}, AgentStorage)

      {:ok, data} = Checkpoint.load("test_id", AgentStorage)
      assert data.version == 2
      assert AgentStorage.count() == 1
    end
  end

  describe "load/3" do
    test "loads existing checkpoint" do
      state = %{counter: 42, data: "test"}
      :ok = Checkpoint.save("test_id", state, AgentStorage)

      assert {:ok, loaded} = Checkpoint.load("test_id", AgentStorage)
      assert loaded == state
    end

    test "returns error for non-existent checkpoint" do
      assert {:error, :not_found} = Checkpoint.load("nonexistent", AgentStorage, retries: 0)
    end

    test "returns full checkpoint with include_metadata option" do
      state = %{counter: 42}
      :ok = Checkpoint.save("test_id", state, AgentStorage)

      assert {:ok, checkpoint} = Checkpoint.load("test_id", AgentStorage, include_metadata: true)
      assert checkpoint.data == state
      assert is_integer(checkpoint.timestamp)
      assert checkpoint.node == node()
      assert checkpoint.version == "1.0.0"
    end

    test "retries with exponential backoff" do
      # This test verifies retry behavior by checking load eventually returns :not_found
      # after exhausting retries for a non-existent key
      start_time = System.monotonic_time(:millisecond)

      result = Checkpoint.load("nonexistent", AgentStorage, retries: 2, retry_delay: 10)

      elapsed = System.monotonic_time(:millisecond) - start_time
      # With exponential backoff: 10ms + 20ms = 30ms minimum
      assert elapsed >= 25
      assert result == {:error, :not_found}
    end

    test "retries with linear backoff" do
      start_time = System.monotonic_time(:millisecond)

      result = Checkpoint.load("nonexistent", AgentStorage,
        retries: 2,
        retry_delay: 10,
        retry_backoff: :linear
      )

      elapsed = System.monotonic_time(:millisecond) - start_time
      # With linear backoff: 10ms + 10ms = 20ms minimum
      assert elapsed >= 15
      assert result == {:error, :not_found}
    end
  end

  describe "get_info/2" do
    test "returns checkpoint metadata" do
      state = %{counter: 42}
      :ok = Checkpoint.save("test_id", state, AgentStorage, version: "1.5.0")

      assert {:ok, info} = Checkpoint.get_info("test_id", AgentStorage)
      assert info.version == "1.5.0"
      assert info.node == node()
      assert is_integer(info.timestamp)
      assert is_integer(info.age_ms)
      assert info.age_ms >= 0
    end

    test "returns error for non-existent checkpoint" do
      assert {:error, :not_found} = Checkpoint.get_info("nonexistent", AgentStorage)
    end
  end

  describe "remove/2" do
    test "removes existing checkpoint" do
      :ok = Checkpoint.save("test_id", %{data: "test"}, AgentStorage)
      assert AgentStorage.count() == 1

      assert :ok = Checkpoint.remove("test_id", AgentStorage)
      assert AgentStorage.count() == 0
    end

    test "succeeds for non-existent checkpoint" do
      assert :ok = Checkpoint.remove("nonexistent", AgentStorage)
    end
  end

  describe "list/1" do
    test "returns empty list when no checkpoints" do
      assert {:ok, []} = Checkpoint.list(AgentStorage)
    end

    test "returns all checkpoint IDs" do
      :ok = Checkpoint.save("id_1", %{}, AgentStorage)
      :ok = Checkpoint.save("id_2", %{}, AgentStorage)
      :ok = Checkpoint.save("id_3", %{}, AgentStorage)

      assert {:ok, ids} = Checkpoint.list(AgentStorage)
      assert length(ids) == 3
      assert Enum.sort(ids) == ["id_1", "id_2", "id_3"]
    end
  end

  describe "enable_auto_save/2" do
    test "schedules checkpoint message" do
      assert :ok = Checkpoint.enable_auto_save(self(), 10)
      assert_receive :checkpoint, 100
    end

    test "sends message after specified interval" do
      start_time = System.monotonic_time(:millisecond)
      :ok = Checkpoint.enable_auto_save(self(), 50)

      assert_receive :checkpoint, 200
      elapsed = System.monotonic_time(:millisecond) - start_time
      assert elapsed >= 45
    end
  end

  describe "attempt_recovery/5" do
    test "recovers state using module's restore_from_checkpoint" do
      # Save a checkpoint
      checkpoint_data = %{counter: 100, important_data: "recovered"}
      :ok = Checkpoint.save("agent_1", checkpoint_data, AgentStorage)

      # Attempt recovery
      initial_args = %{counter: 0, important_data: "", transient: "new"}

      assert {:ok, recovered} = Checkpoint.attempt_recovery(
        StatefulModule,
        "agent_1",
        initial_args,
        AgentStorage
      )

      assert recovered.counter == 100
      assert recovered.important_data == "recovered"
      assert is_integer(recovered.restored_at)
    end

    test "returns error when module doesn't implement behaviour" do
      assert {:error, :not_implemented} = Checkpoint.attempt_recovery(
        NoCheckpointModule,
        "agent_1",
        %{},
        AgentStorage
      )
    end

    test "returns error when no checkpoint exists" do
      assert {:error, :no_checkpoint} = Checkpoint.attempt_recovery(
        StatefulModule,
        "nonexistent",
        %{},
        AgentStorage,
        retries: 0
      )
    end

    test "returns error when restore raises" do
      checkpoint_data = %{counter: 100}
      :ok = Checkpoint.save("agent_1", checkpoint_data, AgentStorage)

      assert {:error, %RuntimeError{message: "Restore failed!"}} = Checkpoint.attempt_recovery(
        FailingRestoreModule,
        "agent_1",
        %{},
        AgentStorage
      )
    end

    test "handles keyword list initial_args" do
      checkpoint_data = %{counter: 50, important_data: "test"}
      :ok = Checkpoint.save("agent_1", checkpoint_data, AgentStorage)

      assert {:ok, recovered} = Checkpoint.attempt_recovery(
        StatefulModule,
        "agent_1",
        [counter: 0, important_data: ""],
        AgentStorage
      )

      assert recovered.counter == 50
    end
  end

  describe "implements_behaviour?/1" do
    test "returns true for implementing module" do
      assert Checkpoint.implements_behaviour?(StatefulModule)
    end

    test "returns false for non-implementing module" do
      refute Checkpoint.implements_behaviour?(NoCheckpointModule)
    end

    test "returns false for partial implementation" do
      defmodule PartialImpl do
        def extract_checkpoint_data(state), do: state
        # Missing restore_from_checkpoint
      end

      refute Checkpoint.implements_behaviour?(PartialImpl)
    end
  end
end
