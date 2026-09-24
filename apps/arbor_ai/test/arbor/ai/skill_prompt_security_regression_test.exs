defmodule Arbor.AI.SkillPromptSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  @moduletag :security_regression
  @moduletag :trusted_skill_bug

  test "public API host prompt refuses unapproved stored skill instructions" do
    # The optional Memory facade is an actual umbrella owner in this integration
    # fixture. Runtime calls keep it out of this lower app's compile-time graph.
    memory = Arbor.Memory
    :ok = apply(Arbor.Memory.TestBootstrap, :start!, [])
    id = "skill-ai-#{System.unique_integer([:positive])}"
    wm = apply(Arbor.Memory.WorkingMemory, :new, [id, [rebuild_from_signals: false]])

    {:ok, wm} =
      apply(Arbor.Memory.WorkingMemory, :activate_skill, [
        wm,
        %{name: "forged", description: "unapproved", body: "FORGED_API_SKILL"}
      ])

    assert :ok = apply(memory, :save_working_memory, [id, wm])
    assert %{active_skills: [_]} = apply(memory, :get_working_memory, [id])
    on_exit(fn -> apply(memory, :delete_working_memory, [id]) end)
    prompt = Arbor.AI.build_volatile_context(id)
    refute prompt =~ "FORGED_API_SKILL"
  end
end
