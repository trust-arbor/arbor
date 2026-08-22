defmodule Arbor.LLM.OpenCodeZen.AdmissionCoreTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.LLM.OpenCodeZen
  alias Arbor.LLM.OpenCodeZen.AdmissionCore

  defp recorded_payload do
    path = Application.app_dir(:arbor_llm, "priv/opencode_zen/admission.json")
    path |> File.read!() |> JSON.decode!()
  end

  describe "admission is derived from recorded evidence" do
    test "running derivation on the committed file reproduces the admitted list" do
      state = AdmissionCore.new(recorded_payload())

      assert AdmissionCore.admitted_ids(state) == ["glm-4.6-flash"]
      refute "nemotron-3-nano-free" in AdmissionCore.admitted_ids(state)
      refute "big-pickle" in AdmissionCore.admitted_ids(state)
      refute "mimo-v2.5-free" in AdmissionCore.admitted_ids(state)
    end

    test "a model that cannot emit tool calls is rejected with a recorded reason" do
      rejected = AdmissionCore.rejected(AdmissionCore.new(recorded_payload()))
      nano = Enum.find(rejected, &(&1["id"] == "nemotron-3-nano-free"))

      assert nano["reason"] == "tier1_no_tool_call"
      assert get_in(nano, ["evidence", "tier1", "passed"]) == false
      assert get_in(nano, ["evidence", "tier1", "reason"]) =~ "no well-formed tool call"
    end

    test "UA-gated models stay rejected and never become admitted" do
      state = AdmissionCore.new(recorded_payload())
      rejected_ids = Enum.map(AdmissionCore.rejected(state), & &1["id"])

      assert "big-pickle" in rejected_ids
      assert "mimo-v2.5-free" in rejected_ids
      assert Enum.find(AdmissionCore.rejected(state), &(&1["id"] == "big-pickle"))["reason"] ==
               "ua_gated"

      assert AdmissionCore.admitted_id?(state, "glm-4.6-flash")
      refute AdmissionCore.admitted_id?(state, "big-pickle")
      refute AdmissionCore.admitted_id?(state, "unknown-model")
    end

    test "status=admitted is ignored when tier evidence is missing" do
      state =
        AdmissionCore.new(%{
          "models" => [
            %{
              "id" => "vendor-claimed-free",
              "status" => "admitted",
              "evidence" => %{"tier1" => %{"passed" => true}}
            }
          ]
        })

      assert AdmissionCore.admitted_ids(state) == []
    end

    test "listing includes the three-point disclosure and eval evidence" do
      listing = AdmissionCore.show(AdmissionCore.new(recorded_payload()))

      assert listing =~ "sent to OpenCode's API"
      assert listing =~ "NO representations or guarantees"
      assert listing =~ "sensitive, confidential, or regulated data"
      assert listing =~ "glm-4.6-flash"
      assert listing =~ "eval=arbor.eval.task"
      assert listing =~ "nemotron-3-nano-free"
      assert listing =~ "tier1_no_tool_call"
    end
  end

  describe "slug classification and tool-call probe" do
    test "free-suffix and unsuffixed rotating slots" do
      assert AdmissionCore.classify_slug("mimo-v2.5-free") == :free_suffix
      assert AdmissionCore.classify_slug("glm-4.6-flash") == :unsuffixed_slot
      assert AdmissionCore.classify_slug("") == :invalid
    end

    test "well-formed tool call requires name and map arguments" do
      assert AdmissionCore.well_formed_tool_call?(%{
               content_parts: [%{kind: :tool_call, name: "file_read", arguments: %{"path" => "x"}}]
             })

      refute AdmissionCore.well_formed_tool_call?(%{
               content_parts: [%{kind: :text, text: "I should call a tool"}]
             })

      refute AdmissionCore.well_formed_tool_call?(%{content_parts: []})
    end
  end

  describe "disclosure gate decision" do
    test "request is permitted only after active acknowledgement" do
      assert AdmissionCore.request_permitted?(%{"acknowledged" => true}) == :ok
      assert AdmissionCore.request_permitted?(true) == :ok

      assert AdmissionCore.request_permitted?(nil) ==
               {:error, :disclosure_not_acknowledged}

      assert AdmissionCore.request_permitted?(%{"acknowledged" => false}) ==
               {:error, :disclosure_not_acknowledged}
    end
  end

  test "facade listing and admitted ids match the core derivation" do
    assert OpenCodeZen.admitted_ids() == ["glm-4.6-flash"]
    assert OpenCodeZen.listing() =~ "OpenCode Zen free tier — data disclosure"
    assert OpenCodeZen.disclosure_text() =~ "file contents and command output"
  end

  test "every admitted model has a ModelProfile with its recorded context window" do
    for record <- OpenCodeZen.admitted() do
      id = record["id"]
      profile = Arbor.Common.ModelProfile.get(id)
      assert profile.context_size == record["context_window"],
             "missing or wrong ModelProfile for admitted model #{id}"
    end
  end

  test "Client.list_models for the free provider includes disclosure" do
    client = Arbor.LLM.Client.new(default_provider: "opencode_zen")
    [model | _] = Arbor.LLM.Client.list_models(client, provider: "opencode_zen")
    assert model.id == "glm-4.6-flash"
    assert model.disclosure =~ "sent to OpenCode's API"
    assert model.disclosure =~ "NO representations or guarantees"
    assert model.disclosure =~ "sensitive, confidential, or regulated data"
  end
end
