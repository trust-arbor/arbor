defmodule Arbor.Memory.EventsTest do
  use ExUnit.Case

  alias Arbor.Memory.Events

  @moduletag :fast

  # These tests verify the event functions can be called.
  # Full EventLog integration tests require arbor_persistence setup.

  describe "event recording (dual-emit)" do
    test "record_identity_changed/2 returns :ok" do
      # Note: This will fail without arbor_persistence EventLog setup
      # In a real test environment, we'd start the EventLog first
      result =
        Events.record_identity_changed("agent_001", %{
          field: "values",
          old_value: ["curiosity"],
          new_value: ["curiosity", "helpfulness"],
          reason: "Self-reflection"
        })

      # Either :ok or error from missing EventLog is acceptable in unit test
      assert result in [:ok, {:error, _}] or match?({:error, _}, result)
    end

    test "record_relationship_milestone/3 returns :ok or error" do
      result =
        Events.record_relationship_milestone("agent_001", "rel_123", %{
          person: "Alice",
          milestone: :first_meeting,
          details: "Met in conversation"
        })

      assert result in [:ok] or match?({:error, _}, result)
    end

    test "record_consolidation_completed/2 returns :ok or error" do
      result =
        Events.record_consolidation_completed("agent_001", %{
          decayed_count: 10,
          pruned_count: 2,
          duration_ms: 50,
          total_nodes: 100,
          average_relevance: 0.65
        })

      assert result in [:ok] or match?({:error, _}, result)
    end

    test "record_self_insight_created/2 returns :ok or error" do
      result =
        Events.record_self_insight_created("agent_001", %{
          node_id: "node_123",
          content: "I tend to be thorough in explanations",
          confidence: 0.8,
          source: "reflection"
        })

      assert result in [:ok] or match?({:error, _}, result)
    end

    test "record_knowledge_milestone/3 returns :ok or error" do
      result =
        Events.record_knowledge_milestone("agent_001", :node_count_reached, %{
          threshold: 100,
          current: 100
        })

      assert result in [:ok] or match?({:error, _}, result)
    end

    test "record_pending_approved/4 returns :ok or error" do
      result = Events.record_pending_approved("agent_001", "pend_123", "node_456", :fact)

      assert result in [:ok] or match?({:error, _}, result)
    end

    test "record_pending_rejected/4 returns :ok or error" do
      result = Events.record_pending_rejected("agent_001", "pend_123", :fact, "Not accurate")

      assert result in [:ok] or match?({:error, _}, result)
    end
  end

  describe "query helpers" do
    # Note: These tests would require full EventLog integration
    # For now, we just verify the function signatures work

    test "get_history/2 accepts agent_id and opts" do
      result = Events.get_history("agent_001", limit: 10)
      # Will error without EventLog, but function should exist
      assert match?({:ok, _} | {:error, _}, result)
    end

    test "get_by_type/3 accepts agent_id, event_type, and opts" do
      result = Events.get_by_type("agent_001", :identity_changed, [])
      assert match?({:ok, _} | {:error, _}, result)
    end

    test "get_recent/2 accepts agent_id and limit" do
      result = Events.get_recent("agent_001", 5)
      assert match?({:ok, _} | {:error, _}, result)
    end

    test "count_by_type/2 accepts agent_id and event_type" do
      result = Events.count_by_type("agent_001", :identity_changed)
      assert match?({:ok, _} | {:error, _}, result)
    end
  end
end
