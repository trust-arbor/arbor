defmodule Arbor.Consensus.EvaluatorBackend do
  @moduledoc """
  Behaviour for pluggable evaluator backends.

  The evaluator backend is responsible for assessing a proposal from
  a given perspective. The default implementation (`RuleBased`) uses
  heuristic rules. Host apps can provide LLM-based backends.

  ## Example Implementation

      defmodule MyApp.LLMEvaluator do
        @behaviour Arbor.Consensus.EvaluatorBackend

        @impl true
        def evaluate(proposal, perspective, opts) do
          # Call your LLM here
          {:ok, evaluation}
        end
      end

  Then configure the coordinator:

      Arbor.Consensus.submit(proposal,
        evaluator_backend: MyApp.LLMEvaluator
      )
  """

  alias Arbor.Contracts.Autonomous.{Evaluation, Proposal}

  @doc """
  Evaluate a proposal from a given perspective.

  Returns a sealed `Evaluation.t()` struct on success.
  """
  @callback evaluate(
              proposal :: Proposal.t(),
              perspective :: atom(),
              opts :: keyword()
            ) :: {:ok, Evaluation.t()} | {:error, term()}
end
