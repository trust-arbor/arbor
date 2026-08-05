defmodule Arbor.Memory.EventsTest do
  use ExUnit.Case

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.Events
  alias Arbor.Memory.Test.DurableEventLog

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
      assert events != []
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
      assert identity_events != []
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
      assert recent != []
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

  describe "maintenance archive identity" do
    test "legacy knowledge archives remain visible through the durable read view" do
      DurableEventLog.start!()
      agent_id = "archive_legacy_read_#{System.unique_integer([:positive])}"

      assert :ok =
               Events.record_knowledge_archived(agent_id, %{
                 node_id: "legacy-node",
                 type: :fact,
                 content: "legacy archive",
                 relevance: 0.1,
                 reason: :low_relevance
               })

      assert {:ok, [%Arbor.Persistence.Event{data: data}]} =
               Events.get_by_type(agent_id, :knowledge_archived)

      assert data["agent_id"] == agent_id
      assert data["node_id"] == "legacy-node"
    end

    test "exact durable knowledge archives are visible through history and recent reads" do
      DurableEventLog.start!()
      agent_id = "archive_durable_read_#{System.unique_integer([:positive])}"
      occurred_at = ~U[2026-08-05 12:00:00Z]

      entry = %{
        archive_payload: %{"node_id" => "durable-node", "reason" => "low_relevance"},
        idempotency_key: {"archive-read", "durable-node", :low_relevance},
        provenance_status: :verified,
        taint: %Taint{
          level: :trusted,
          sensitivity: :public,
          sanitizations: 0,
          confidence: :verified,
          source: "archive_read_test",
          chain: []
        }
      }

      assert :ok = Events.archive_knowledge_once(agent_id, entry, occurred_at)
      assert {:ok, [history_event]} = Events.get_history(agent_id)
      assert {:ok, [recent_event]} = Events.get_recent(agent_id, 1)
      assert history_event.id == recent_event.id
      assert history_event.data["agent_id"] == agent_id
    end

    test "durable archive read failures are returned instead of hidden by legacy history" do
      DurableEventLog.start!()

      DurableEventLog.lease_target!(%{
        name: :missing_archive_read_target,
        backend: Arbor.Memory.Test.NodeRestartEventLog,
        opts: []
      })

      assert {:error, :store_unavailable} =
               Events.get_history("archive_read_failure_#{System.unique_integer([:positive])}")
    end

    test "security regression scopes the same maintenance identity to each agent" do
      DurableEventLog.start!()

      first_agent = "archive_identity_first_#{System.unique_integer([:positive])}"
      second_agent = "archive_identity_second_#{System.unique_integer([:positive])}"
      occurred_at = ~U[2026-08-05 12:00:00Z]

      entry = %{
        archive_payload: %{
          "node_id" => "shared-node",
          "content" => "same archived content",
          "reason" => "low_relevance"
        },
        idempotency_key: {"shared-operation", "shared-node", :low_relevance},
        provenance_status: :verified,
        taint: %Taint{
          level: :trusted,
          sensitivity: :public,
          sanitizations: 0,
          confidence: :verified,
          source: "archive_identity_test",
          chain: []
        }
      }

      assert :ok = Events.archive_knowledge_once(first_agent, entry, occurred_at)
      assert :ok = Events.archive_knowledge_once(second_agent, entry, occurred_at)

      assert {:ok, [first_event]} = Events.get_by_type(first_agent, :knowledge_archived)
      assert {:ok, [second_event]} = Events.get_by_type(second_agent, :knowledge_archived)
      assert first_event.id != second_event.id
      assert first_event.data["agent_id"] == first_agent
      assert second_event.data["agent_id"] == second_agent
    end
  end
end
