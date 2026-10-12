defmodule Arbor.Actions.Session.ProcessResultsCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Session.ProcessResultsCore, as: Core

  @moduletag :fast

  @empty_fields %{
    actions: [],
    goal_updates: [],
    new_goals: [],
    memory_notes: [],
    concerns: [],
    curiosity: [],
    decompositions: [],
    new_intents: [],
    proposal_decisions: [],
    identity_insights: [],
    proposals: [],
    fix_proposal: nil
  }

  defp failed(raw, opts \\ []) do
    core = Core.new(raw, opts)
    assert core.status == :parse_failed
    assert Core.parse_failed?(core)
    assert Core.fields(core) == @empty_fields
    core.reason
  end

  describe "new/2 — parse failures are classified, never mistaken for idle" do
    test "blank replies are :empty" do
      assert failed("") == :empty
      assert failed("   \n\t ") == :empty
      assert failed(nil) == :empty
      assert failed("```json\n\n```") == :empty
    end

    test "text that does not decode is :not_json" do
      assert failed("I have nothing to do this cycle.") == :not_json
      # Prose-wrapped JSON: extraction is strict, so it is a failure, not idle.
      assert failed(~s(Here is my reply: {"actions": []})) == :not_json
      # Truncated object (e.g. the reply ran out of max_tokens).
      assert failed(~s({"thinking": "long", "actions": [{"type": "file.re)) == :not_json
      assert failed(%{"actions" => []}) == :not_json
    end

    test "valid JSON whose top level is not an object is :no_json_object" do
      assert failed(~s([{"type": "file.read"}])) == :no_json_object
      assert failed(~s("just a string")) == :no_json_object
      assert failed("42") == :no_json_object
      assert failed("null") == :no_json_object
    end

    test "a JSON object without any contract key is :invalid_shape" do
      assert failed(~s({"response": "hello"})) == :invalid_shape
      assert failed("{}") == :invalid_shape
      assert failed(~s({"consolidated": true})) == :invalid_shape
    end

    test "records the reply size for the log line and signal" do
      assert Core.new("not json").reply_bytes == 8
      assert Core.new(nil).reply_bytes == 0
    end
  end

  describe "new/2 — parsed replies" do
    test "a reply with only empty arrays is a genuinely idle, parsed reply" do
      core =
        Core.new(
          Jason.encode!(%{"thinking" => "all quiet", "actions" => [], "memory_notes" => []})
        )

      assert core.status == :parsed
      assert core.reason == nil
      assert core.rejected_fields == []
      assert Core.fields(core) == @empty_fields
    end

    test "an object holding only a prompt-only contract key still parses" do
      assert Core.new(~s({"thinking": "nothing new"})).status == :parsed
      assert Core.new(~s({"cognitive_mode": "reflection"})).status == :parsed
    end

    test "fenced JSON parses" do
      core = Core.new(~s(```json\n{"actions": [{"type": "file.read"}]}\n```))
      assert core.status == :parsed
      assert [%{"type" => "file.read"}] = Core.fields(core).actions
    end

    test "a reply with actions extracts them" do
      core =
        Core.new(
          Jason.encode!(%{
            "actions" => [%{"type" => "file.read", "params" => %{"path" => "a"}}],
            "concerns" => ["c1"]
          })
        )

      assert core.status == :parsed
      assert Core.fields(core).actions == [%{"type" => "file.read", "params" => %{"path" => "a"}}]
      assert Core.fields(core).concerns == ["c1"]
    end

    test "malformed contract fields are named while the valid items survive" do
      core =
        Core.new(
          Jason.encode!(%{
            "actions" => [%{"no_type" => true}, %{"type" => "valid"}],
            "memory_notes" => "should be a list",
            "concerns" => ["ok"],
            "goal_updates" => nil
          })
        )

      assert core.status == :parsed
      assert core.rejected_fields == ["actions", "memory_notes"]
      assert Core.fields(core).actions == [%{"type" => "valid"}]
      assert Core.fields(core).memory_notes == []
      assert Core.fields(core).concerns == ["ok"]
    end

    test "an actions object instead of a list runs nothing and is named" do
      core = Core.new(Jason.encode!(%{"actions" => %{"type" => "shell.execute"}}))

      assert core.status == :parsed
      assert core.rejected_fields == ["actions"]
      assert Core.fields(core).actions == []
    end
  end

  describe "new/2 — modes without an LLM call" do
    test "consolidation's own action output is :no_reply, not a parse failure" do
      consolidate_output =
        Jason.encode!(%{
          "consolidated" => true,
          "consolidation_kg" => %{},
          "consolidation_identity" => %{}
        })

      for mode <- ["consolidation", :consolidation] do
        core = Core.new(consolidate_output, cognitive_mode: mode)
        assert core.status == :no_reply
        assert core.reason == nil
        refute Core.parse_failed?(core)
        assert Core.fields(core) == @empty_fields
      end
    end

    test "a heartbeat object in consolidation mode still parses" do
      core = Core.new(~s({"actions": [{"type": "memory.read"}]}), cognitive_mode: "consolidation")
      assert core.status == :parsed
      assert [%{"type" => "memory.read"}] = Core.fields(core).actions
    end

    test "LLM modes keep failures visible" do
      for mode <- ["reflection", "goal_pursuit", "plan_execution", nil] do
        assert failed("prose", cognitive_mode: mode) == :not_json
      end
    end
  end

  describe "show/1" do
    test "is JSON-clean and carries the parse outcome next to the fields" do
      failed = Core.show(Core.new("not json"))

      assert failed.parse_status == "parse_failed"
      assert failed.parse_error == "not_json"
      assert failed.parse_rejected_fields == []
      assert failed.actions == []
      assert {:ok, _json} = Jason.encode(failed)

      parsed = Core.show(Core.new(~s({"actions": []})))
      assert parsed.parse_status == "parsed"
      assert parsed.parse_error == nil

      no_reply = Core.show(Core.new(~s({"consolidated": true}), cognitive_mode: "consolidation"))
      assert no_reply.parse_status == "no_reply"
      assert no_reply.parse_error == nil
    end
  end

  describe "preview" do
    test "is bounded, single-line and valid UTF-8" do
      raw = String.duplicate("word \n", 5_000) <> <<0xFF, 0xFE>>
      preview = raw |> Core.preview_window() |> Core.truncate_preview()

      assert String.valid?(preview)
      refute preview =~ "\n"
      assert String.length(preview) <= 163
      assert String.ends_with?(preview, "...")
    end

    test "short replies pass through, non-binaries preview as empty" do
      assert "hi there" == "  hi\n there " |> Core.preview_window() |> Core.truncate_preview()
      assert Core.preview_window(nil) == ""
    end
  end

  test "functional core contains no impurity" do
    source =
      File.read!(
        Path.expand("../../../../lib/arbor/actions/session/process_results_core.ex", __DIR__)
      )

    for forbidden <- [
          "Logger.",
          "Arbor.Signals",
          ":telemetry",
          "File.",
          "System.",
          "Application.",
          "GenServer.",
          "Process.",
          ":ets.",
          "DateTime.utc_now",
          "make_ref",
          ":rand.",
          "strong_rand_bytes",
          "String.to_atom",
          "IO."
        ] do
      refute source =~ forbidden, "process results core must not call #{forbidden}"
    end
  end
end
