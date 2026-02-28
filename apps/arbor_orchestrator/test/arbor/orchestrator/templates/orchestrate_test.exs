defmodule Arbor.Orchestrator.Templates.OrchestrateTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Orchestrator.Templates.Orchestrate

  @two_branches [
    %{name: "branch_0", agent: "claude", workdir: "/tmp/wt0", tools: "file_read,file_write"},
    %{name: "branch_1", agent: "codex", workdir: "/tmp/wt1", tools: "file_read,file_write"}
  ]

  describe "generate/3" do
    test "produces valid DOT with planning phase" do
      dot = Orchestrate.generate("Build auth system", @two_branches)

      assert dot =~ "digraph orchestrate {"
      assert dot =~ ~s(goal="Build auth system")
      assert dot =~ ~s(type="start")
      assert dot =~ ~s(type="parallel")
      assert dot =~ ~s(type="parallel.fan_in")
      assert dot =~ ~s(type="exit")
      assert dot =~ "start -> plan -> fork"
      assert dot =~ "fork -> branch_0 -> collect"
      assert dot =~ "fork -> branch_1 -> collect"
      assert dot =~ "collect -> synthesize -> done"
    end

    test "includes plan node by default" do
      dot = Orchestrate.generate("Test goal", @two_branches)

      assert dot =~ "plan ["
      assert dot =~ ~s(type="codergen")
      assert dot =~ "decompose it into exactly 2 independent subtasks"
    end

    test "skips plan node with no_plan option" do
      dot = Orchestrate.generate("Test goal", @two_branches, no_plan: true)

      refute dot =~ "plan ["
      assert dot =~ "start -> fork"
      refute dot =~ "start -> plan"
    end

    test "generates correct branch nodes" do
      dot = Orchestrate.generate("Test goal", @two_branches)

      # Branch 0 — claude
      assert dot =~ "branch_0 ["
      assert dot =~ ~s(llm_provider="acp")
      assert dot =~ ~s(provider_options=)
      assert dot =~ ~s(claude)
      assert dot =~ ~s(workdir="/tmp/wt0")
      assert dot =~ ~s(prompt_context_key="subtask.0")

      # Branch 1 — codex
      assert dot =~ "branch_1 ["
      assert dot =~ ~s(codex)
      assert dot =~ ~s(workdir="/tmp/wt1")
      assert dot =~ ~s(prompt_context_key="subtask.1")
    end

    test "sets max_parallel from option" do
      dot = Orchestrate.generate("Test goal", @two_branches, max_parallel: 1)
      assert dot =~ ~s(max_parallel="1")
    end

    test "defaults max_parallel to branch count" do
      dot = Orchestrate.generate("Test goal", @two_branches)
      assert dot =~ ~s(max_parallel="2")
    end

    test "supports custom join and error policies" do
      dot =
        Orchestrate.generate("Test goal", @two_branches,
          join_policy: "first_success",
          error_policy: "fail_fast"
        )

      assert dot =~ ~s(join_policy="first_success")
      assert dot =~ ~s(error_policy="fail_fast")
    end

    test "single branch works" do
      branches = [%{name: "branch_0", agent: "claude", workdir: "."}]
      dot = Orchestrate.generate("Solo task", branches)

      assert dot =~ "branch_0 ["
      assert dot =~ "fork -> branch_0 -> collect"
      refute dot =~ "branch_1"
    end

    test "three branches work" do
      branches = [
        %{name: "branch_0", agent: "claude", workdir: "/wt0"},
        %{name: "branch_1", agent: "codex", workdir: "/wt1"},
        %{name: "branch_2", agent: "gemini", workdir: "/wt2"}
      ]

      dot = Orchestrate.generate("Big task", branches)

      assert dot =~ "fork -> branch_0 -> collect"
      assert dot =~ "fork -> branch_1 -> collect"
      assert dot =~ "fork -> branch_2 -> collect"
      assert dot =~ ~s(max_parallel="3")
    end

    test "escapes quotes in goal" do
      dot = Orchestrate.generate(~s(Fix the "broken" thing), @two_branches)
      assert dot =~ ~s(goal="Fix the \\"broken\\" thing")
    end

    test "includes synthesize node" do
      dot = Orchestrate.generate("Test goal", @two_branches)

      assert dot =~ "synthesize ["
      assert dot =~ "Review the results from all parallel branches"
    end

    test "generates parseable DOT" do
      dot = Orchestrate.generate("Test goal", @two_branches)

      # Verify it can be parsed by the orchestrator parser
      assert {:ok, _graph} = Arbor.Orchestrator.parse(dot)
    end

    test "default tools include full set" do
      branches = [%{name: "branch_0", agent: "claude", workdir: "."}]
      dot = Orchestrate.generate("Test", branches)

      assert dot =~ "file_read,file_write,file_search,file_glob,shell"
    end

    test "custom tools per branch" do
      branches = [
        %{name: "branch_0", agent: "claude", workdir: ".", tools: "file_read,file_search"}
      ]

      dot = Orchestrate.generate("Test", branches)
      assert dot =~ ~s(tools="file_read,file_search")
    end
  end
end
