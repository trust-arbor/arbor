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

    assert admitted == [
             "x-preview-f-free",
             "nemotron-3-ultra-free",
             "nemotron-3.5-lightning-free"
           ]

    assert Enum.any?(rejected, &(&1["id"] == "laguna-s-2.1-free"))
  end
end

defmodule Arbor.Agent.Eval.OpenCodeZenLiveTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Agent.Eval.OpenCodeZenLive
  alias Arbor.LLM.OpenCodeZen.AdmissionCore

  test "live probe runs both advertised tiers and updates the recorded catalog" do
    parent = self()

    passing = %{
      content_parts: [%{kind: :tool_call, name: "ping", arguments: %{"ok" => true}}]
    }

    {:ok, payload} =
      OpenCodeZenLive.run(
        ids: ["glm-4.6-flash", "nemotron-3-nano-free"],
        max_heartbeats: 2,
        existing: AdmissionCore.new(%{"models" => []}),
        now: "2026-08-21",
        complete: fn id ->
          send(parent, {:tier1, id})

          if id == "glm-4.6-flash" do
            {:ok, passing}
          else
            {:ok, %{content_parts: [%{kind: :text, text: "no tools"}]}}
          end
        end,
        eval_task: fn id, max_heartbeats ->
          send(parent, {:tier2, id, max_heartbeats})
          %{proposal_submitted: true, heartbeats_to_proposal: max_heartbeats}
        end,
        persist: fn payload ->
          send(parent, {:persisted, payload})
          :ok
        end
      )

    assert_received {:tier1, "glm-4.6-flash"}
    assert_received {:tier1, "nemotron-3-nano-free"}
    assert_received {:tier2, "glm-4.6-flash", 2}
    refute_received {:tier2, "nemotron-3-nano-free", _}
    assert_received {:persisted, ^payload}

    catalog = AdmissionCore.new(payload)
    assert AdmissionCore.admitted_ids(catalog) == ["glm-4.6-flash"]

    nano = Enum.find(AdmissionCore.rejected(catalog), &(&1["id"] == "nemotron-3-nano-free"))
    assert nano["reason"] == "tier1_no_tool_call"
    assert get_in(payload, ["eval", "tier2"]) =~ "--max-heartbeats 2"
  end

  test "tier-1 probe assembles an enforcing tool_choice on the outbound request" do
    request = OpenCodeZenLive.tier1_request("glm-4.6-flash")
    opts = Arbor.LLM.Adapter.ReqLLM.build_req_opts(request, [])

    assert opts[:tool_choice] == %{type: "tool", name: "ping"}
    assert Enum.any?(opts[:tools], &(&1.name == "ping"))
  end
end
