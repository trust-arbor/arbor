defmodule Arbor.Memory.EventsTest do
  use ExUnit.Case

  alias Arbor.Memory.Events

  @moduletag :fast

  describe "event recording (dual-emit)" do
    test "record_identity_changed/2 writes event" do
      agent_id = "events_#{System.unique_integer([:positive])}"

      assert :ok =
               Events.record_identity_changed(agent_id, %{
                 field: "values",
                 old_value: ["curiosity"],
                 new_value: ["curiosity", "helpfulness"],
                 reason: "Self-reflection"
               })
    end

    test "record_relationship_milestone/3 writes event" do
      agent_id = "events_#{System.unique_integer([:positive])}"

      assert :ok =
               Events.record_relationship_milestone(agent_id, "rel_123", %{
                 person: "Alice",
                 milestone: :first_meeting,
                 details: "Met in conversation"
               })
    end

    test "record_consolidation_completed/2 writes event" do
      agent_id = "events_#{System.unique_integer([:positive])}"

      assert :ok =
               Events.record_consolidation_completed(agent_id, %{
                 decayed_count: 10,
                 pruned_count: 2,
                 duration_ms: 50,
                 total_nodes: 100,
                 average_relevance: 0.65
               })
    end

    test "record_self_insight_created/2 writes event" do
      agent_id = "events_#{System.unique_integer([:positive])}"

      assert :ok =
               Events.record_self_insight_created(agent_id, %{
                 node_id: "node_123",
                 content: "I tend to be thorough in explanations",
                 confidence: 0.8,
                 source: "reflection"
               })
    end

    test "record_knowledge_milestone/3 writes event" do
      agent_id = "events_#{System.unique_integer([:positive])}"

      assert :ok =
               Events.record_knowledge_milestone(agent_id, :node_count_reached, %{
                 threshold: 100,
                 current: 100
               })
    end

    test "record_pending_approved/4 writes event" do
      agent_id = "events_#{System.unique_integer([:positive])}"
      assert :ok = Events.record_pending_approved(agent_id, "pend_123", "node_456", :fact)
    end

    test "record_pending_rejected/4 writes event" do
      agent_id = "events_#{System.unique_integer([:positive])}"
      assert :ok = Events.record_pending_rejected(agent_id, "pend_123", :fact, "Not accurate")
    end
  end

  describe "query helpers" do
    test "get_history/2 returns events for agent" do
      agent_id = "history_#{System.unique_integer([:positive])}"

      :ok =
        Events.record_identity_changed(agent_id, %{
          field: "name",
          old_value: "old",
          new_value: "new"
        })

      {:ok, events} = Events.get_history(agent_id)
      assert length(events) >= 1
    end

    test "get_by_type/3 filters events" do
      agent_id = "bytype_#{System.unique_integer([:positive])}"

      :ok =
        Events.record_identity_changed(agent_id, %{
          field: "name",
          old_value: "a",
          new_value: "b"
        })

      :ok =
        Events.record_consolidation_completed(agent_id, %{
          decayed_count: 1,
          pruned_count: 0,
          duration_ms: 10,
          total_nodes: 5,
          average_relevance: 0.8
        })

      {:ok, identity_events} = Events.get_by_type(agent_id, :identity_changed)
      assert length(identity_events) >= 1
    end

    test "get_recent/2 returns latest events" do
      agent_id = "recent_#{System.unique_integer([:positive])}"

      :ok =
        Events.record_identity_changed(agent_id, %{
          field: "name",
          old_value: "old",
          new_value: "new"
        })

      {:ok, recent} = Events.get_recent(agent_id, 5)
      assert length(recent) >= 1
    end

    test "count_by_type/2 counts events" do
      agent_id = "count_#{System.unique_integer([:positive])}"

      :ok =
        Events.record_identity_changed(agent_id, %{
          field: "name",
          old_value: "a",
          new_value: "b"
        })

      {:ok, count} = Events.count_by_type(agent_id, :identity_changed)
      assert count >= 1
    end
  end
end
