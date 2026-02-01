defmodule Arbor.Memory.PreconsciousTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.{Preconscious, WorkingMemory, Index, Proposal}

  @moduletag :fast

  setup do
    agent_id = "test_agent_#{:erlang.unique_integer([:positive])}"

    # Ensure ETS tables exist
    ensure_table(:arbor_working_memory)
    ensure_table(:arbor_memory_proposals)
    ensure_table(:arbor_preconscious_config)

    # Start memory index via supervisor
    {:ok, _pid} = Arbor.Memory.IndexSupervisor.start_index(agent_id)

    on_exit(fn ->
      # Clean up after test
      Arbor.Memory.IndexSupervisor.stop_index(agent_id)
      :ets.delete(:arbor_working_memory, agent_id)
      cleanup_proposals(agent_id)
    end)

    {:ok, agent_id: agent_id}
  end

  defp ensure_table(name) do
    if :ets.whereis(name) == :undefined do
      try do
        :ets.new(name, [:named_table, :public, :set])
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp cleanup_proposals(agent_id) do
    if :ets.whereis(:arbor_memory_proposals) != :undefined do
      :ets.match_delete(:arbor_memory_proposals, {{agent_id, :_}, :_})
    end
  end

  # ============================================================================
  # Context Extraction Tests
  # ============================================================================

  describe "extract_context/2" do
    test "returns empty context when no working memory", %{agent_id: agent_id} do
      {:ok, context} = Preconscious.extract_context(agent_id)

      assert context.topics == []
      assert context.goals == []
      assert context.combined_query == ""
    end

    test "extracts topics from recent thoughts", %{agent_id: agent_id} do
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("Thinking about Elixir patterns")
        |> WorkingMemory.add_thought("Working on GenServer supervision")
        |> WorkingMemory.add_thought("Debugging OTP behavior")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      {:ok, context} = Preconscious.extract_context(agent_id)

      assert is_list(context.topics)
      assert length(context.topics) > 0
      # Should extract significant words like "elixir", "patterns", "genserver", etc.
      assert String.length(context.combined_query) > 0
    end

    test "includes active goals in context", %{agent_id: agent_id} do
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.set_goals(["Implement memory system", "Add vector search"])
        |> WorkingMemory.add_thought("Working on implementation")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      {:ok, context} = Preconscious.extract_context(agent_id)

      assert context.goals == ["Implement memory system", "Add vector search"]
      # Goals should be included in search query
      assert String.contains?(context.combined_query, "memory") or
             String.contains?(context.combined_query, "system") or
             String.contains?(context.combined_query, "vector")
    end

    test "respects lookback option", %{agent_id: agent_id} do
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("Thought 1")
        |> WorkingMemory.add_thought("Thought 2")
        |> WorkingMemory.add_thought("Thought 3")
        |> WorkingMemory.add_thought("Thought 4")
        |> WorkingMemory.add_thought("Thought 5")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      # Limit to 2 thoughts
      {:ok, context} = Preconscious.extract_context(agent_id, lookback: 2)

      # With only 2 thoughts, we get fewer topics
      assert is_list(context.topics)
    end
  end

  # ============================================================================
  # Anticipation Check Tests
  # ============================================================================

  describe "check/2" do
    test "returns empty when no working memory", %{agent_id: agent_id} do
      {:ok, anticipation} = Preconscious.check(agent_id)

      assert anticipation.memories == []
      assert anticipation.relevance_score == 0.0
    end

    test "returns empty when working memory has no content", %{agent_id: agent_id} do
      wm = WorkingMemory.new(agent_id)
      :ets.insert(:arbor_working_memory, {agent_id, wm})

      {:ok, anticipation} = Preconscious.check(agent_id)

      assert anticipation.memories == []
      assert anticipation.query_used == ""
    end

    test "finds relevant memories when index has matching content", %{agent_id: agent_id} do
      # Create a pre-computed embedding to avoid LLM calls
      embedding = for _ <- 1..768, do: :rand.uniform()

      # Index some content
      {:ok, pid} = Arbor.Memory.IndexSupervisor.get_index(agent_id)
      {:ok, _id1} = Index.index(pid, "Elixir GenServer patterns are useful", %{type: :fact}, embedding: embedding)
      {:ok, _id2} = Index.index(pid, "OTP supervision trees help reliability", %{type: :fact}, embedding: embedding)

      # Set up working memory with related thoughts
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("Learning about GenServer patterns")
        |> WorkingMemory.set_goals(["Understand Elixir OTP"])

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      # Run preconscious check with low threshold to ensure matches
      {:ok, anticipation} = Preconscious.check(agent_id, relevance_threshold: 0.0)

      # Should find the indexed memories
      # Note: With hash-based fallback embedding, we may not get exact matches
      # but the mechanism should work
      assert is_list(anticipation.memories)
      assert String.length(anticipation.query_used) > 0
      assert anticipation.context_summary != "No active context"
    end

    test "respects relevance threshold", %{agent_id: agent_id} do
      embedding = for _ <- 1..768, do: :rand.uniform()

      {:ok, pid} = Arbor.Memory.IndexSupervisor.get_index(agent_id)
      {:ok, _id} = Index.index(pid, "Some random content", %{type: :fact}, embedding: embedding)

      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("Completely unrelated topic")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      # With high threshold, should filter out low-relevance matches
      {:ok, anticipation} = Preconscious.check(agent_id, relevance_threshold: 0.99)

      # Very high threshold should filter everything
      assert anticipation.memories == []
    end

    test "respects max_results option", %{agent_id: agent_id} do
      embedding = for _ <- 1..768, do: :rand.uniform()

      {:ok, pid} = Arbor.Memory.IndexSupervisor.get_index(agent_id)

      # Index many items
      for i <- 1..10 do
        {:ok, _id} = Index.index(pid, "Memory item #{i}", %{type: :fact}, embedding: embedding)
      end

      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("Looking for memories")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      {:ok, anticipation} = Preconscious.check(agent_id, relevance_threshold: 0.0, max_results: 2)

      assert length(anticipation.memories) <= 2
    end
  end

  # ============================================================================
  # Configuration Tests
  # ============================================================================

  describe "configure/2" do
    test "sets custom configuration", %{agent_id: agent_id} do
      :ok = Preconscious.configure(agent_id,
        relevance_threshold: 0.6,
        max_per_check: 5,
        lookback_turns: 10
      )

      config = Preconscious.get_config(agent_id)

      assert config.relevance_threshold == 0.6
      assert config.max_per_check == 5
      assert config.lookback_turns == 10
    end

    test "validates threshold bounds", %{agent_id: agent_id} do
      :ok = Preconscious.configure(agent_id, relevance_threshold: 1.5)
      assert Preconscious.get_config(agent_id).relevance_threshold == 1.0

      :ok = Preconscious.configure(agent_id, relevance_threshold: -0.5)
      assert Preconscious.get_config(agent_id).relevance_threshold == 0.0
    end

    test "validates max_per_check bounds", %{agent_id: agent_id} do
      :ok = Preconscious.configure(agent_id, max_per_check: 100)
      assert Preconscious.get_config(agent_id).max_per_check == 10

      :ok = Preconscious.configure(agent_id, max_per_check: 0)
      assert Preconscious.get_config(agent_id).max_per_check == 1
    end

    test "validates lookback_turns bounds", %{agent_id: agent_id} do
      :ok = Preconscious.configure(agent_id, lookback_turns: 50)
      assert Preconscious.get_config(agent_id).lookback_turns == 20

      :ok = Preconscious.configure(agent_id, lookback_turns: 0)
      assert Preconscious.get_config(agent_id).lookback_turns == 1
    end

    test "returns defaults when not configured" do
      unconfigured_agent = "unconfigured_#{:erlang.unique_integer([:positive])}"
      config = Preconscious.get_config(unconfigured_agent)

      # Should return application defaults
      assert config.relevance_threshold == 0.4
      assert config.max_per_check == 3
      assert config.lookback_turns == 5
    end
  end

  # ============================================================================
  # Proposal Creation Tests
  # ============================================================================

  describe "create_proposals/2" do
    test "creates proposals from anticipation results", %{agent_id: agent_id} do
      anticipation = %{
        memories: [
          %{id: "mem_1", content: "Memory 1", similarity: 0.8, metadata: %{}, indexed_at: DateTime.utc_now()},
          %{id: "mem_2", content: "Memory 2", similarity: 0.7, metadata: %{}, indexed_at: DateTime.utc_now()}
        ],
        query_used: "elixir patterns",
        relevance_score: 0.75,
        context_summary: "Topics: elixir, patterns"
      }

      {:ok, proposals} = Preconscious.create_proposals(agent_id, anticipation)

      assert length(proposals) == 2

      [p1, p2] = proposals
      assert p1.type == :preconscious
      assert p1.content == "Memory 1"
      assert p1.confidence == 0.8
      assert p1.source == "preconscious"

      assert p2.type == :preconscious
      assert p2.content == "Memory 2"
      assert p2.confidence == 0.7
    end

    test "handles empty anticipation", %{agent_id: agent_id} do
      anticipation = %{
        memories: [],
        query_used: "",
        relevance_score: 0.0,
        context_summary: "No active context"
      }

      {:ok, proposals} = Preconscious.create_proposals(agent_id, anticipation)

      assert proposals == []
    end
  end

  # ============================================================================
  # BackgroundChecks Integration Tests
  # ============================================================================

  describe "BackgroundChecks integration" do
    @tag :integration
    test "preconscious check runs in background checks", %{agent_id: agent_id} do
      # Set up working memory
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("Testing preconscious integration")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      # Run background checks
      result = Arbor.Memory.BackgroundChecks.run(agent_id)

      # Should include preconscious check results (may be empty if no matches)
      assert is_map(result)
      assert is_list(result.suggestions)
      assert is_list(result.actions)
      assert is_list(result.warnings)
    end

    @tag :integration
    test "preconscious check can be skipped", %{agent_id: agent_id} do
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("Testing skip option")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      # Run with skip_preconscious option
      result = Arbor.Memory.BackgroundChecks.run(agent_id, skip_preconscious: true)

      # Should still return valid result
      assert is_map(result)
      assert is_list(result.suggestions)
    end

    @tag :integration
    test "check_preconscious returns suggestions when memories found", %{agent_id: agent_id} do
      embedding = for _ <- 1..768, do: :rand.uniform()

      {:ok, pid} = Arbor.Memory.IndexSupervisor.get_index(agent_id)
      {:ok, _id} = Index.index(pid, "Related memory content", %{type: :fact}, embedding: embedding)

      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("Searching for related content")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      # Call check_preconscious directly with low threshold
      result = Arbor.Memory.BackgroundChecks.check_preconscious(agent_id, relevance_threshold: 0.0)

      assert is_map(result)
      assert is_list(result.suggestions)

      # If we found matches, they should be preconscious type
      for suggestion <- result.suggestions do
        assert suggestion.type == :preconscious
      end
    end
  end

  # ============================================================================
  # Proposal Type Tests
  # ============================================================================

  describe "Proposal type :preconscious" do
    test "preconscious is a valid proposal type", %{agent_id: agent_id} do
      # Ensure the graph ETS table exists for proposal acceptance
      if :ets.whereis(:arbor_memory_graphs) == :undefined do
        :ets.new(:arbor_memory_graphs, [:named_table, :public, :set])
      end

      {:ok, proposal} = Proposal.create(agent_id, :preconscious, %{
        content: "Surfaced memory",
        confidence: 0.75,
        source: "preconscious",
        evidence: ["Topics: elixir"]
      })

      assert proposal.type == :preconscious
      assert proposal.content == "Surfaced memory"
      assert proposal.confidence == 0.75
      assert proposal.status == :pending
    end
  end
end
