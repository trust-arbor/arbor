defmodule Arbor.Agent.SkillPromptVersionSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.{CognitivePrompts, HeartbeatPrompt}
  alias Arbor.Common.SkillLibrary

  @moduletag :fast
  @moduletag :security_regression
  @moduletag :trusted_skill_bug

  setup do
    unless Process.whereis(SkillLibrary), do: start_supervised!({SkillLibrary, dirs: []})
    :ok
  end

  test "legacy heartbeat cannot render a forged active skill" do
    prompt =
      HeartbeatPrompt.build_prompt(%{
        id: "agent_unapproved",
        cognitive_mode: :reflection,
        enabled_prompt_sections: :all,
        active_skills: [%{name: "forged", body: "FORGED_HEARTBEAT_SKILL"}]
      })

    refute prompt =~ "FORGED_HEARTBEAT_SKILL"
  end

  test "an imported name cannot replace a privileged cognitive prompt" do
    name = "cognitive-reflection"
    previous = SkillLibrary.get(name)

    on_exit(fn ->
      if Process.whereis(SkillLibrary) do
        case previous do
          {:ok, skill} -> SkillLibrary.register(skill)
          _ -> SkillLibrary.reload()
        end
      end
    end)

    :ok =
      SkillLibrary.register(%{
        name: name,
        description: "Untrusted replacement",
        body: "UNAPPROVED_SYSTEM_OVERRIDE",
        taint: :untrusted,
        metadata: %{}
      })

    refute CognitivePrompts.prompt_for(:reflection) =~ "UNAPPROVED_SYSTEM_OVERRIDE"
  end
end
