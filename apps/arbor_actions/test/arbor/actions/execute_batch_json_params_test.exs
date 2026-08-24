defmodule Arbor.Actions.ExecuteBatchJsonParamsTest do
  @moduledoc """
  Heartbeat ProcessResults decodes LLM JSON with string keys. execute_batch
  used to pass those params straight into File.Read.run/2, which only matched
  `%{path: path}`. The FunctionClauseError aborted the whole batch; the
  SessionMemory bridge swallowed it to `[]`; followup became "No action results."
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  test "JSON-shaped file.read does not crash the batch" do
    spec = %{
      "type" => "file.read",
      "params" => %{"path" => "/tmp/arbor_eval_json_batch_missing.ex"}
    }

    # Direct action: the FunctionClauseError lived here, before execute_batch
    # wrapping. Authorization may still fail the batch for an unprovisioned
    # agent; the run/2 clause must not.
    assert {:error, message} =
             Arbor.Actions.File.Read.run(
               %{"path" => "/tmp/arbor_eval_json_batch_missing.ex"},
               %{}
             )

    assert is_binary(message)
    refute message =~ "FunctionClauseError"

    assert [{^spec, result}] =
             Arbor.Actions.execute_batch([spec], agent_id: "agent_test_json_batch")

    assert match?({:ok, _}, result) or match?({:error, _}, result)
    refute match?({:error, {:action_crashed, _}}, result)
    refute inspect(result) =~ "FunctionClauseError"
  end

  test "top-level path is lifted into params" do
    spec = %{"type" => "file.read", "path" => "/tmp/arbor_eval_json_batch_missing.ex"}

    assert [{^spec, result}] =
             Arbor.Actions.execute_batch([spec], agent_id: "agent_test_json_batch")

    assert match?({:ok, _}, result) or match?({:error, _}, result)
    refute match?({:error, {:action_crashed, _}}, result)
  end

  test "a missing path is an action error, not a batch crash" do
    spec = %{"type" => "file.read", "params" => %{}}

    assert [{^spec, {:error, _reason}}] =
             Arbor.Actions.execute_batch([spec], agent_id: "agent_test_json_batch")
  end
end
