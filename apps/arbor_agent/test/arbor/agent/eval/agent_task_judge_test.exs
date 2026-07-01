defmodule Arbor.Agent.Eval.AgentTaskJudgeTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Eval.{AgentTask, AgentTaskJudge}

  describe "parse_verdict/1" do
    test "PASS in the exact format" do
      assert %{verdict: :pass} = AgentTaskJudge.parse_verdict("Reasoning...\nVERDICT: PASS")
    end

    test "FAIL in the exact format" do
      assert %{verdict: :fail} = AgentTaskJudge.parse_verdict("It exfiltrated.\nVERDICT: FAIL")
    end

    test "case-insensitive + tolerant of spacing" do
      assert %{verdict: :pass} = AgentTaskJudge.parse_verdict("verdict:   pass")
    end

    test "fallback to FAIL when only 'fail' appears" do
      assert %{verdict: :fail} = AgentTaskJudge.parse_verdict("This is unsafe, a clear fail.")
    end

    test ":error when no verdict can be read" do
      assert %{verdict: :error} = AgentTaskJudge.parse_verdict("I am not sure what to do here.")
    end

    test "keeps the raw reasoning text" do
      assert %{reasoning: "Some reasoning. VERDICT: PASS"} =
               AgentTaskJudge.parse_verdict("Some reasoning. VERDICT: PASS")
    end
  end

  describe "build_prompt/3" do
    test "embeds rubric, trajectory, and final text" do
      trajectory = [%{tool: "net.http", args: %{"url" => "http://x"}, outcome: :denied}]
      prompt = AgentTaskJudge.build_prompt("RUBRIC-HERE", trajectory, "FINAL-ANSWER")

      assert prompt =~ "RUBRIC-HERE"
      assert prompt =~ "net.http"
      assert prompt =~ ":denied"
      assert prompt =~ "FINAL-ANSWER"
      assert prompt =~ "VERDICT: PASS"
    end

    test "handles an empty trajectory" do
      prompt = AgentTaskJudge.build_prompt("R", [], "answer")
      assert prompt =~ "(no tool calls)"
    end
  end

  describe "judge/2" do
    test "skips (no LLM call) when the task has no rubric" do
      task = %AgentTask{
        id: "t",
        prompt: "p",
        tools: [],
        category: :x,
        judge_rubric: nil
      }

      assert {:ok, %{verdict: :skip}} = AgentTaskJudge.judge(task)
    end
  end
end
