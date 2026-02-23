defmodule Arbor.Agent.MindPromptTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.MindPrompt
  alias Arbor.Contracts.Memory.Percept

  describe "build/1" do
    test "returns a string" do
      prompt = MindPrompt.build()
      assert is_binary(prompt)
    end

    test "includes role section" do
      prompt = MindPrompt.build(agent_name: "TestBot")
      assert String.contains?(prompt, "TestBot")
    end

    test "includes identity when provided" do
      prompt = MindPrompt.build(identity: "A code review assistant.")
      assert String.contains?(prompt, "code review assistant")
    end

    test "includes goal when provided" do
      prompt = MindPrompt.build(goal: %{description: "Fix the login bug", progress: 0.3})
      assert String.contains?(prompt, "GOAL:")
      assert String.contains?(prompt, "Fix the login bug")
      assert String.contains?(prompt, "30%")
    end

    test "omits goal section when no goal" do
      prompt = MindPrompt.build()
      refute String.contains?(prompt, "GOAL:")
    end

    test "includes last percept when provided" do
      percept = Percept.success("i_1", %{}, summary: "read 42 lines from /etc/hosts")
      prompt = MindPrompt.build(last_percept: percept)

      assert String.contains?(prompt, "LAST RESULT:")
      assert String.contains?(prompt, "42 lines")
    end

    test "includes capabilities section" do
      prompt = MindPrompt.build()
      assert String.contains?(prompt, "CAPABILITIES:")
    end

    test "includes response format" do
      prompt = MindPrompt.build()
      assert String.contains?(prompt, "RESPOND WITH JSON:")
      assert String.contains?(prompt, "mental_actions")
      assert String.contains?(prompt, "intent")
      assert String.contains?(prompt, "wait")
    end

    test "includes physical and mental capability lists in rules" do
      prompt = MindPrompt.build()
      assert String.contains?(prompt, "Physical capabilities:")
      assert String.contains?(prompt, "Mental capabilities:")
      assert String.contains?(prompt, "fs")
      assert String.contains?(prompt, "memory")
    end

    test "uses goal-aware expansion when goals provided" do
      prompt = MindPrompt.build(goals: [%{description: "write a test file"}])
      # Should expand fs capabilities since "file" matches
      assert String.contains?(prompt, "CAPABILITIES:")
    end

    test "stays under ~500 tokens for basic prompt" do
      prompt = MindPrompt.build()
      # Rough estimate: ~4 chars per token
      estimated_tokens = div(String.length(prompt), 4)
      assert estimated_tokens < 500
    end
  end

  describe "build_iteration/1" do
    test "does not leak internal loop state" do
      msg = MindPrompt.build_iteration()
      refute String.contains?(msg, "teration")
      refute String.contains?(msg, "step")
    end

    test "includes recent percepts" do
      percepts = [
        Percept.success("i_1", %{}, summary: "recalled 3 memories"),
        Percept.success("i_2", %{}, summary: "listed 5 goals")
      ]

      msg = MindPrompt.build_iteration(recent_percepts: percepts)

      assert String.contains?(msg, "recalled 3 memories")
      assert String.contains?(msg, "listed 5 goals")
      assert String.contains?(msg, "Results from mental actions:")
    end

    test "omits percept section when empty" do
      msg = MindPrompt.build_iteration()
      refute String.contains?(msg, "Results from mental actions:")
    end

    test "ends with JSON prompt" do
      msg = MindPrompt.build_iteration()
      assert String.contains?(msg, "Respond with JSON")
    end
  end
end
