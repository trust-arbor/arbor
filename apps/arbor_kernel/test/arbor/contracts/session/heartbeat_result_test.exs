defmodule Arbor.Contracts.Session.HeartbeatResultTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.LLM.TokenUsage
  alias Arbor.Contracts.Session.HeartbeatResult

  @moduletag :fast

  defp state, do: %{agent_id: "agent_test", session_id: "sess_test"}

  defp result(extra) do
    %{
      context:
        Map.merge(
          %{
            "session.cognitive_mode" => "diagnostic",
            "session.usage" => %{
              "input_tokens" => 1234,
              "output_tokens" => 567,
              "duration_ms" => 5940,
              "provider" => "openrouter",
              "model" => "trinity"
            }
          },
          extra
        )
    }
  end

  describe "from_result_ctx/2" do
    test "constructs typed struct from a heartbeat result context" do
      hr = HeartbeatResult.from_result_ctx(state(), result(%{}))

      assert hr.agent_id == "agent_test"
      assert hr.session_id == "sess_test"
      assert hr.cognitive_mode == "diagnostic"
      assert %TokenUsage{input_tokens: 1234, output_tokens: 567} = hr.usage
      assert hr.duration_ms == 5940
    end

    test "lifts list-shaped fields into typed list fields" do
      ctx = %{
        "session.actions" => [%{"type" => "monitor.read"}],
        "session.new_goals" => [%{"description" => "x"}],
        "session.memory_notes" => ["note"],
        "session.concerns" => ["c1", "c2"],
        "session.curiosity" => ["q1"],
        "session.identity_insights" => [%{"category" => "trait"}],
        "session.decompositions" => [%{"goal_id" => "g1"}],
        "session.proposal_decisions" => [%{"proposal_id" => "p1"}]
      }

      hr = HeartbeatResult.from_result_ctx(state(), result(ctx))

      assert length(hr.actions) == 1
      assert length(hr.new_goals) == 1
      assert hr.memory_notes == ["note"]
      assert hr.concerns == ["c1", "c2"]
      assert hr.curiosity == ["q1"]
      assert length(hr.identity_insights) == 1
      assert length(hr.decompositions) == 1
      assert length(hr.proposal_decisions) == 1
    end

    test "missing context produces a near-empty struct" do
      hr = HeartbeatResult.from_result_ctx(state(), nil)
      assert hr.agent_id == "agent_test"
      assert HeartbeatResult.empty?(hr)
    end

    test "thinking falls back to last_response" do
      ctx = %{"last_response" => "I am thinking"}
      hr = HeartbeatResult.from_result_ctx(state(), result(ctx))
      assert hr.thinking == "I am thinking"
    end
  end

  describe "to_signal_data/1" do
    test "produces a flat atom-keyed map with usage as a sub-map" do
      hr = HeartbeatResult.from_result_ctx(state(), result(%{}))
      data = HeartbeatResult.to_signal_data(hr)

      assert data.agent_id == "agent_test"
      assert data.cognitive_mode == "diagnostic"
      assert is_map(data.usage)
      assert data.usage.input_tokens == 1234
      assert data.usage.output_tokens == 567
    end

    test "computes goal_updates_count from updates + new_goals combined" do
      ctx = %{
        "session.goal_updates" => [%{"id" => "g1"}, %{"id" => "g2"}],
        "session.new_goals" => [%{"description" => "x"}]
      }

      hr = HeartbeatResult.from_result_ctx(state(), result(ctx))
      data = HeartbeatResult.to_signal_data(hr)
      assert data.goal_updates_count == 3
    end
  end

  describe "to_persistence/1" do
    test "produces flat scalar fields suitable for the event log" do
      hr = HeartbeatResult.from_result_ctx(state(), result(%{}))
      row = HeartbeatResult.to_persistence(hr)

      assert row.agent_id == "agent_test"
      assert row.duration_ms == 5940
      assert is_map(row.token_usage)
      assert row.token_usage.input_tokens == 1234
      assert row.actions_count == 0
    end
  end

  describe "to_telemetry/1" do
    test "produces a measurements map" do
      hr = HeartbeatResult.from_result_ctx(state(), result(%{}))
      tel = HeartbeatResult.to_telemetry(hr)
      assert tel.input_tokens == 1234
      assert tel.output_tokens == 567
    end
  end

  describe "empty?/1" do
    test "true when no thinking, no usage, no actions" do
      hr =
        HeartbeatResult.from_result_ctx(state(), %{
          context: %{}
        })

      assert HeartbeatResult.empty?(hr)
    end

    test "false when any LLM activity occurred" do
      hr = HeartbeatResult.from_result_ctx(state(), result(%{}))
      refute HeartbeatResult.empty?(hr)
    end
  end
end
