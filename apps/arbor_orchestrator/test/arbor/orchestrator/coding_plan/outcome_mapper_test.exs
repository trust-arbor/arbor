defmodule Arbor.Orchestrator.CodingPlan.OutcomeMapperTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Orchestrator.CodingPlan.OutcomeMapper
  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Graph

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
    {:ok, graph} = dot_path() |> File.read!() |> Parser.parse()

    dot_codes =
      dot_constant_outputs("error", failed_node_section()) ++
        directly_routed_pipeline_error_codes(graph) ++
        (dot_constant_outputs("status", File.read!(dot_path()))
         |> Enum.filter(&(&1 == "pipeline_error")))

    assert MapSet.new(OutcomeMapper.pipeline_error_codes()) == MapSet.new(dot_codes)
  end

  test "every constant error routed directly to pipeline_error is registered" do
    {:ok, graph} = dot_path() |> File.read!() |> Parser.parse()

    graph
    |> directly_routed_pipeline_error_codes()
    |> Enum.each(fn code ->
      assert OutcomeMapper.pipeline_error_code?(code),
             "DOT pipeline error #{inspect(code)} is absent from TaskOutcomeRegistry"
    end)
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

  test "blank projected provider session falls back to the worker message" do
    evidence =
      completed_evidence()
      |> Map.put("worker_provider_session_id", "")
      |> put_in(["worker_msg", "session_id"], "provider-session-from-message")

    assert {:ok, outcome} =
             OutcomeMapper.map_pipeline_error("worker_provider_account_exhausted", evidence)

    assert outcome["provider_session_id"] == "provider-session-from-message"
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

  defp directly_routed_pipeline_error_codes(graph) do
    graph.nodes
    |> Enum.flat_map(fn {node_id, node} ->
      attrs = node.attrs

      if attrs["transform"] == "constant" and attrs["output_key"] == "error" and
           directly_routes_to_pipeline_error?(graph, node_id) do
        [attrs["expression"]]
      else
        []
      end
    end)
    |> Enum.sort()
  end

  defp directly_routes_to_pipeline_error?(graph, node_id) do
    Enum.any?(Graph.outgoing_edges(graph, node_id), fn edge ->
      case Map.fetch(graph.nodes, edge.to) do
        {:ok, target} ->
          target.attrs["transform"] == "constant" and
            target.attrs["output_key"] == "status" and
            target.attrs["expression"] == "pipeline_error"

        :error ->
          false
      end
    end)
  end
end
