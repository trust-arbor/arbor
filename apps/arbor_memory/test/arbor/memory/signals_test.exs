defmodule Arbor.Memory.SignalsTest do
  use ExUnit.Case

  alias Arbor.Memory.Signals

  @moduletag :fast

  # These tests verify the signal functions can be called without error.
  # Full signal delivery testing requires arbor_signals integration tests.

  describe "signal emissions" do
    test "emit_indexed/2 returns :ok" do
      assert :ok =
               Signals.emit_indexed("agent_001", %{
                 entry_id: "mem_123",
                 type: :fact,
                 source: "test"
               })
    end

    test "emit_recalled/4 returns :ok" do
      assert :ok = Signals.emit_recalled("agent_001", "query", 5, top_similarity: 0.9)
    end

    test "emit_consolidation_started/1 returns :ok" do
      assert :ok = Signals.emit_consolidation_started("agent_001")
    end

    test "emit_consolidation_completed/2 returns :ok" do
      assert :ok =
               Signals.emit_consolidation_completed("agent_001", %{
                 decayed_count: 10,
                 pruned_count: 2,
                 duration_ms: 50
               })
    end

    test "emit_fact_extracted/2 returns :ok" do
      assert :ok =
               Signals.emit_fact_extracted("agent_001", %{
                 id: "pend_123",
                 content: "A fact about something",
                 confidence: 0.8,
                 source: "conversation"
               })
    end

    test "emit_learning_extracted/2 returns :ok" do
      assert :ok =
               Signals.emit_learning_extracted("agent_001", %{
                 id: "pend_456",
                 content: "A learned pattern",
                 confidence: 0.7,
                 source: "action_analysis"
               })
    end

    test "emit_knowledge_added/3 returns :ok" do
      assert :ok = Signals.emit_knowledge_added("agent_001", "node_123", :fact)
    end

    test "emit_knowledge_linked/4 returns :ok" do
      assert :ok = Signals.emit_knowledge_linked("agent_001", "node_a", "node_b", :supports)
    end

    test "emit_knowledge_decayed/2 returns :ok" do
      assert :ok =
               Signals.emit_knowledge_decayed("agent_001", %{
                 node_count: 100,
                 average_relevance: 0.65
               })
    end

    test "emit_knowledge_pruned/2 returns :ok" do
      assert :ok = Signals.emit_knowledge_pruned("agent_001", 5)
    end

    test "emit_pending_approved/3 returns :ok" do
      assert :ok = Signals.emit_pending_approved("agent_001", "pend_123", "node_456")
    end

    test "emit_pending_rejected/2 returns :ok" do
      assert :ok = Signals.emit_pending_rejected("agent_001", "pend_123")
    end

    test "emit_memory_initialized/2 returns :ok" do
      assert :ok =
               Signals.emit_memory_initialized("agent_001", %{
                 index_enabled: true,
                 graph_enabled: true
               })
    end

    test "emit_memory_cleaned_up/1 returns :ok" do
      assert :ok = Signals.emit_memory_cleaned_up("agent_001")
    end
  end
end
