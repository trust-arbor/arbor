defmodule Arbor.Actions.Council do
  @moduledoc """
  Advisory council consultation operations as Jido actions.

  This module provides Jido-compatible actions for consulting the advisory
  council. Actions wrap the underlying `Consult.ask/3` and `Consult.ask_one/4`
  APIs with capability-based authorization and signal emission for observability.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Consult` | Query all perspectives in parallel |
  | `ConsultOne` | Query a single perspective |

  ## Architecture

  The advisory council provides design feedback from multiple perspectives
  (brainstorming, security, stability, etc.). Each consultation is an LLM
  call that may span multiple providers for model diversity.

  ## Examples

      # Ask all perspectives
      {:ok, result} = Arbor.Actions.Council.Consult.run(
        %{question: "Should caching use Redis or ETS?"},
        %{}
      )
      result.responses  # => [{:brainstorming, eval}, {:security, eval}, ...]

      # Ask a single perspective
      {:ok, result} = Arbor.Actions.Council.ConsultOne.run(
        %{
          question: "Is this design secure?",
          perspective: :security
        },
        %{}
      )
      result.reasoning  # => "The design follows capability-based..."

  ## Authorization

  - Consult: `arbor://actions/execute/council.consult`
  - ConsultOne: `arbor://actions/execute/council.consult_one`
  """

  alias Arbor.Common.SafeAtom

  # Perspectives available in AdvisoryLLM
  @allowed_perspectives [
    :brainstorming,
    :user_experience,
    :security,
    :privacy,
    :stability,
    :capability,
    :emergence,
    :vision,
    :performance,
    :generalization,
    :resource_usage,
    :consistency
  ]

  defmodule Consult do
    @moduledoc """
    Query all advisory council perspectives in parallel.

    Builds a lightweight advisory proposal from the question and context,
    then queries all perspectives from the evaluator module. Returns collected
    responses with metadata about the consultation.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `question` | string | yes | The question to consult on |
    | `context` | map | no | Additional context for perspectives (default: %{}) |
    | `timeout` | non_neg_integer | no | Per-perspective timeout in ms (default: 180_000) |
    | `evaluator` | atom | no | Evaluator module (default: AdvisoryLLM) |

    ## Returns

    - `responses` - List of `{perspective, evaluation}` tuples
    - `perspective_count` - Number of perspectives queried
    - `response_count` - Number of successful responses
    - `duration_ms` - Total consultation time
    - `question_topic` - The question (for logging)
    """

    use Jido.Action,
      name: "council_consult",
      description: "Query all advisory council perspectives about a question",
      category: "council",
      tags: ["council", "advisory", "consult", "llm"],
      schema: [
        question: [
          type: :string,
          required: true,
          doc: "The question to consult on"
        ],
        context: [
          type: :map,
          default: %{},
          doc: "Additional context for perspectives"
        ],
        timeout: [
          type: :non_neg_integer,
          default: 180_000,
          doc: "Per-perspective timeout in ms"
        ],
        evaluator: [
          type: :atom,
          default: Arbor.Consensus.Evaluators.AdvisoryLLM,
          doc: "Evaluator module to use"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Consensus.Evaluators.Consult, as: ConsultAPI

    @doc """
    Taint roles for this action's parameters.

    - `question` is `:control` because it determines what the council evaluates
    - `context` is `:data` because it's passed through to perspectives
    - `timeout` is `:data` because it's a numeric configuration value
    - `evaluator` is `:control` because it determines which evaluator runs
    """
    def taint_roles do
      %{
        question: :control,
        context: :data,
        timeout: :data,
        evaluator: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, _context) do
      question = params[:question]
      ctx = params[:context] || %{}
      timeout = params[:timeout] || 180_000
      evaluator = params[:evaluator] || Arbor.Consensus.Evaluators.AdvisoryLLM

      # Extract a topic from the question for signal metadata (first 100 chars)
      question_topic = String.slice(question, 0, 100)

      Actions.emit_started(__MODULE__, %{
        question_topic: question_topic,
        evaluator: evaluator
      })

      start_time = System.monotonic_time(:millisecond)

      case ConsultAPI.ask(evaluator, question, context: ctx, timeout: timeout) do
        {:ok, responses} ->
          duration_ms = System.monotonic_time(:millisecond) - start_time
          perspective_count = length(evaluator.perspectives())

          {successful, failed} =
            Enum.split_with(responses, fn
              {_perspective, %{} = _eval} -> true
              {_perspective, {:error, _}} -> false
              _ -> true
            end)

          response_count = length(successful)

          result = %{
            responses: responses,
            perspective_count: perspective_count,
            response_count: response_count,
            duration_ms: duration_ms,
            question_topic: question_topic
          }

          completed_metadata =
            build_completed_metadata(
              perspective_count,
              response_count,
              duration_ms,
              question_topic,
              failed
            )

          Actions.emit_completed(__MODULE__, completed_metadata)

          {:ok, result}

        {:error, reason} = error ->
          Actions.emit_failed(__MODULE__, %{
            question_topic: question_topic,
            reason: inspect(reason)
          })

          error
      end
    end

    defp build_completed_metadata(
           perspective_count,
           response_count,
           duration_ms,
           question_topic,
           failed
         ) do
      base = %{
        perspective_count: perspective_count,
        response_count: response_count,
        duration_ms: duration_ms,
        question_topic: question_topic
      }

      maybe_add_failures(base, failed)
    end

    defp maybe_add_failures(metadata, []), do: metadata

    defp maybe_add_failures(metadata, failed) do
      failed_info =
        Enum.map(failed, fn {perspective, {:error, reason}} ->
          {perspective, inspect(reason)}
        end)

      Map.put(metadata, :failed_perspectives, failed_info)
    end
  end

  defmodule ConsultOne do
    @moduledoc """
    Query a single advisory council perspective.

    Like `Consult`, but queries only one perspective. Useful for targeted
    questions where you know which lens to apply (e.g., asking `:security`
    about authentication design).

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `question` | string | yes | The question to consult on |
    | `perspective` | atom | yes | The perspective to query |
    | `context` | map | no | Additional context (default: %{}) |
    | `timeout` | non_neg_integer | no | Timeout in ms (default: 180_000) |
    | `evaluator` | atom | no | Evaluator module (default: AdvisoryLLM) |

    ## Returns

    - `evaluation` - The evaluation struct from the perspective
    - `perspective` - The perspective that was queried
    - `duration_ms` - Consultation time
    - `question_topic` - The question (for logging)
    """

    use Jido.Action,
      name: "council_consult_one",
      description: "Query a single advisory council perspective",
      category: "council",
      tags: ["council", "advisory", "consult", "llm", "single"],
      schema: [
        question: [
          type: :string,
          required: true,
          doc: "The question to consult on"
        ],
        perspective: [
          type: :atom,
          required: true,
          doc: "The perspective to query (e.g., :security, :stability)"
        ],
        context: [
          type: :map,
          default: %{},
          doc: "Additional context for the perspective"
        ],
        timeout: [
          type: :non_neg_integer,
          default: 180_000,
          doc: "Timeout in ms"
        ],
        evaluator: [
          type: :atom,
          default: Arbor.Consensus.Evaluators.AdvisoryLLM,
          doc: "Evaluator module to use"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Council
    alias Arbor.Consensus.Evaluators.Consult, as: ConsultAPI

    @doc """
    Taint roles for this action's parameters.

    - `question` is `:control` because it determines what the council evaluates
    - `perspective` is `:control` because it determines which perspective runs
    - `context` is `:data` because it's passed through to the perspective
    - `timeout` is `:data` because it's a numeric configuration value
    - `evaluator` is `:control` because it determines which evaluator runs
    """
    def taint_roles do
      %{
        question: :control,
        perspective: :control,
        context: :data,
        timeout: :data,
        evaluator: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, _context) do
      question = params[:question]
      raw_perspective = params[:perspective]
      ctx = params[:context] || %{}
      timeout = params[:timeout] || 180_000
      evaluator = params[:evaluator] || Arbor.Consensus.Evaluators.AdvisoryLLM

      # Normalize perspective using SafeAtom if it's a string
      perspective = Council.normalize_perspective(raw_perspective)

      case perspective do
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, %{
            question_topic: String.slice(question, 0, 100),
            reason: inspect(reason)
          })

          {:error, reason}

        perspective when is_atom(perspective) ->
          do_consult_one(question, perspective, ctx, timeout, evaluator)
      end
    end

    defp do_consult_one(question, perspective, ctx, timeout, evaluator) do
      question_topic = String.slice(question, 0, 100)

      Actions.emit_started(__MODULE__, %{
        question_topic: question_topic,
        perspective: perspective,
        evaluator: evaluator
      })

      start_time = System.monotonic_time(:millisecond)

      case ConsultAPI.ask_one(evaluator, question, perspective, context: ctx, timeout: timeout) do
        {:ok, evaluation} ->
          duration_ms = System.monotonic_time(:millisecond) - start_time

          result = %{
            evaluation: evaluation,
            perspective: perspective,
            duration_ms: duration_ms,
            question_topic: question_topic,
            reasoning: evaluation.reasoning
          }

          Actions.emit_completed(__MODULE__, %{
            perspective: perspective,
            duration_ms: duration_ms,
            question_topic: question_topic
          })

          {:ok, result}

        {:error, reason} = error ->
          Actions.emit_failed(__MODULE__, %{
            question_topic: question_topic,
            perspective: perspective,
            reason: inspect(reason)
          })

          error
      end
    end
  end

  # ===========================================================================
  # Shared Helpers
  # ===========================================================================

  @doc false
  def normalize_perspective(perspective) when is_atom(perspective), do: perspective

  def normalize_perspective(perspective) when is_binary(perspective) do
    case SafeAtom.to_allowed(perspective, @allowed_perspectives) do
      {:ok, atom} -> atom
      {:error, _} -> {:error, {:invalid_perspective, perspective, @allowed_perspectives}}
    end
  end

  def normalize_perspective(other), do: {:error, {:invalid_perspective_type, other}}
end
