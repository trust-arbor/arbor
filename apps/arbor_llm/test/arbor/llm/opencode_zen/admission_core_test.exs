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
    test "every admitted model carries a PASSING tier 1" do
      # Policy (2026-08-24): admission requires a passing tier 1 and the absence
      # of a tier-2 FAILURE. Tier 2 not having run is permissive; the gate is a
      # quality filter over the keyless tier Arbor picked for the user, not a
      # security boundary, and one that admits nothing protects no one.
      state = AdmissionCore.new(recorded_payload())

      for id <- AdmissionCore.admitted_ids(state) do
        record = Enum.find(state.models, &(&1["id"] == id))

        assert get_in(record, ["evidence", "tier1", "passed"]) == true,
               "#{id} is admitted without a passing tier 1"
      end
    end

    test "a model whose tier 2 was MEASURED AND FAILED is never admitted" do
      # The distinction that must not collapse: "not tested yet" is permissive,
      # "tested and failed" is permanent rejection.
      state =
        AdmissionCore.new(%{
          "models" => [
            %{
              "id" => "failed-tier2",
              "evidence" => %{
                "tier1" => %{"passed" => true},
                "tier2" => %{"passed" => false}
              }
            },
            %{
              "id" => "untested-tier2",
              "evidence" => %{
                "tier1" => %{"passed" => true},
                "tier2" => %{"passed" => false, "skipped" => true}
              }
            }
          ]
        })

      refute AdmissionCore.admitted_id?(state, "failed-tier2")
      assert AdmissionCore.admitted_id?(state, "untested-tier2")
      assert AdmissionCore.evidence_level(hd(state.models)) == :tier1_only
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
      # A vendor (or a hopeful author) writing status=admitted is not evidence.
      # No tier 1 means no admission, whatever the status field claims.
      state =
        AdmissionCore.new(%{
          "models" => [
            %{
              "id" => "vendor-claimed-free",
              "status" => "admitted",
              "evidence" => %{}
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

      # The relay publishes no context window, and inventing one is exactly the
      # defect this catalog exists to prevent — so a record may legitimately
      # omit it and rely on ModelProfile's conservative default. Assert the
      # match only where a window was actually recorded.
      case record["context_window"] do
        nil ->
          assert is_integer(profile.context_size) and profile.context_size > 0,
                 "ModelProfile default must still yield a usable window for #{id}"

        recorded ->
          assert profile.context_size == recorded,
                 "wrong ModelProfile context window for admitted model #{id}"
      end
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
