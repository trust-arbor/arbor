defmodule Arbor.Agent.Orchestration.TerminalGuardCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Orchestration.TerminalGuardCore

  @moduletag :fast

  describe "contradicts_live_runner?/3 (finalization security regression, 2026-09-04)" do
    test "a runner-gone terminal is refused while the task's runner ref is still monitored" do
      ref = make_ref()
      refs = %{ref => "task_live", make_ref() => "task_other"}

      assert TerminalGuardCore.contradicts_live_runner?("task_live", "task_runner_failed", refs)
      assert TerminalGuardCore.contradicts_live_runner?("task_live", "task_owner_died", refs)
    end

    test "a runner-gone terminal is allowed once the task's runner ref is gone" do
      refs = %{make_ref() => "task_other"}

      refute TerminalGuardCore.contradicts_live_runner?("task_live", "task_runner_failed", refs)
      refute TerminalGuardCore.contradicts_live_runner?("task_live", "task_runner_failed", %{})
    end

    test "terminals that do not claim the runner is gone are never refused" do
      refs = %{make_ref() => "task_live"}

      for code <-
            ~w(task_cancelled human_review_required change_committed invalid_terminal_evidence unknown) do
        refute TerminalGuardCore.contradicts_live_runner?("task_live", code, refs)
      end
    end

    test "non-reference keys never count as a live runner" do
      refute TerminalGuardCore.contradicts_live_runner?(
               "task_live",
               "task_runner_failed",
               %{"not_a_ref" => "task_live"}
             )
    end
  end

  describe "terminal_code/1" do
    test "reads the canonical outcome code and falls back to unknown" do
      assert TerminalGuardCore.terminal_code(%{"outcome" => %{"code" => "task_runner_failed"}}) ==
               "task_runner_failed"

      assert TerminalGuardCore.terminal_code(%{"outcome" => %{}}) == "unknown"
      assert TerminalGuardCore.terminal_code(nil) == "unknown"
    end
  end
end
