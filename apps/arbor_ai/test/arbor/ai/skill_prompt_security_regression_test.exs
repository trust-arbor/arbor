defmodule Arbor.AI.SkillPromptSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  @moduletag :security_regression
  @moduletag :trusted_skill_bug

  test "public API host prompt refuses unapproved stored skill instructions" do
    # The optional Memory facade is an actual umbrella owner in this integration
    # fixture. Runtime calls keep it out of this lower app's compile-time graph.
    # The durable store is owned by this test. TestBootstrap's default authority
    # is a permanent Memory.Supervisor child and would stay registered into the
    # next umbrella app, where graph tests require the name to be free.
    memory = Arbor.Memory
    :ok = apply(Arbor.Memory.TestBootstrap, :start!, [[authority: false]])

    start_supervised!(
      {Arbor.Persistence.BufferedStore,
       [name: :arbor_memory_durable, backend: nil, write_mode: :sync]}
    )

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
