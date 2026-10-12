defmodule Arbor.Actions.SessionProcessResultsParseStatusTest do
  @moduledoc """
  Regression (Imp review 2026-09-27, D1): a heartbeat reply that fails to parse
  must be distinguishable from a genuinely idle heartbeat.

  Before the fix `Session.ProcessResults` answered every unparseable reply with
  `{:ok, all-empty}` and no log, which is exactly what an idle agent's parsed
  reply produces. The failure still runs no actions (fail closed); these tests
  pin that it is now also marked (`parse_status`), logged with a bounded,
  redacted preview, and signalled.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.Actions.Session.ProcessResults

  @moduletag :fast

  defp run!(raw, extra \\ %{}, context \\ %{}) do
    assert {:ok, result} = ProcessResults.run(Map.put(extra, "last_response", raw), context)
    result
  end

  defp assert_runs_nothing(result) do
    assert result.actions == []
    assert result.decompositions == []
    assert result.new_intents == []
    assert result.goal_updates == []
    assert result.new_goals == []
    assert result.proposal_decisions == []
    assert result.identity_insights == []
    assert result.proposals == []
    assert result.fix_proposal == nil
  end

  describe "parse failure vs idle" do
    test "a non-JSON reply runs no actions and is marked parse_failed, not idle" do
      log =
        capture_log(fn ->
          result = run!("I looked around and decided to read lib/foo.ex.")

          assert_runs_nothing(result)
          assert result.parse_status == "parse_failed"
          assert result.parse_error == "not_json"
        end)

      assert log =~ "heartbeat reply did not parse (not_json)"
      assert log =~ "no actions will run"
    end

    test "valid JSON without the heartbeat object is marked parse_failed" do
      capture_log(fn ->
        array = run!(~s([{"type": "file.read", "params": {"path": "lib/foo.ex"}}]))
        assert_runs_nothing(array)
        assert array.parse_status == "parse_failed"
        assert array.parse_error == "no_json_object"

        wrong_object = run!(~s({"response": "I will read lib/foo.ex"}))
        assert_runs_nothing(wrong_object)
        assert wrong_object.parse_status == "parse_failed"
        assert wrong_object.parse_error == "invalid_shape"
      end)
    end

    test "an empty reply (e.g. exhausted reasoning budget) is marked parse_failed" do
      capture_log(fn ->
        result = run!("")
        assert_runs_nothing(result)
        assert result.parse_status == "parse_failed"
        assert result.parse_error == "empty"
      end)
    end

    test "valid JSON with empty arrays is a genuinely idle heartbeat: parsed, no error" do
      log =
        capture_log(fn ->
          result =
            run!(
              Jason.encode!(%{
                "thinking" => "Nothing needs attention.",
                "actions" => [],
                "memory_notes" => [],
                "goal_updates" => []
              })
            )

          assert_runs_nothing(result)
          assert result.parse_status == "parsed"
          assert result.parse_error == nil
          assert result.parse_rejected_fields == []
        end)

      refute log =~ "did not parse"
    end

    test "a valid reply with actions and intents parses and extracts them" do
      result =
        run!(
          Jason.encode!(%{
            "actions" => [%{"type" => "file.read", "params" => %{"path" => "lib/foo.ex"}}],
            "new_intents" => [%{"action" => "file.read"}],
            "decompositions" => [%{"goal_id" => "g1", "intentions" => []}]
          })
        )

      assert result.parse_status == "parsed"
      assert result.parse_error == nil
      assert [%{"type" => "file.read"}] = result.actions
      assert [%{"action" => "file.read"}] = result.new_intents
      assert [%{"goal_id" => "g1"}] = result.decompositions
    end

    test "consolidation's own action output is no_reply, not a parse failure" do
      consolidate_output =
        Jason.encode!(%{
          "consolidated" => true,
          "consolidation_kg" => %{},
          "consolidation_identity" => %{}
        })

      log =
        capture_log(fn ->
          result = run!(consolidate_output, %{"cognitive_mode" => "consolidation"})
          assert_runs_nothing(result)
          assert result.parse_status == "no_reply"
          assert result.parse_error == nil
        end)

      refute log =~ "did not parse"
    end
  end

  describe "visibility" do
    test "the log preview is bounded and redacted, never the full reply" do
      secret = "AKIA" <> "IOSFODNN7EXAMPLE"
      tail = "TAIL-MARKER-#{System.unique_integer([:positive])}"
      raw = "Sure! key=#{secret} " <> String.duplicate("filler ", 400) <> tail

      log = capture_log(fn -> run!(raw) end)

      assert log =~ "heartbeat reply did not parse (not_json)"
      assert log =~ "bytes=#{byte_size(raw)}"
      refute log =~ secret
      refute log =~ tail
    end

    test "emits agent.heartbeat_parse_failed with the reason and no reply content" do
      agent_id = "agent_parse_#{System.unique_integer([:positive])}"
      test_pid = self()

      {:ok, sub_id} =
        Arbor.Signals.subscribe("agent.heartbeat_parse_failed", fn signal ->
          if signal.data[:agent_id] == agent_id, do: send(test_pid, {:parse_failed, signal.data})
          :ok
        end)

      on_exit(fn -> Arbor.Signals.unsubscribe(sub_id) end)

      capture_log(fn ->
        run!("not json at all", %{"cognitive_mode" => "reflection"}, %{agent_id: agent_id})
      end)

      assert_receive {:parse_failed, data}, 1_000
      assert data.reason == "not_json"
      assert data.cognitive_mode == "reflection"
      assert data.reply_bytes == byte_size("not json at all")
      refute Map.has_key?(data, :preview)
    end

    test "a parsed reply emits no parse-failure signal" do
      agent_id = "agent_parse_ok_#{System.unique_integer([:positive])}"
      test_pid = self()

      {:ok, sub_id} =
        Arbor.Signals.subscribe("agent.heartbeat_parse_failed", fn signal ->
          if signal.data[:agent_id] == agent_id, do: send(test_pid, :unexpected_signal)
          :ok
        end)

      on_exit(fn -> Arbor.Signals.unsubscribe(sub_id) end)

      run!(~s({"actions": []}), %{}, %{agent_id: agent_id})
      refute_receive :unexpected_signal, 200
    end
  end
end
