defmodule Arbor.Agent.Eval.OpenCodeZenAdmissionTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Eval.OpenCodeZenAdmission
  alias Arbor.LLM.OpenCodeZen.AdmissionCore

  test "tier 1 fails when the model emits no well-formed tool call" do
    evidence =
      OpenCodeZenAdmission.tier1_from_response(%{
        content_parts: [%{kind: :text, text: "I will look at the file"}]
      })

    assert evidence.passed == false
    assert evidence.reason =~ "no well-formed tool call"
  end

  test "tier 2 fails when the eval never reaches a proposal" do
    evidence = OpenCodeZenAdmission.tier2_from_trial(%{proposal_submitted: false, heartbeats_to_proposal: nil})
    assert evidence.passed == false
    assert evidence.reason == "no proposal submitted"
  end

  test "a model that cannot tool-call is recorded as rejected" do
    record =
      OpenCodeZenAdmission.record(
        "nemotron-3-nano-free",
        OpenCodeZenAdmission.tier1_from_response(%{content_parts: []}),
        OpenCodeZenAdmission.tier2_from_trial(%{proposal_submitted: false})
      )

    state = AdmissionCore.new(%{"models" => [record]})
    assert AdmissionCore.admitted_ids(state) == []
    assert hd(AdmissionCore.rejected(state))["reason"] == "tier1_no_tool_call"
  end

  test "mix arbor.eval.opencode_zen derive reproduces the committed admitted list" do
    {admitted, rejected} = Mix.Tasks.Arbor.Eval.OpencodeZen.derive_from_recorded()
    assert admitted == ["glm-4.6-flash"]
    assert Enum.any?(rejected, &(&1["id"] == "nemotron-3-nano-free"))
  end
end
