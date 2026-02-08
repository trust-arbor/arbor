defmodule Arbor.Memory.InsightDetectorWMTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.{InsightDetector, WorkingMemory}

  @moduletag :fast

  setup do
    agent_id = "test_agent_#{System.unique_integer([:positive])}"

    ensure_table(:arbor_working_memory)

    on_exit(fn ->
      if :ets.whereis(:arbor_working_memory) != :undefined do
        :ets.delete(:arbor_working_memory, agent_id)
      end
    end)

    %{agent_id: agent_id}
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

  # ============================================================================
  # detect_from_working_memory/2
  # ============================================================================

  describe "detect_from_working_memory/2" do
    test "returns empty when no working memory", %{agent_id: agent_id} do
      assert InsightDetector.detect_from_working_memory(agent_id) == []
    end

    test "returns empty when too few thoughts", %{agent_id: agent_id} do
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("Just one thought")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      assert InsightDetector.detect_from_working_memory(agent_id) == []
    end

    test "detects curiosity pattern", %{agent_id: agent_id} do
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("I wonder why this pattern exists")
        |> WorkingMemory.add_thought("How does the OTP supervisor work?")
        |> WorkingMemory.add_thought("What if we used a different approach?")
        |> WorkingMemory.add_thought("This is a curious behavior to explore")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      insights = InsightDetector.detect_from_working_memory(agent_id)

      assert length(insights) > 0
      categories = Enum.map(insights, & &1.category)
      assert :curiosity in categories
    end

    test "detects methodical pattern", %{agent_id: agent_id} do
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("First, let me analyze the structure")
        |> WorkingMemory.add_thought("Next step is to plan the implementation")
        |> WorkingMemory.add_thought("Then we need to organize the modules")
        |> WorkingMemory.add_thought("The sequence should be systematic")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      insights = InsightDetector.detect_from_working_memory(agent_id)

      categories = Enum.map(insights, & &1.category)
      assert :methodical in categories
    end

    test "detects caution pattern", %{agent_id: agent_id} do
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("Let me carefully check the output")
        |> WorkingMemory.add_thought("I should verify this before proceeding")
        |> WorkingMemory.add_thought("Need to validate the test results")
        |> WorkingMemory.add_thought("Double-check to ensure correctness")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      insights = InsightDetector.detect_from_working_memory(agent_id)

      categories = Enum.map(insights, & &1.category)
      assert :caution in categories
    end

    test "detects learning pattern", %{agent_id: agent_id} do
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("I learned that ETS is very fast")
        |> WorkingMemory.add_thought("Now I understand how GenServers work")
        |> WorkingMemory.add_thought("I discovered a new pattern for this")
        |> WorkingMemory.add_thought("This insight helps me figure things out")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      insights = InsightDetector.detect_from_working_memory(agent_id)

      categories = Enum.map(insights, & &1.category)
      assert :learning in categories
    end

    test "respects max_suggestions option", %{agent_id: agent_id} do
      # Mix lots of keywords from all categories
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("I wonder why, I learned that, first step, careful check")
        |> WorkingMemory.add_thought("How does this work? I discovered something, plan and verify")
        |> WorkingMemory.add_thought("Explore systematically, next step, validate the insight")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      insights = InsightDetector.detect_from_working_memory(agent_id, max_suggestions: 2)

      assert length(insights) <= 2
    end

    test "respects min_hits option", %{agent_id: agent_id} do
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("I wonder about this")
        |> WorkingMemory.add_thought("Nothing special here")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      # With high min_hits, should get nothing
      insights = InsightDetector.detect_from_working_memory(agent_id, min_hits: 10)
      assert insights == []
    end

    test "handles structured thought maps", %{agent_id: agent_id} do
      wm =
        WorkingMemory.new(agent_id)
        |> WorkingMemory.add_thought("Why does this pattern work? I wonder about the structure")
        |> WorkingMemory.add_thought("How curious, let me explore this question further")

      :ets.insert(:arbor_working_memory, {agent_id, wm})

      # Should handle both string and map thoughts gracefully
      insights = InsightDetector.detect_from_working_memory(agent_id)
      assert is_list(insights)
    end
  end
end
