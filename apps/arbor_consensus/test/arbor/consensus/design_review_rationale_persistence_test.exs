defmodule Arbor.Consensus.DesignReviewRationalePersistenceTest do
  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Consensus
  alias Arbor.Consensus.ConsultationLog
  alias Arbor.Consensus.Evaluators.AdvisoryLLM
  alias Arbor.Consensus.TestHelpers

  @moduletag :database

  test "design rationale and malformed-response evidence survive the public consultation readback" do
    rationale =
      String.duplicate(
        "The design keeps side effects outside the pure core — a frozen requirement.\n",
        50
      )

    for {verdict, explanation, expected_vote} <- [
          {"approve", rationale, "approve"},
          {"rework", "The proposed core still performs IO, violating the pure-core requirement.",
           "reject"},
          {"approve", nil, "reject"}
        ] do
      proposal =
        TestHelpers.build_proposal(%{
          description: "Review the pure-core design",
          context: %{"evaluation_protocol" => "design_review"}
        })

      assert {:ok, run_id} =
               ConsultationLog.create_bound_run(proposal.description, [:security],
                 context: proposal.context
               )

      concerns = if verdict == "rework", do: ["Move IO into the imperative shell."], else: []
      response = %{"verdict" => verdict, "concerns" => concerns}
      response = if explanation, do: Map.put(response, "rationale", explanation), else: response
      payload = Jason.encode!(response)

      assert {:ok, evaluation} =
               AdvisoryLLM.evaluate(proposal, :security,
                 llm_fn: fn _, _ -> {:ok, payload} end,
                 consultation_id: run_id
               )

      # Read while the run is still running: observers need not wait for the
      # aggregate council to finish before inspecting this completed seat.
      assert {:ok, stored} = Consensus.get_consultation(run_id)
      assert stored.status == "running"
      assert [result] = stored.results
      assert result.actual == payload
      assert Jason.decode!(result.actual)["rationale"] == explanation
      assert result.scores["vote"] == expected_vote
      assert result.metadata["concerns"] == evaluation.concerns
      assert result.metadata["perspective"] == "security"

      if is_nil(explanation) do
        assert evaluation.concerns == [
                 "malformed design-review rationale: expected a non-empty string"
               ]
      end
    end
  end
end
