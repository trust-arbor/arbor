defmodule Arbor.Consensus.Evaluators.Consult do
  @moduledoc """
  Convenience module for consulting evaluator agents directly.

  Instead of routing through a Coordinator, you pick an evaluator
  and ask it questions. You are the Coordinator — the evaluator
  provides analysis, you make decisions.

  ## Examples

      alias Arbor.Consensus.Evaluators.{AdvisoryLLM, Consult}

      # Ask all perspectives
      {:ok, results} = Consult.ask(AdvisoryLLM, "Should caching use Redis or ETS?",
        context: %{constraints: "must survive restarts"}
      )

      Enum.each(results, fn {perspective, eval} ->
        IO.puts("=== \#{perspective} ===")
        IO.puts(eval.reasoning)
      end)

      # Ask a single perspective
      {:ok, eval} = Consult.ask_one(AdvisoryLLM, "How should TopicMatcher work?", :design_review,
        context: %{options: ["pattern matching", "LLM classification", "hybrid"]}
      )
  """

  alias Arbor.Contracts.Consensus.Proposal

  @default_timeout 120_000

  @doc """
  Ask an evaluator all its perspectives about a question.

  Builds a lightweight advisory proposal from the description and context,
  evaluates from each perspective in parallel, and returns the collected results.

  ## Options

  - `:context` — map of additional context for the evaluator (default: `%{}`)
  - `:timeout` — per-perspective timeout in ms (default: 120_000)
  - `:ai_module` — override the AI module (useful for testing)

  Returns `{:ok, [{perspective, evaluation}]}` sorted by perspective,
  or `{:error, reason}` if proposal creation fails.
  """
  @spec ask(module(), String.t(), keyword()) ::
          {:ok, [{atom(), Arbor.Contracts.Consensus.Evaluation.t()}]} | {:error, term()}
  def ask(evaluator_module, description, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, proposal} <- build_advisory_proposal(description, context) do
      perspectives = evaluator_module.perspectives()
      eval_opts = Keyword.drop(opts, [:context])

      results =
        perspectives
        |> Enum.map(fn perspective ->
          Task.async(fn ->
            {perspective, evaluator_module.evaluate(proposal, perspective, eval_opts)}
          end)
        end)
        |> Task.await_many(timeout + 5_000)
        |> Enum.map(fn
          {perspective, {:ok, evaluation}} -> {perspective, evaluation}
          {perspective, {:error, reason}} -> {perspective, {:error, reason}}
        end)
        |> Enum.sort_by(fn {perspective, _} -> perspective end)

      {:ok, results}
    end
  end

  @doc """
  Ask an evaluator a single perspective about a question.

  Like `ask/3` but for one perspective only — no parallel tasks.

  ## Options

  Same as `ask/3`.
  """
  @spec ask_one(module(), String.t(), atom(), keyword()) ::
          {:ok, Arbor.Contracts.Consensus.Evaluation.t()} | {:error, term()}
  def ask_one(evaluator_module, description, perspective, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    eval_opts = Keyword.drop(opts, [:context])

    with {:ok, proposal} <- build_advisory_proposal(description, context) do
      evaluator_module.evaluate(proposal, perspective, eval_opts)
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp build_advisory_proposal(description, context) do
    Proposal.new(%{
      proposer: "human",
      change_type: :advisory,
      description: description,
      target_layer: 4,
      context: context
    })
  end
end
