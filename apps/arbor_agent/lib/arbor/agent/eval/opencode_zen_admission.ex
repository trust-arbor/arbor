defmodule Arbor.Agent.Eval.OpenCodeZenAdmission do
  @moduledoc """
  Convert Arbor eval outcomes into OpenCode Zen admission records.

  Tier 1 is a mechanical well-formed tool-call check. Tier 2 is
  `mix arbor.eval.task`: a model that cannot tool-call never reaches a
  proposal, which is the admission criterion.
  """

  alias Arbor.LLM.OpenCodeZen.AdmissionCore

  @doc "Tier-1 evidence from a completion response."
  @spec tier1_from_response(term()) :: map()
  def tier1_from_response(response) do
    passed? = AdmissionCore.well_formed_tool_call?(response)

    %{
      passed: passed?,
      eval: "mechanical_tool_call",
      score: if(passed?, do: 1.0, else: 0.0),
      reason: if(passed?, do: nil, else: "response contained no well-formed tool call")
    }
  end

  @doc "Tier-2 evidence from a TaskEval trial map."
  @spec tier2_from_trial(map()) :: map()
  def tier2_from_trial(trial) when is_map(trial) do
    submitted? = Map.get(trial, :proposal_submitted) == true or Map.get(trial, "proposal_submitted") == true

    %{
      passed: submitted?,
      eval: "arbor.eval.task",
      score: if(submitted?, do: 1.0, else: 0.0),
      heartbeats_to_proposal:
        Map.get(trial, :heartbeats_to_proposal) || Map.get(trial, "heartbeats_to_proposal"),
      proposal_submitted: submitted?,
      reason: if(submitted?, do: nil, else: "no proposal submitted")
    }
  end

  @doc "Build a catalog record from the two-tier probe results."
  @spec record(String.t(), map(), map()) :: map()
  def record(id, tier1, tier2) when is_binary(id) do
    reason =
      cond do
        Map.get(tier1, :passed) != true -> "tier1_no_tool_call"
        Map.get(tier2, :passed) != true -> "tier2_no_proposal"
        true -> nil
      end

    AdmissionCore.record(id, %{tier1: tier1, tier2: tier2, reason: reason})
  end
end
