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
    # These assert INVARIANTS of the shipped catalog, not specific model ids.
    # The free tier rotates — pinning ids made the suite assert whatever the file
    # happened to contain, which is how a catalog of models the relay does not
    # serve passed its own tests.
    test "every admitted model carries passing evidence for BOTH tiers" do
      state = AdmissionCore.new(recorded_payload())

      for id <- AdmissionCore.admitted_ids(state) do
        record = Enum.find(state.models, &(&1["id"] == id))

        assert get_in(record, ["evidence", "tier1", "passed"]) == true,
               "#{id} is admitted without a passing tier 1"

        assert get_in(record, ["evidence", "tier2", "passed"]) == true,
               "#{id} is admitted without a passing tier 2"
      end
    end

    test "no model is admitted on an unrun or skipped tier" do
      state = AdmissionCore.new(recorded_payload())

      for record <- state.models do
        if get_in(record, ["evidence", "tier2", "skipped"]) == true do
          refute AdmissionCore.admitted_id?(state, record["id"]),
                 "#{record["id"]} is admitted despite a skipped tier 2"
        end
      end
    end

    test "UA-gated models stay rejected and never become admitted" do
      state = AdmissionCore.new(recorded_payload())
      rejected_ids = Enum.map(AdmissionCore.rejected(state), & &1["id"])

      # Arbor sends honest attribution rather than spoofing `opencode/latest`,
      # so the relay rate-limits these. Accepting the smaller list is the point.
      assert "big-pickle" in rejected_ids
      assert "mimo-v2.5-free" in rejected_ids

      refute AdmissionCore.admitted_id?(state, "big-pickle")
      refute AdmissionCore.admitted_id?(state, "mimo-v2.5-free")
      refute AdmissionCore.admitted_id?(state, "unknown-model")
    end

    test "every rejection records a machine-readable reason" do
      state = AdmissionCore.new(recorded_payload())

      for record <- AdmissionCore.rejected(state) do
        assert is_binary(record["reason"]) and record["reason"] != "",
               "#{record["id"]} is rejected without a reason"
      end
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
      assert listing =~ "Admitted models"
      assert listing =~ "Rejected"

      # Every rejection must show its recorded reason, whatever the reasons
      # currently are — not a specific one, which rotates with the catalog.
      for record <- AdmissionCore.rejected(AdmissionCore.new(recorded_payload())) do
        assert listing =~ record["reason"],
               "listing omits the recorded reason for #{record["id"]}"
      end
    end
  end

  describe "slug classification and tool-call probe" do
    test "free-suffix and unsuffixed rotating slots" do
      assert AdmissionCore.classify_slug("mimo-v2.5-free") == :free_suffix
      assert AdmissionCore.classify_slug("glm-4.6-flash") == :unsuffixed_slot
      assert AdmissionCore.classify_slug("") == :invalid
    end

    test "accepts the real OpenAI wire shape, where arguments is a JSON string" do
      # Verified live against opencode.ai/zen/v1 on 2026-08-23 — this is exactly
      # what ReqLLM surfaces for x-preview-f-free. Requiring is_map(arguments)
      # rejected every model that emits a correct tool call, so tier 1 could
      # never pass and no catalog could be honestly derived.
      assert AdmissionCore.well_formed_tool_call?(%{
               content_parts: [
                 %{
                   id: "call_-7323569051052013656",
                   name: "ping",
                   type: "function",
                   arguments: ~s({"note":"ok"}),
                   kind: :tool_call
                 }
               ]
             })
    end

    test "rejects a tool call whose arguments string is not a JSON object" do
      refute AdmissionCore.well_formed_tool_call?(%{
               content_parts: [%{kind: :tool_call, name: "ping", arguments: "not json"}]
             })

      refute AdmissionCore.well_formed_tool_call?(%{
               content_parts: [%{kind: :tool_call, name: "ping", arguments: "[1,2]"}]
             })
    end

    test "well-formed tool call requires name and map arguments" do
      assert AdmissionCore.well_formed_tool_call?(%{
               content_parts: [
                 %{kind: :tool_call, name: "file_read", arguments: %{"path" => "x"}}
               ]
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
    # The facade must agree with the core on whatever the catalog currently
    # holds — not on a fixed id list, which rotates with the free tier.
    assert OpenCodeZen.admitted_ids() ==
             AdmissionCore.admitted_ids(AdmissionCore.new(recorded_payload()))

    assert OpenCodeZen.listing() =~ "OpenCode Zen free tier — data disclosure"
    # Normalize whitespace before matching: the disclosure is hard-wrapped for
    # terminal display, so the phrase spans a line break ("such as file\n
    # contents and command output"). Assert the CONTENT, not the wrapping.
    normalized = String.replace(OpenCodeZen.disclosure_text(), ~r/\s+/, " ")
    assert normalized =~ "file contents and command output"
    assert normalized =~ "NO representations or guarantees"
    assert normalized =~ "sensitive, confidential, or regulated data"
  end

  test "every admitted model has a ModelProfile with its recorded context window" do
    for record <- OpenCodeZen.admitted() do
      id = record["id"]
      profile = Arbor.Common.ModelProfile.get(id)

      assert profile.context_size == record["context_window"],
             "missing or wrong ModelProfile for admitted model #{id}"
    end
  end

  test "Client.list_models for the free provider carries the disclosure on every entry" do
    # Listing exposes only ADMITTED models, so it is empty while the catalog has
    # none — assert the property that must hold for each entry, whatever the
    # rotating free tier currently admits.
    client = Arbor.LLM.Client.new(default_provider: "opencode_zen")
    models = Arbor.LLM.Client.list_models(client, provider: "opencode_zen")

    assert Enum.map(models, & &1.id) == OpenCodeZen.admitted_ids()

    for model <- models do
      assert model.disclosure =~ "sent to OpenCode's API"
      assert model.disclosure =~ "NO representations or guarantees"
      assert model.disclosure =~ "sensitive, confidential, or regulated data"
    end
  end
end
