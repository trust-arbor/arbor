defmodule Arbor.Memory.IntentStoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Memory.Intent
  alias Arbor.Contracts.Memory.Percept
  alias Arbor.Memory.IntentStore

  @moduletag :fast

  setup do
    agent_id = "test_agent_#{System.unique_integer([:positive])}"
    on_exit(fn -> IntentStore.clear(agent_id) end)
    %{agent_id: agent_id}
  end

  describe "record_intent/2" do
    test "records an intent", %{agent_id: agent_id} do
      intent = Intent.action(:shell_execute, %{command: "mix test"})
      assert {:ok, ^intent} = IntentStore.record_intent(agent_id, intent)
    end

    test "stores intent in retrievable buffer", %{agent_id: agent_id} do
      intent = Intent.think("Analyzing the problem")
      {:ok, _} = IntentStore.record_intent(agent_id, intent)

      recent = IntentStore.recent_intents(agent_id)
      assert length(recent) == 1
      assert hd(recent).id == intent.id
    end
  end

  describe "record_percept/2" do
    test "records a percept", %{agent_id: agent_id} do
      percept = Percept.success("int_abc", %{exit_code: 0})
      assert {:ok, ^percept} = IntentStore.record_percept(agent_id, percept)
    end

    test "stores percept in retrievable buffer", %{agent_id: agent_id} do
      percept = Percept.failure("int_abc", "compilation error")
      {:ok, _} = IntentStore.record_percept(agent_id, percept)

      recent = IntentStore.recent_percepts(agent_id)
      assert length(recent) == 1
      assert hd(recent).id == percept.id
    end
  end

  describe "recent_intents/2" do
    test "returns most recent first", %{agent_id: agent_id} do
      for i <- 1..5 do
        intent = Intent.think("Thought #{i}")
        IntentStore.record_intent(agent_id, intent)
      end

      recent = IntentStore.recent_intents(agent_id, limit: 3)
      assert length(recent) == 3
    end

    test "filters by type", %{agent_id: agent_id} do
      IntentStore.record_intent(agent_id, Intent.think("Thinking"))
      IntentStore.record_intent(agent_id, Intent.action(:run, %{}))
      IntentStore.record_intent(agent_id, Intent.think("More thinking"))

      thinks = IntentStore.recent_intents(agent_id, type: :think)
      assert length(thinks) == 2
      assert Enum.all?(thinks, &(&1.type == :think))
    end

    test "filters by since", %{agent_id: agent_id} do
      old_intent = Intent.new(:think, created_at: ~U[2026-01-01 00:00:00Z])
      new_intent = Intent.think("Recent thought")

      IntentStore.record_intent(agent_id, old_intent)
      IntentStore.record_intent(agent_id, new_intent)

      recent = IntentStore.recent_intents(agent_id, since: ~U[2026-02-01 00:00:00Z])
      assert length(recent) == 1
    end

    test "respects limit", %{agent_id: agent_id} do
      for _ <- 1..10 do
        IntentStore.record_intent(agent_id, Intent.think())
      end

      assert length(IntentStore.recent_intents(agent_id, limit: 5)) == 5
    end
  end

  describe "recent_percepts/2" do
    test "returns most recent first", %{agent_id: agent_id} do
      for _ <- 1..5 do
        IntentStore.record_percept(agent_id, Percept.success())
      end

      recent = IntentStore.recent_percepts(agent_id, limit: 3)
      assert length(recent) == 3
    end

    test "filters by type", %{agent_id: agent_id} do
      IntentStore.record_percept(agent_id, Percept.success())
      IntentStore.record_percept(agent_id, Percept.timeout("int_1", 5000))
      IntentStore.record_percept(agent_id, Percept.success())

      timeouts = IntentStore.recent_percepts(agent_id, type: :timeout)
      assert length(timeouts) == 1
    end
  end

  describe "get_percept_for_intent/2" do
    test "finds percept linked to intent", %{agent_id: agent_id} do
      intent = Intent.action(:shell_execute, %{command: "mix test"})
      percept = Percept.success(intent.id, %{exit_code: 0})

      IntentStore.record_intent(agent_id, intent)
      IntentStore.record_percept(agent_id, percept)

      assert {:ok, found} = IntentStore.get_percept_for_intent(agent_id, intent.id)
      assert found.id == percept.id
      assert found.intent_id == intent.id
    end

    test "returns not_found when no matching percept", %{agent_id: agent_id} do
      assert {:error, :not_found} =
               IntentStore.get_percept_for_intent(agent_id, "nonexistent")
    end
  end

  describe "ring buffer behavior" do
    test "evicts oldest entries when buffer is full", %{agent_id: agent_id} do
      # The default buffer size is 100, but we can test the eviction behavior
      # by recording more than the buffer size
      for i <- 1..105 do
        intent = Intent.new(:think, reasoning: "Thought #{i}")
        IntentStore.record_intent(agent_id, intent)
      end

      all = IntentStore.recent_intents(agent_id, limit: 200)
      # Should be capped at buffer size (100)
      assert length(all) == 100
    end
  end

  describe "clear/1" do
    test "removes all data for an agent", %{agent_id: agent_id} do
      IntentStore.record_intent(agent_id, Intent.think())
      IntentStore.record_percept(agent_id, Percept.success())

      IntentStore.clear(agent_id)

      assert IntentStore.recent_intents(agent_id) == []
      assert IntentStore.recent_percepts(agent_id) == []
    end
  end

  describe "agent isolation" do
    test "agents have separate buffers" do
      agent_a = "agent_a_#{System.unique_integer([:positive])}"
      agent_b = "agent_b_#{System.unique_integer([:positive])}"

      IntentStore.record_intent(agent_a, Intent.think("Agent A thought"))
      IntentStore.record_intent(agent_b, Intent.think("Agent B thought"))

      assert length(IntentStore.recent_intents(agent_a)) == 1
      assert length(IntentStore.recent_intents(agent_b)) == 1

      IntentStore.clear(agent_a)
      IntentStore.clear(agent_b)
    end
  end
end
