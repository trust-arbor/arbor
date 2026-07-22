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

  test "pipeline registry matches the independent DOT constant-error registry" do
    dot_codes =
      dot_constant_outputs("error", failed_node_section()) ++
        (dot_constant_outputs("status", File.read!(dot_path()))
         |> Enum.filter(&(&1 == "pipeline_error")))

    assert MapSet.new(OutcomeMapper.pipeline_error_codes()) == MapSet.new(dot_codes)
  end

  test "every DOT constant status is a compatibility terminal or pipeline_error" do
    for status <- dot_constant_outputs("status", File.read!(dot_path())) do
      assert OutcomeMapper.terminal_status?(status) or status == "pipeline_error"
    end
  end

  test "review and capacity retry semantics avoid unnecessary worker restarts" do
    terminal_retries = %{
      "pr_failed" => "after_external_change",
      "review_failed" => "after_external_change",
      "validation_capacity_exceeded" => "after_external_change"
    }

    pipeline_retries = %{
      "committed_change_materialization_failed" => "after_external_change",
      "council_review_failed" => "after_external_change",
      "draft_pr_failed" => "after_external_change",
      "review_tier_invalid_or_missing" => "after_external_change"
    }

    for {status, retry} <- terminal_retries do
      assert {:ok, outcome} = OutcomeMapper.map_terminal(status, completed_evidence())
      assert outcome["retry"] == retry
    end

    for {code, retry} <- pipeline_retries do
      assert {:ok, outcome} = OutcomeMapper.map_pipeline_error(code, completed_evidence())
      assert outcome["retry"] == retry
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

  defp dot_path do
    Path.expand("../../../../priv/pipelines/coding-change-v1.dot", __DIR__)
  end

  defp failed_node_section do
    source = File.read!(dot_path())

    [section] =
      Regex.run(~r{(// Failed-node details.*?// Cleanup)}s, source, capture: :all_but_first)

    section
  end

  defp dot_constant_outputs(output_key, source) do
    source
    |> String.split("\n  ]\n")
    |> Enum.filter(fn block ->
      String.contains?(block, ~s(type="transform")) and
        String.contains?(block, ~s(transform="constant")) and
        String.contains?(block, ~s(output_key="#{output_key}"))
    end)
    |> Enum.map(fn block ->
      [_, expression] = Regex.run(~r/expression="([^"]+)"/, block)
      expression
    end)
  end
end
