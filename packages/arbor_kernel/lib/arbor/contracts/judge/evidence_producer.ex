defmodule Arbor.Contracts.Judge.EvidenceProducer do
  @moduledoc """
  Behaviour for evidence producers.

  Evidence producers are deterministic checks that evaluate output quality
  without calling an LLM. They produce `Evidence` structs with scores
  and pass/fail results.

  ## Implementing

      defmodule MyProducer do
        @behaviour Arbor.Contracts.Judge.EvidenceProducer

        @impl true
        def name, do: :my_check

        @impl true
        def description, do: "Checks something specific about the output"

        @impl true
        def produce(subject, context, _opts) do
          score = # ... compute score ...
          {:ok, %Arbor.Contracts.Judge.Evidence{
            type: :my_check,
            score: score,
            passed: score >= 0.5,
            detail: "Details about the check",
            producer: __MODULE__
          }}
        end
      end

  ## Subject Map

  The `subject` map contains:
  - `:content` — the text/output being evaluated
  - `:perspective` — (optional) the perspective that produced it
  - `:metadata` — (optional) additional metadata

  ## Context Map

  The `context` map contains:
  - `:question` — the original question/prompt
  - `:reference_docs` — list of reference document paths
  - `:perspective_prompt` — the perspective's system prompt
  """

  alias Arbor.Contracts.Judge.Evidence

  @doc "Unique name for this producer (used as evidence type)."
  @callback name() :: atom()

  @doc "Human-readable description of what this producer checks."
  @callback description() :: String.t()

  @doc """
  Produce evidence by evaluating the subject in the given context.

  Returns `{:ok, Evidence.t()}` on success or `{:error, reason}` on failure.
  """
  @callback produce(subject :: map(), context :: map(), opts :: keyword()) ::
              {:ok, Evidence.t()} | {:error, term()}
end
