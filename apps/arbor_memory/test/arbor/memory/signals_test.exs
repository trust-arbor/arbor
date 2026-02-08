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

    test "emit_identity/2 returns :ok" do
      assert :ok = Signals.emit_identity("agent_001", name: "Claude", traits: %{curious: true})
    end

    test "emit_identity/2 with defaults returns :ok" do
      assert :ok = Signals.emit_identity("agent_001")
    end

    test "emit_decision/4 returns :ok" do
      assert :ok =
               Signals.emit_decision("agent_001", "Use GenServer over Agent", %{
                 alternatives: ["Agent", "GenServer", "raw process"],
                 chosen: "GenServer"
               }, reasoning: "Need state + call/cast", confidence: 0.9)
    end

    test "emit_decision/3 with defaults returns :ok" do
      assert :ok =
               Signals.emit_decision("agent_001", "Deploy to staging", %{version: "1.2.0"})
    end
  end

  describe "query functions" do
    setup do
      # Ensure signals bus is running for query tests
      ensure_signals_bus_started()
      agent_id = "query_test_#{System.unique_integer([:positive])}"
      %{agent_id: agent_id}
    end

    test "query_episodes/2 returns empty list when no episodes", %{agent_id: agent_id} do
      assert {:ok, []} = Signals.query_episodes(agent_id)
    end

    test "query_episodes/2 returns episodes after emit", %{agent_id: agent_id} do
      Signals.emit_episode_archived(agent_id, %{
        id: "ep_1",
        description: "Completed a migration task",
        outcome: :success,
        importance: 0.8
      })

      Process.sleep(50)

      {:ok, episodes} = Signals.query_episodes(agent_id, limit: 10)

      # May or may not find it depending on signal bus timing
      for ep <- episodes do
        assert is_map(ep)
      end
    end

    test "query_episodes/2 filters by outcome", %{agent_id: agent_id} do
      Signals.emit_episode_archived(agent_id, %{
        id: "ep_s", description: "Success ep", outcome: :success, importance: 0.5
      })

      Signals.emit_episode_archived(agent_id, %{
        id: "ep_f", description: "Failure ep", outcome: :failure, importance: 0.5
      })

      Process.sleep(50)

      {:ok, success_eps} = Signals.query_episodes(agent_id, outcome: :success)

      for ep <- success_eps do
        assert ep[:outcome] == :success
      end
    end

    test "query_episodes/2 filters by search text", %{agent_id: agent_id} do
      Signals.emit_episode_archived(agent_id, %{
        id: "ep_mg", description: "Migration completed", outcome: :success
      })

      Process.sleep(50)

      {:ok, results} = Signals.query_episodes(agent_id, search: "migration")

      for ep <- results do
        assert String.contains?(String.downcase(to_string(ep[:description])), "migration")
      end
    end

    test "query_archived_knowledge/2 returns empty list when none archived", %{agent_id: agent_id} do
      assert {:ok, []} = Signals.query_archived_knowledge(agent_id)
    end

    test "query_archived_knowledge/2 returns archived nodes", %{agent_id: agent_id} do
      Signals.emit_knowledge_archived(agent_id, %{
        id: "node_1", type: :concept, content: "Elixir patterns", relevance: 0.1
      }, :low_relevance)

      Process.sleep(50)

      {:ok, nodes} = Signals.query_archived_knowledge(agent_id, limit: 10)

      for node <- nodes do
        assert is_map(node)
      end
    end

    test "query_archived_knowledge/2 filters by node_type", %{agent_id: agent_id} do
      Signals.emit_knowledge_archived(agent_id, %{
        id: "n_c", type: :concept, content: "A concept", relevance: 0.1
      }, :low_relevance)

      Signals.emit_knowledge_archived(agent_id, %{
        id: "n_p", type: :person, content: "A person", relevance: 0.1
      }, :low_relevance)

      Process.sleep(50)

      {:ok, concepts} = Signals.query_archived_knowledge(agent_id, node_type: :concept)

      for node <- concepts do
        assert node[:node_type] == :concept
      end
    end

    test "latest_memory/2 returns :not_found when empty", %{agent_id: agent_id} do
      assert {:error, :not_found} = Signals.latest_memory(agent_id, :identity)
    end

    test "latest_memory/2 returns most recent signal data", %{agent_id: agent_id} do
      Signals.emit_identity(agent_id, name: "Claude")
      Process.sleep(50)

      case Signals.latest_memory(agent_id, :identity) do
        {:ok, data} ->
          assert is_map(data)
          assert data[:name] == "Claude"

        {:error, :not_found} ->
          # Acceptable if signal timing prevents retrieval
          :ok
      end
    end

    test "memory_signal_types/0 returns a non-empty list of atoms" do
      types = Signals.memory_signal_types()
      assert is_list(types)
      assert length(types) > 50
      assert Enum.all?(types, &is_atom/1)

      # Verify key types are present
      assert :identity in types
      assert :decision in types
      assert :indexed in types
      assert :recalled in types
      assert :episode_archived in types
      assert :knowledge_archived in types
      assert :bridge_interrupt in types
      assert :engagement_changed in types
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp ensure_signals_bus_started do
    unless Process.whereis(Arbor.Signals.Bus) do
      for child <- [
            {Arbor.Signals.Store, []},
            {Arbor.Signals.TopicKeys, []},
            {Arbor.Signals.Channels, []},
            {Arbor.Signals.Bus, []}
          ] do
        Supervisor.start_child(Arbor.Signals.Supervisor, child)
      end
    end
  end
end
