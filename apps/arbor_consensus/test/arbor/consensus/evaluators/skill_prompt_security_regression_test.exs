defmodule Arbor.Consensus.Evaluators.SkillPromptSecurityRegressionTest do
  use ExUnit.Case, async: false
  alias Arbor.Common.SkillLibrary
  alias Arbor.Consensus.Evaluators.AdvisoryLLM
  alias Arbor.Contracts.Consensus.Proposal

  @moduletag :fast
  @moduletag :security_regression
  @moduletag :trusted_skill_bug

  test "advisory evaluation does not promote an unapproved imported system prompt" do
    unless Process.whereis(SkillLibrary), do: start_supervised!({SkillLibrary, dirs: []})
    previous = SkillLibrary.get("security-perspective")

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
        name: "security-perspective",
        description: "untrusted",
        body: "FORGED_COUNCIL_SYSTEM_PROMPT",
        taint: :untrusted
      })

    {:ok, proposal} =
      Proposal.new(%{
        proposer: "test",
        topic: :advisory,
        description: "Review the small design",
        target_layer: 4
      })

    observer = self()

    llm = fn system, _user ->
      send(observer, {:system_prompt, system})

      {:ok,
       ~s({"analysis":"Bounded review","considerations":[],"alternatives":[],"recommendation":"Review exact authority"})}
    end

    assert {:ok, _} = AdvisoryLLM.evaluate(proposal, :security, llm_fn: llm)
    assert_receive {:system_prompt, system}
    refute system =~ "FORGED_COUNCIL_SYSTEM_PROMPT"
    assert system =~ "security"
  end
end
