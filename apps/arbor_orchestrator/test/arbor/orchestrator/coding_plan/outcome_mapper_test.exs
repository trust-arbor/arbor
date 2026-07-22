defmodule Arbor.Orchestrator.CodingPlan.OutcomeMapperTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Orchestrator.CodingPlan.OutcomeMapper

  test "exhaustively maps every compatibility terminal" do
    for status <- OutcomeMapper.terminal_statuses() do
      assert {:ok, outcome} = OutcomeMapper.map_terminal(status, completed_evidence())
      assert outcome["code"] == status
      assert OutcomeMapper.valid?(outcome)
      assert OutcomeMapper.compatible_with_status?(outcome, status)
    end
  end

  test "exhaustively maps every registered pipeline error code" do
    for code <- OutcomeMapper.pipeline_error_codes() do
      assert {:ok, outcome} = OutcomeMapper.map_pipeline_error(code, completed_evidence())
      assert outcome["code"] == code
      assert OutcomeMapper.valid?(outcome)
    end
  end

  test "missing stop reason fails closed as invalid terminal evidence" do
    evidence = put_in(completed_evidence(), ["worker_msg"], %{"delivery_status" => "delivered"})

    assert {:error, outcome} = OutcomeMapper.map_terminal("change_committed", evidence)
    assert outcome["code"] == "invalid_terminal_evidence"
  end

  test "unconfirmed delivery fails closed as invalid terminal evidence" do
    evidence = put_in(completed_evidence(), ["worker_msg", "delivery_status"], "delivery_unknown")

    assert {:error, outcome} = OutcomeMapper.map_terminal("change_committed", evidence)
    assert outcome["code"] == "invalid_terminal_evidence"
  end

  test "provider account exhaustion remains distinct" do
    evidence =
      put_in(
        completed_evidence(),
        ["worker_msg", "delivery_status"],
        "provider_account_exhausted"
      )

    assert {:ok, outcome} = OutcomeMapper.map_pipeline_error(nil, evidence)
    assert outcome["code"] == "worker_provider_account_exhausted"
  end

  test "requested and confirmed model mismatch remains distinct" do
    evidence = put_in(completed_evidence(), ["worker_status", "model"], "confirmed-model")

    assert {:ok, outcome} =
             OutcomeMapper.map_terminal("change_committed", evidence,
               requested_model: "requested-model"
             )

    assert outcome["code"] == "worker_model_mismatch"
    assert outcome["requested_model"] == "requested-model"
    assert outcome["confirmed_model"] == "confirmed-model"
  end

  test "unknown pipeline code fails closed" do
    assert {:ok, outcome} = OutcomeMapper.map_pipeline_error("unknown_code", completed_evidence())
    assert outcome["code"] == "invalid_terminal_evidence"
  end

  test "malformed outcomes are rejected" do
    refute OutcomeMapper.valid?(%{"code" => "change_committed"})
    refute OutcomeMapper.valid?(%{"version" => 1, "code" => "change_committed", :bad => true})
  end

  defp completed_evidence do
    %{
      "worker_session_id" => "worker-1",
      "worker_provider_session_id" => "provider-session-1",
      "worker" => %{"provider" => "codex", "model" => "requested-model"},
      "worker_status" => %{
        "worker_session_id" => "worker-1",
        "provider" => "codex",
        "model" => "requested-model",
        "session_id" => "provider-session-1"
      },
      "worker_msg" => %{
        "delivery_status" => "delivered",
        "stop_reason" => "end_turn",
        "session_id" => "provider-session-1"
      }
    }
  end
end
