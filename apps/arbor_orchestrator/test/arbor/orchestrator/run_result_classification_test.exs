defmodule Arbor.Orchestrator.RunResultClassificationTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.Engine.Outcome

  @moduletag :fast

  test "only a successful typed Engine outcome is complete" do
    assert {:ok, :success} = Orchestrator.classify_run_result(result(:success))

    for status <- [:partial_success, :fail, :retry, :skipped] do
      assert {:error, {:pipeline_outcome, ^status}} =
               Orchestrator.classify_run_result(result(status))
    end
  end

  test "absent, arbitrary and malformed outcomes never establish completion" do
    for result <- [
          nil,
          %{},
          %{status: :completed},
          %{run_id: "r", completed_nodes: [], context: %{}, final_outcome: %{status: :success}},
          %{result(:success) | final_outcome: nil},
          result(:unknown),
          %{result(:success) | run_id: nil}
        ] do
      assert {:error, :invalid_run_result} = Orchestrator.classify_run_result(result)
    end
  end

  defp result(status) do
    %{
      run_id: "classification-test",
      completed_nodes: ["start", "done"],
      context: %{},
      final_outcome: %Outcome{status: status}
    }
  end
end
