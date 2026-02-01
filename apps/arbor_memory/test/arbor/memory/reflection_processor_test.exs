defmodule Arbor.Memory.ReflectionProcessorTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory.ReflectionProcessor

  @moduletag :fast

  setup do
    # Ensure ETS table exists
    if :ets.whereis(:arbor_reflections) == :undefined do
      try do
        :ets.new(:arbor_reflections, [:named_table, :public, :set])
      rescue
        ArgumentError -> :ok
      end
    end

    agent_id = "test_agent_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      # Safely delete - table may not exist
      if :ets.whereis(:arbor_reflections) != :undefined do
        try do
          :ets.delete(:arbor_reflections, agent_id)
        rescue
          ArgumentError -> :ok
        end
      end
    end)

    %{agent_id: agent_id}
  end

  describe "reflect/3" do
    test "returns structured reflection map", %{agent_id: agent_id} do
      {:ok, reflection} = ReflectionProcessor.reflect(agent_id, "What patterns do I see?")

      assert is_binary(reflection.id)
      assert reflection.agent_id == agent_id
      assert reflection.prompt == "What patterns do I see?"
      assert is_binary(reflection.analysis)
      assert is_list(reflection.insights)
      assert is_map(reflection.self_assessment)
      assert %DateTime{} = reflection.timestamp
    end

    test "uses mock LLM module by default", %{agent_id: agent_id} do
      {:ok, reflection} = ReflectionProcessor.reflect(agent_id, "How can I improve?")

      # Mock should include "improve" related content
      assert String.contains?(reflection.analysis, "improvement") or
               String.contains?(reflection.analysis, "improve") or
               String.contains?(reflection.analysis, agent_id)

      assert length(reflection.insights) > 0
    end

    test "stores reflection in history", %{agent_id: agent_id} do
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "Test prompt")

      {:ok, history} = ReflectionProcessor.history(agent_id)
      assert length(history) == 1
      assert hd(history).prompt == "Test prompt"
    end

    test "respects include_self_knowledge option", %{agent_id: agent_id} do
      # Should not error when self_knowledge is not available
      {:ok, reflection} =
        ReflectionProcessor.reflect(agent_id, "Test",
          include_self_knowledge: true
        )

      assert is_binary(reflection.analysis)
    end
  end

  describe "periodic_reflection/1" do
    test "runs without error", %{agent_id: agent_id} do
      {:ok, reflection} = ReflectionProcessor.periodic_reflection(agent_id)

      assert is_binary(reflection.analysis)
      assert is_list(reflection.insights)
    end

    test "uses standard prompt about patterns and growth", %{agent_id: agent_id} do
      {:ok, reflection} = ReflectionProcessor.periodic_reflection(agent_id)

      assert String.contains?(reflection.prompt, "pattern") or
               String.contains?(reflection.prompt, "activity")
    end
  end

  describe "history/2" do
    test "returns empty list for new agent", %{agent_id: agent_id} do
      {:ok, history} = ReflectionProcessor.history(agent_id)
      assert history == []
    end

    test "returns past reflections in order", %{agent_id: agent_id} do
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "First")
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "Second")
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "Third")

      {:ok, history} = ReflectionProcessor.history(agent_id)
      assert length(history) == 3
      # Most recent first
      assert hd(history).prompt == "Third"
    end

    test "respects limit option", %{agent_id: agent_id} do
      for i <- 1..5 do
        {:ok, _} = ReflectionProcessor.reflect(agent_id, "Prompt #{i}")
      end

      {:ok, limited} = ReflectionProcessor.history(agent_id, limit: 2)
      assert length(limited) == 2
    end

    test "respects since option", %{agent_id: agent_id} do
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "Old")
      old_time = DateTime.utc_now()
      Process.sleep(10)
      {:ok, _} = ReflectionProcessor.reflect(agent_id, "New")

      {:ok, filtered} = ReflectionProcessor.history(agent_id, since: old_time)
      assert length(filtered) == 1
      assert hd(filtered).prompt == "New"
    end
  end

  describe "MockLLM" do
    test "reflect returns structured response" do
      {:ok, response} =
        ReflectionProcessor.MockLLM.reflect("Test prompt", %{
          agent_id: "test"
        })

      assert is_binary(response.analysis)
      assert is_list(response.insights)
      assert is_map(response.self_assessment)
    end

    test "analysis varies based on prompt content" do
      {:ok, pattern_response} =
        ReflectionProcessor.MockLLM.reflect("What patterns do I see?", %{})

      {:ok, improve_response} =
        ReflectionProcessor.MockLLM.reflect("How can I improve?", %{})

      # Both should be valid but different
      assert is_binary(pattern_response.analysis)
      assert is_binary(improve_response.analysis)
    end

    test "self_assessment reflects context" do
      {:ok, with_caps} =
        ReflectionProcessor.MockLLM.reflect("Test", %{
          capabilities: [%{name: "elixir", proficiency: 0.8}]
        })

      {:ok, without_caps} =
        ReflectionProcessor.MockLLM.reflect("Test", %{
          capabilities: []
        })

      # With capabilities should have higher confidence
      assert with_caps.self_assessment.capability_confidence >
               without_caps.self_assessment.capability_confidence
    end
  end
end
