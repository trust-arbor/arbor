defmodule Arbor.Actions.SessionMemoryTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.SessionMemory

  @moduletag :fast

  # ============================================================================
  # Recall
  # ============================================================================

  describe "Recall — schema" do
    test "action metadata" do
      assert SessionMemory.Recall.name() == "session_memory_recall"
    end

    test "requires agent_id" do
      assert {:error, _} = SessionMemory.Recall.validate_params(%{})
    end

    test "accepts valid params" do
      assert {:ok, _} =
               SessionMemory.Recall.validate_params(%{
                 agent_id: "agent_1",
                 recall_type: "goals"
               })
    end
  end

  describe "Recall — run" do
    test "recall goals returns empty list when facade unavailable" do
      assert {:ok, %{goals: result}} =
               SessionMemory.Recall.run(%{agent_id: "test", recall_type: "goals"}, %{})

      assert is_list(result)
    end

    test "recall intents returns empty list when facade unavailable" do
      assert {:ok, %{active_intents: result}} =
               SessionMemory.Recall.run(%{agent_id: "test", recall_type: "intents"}, %{})

      assert is_list(result)
    end

    test "recall beliefs returns map when facade unavailable" do
      assert {:ok, %{beliefs: result}} =
               SessionMemory.Recall.run(%{agent_id: "test", recall_type: "beliefs"}, %{})

      assert is_map(result)
    end

    test "default recall type returns recalled_memories" do
      assert {:ok, %{recalled_memories: _}} =
               SessionMemory.Recall.run(%{agent_id: "test"}, %{})
    end

    test "raises without agent_id" do
      assert_raise ArgumentError, ~r/agent_id/, fn ->
        SessionMemory.Recall.run(%{}, %{})
      end
    end
  end

  # ============================================================================
  # Update
  # ============================================================================

  describe "Update — schema" do
    test "action metadata" do
      assert SessionMemory.Update.name() == "session_memory_update"
    end

    test "requires agent_id" do
      assert {:error, _} = SessionMemory.Update.validate_params(%{})
    end
  end

  describe "Update — run" do
    test "returns success even when facade unavailable" do
      assert {:ok, %{memory_updated: true}} =
               SessionMemory.Update.run(
                 %{agent_id: "test", turn_data: %{"notes" => ["test"]}},
                 %{}
               )
    end

    test "raises without agent_id" do
      assert_raise ArgumentError, ~r/agent_id/, fn ->
        SessionMemory.Update.run(%{}, %{})
      end
    end
  end

  # ============================================================================
  # Checkpoint
  # ============================================================================

  describe "Checkpoint — schema" do
    test "action metadata" do
      assert SessionMemory.Checkpoint.name() == "session_memory_checkpoint"
    end

    test "requires session_id" do
      assert {:error, _} = SessionMemory.Checkpoint.validate_params(%{})
    end
  end

  describe "Checkpoint — run" do
    test "returns last_checkpoint turn count" do
      assert {:ok, %{last_checkpoint: 5}} =
               SessionMemory.Checkpoint.run(
                 %{session_id: "sess_1", turn_count: 5, snapshot: %{}},
                 %{}
               )
    end

    test "raises without session_id" do
      assert_raise ArgumentError, ~r/session_id/, fn ->
        SessionMemory.Checkpoint.run(%{}, %{})
      end
    end
  end

  # ============================================================================
  # Consolidate
  # ============================================================================

  describe "Consolidate — schema" do
    test "action metadata" do
      assert SessionMemory.Consolidate.name() == "session_memory_consolidate"
    end

    test "requires agent_id" do
      assert {:error, _} = SessionMemory.Consolidate.validate_params(%{})
    end
  end

  describe "Consolidate — run" do
    test "returns consolidated result" do
      assert {:ok, result} = SessionMemory.Consolidate.run(%{agent_id: "test"}, %{})
      assert result.consolidated == true
    end

    test "raises without agent_id" do
      assert_raise ArgumentError, ~r/agent_id/, fn ->
        SessionMemory.Consolidate.run(%{}, %{})
      end
    end
  end

  # ============================================================================
  # UpdateWorkingMemory
  # ============================================================================

  describe "UpdateWorkingMemory — schema" do
    test "action metadata" do
      assert SessionMemory.UpdateWorkingMemory.name() == "session_memory_update_wm"
    end

    test "requires agent_id" do
      assert {:error, _} = SessionMemory.UpdateWorkingMemory.validate_params(%{})
    end
  end

  describe "UpdateWorkingMemory — run" do
    test "returns wm_updated on success" do
      assert {:ok, %{wm_updated: true}} =
               SessionMemory.UpdateWorkingMemory.run(
                 %{agent_id: "test", concerns: ["c1"], curiosity: ["q1"]},
                 %{}
               )
    end

    test "raises without agent_id" do
      assert_raise ArgumentError, ~r/agent_id/, fn ->
        SessionMemory.UpdateWorkingMemory.run(%{}, %{})
      end
    end
  end

  # ============================================================================
  # Bridge helper
  # ============================================================================

  describe "bridge/4" do
    test "returns default for non-existent module" do
      assert :fallback ==
               SessionMemory.bridge(NonExistentModule, :foo, [], :fallback)
    end

    test "returns default for missing function" do
      assert :fallback ==
               SessionMemory.bridge(Kernel, :nonexistent_function, [1, 2, 3], :fallback)
    end

    test "calls real function when available" do
      assert 3 == SessionMemory.bridge(Kernel, :+, [1, 2], nil)
    end
  end
end
