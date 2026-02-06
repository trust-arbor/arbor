defmodule Arbor.Contracts.Consensus.Evaluator do
  @moduledoc """
  Behaviour for self-describing evaluator agents.

  Self-describing evaluator agents that can be consulted directly without
  needing routing infrastructure. Each evaluator declares its own identity,
  perspectives, and strategy.

  ## Callbacks

  Required:
  - `name/0` — unique atom identifying this evaluator
  - `perspectives/0` — list of perspective atoms this evaluator can assess from
  - `evaluate/3` — assess a proposal from a given perspective

  Optional:
  - `strategy/0` — how this evaluator works (`:llm`, `:rule_based`, `:deterministic`, `:hybrid`)

  ## Example

      defmodule MyApp.SecurityEvaluator do
        @behaviour Arbor.Contracts.Consensus.Evaluator

        @impl true
        def name, do: :security_advisor

        @impl true
        def perspectives, do: [:vulnerability_scan, :threat_model, :compliance]

        @impl true
        def evaluate(proposal, perspective, opts) do
          # ... return {:ok, Evaluation.t()} or {:error, term()}
        end

        @impl true
        def strategy, do: :hybrid
      end
  """

  alias Arbor.Contracts.Consensus.{Evaluation, Proposal}

  @doc "Unique name identifying this evaluator."
  @callback name() :: atom()

  @doc "Perspectives this evaluator can assess from."
  @callback perspectives() :: [atom()]

  @doc "Evaluate a proposal from a given perspective."
  @callback evaluate(proposal :: Proposal.t(), perspective :: atom(), opts :: keyword()) ::
              {:ok, Evaluation.t()} | {:error, term()}

  @doc "Strategy this evaluator uses (`:llm`, `:rule_based`, `:deterministic`, `:hybrid`)."
  @callback strategy() :: :llm | :rule_based | :deterministic | :hybrid

  @optional_callbacks [strategy: 0]
end
