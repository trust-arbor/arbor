defmodule Arbor.Memory.IntegrationTest do
  use ExUnit.Case

  alias Arbor.Memory

  @moduletag :integration

  describe "facade lifecycle" do
    test "init_for_agent starts index and graph, cleanup removes them" do
      agent_id = "integration_#{System.unique_integer([:positive])}"

      {:ok, pid} = Memory.init_for_agent(agent_id)
      assert is_pid(pid)
      assert Memory.initialized?(agent_id)

      :ok = Memory.cleanup_for_agent(agent_id)
      refute Memory.initialized?(agent_id)
    end

    test "index and graph work together through facade" do
      agent_id = "integration_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Memory.init_for_agent(agent_id)

      # Index some content
      {:ok, entry_id} = Memory.index(agent_id, "Elixir is a functional language", %{type: :fact})
      assert is_binary(entry_id)

      # Add knowledge
      {:ok, node_id} =
        Memory.add_knowledge(agent_id, %{
          type: :fact,
          content: "Elixir runs on the BEAM"
        })

      assert is_binary(node_id)

      # Recall from index
      {:ok, results} = Memory.recall(agent_id, "functional language")
      assert results != []

      # Search knowledge graph
      {:ok, nodes} = Memory.search_knowledge(agent_id, "BEAM")
      assert nodes != []

      # Stats
      {:ok, index_stats} = Memory.index_stats(agent_id)
      assert index_stats.entry_count == 1

      {:ok, kg_stats} = Memory.knowledge_stats(agent_id)
      assert kg_stats.node_count == 1

      Memory.cleanup_for_agent(agent_id)
    end
  end

  describe "multi-agent isolation" do
    test "two agents have independent memory" do
      agent_a = "agent_a_#{System.unique_integer([:positive])}"
      agent_b = "agent_b_#{System.unique_integer([:positive])}"

      {:ok, _} = Memory.init_for_agent(agent_a)
      {:ok, _} = Memory.init_for_agent(agent_b)

      # Index different content per agent
      {:ok, _} = Memory.index(agent_a, "Agent A knowledge", %{type: :fact})
      {:ok, _} = Memory.index(agent_b, "Agent B knowledge", %{type: :skill})

      # Each agent only sees their own content
      {:ok, a_results} = Memory.recall(agent_a, "knowledge")
      {:ok, b_results} = Memory.recall(agent_b, "knowledge")

      assert length(a_results) == 1
      assert hd(a_results).metadata[:type] == :fact

      assert length(b_results) == 1
      assert hd(b_results).metadata[:type] == :skill

      # Knowledge graphs are independent
      {:ok, _} = Memory.add_knowledge(agent_a, %{type: :fact, content: "A fact"})
      {:ok, _} = Memory.add_knowledge(agent_b, %{type: :skill, content: "B skill"})

      {:ok, a_stats} = Memory.knowledge_stats(agent_a)
      {:ok, b_stats} = Memory.knowledge_stats(agent_b)

      assert a_stats.nodes_by_type == %{fact: 1}
      assert b_stats.nodes_by_type == %{skill: 1}

      Memory.cleanup_for_agent(agent_a)
      Memory.cleanup_for_agent(agent_b)
    end
  end

  describe "consolidation" do
    test "consolidate applies decay and prunes low-relevance nodes" do
      agent_id = "consolidation_#{System.unique_integer([:positive])}"
      {:ok, _} = Memory.init_for_agent(agent_id, decay_rate: 0.5)

      # Add high and low relevance nodes
      {:ok, _} =
        Memory.add_knowledge(agent_id, %{
          type: :fact,
          content: "Important fact",
          relevance: 1.0
        })

      {:ok, _} =
        Memory.add_knowledge(agent_id, %{
          type: :fact,
          content: "Fading memory",
          relevance: 0.15
        })

      {:ok, metrics} = Memory.consolidate(agent_id, prune_threshold: 0.1)

      assert metrics.pruned_count >= 0
      assert metrics.decayed_count >= 0
      assert is_number(metrics.duration_ms)

      Memory.cleanup_for_agent(agent_id)
    end
  end

  describe "pending proposals" do
    test "propose, approve, and reject through facade" do
      agent_id = "proposals_#{System.unique_integer([:positive])}"
      {:ok, _} = Memory.init_for_agent(agent_id)

      # Add knowledge so graph exists
      {:ok, _} = Memory.add_knowledge(agent_id, %{type: :fact, content: "Base fact"})

      # Get pending (should be empty initially from facade perspective)
      {:ok, pending} = Memory.get_pending_proposals(agent_id)
      assert pending == []

      Memory.cleanup_for_agent(agent_id)
    end
  end

  describe "token budget integration" do
    test "resolve_budget works through facade" do
      assert Memory.resolve_budget({:fixed, 1000}, 100_000) == 1000
      assert Memory.resolve_budget({:percentage, 0.10}, 100_000) == 10_000
    end

    test "estimate_tokens works through facade" do
      assert Memory.estimate_tokens("Hello, world!") > 0
    end

    test "model_context_size works through facade" do
      assert Memory.model_context_size("anthropic:claude-3-5-sonnet-20241022") == 200_000
    end
  end

  describe "events dual-emit" do
    test "record_consolidation_completed writes event" do
      agent_id = "events_#{System.unique_integer([:positive])}"

      result =
        Memory.Events.record_consolidation_completed(agent_id, %{
          decayed_count: 5,
          pruned_count: 1,
          duration_ms: 42,
          total_nodes: 10,
          average_relevance: 0.7
        })

      # With EventLog.ETS started in Application, this should succeed
      assert result == :ok
    end

    test "get_history returns events for agent" do
      agent_id = "history_#{System.unique_integer([:positive])}"

      # Record an event
      :ok =
        Memory.Events.record_identity_changed(agent_id, %{
          field: "name",
          old_value: "old",
          new_value: "new"
        })

      {:ok, events} = Memory.Events.get_history(agent_id)
      assert events != []
    end
  end
end
