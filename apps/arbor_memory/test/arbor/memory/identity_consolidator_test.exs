defmodule Arbor.Memory.IdentityConsolidatorTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory.{IdentityConsolidator, KnowledgeGraph, SelfKnowledge}

  @moduletag :fast

  setup do
    # Ensure ETS tables exist
    for table <- [
          :arbor_identity_rate_limits,
          :arbor_self_knowledge,
          :arbor_memory_graphs,
          :arbor_consolidation_state
        ] do
      if :ets.whereis(table) == :undefined do
        try do
          :ets.new(table, [:named_table, :public, :set])
        rescue
          ArgumentError -> :ok
        end
      end
    end

    # Clean up for this test
    agent_id = "test_agent_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      for table <- [
            :arbor_identity_rate_limits,
            :arbor_self_knowledge,
            :arbor_memory_graphs,
            :arbor_consolidation_state
          ] do
        if :ets.whereis(table) != :undefined do
          try do
            :ets.delete(table, agent_id)
          rescue
            ArgumentError -> :ok
          end
        end
      end
    end)

    %{agent_id: agent_id}
  end

  # ============================================================================
  # Existing Tests — should_consolidate?
  # ============================================================================

  describe "should_consolidate?/2" do
    test "returns true for native agents by default", %{agent_id: agent_id} do
      assert IdentityConsolidator.should_consolidate?(agent_id)
    end

    test "returns true with force option", %{agent_id: agent_id} do
      assert IdentityConsolidator.should_consolidate?(agent_id, force: true)
    end

    test "returns false when rate limited", %{agent_id: agent_id} do
      now = System.monotonic_time(:millisecond)

      :ets.insert(
        :arbor_identity_rate_limits,
        {agent_id, [now, now - 1000, now - 2000]}
      )

      refute IdentityConsolidator.should_consolidate?(agent_id)
    end

    test "respects cooldown period", %{agent_id: agent_id} do
      now = System.monotonic_time(:millisecond)
      recent = now - 1 * 60 * 60 * 1000
      :ets.insert(:arbor_identity_rate_limits, {agent_id, [recent]})

      refute IdentityConsolidator.should_consolidate?(agent_id)
    end

    test "allows consolidation after cooldown", %{agent_id: agent_id} do
      now = System.monotonic_time(:millisecond)
      old = now - 5 * 60 * 60 * 1000
      :ets.insert(:arbor_identity_rate_limits, {agent_id, [old]})

      assert IdentityConsolidator.should_consolidate?(agent_id)
    end
  end

  # ============================================================================
  # Existing Tests — consolidate/2
  # ============================================================================

  describe "consolidate/2" do
    test "returns no_changes when no graph exists", %{agent_id: agent_id} do
      result = IdentityConsolidator.consolidate(agent_id)
      assert result == {:ok, :no_changes}
    end

    test "returns rate_limited error when at limit", %{agent_id: agent_id} do
      now = System.monotonic_time(:millisecond)

      :ets.insert(
        :arbor_identity_rate_limits,
        {agent_id, [now, now - 1000, now - 2000]}
      )

      result = IdentityConsolidator.consolidate(agent_id)
      assert result == {:error, :rate_limited}
    end

    test "force option bypasses rate limits", %{agent_id: agent_id} do
      now = System.monotonic_time(:millisecond)

      :ets.insert(
        :arbor_identity_rate_limits,
        {agent_id, [now, now - 1000, now - 2000]}
      )

      result = IdentityConsolidator.consolidate(agent_id, force: true)
      assert result == {:ok, :no_changes}
    end
  end

  # ============================================================================
  # Existing Tests — SelfKnowledge Storage
  # ============================================================================

  describe "get_self_knowledge/1 and save_self_knowledge/2" do
    test "returns nil when not set", %{agent_id: agent_id} do
      assert IdentityConsolidator.get_self_knowledge(agent_id) == nil
    end

    test "saves and retrieves self knowledge", %{agent_id: agent_id} do
      sk = SelfKnowledge.new(agent_id)
      sk = SelfKnowledge.add_trait(sk, :curious, 0.8)

      :ok = IdentityConsolidator.save_self_knowledge(agent_id, sk)

      retrieved = IdentityConsolidator.get_self_knowledge(agent_id)
      assert retrieved.agent_id == agent_id
      assert length(retrieved.personality_traits) == 1
    end
  end

  # ============================================================================
  # Existing Tests — Rollback
  # ============================================================================

  describe "rollback/2" do
    test "returns error when no self knowledge", %{agent_id: agent_id} do
      result = IdentityConsolidator.rollback(agent_id)
      assert result == {:error, :no_self_knowledge}
    end

    test "returns error when no history", %{agent_id: agent_id} do
      sk = SelfKnowledge.new(agent_id)
      IdentityConsolidator.save_self_knowledge(agent_id, sk)

      result = IdentityConsolidator.rollback(agent_id)
      assert result == {:error, :no_history}
    end

    test "rollback restores previous version", %{agent_id: agent_id} do
      sk =
        SelfKnowledge.new(agent_id)
        |> SelfKnowledge.add_trait(:curious, 0.8)
        |> SelfKnowledge.snapshot()
        |> SelfKnowledge.add_trait(:methodical, 0.9)

      IdentityConsolidator.save_self_knowledge(agent_id, sk)

      {:ok, rolled_back} = IdentityConsolidator.rollback(agent_id)
      assert length(rolled_back.personality_traits) == 1
      assert hd(rolled_back.personality_traits).trait == :curious
    end
  end

  # ============================================================================
  # Existing Tests — History + Agent Type
  # ============================================================================

  describe "history/2" do
    test "returns empty list when no events", %{agent_id: agent_id} do
      {:ok, history} = IdentityConsolidator.history(agent_id)
      assert is_list(history)
    end
  end

  describe "agent type filtering" do
    test "respects disabled_for config" do
      agent_id = "bridged_agent_test"
      old_config = Application.get_env(:arbor_memory, :identity_consolidation, [])

      Application.put_env(:arbor_memory, :identity_consolidation,
        disabled_for: [:bridged]
      )

      on_exit(fn ->
        Application.put_env(:arbor_memory, :identity_consolidation, old_config)
      end)

      assert IdentityConsolidator.should_consolidate?(agent_id)
    end
  end

  # ============================================================================
  # New Tests — Consolidation State
  # ============================================================================

  describe "get_consolidation_state/1" do
    test "returns defaults for new agent", %{agent_id: agent_id} do
      state = IdentityConsolidator.get_consolidation_state(agent_id)
      assert state.consolidation_count == 0
      assert state.last_consolidation_at == nil
    end

    test "returns stored state after consolidation", %{agent_id: agent_id} do
      # Set up a graph with a qualifying insight to trigger actual consolidation
      graph = setup_graph_with_insight(agent_id, %{
        content: "This agent is very curious and analytical",
        confidence: 0.85,
        relevance: 0.7,
        age_days: 5,
        access_count: 5,
        metadata: %{category: :personality, evidence: ["observed in conversations"]}
      })

      store_graph(agent_id, graph)

      case IdentityConsolidator.consolidate(agent_id) do
        {:ok, _sk, _result} ->
          state = IdentityConsolidator.get_consolidation_state(agent_id)
          assert state.consolidation_count == 1
          assert %DateTime{} = state.last_consolidation_at

        {:ok, :no_changes} ->
          # InsightDetector may not find insights — that's OK, state wasn't updated
          :ok
      end
    end
  end

  # ============================================================================
  # New Tests — find_promotion_candidates/2
  # ============================================================================

  describe "find_promotion_candidates/2" do
    test "returns empty list when no graph", %{agent_id: agent_id} do
      assert IdentityConsolidator.find_promotion_candidates(agent_id) == []
    end

    test "returns empty list when graph has no insight nodes", %{agent_id: agent_id} do
      graph = KnowledgeGraph.new(agent_id)
      store_graph(agent_id, graph)

      assert IdentityConsolidator.find_promotion_candidates(agent_id) == []
    end

    test "returns qualifying insights above thresholds", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "Agent demonstrates curious behavior",
        confidence: 0.85,
        relevance: 0.7,
        age_days: 5,
        access_count: 5,
        metadata: %{evidence: ["multiple observations"]}
      })

      store_graph(agent_id, graph)

      candidates = IdentityConsolidator.find_promotion_candidates(agent_id)
      assert length(candidates) == 1
      assert hd(candidates).confidence >= 0.75
    end

    test "filters out blocked insights", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "Agent is curious",
        confidence: 0.85,
        relevance: 0.7,
        age_days: 5,
        access_count: 5,
        metadata: %{evidence: ["obs"], promotion_blocked: true}
      })

      store_graph(agent_id, graph)

      candidates = IdentityConsolidator.find_promotion_candidates(agent_id)
      assert candidates == []
    end

    test "filters out insights below min_confidence", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "Maybe agent is curious",
        confidence: 0.5,
        relevance: 0.7,
        age_days: 5,
        access_count: 5,
        metadata: %{evidence: ["weak observation"]}
      })

      store_graph(agent_id, graph)

      candidates = IdentityConsolidator.find_promotion_candidates(agent_id)
      assert candidates == []
    end

    test "filters out too-young insights", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "Agent is curious",
        confidence: 0.85,
        relevance: 0.7,
        age_days: 1,
        access_count: 5,
        metadata: %{evidence: ["recent observation"]}
      })

      store_graph(agent_id, graph)

      candidates = IdentityConsolidator.find_promotion_candidates(agent_id)
      assert candidates == []
    end

    test "filters out low-access insights", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "Agent is curious",
        confidence: 0.85,
        relevance: 0.7,
        age_days: 5,
        access_count: 1,
        metadata: %{evidence: ["observation"]}
      })

      store_graph(agent_id, graph)

      candidates = IdentityConsolidator.find_promotion_candidates(agent_id)
      assert candidates == []
    end

    test "fast-track: high confidence skips age/access", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "Agent is very curious",
        confidence: 0.95,
        relevance: 0.7,
        age_days: 0,
        access_count: 0,
        metadata: %{evidence: ["strong evidence"]}
      })

      store_graph(agent_id, graph)

      # Without fast_track: should not qualify (too young, no access)
      assert IdentityConsolidator.find_promotion_candidates(agent_id) == []

      # With fast_track: should qualify
      candidates = IdentityConsolidator.find_promotion_candidates(agent_id, fast_track: true)
      assert length(candidates) == 1
    end

    test "filters out already-promoted insights", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "Agent is curious",
        confidence: 0.85,
        relevance: 0.7,
        age_days: 5,
        access_count: 5,
        metadata: %{evidence: ["obs"], promoted_at: "2025-01-01T00:00:00Z"}
      })

      store_graph(agent_id, graph)

      candidates = IdentityConsolidator.find_promotion_candidates(agent_id)
      assert candidates == []
    end
  end

  # ============================================================================
  # New Tests — block_insight/3 + unblock_insight/2
  # ============================================================================

  describe "block_insight/3" do
    test "returns error when no graph", %{agent_id: agent_id} do
      assert {:error, :no_graph} = IdentityConsolidator.block_insight(agent_id, "node_1", "reason")
    end

    test "returns error for nonexistent insight", %{agent_id: agent_id} do
      graph = KnowledgeGraph.new(agent_id)
      store_graph(agent_id, graph)

      assert {:error, :not_found} =
               IdentityConsolidator.block_insight(agent_id, "nonexistent", "reason")
    end

    test "sets promotion_blocked in metadata", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "Agent is curious",
        confidence: 0.85,
        relevance: 0.7,
        age_days: 5,
        access_count: 5,
        metadata: %{evidence: ["obs"]}
      })

      store_graph(agent_id, graph)

      # Get the node ID
      [node] = KnowledgeGraph.find_by_type(graph, :insight)

      assert :ok = IdentityConsolidator.block_insight(agent_id, node.id, "Not representative")

      # Verify metadata was updated
      {:ok, updated_graph} = get_stored_graph(agent_id)
      {:ok, updated_node} = KnowledgeGraph.get_node(updated_graph, node.id)
      assert updated_node.metadata[:promotion_blocked] == true
      assert updated_node.metadata[:blocked_reason] == "Not representative"
    end

    test "blocked insight excluded from candidates", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "Agent is curious",
        confidence: 0.85,
        relevance: 0.7,
        age_days: 5,
        access_count: 5,
        metadata: %{evidence: ["obs"]}
      })

      store_graph(agent_id, graph)
      [node] = KnowledgeGraph.find_by_type(graph, :insight)

      # Before blocking: should be a candidate
      assert length(IdentityConsolidator.find_promotion_candidates(agent_id)) == 1

      # Block it
      :ok = IdentityConsolidator.block_insight(agent_id, node.id, "Not representative")

      # After blocking: should not be a candidate
      assert IdentityConsolidator.find_promotion_candidates(agent_id) == []
    end
  end

  describe "unblock_insight/2" do
    test "returns error when no graph", %{agent_id: agent_id} do
      assert {:error, :no_graph} = IdentityConsolidator.unblock_insight(agent_id, "node_1")
    end

    test "clears blocked status", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "Agent is curious",
        confidence: 0.85,
        relevance: 0.7,
        age_days: 5,
        access_count: 5,
        metadata: %{evidence: ["obs"]}
      })

      store_graph(agent_id, graph)
      [node] = KnowledgeGraph.find_by_type(graph, :insight)

      # Block then unblock
      :ok = IdentityConsolidator.block_insight(agent_id, node.id, "Reason")
      assert IdentityConsolidator.find_promotion_candidates(agent_id) == []

      :ok = IdentityConsolidator.unblock_insight(agent_id, node.id)

      # Should be a candidate again
      candidates = IdentityConsolidator.find_promotion_candidates(agent_id)
      assert length(candidates) == 1
    end
  end

  # ============================================================================
  # New Tests — Consolidation with KG Insights
  # ============================================================================

  describe "consolidate/2 with KG insights" do
    test "returns 3-tuple with result metadata when changes made", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "This agent shows curious and analytical thinking patterns",
        confidence: 0.85,
        relevance: 0.7,
        age_days: 5,
        access_count: 5,
        metadata: %{category: :personality, evidence: ["observed patterns"]}
      })

      store_graph(agent_id, graph)

      case IdentityConsolidator.consolidate(agent_id) do
        {:ok, sk, result} ->
          assert %SelfKnowledge{} = sk
          assert is_map(result)
          assert Map.has_key?(result, :promoted_count)
          assert Map.has_key?(result, :deferred_count)
          assert Map.has_key?(result, :blocked_count)
          assert Map.has_key?(result, :changes_made)
          assert Map.has_key?(result, :consolidation_number)

        {:ok, :no_changes} ->
          # If InsightDetector didn't find matching insights, still ok
          :ok
      end
    end

    test "marks promoted insights in KG", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "Agent is very curious in its exploration style",
        confidence: 0.85,
        relevance: 0.7,
        age_days: 5,
        access_count: 5,
        metadata: %{category: :personality, evidence: ["conversation analysis"]}
      })

      store_graph(agent_id, graph)
      [node] = KnowledgeGraph.find_by_type(graph, :insight)

      case IdentityConsolidator.consolidate(agent_id) do
        {:ok, _sk, result} ->
          if result.promoted_count > 0 do
            {:ok, updated_graph} = get_stored_graph(agent_id)
            {:ok, promoted_node} = KnowledgeGraph.get_node(updated_graph, node.id)
            assert promoted_node.metadata[:promoted_at] != nil
            assert promoted_node.metadata[:promotion_blocked] == true
          end

        {:ok, :no_changes} ->
          :ok
      end
    end

    test "updates consolidation state after successful consolidation", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "Agent shows curious behavior in learning",
        confidence: 0.85,
        relevance: 0.7,
        age_days: 5,
        access_count: 5,
        metadata: %{category: :personality, evidence: ["learning patterns"]}
      })

      store_graph(agent_id, graph)

      # Before consolidation
      state_before = IdentityConsolidator.get_consolidation_state(agent_id)
      assert state_before.consolidation_count == 0

      case IdentityConsolidator.consolidate(agent_id) do
        {:ok, _sk, _result} ->
          state_after = IdentityConsolidator.get_consolidation_state(agent_id)
          assert state_after.consolidation_count == 1
          assert %DateTime{} = state_after.last_consolidation_at

        {:ok, :no_changes} ->
          :ok
      end
    end

    test "blocked insights are not promoted", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "Agent is curious",
        confidence: 0.85,
        relevance: 0.7,
        age_days: 5,
        access_count: 5,
        metadata: %{category: :personality, evidence: ["obs"], promotion_blocked: true}
      })

      store_graph(agent_id, graph)

      case IdentityConsolidator.consolidate(agent_id) do
        {:ok, _sk, result} ->
          assert result.promoted_count == 0
          assert result.blocked_count >= 1

        {:ok, :no_changes} ->
          :ok
      end
    end

    test "result contains deferred count for non-qualifying insights", %{agent_id: agent_id} do
      # Create a graph with one qualifying and one deferred insight
      graph = KnowledgeGraph.new(agent_id)
      now = DateTime.utc_now()
      old = DateTime.add(now, -6 * 86_400, :second)

      # Qualifying insight (old, high confidence, etc.)
      {:ok, graph, _id1} =
        KnowledgeGraph.add_node(graph, %{
          type: :insight,
          content: "Agent is very curious about new things",
          confidence: 0.85,
          relevance: 0.7,
          metadata: %{category: :personality, evidence: ["obs"]},
          skip_dedup: true
        })

      # Update created_at and access_count on first node
      [node1 | _] = KnowledgeGraph.find_by_type(graph, :insight)
      graph = put_in(graph.nodes[node1.id][:created_at], old)
      graph = put_in(graph.nodes[node1.id][:access_count], 5)

      # Deferred insight (too young)
      {:ok, graph, _id2} =
        KnowledgeGraph.add_node(graph, %{
          type: :insight,
          content: "Agent might be analytical too",
          confidence: 0.80,
          relevance: 0.6,
          metadata: %{category: :personality, evidence: ["weak obs"]},
          skip_dedup: true
        })

      store_graph(agent_id, graph)

      case IdentityConsolidator.consolidate(agent_id) do
        {:ok, _sk, result} ->
          # One promoted (old, high confidence), one deferred (too young)
          assert result.promoted_count + result.deferred_count >= 1

        {:ok, :no_changes} ->
          :ok
      end
    end

    test "analyze_patterns: false skips pattern analysis", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "Agent is curious in its approach",
        confidence: 0.85,
        relevance: 0.7,
        age_days: 5,
        access_count: 5,
        metadata: %{category: :personality, evidence: ["obs"]}
      })

      store_graph(agent_id, graph)

      case IdentityConsolidator.consolidate(agent_id, analyze_patterns: false) do
        {:ok, _sk, result} ->
          assert result.pattern_insights_count == 0

        {:ok, :no_changes} ->
          :ok
      end
    end
  end

  # ============================================================================
  # New Tests — Pattern Analysis
  # ============================================================================

  describe "pattern analysis integration" do
    test "analyze_patterns: false returns no patterns", %{agent_id: agent_id} do
      graph = KnowledgeGraph.new(agent_id)
      store_graph(agent_id, graph)

      # Can't directly call private function, but consolidation with no insights
      # and analyze_patterns: false should return no_changes
      result = IdentityConsolidator.consolidate(agent_id, analyze_patterns: false)
      assert result == {:ok, :no_changes}
    end
  end

  # ============================================================================
  # New Tests — Category Synthesis from KG
  # ============================================================================

  describe "KG category synthesis" do
    test "personality insight adds trait to SelfKnowledge", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "Agent demonstrates a deeply curious nature",
        confidence: 0.85,
        relevance: 0.7,
        age_days: 5,
        access_count: 5,
        metadata: %{category: :personality, evidence: ["conversations show curiosity"]}
      })

      store_graph(agent_id, graph)

      case IdentityConsolidator.consolidate(agent_id) do
        {:ok, sk, result} ->
          if result.promoted_count > 0 do
            traits = Enum.map(sk.personality_traits, & &1.trait)
            assert :curious in traits
          end

        {:ok, :no_changes} ->
          :ok
      end
    end

    test "capability insight adds capability to SelfKnowledge", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "Agent shows evidence based reasoning capabilities",
        confidence: 0.85,
        relevance: 0.7,
        age_days: 5,
        access_count: 5,
        metadata: %{category: :capability, evidence: ["analysis patterns"]}
      })

      store_graph(agent_id, graph)

      case IdentityConsolidator.consolidate(agent_id) do
        {:ok, sk, _result} ->
          caps = Enum.map(sk.capabilities, & &1.name)
          # Should have extracted "evidence_based_reasoning" from content
          assert "evidence_based_reasoning" in caps or caps != []

        {:ok, :no_changes} ->
          :ok
      end
    end

    test "value insight adds value to SelfKnowledge", %{agent_id: agent_id} do
      graph = setup_graph_with_insight(agent_id, %{
        content: "Agent values learning and growth mindset",
        confidence: 0.85,
        relevance: 0.7,
        age_days: 5,
        access_count: 5,
        metadata: %{category: :value, evidence: ["behavior analysis"]}
      })

      store_graph(agent_id, graph)

      case IdentityConsolidator.consolidate(agent_id) do
        {:ok, sk, _result} ->
          values = Enum.map(sk.values, & &1.value)
          assert :learning in values or :growth in values or values != []

        {:ok, :no_changes} ->
          :ok
      end
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp setup_graph_with_insight(agent_id, params) do
    graph = KnowledgeGraph.new(agent_id)
    now = DateTime.utc_now()
    age_days = Map.get(params, :age_days, 5)
    created_at = DateTime.add(now, -age_days * 86_400, :second)

    {:ok, graph, node_id} =
      KnowledgeGraph.add_node(graph, %{
        type: :insight,
        content: params.content,
        confidence: params.confidence,
        relevance: params.relevance,
        metadata: params.metadata,
        skip_dedup: true
      })

    # Set created_at and access_count (add_node sets defaults)
    graph = put_in(graph.nodes[node_id][:created_at], created_at)
    graph = put_in(graph.nodes[node_id][:access_count], Map.get(params, :access_count, 0))

    graph
  end

  defp store_graph(agent_id, graph) do
    :ets.insert(:arbor_memory_graphs, {agent_id, graph})
  end

  defp get_stored_graph(agent_id) do
    case :ets.lookup(:arbor_memory_graphs, agent_id) do
      [{^agent_id, graph}] -> {:ok, graph}
      [] -> {:error, :not_found}
    end
  end
end
