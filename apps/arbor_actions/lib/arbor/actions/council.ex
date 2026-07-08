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
  | `ReviewChange` | Run the binding code-review council over a branch diff |

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

  - Consult: `arbor://ai/generate`
  - ConsultOne: `arbor://ai/generate`
  """

  alias Arbor.Common.SafeAtom
  alias Arbor.Actions.Council.BlastRadius
  alias Arbor.Contracts.Consensus.CodeReviewRequest
  alias Arbor.Contracts.Judge.Verdict
  alias Arbor.Persistence.VerdictLog

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

  defmodule ReviewChange do
    @moduledoc """
    Run the binding code-review council over a completed branch diff.

    This is the code-review counterpart to advisory council consultation. It
    builds a `CodeReviewRequest`, runs the `code-review-council.dot` decision
    graph through `Arbor.Consensus.decide/2`, projects the vote result onto the
    shared `Verdict` contract, and records the verdict through `VerdictLog`.
    """

    use Jido.Action,
      name: "council_review_change",
      description: "Run the binding code-review council over a branch diff",
      category: "council",
      tags: ["council", "code_review", "verdict", "llm"],
      schema: [
        request: [
          type: :map,
          doc: "Optional CodeReviewRequest-compatible map; field params override it"
        ],
        diff: [
          type: :string,
          doc: "Unified diff for the completed branch"
        ],
        files: [
          type: {:list, :string},
          doc: "Relative paths touched by the diff"
        ],
        branch: [
          type: :string,
          doc: "Branch under review"
        ],
        base_ref: [
          type: :string,
          doc: "Base ref for the branch"
        ],
        intent: [
          type: :string,
          doc: "Task or summary the change claims to address"
        ],
        agent_id: [
          type: :string,
          doc: "Agent that produced the change"
        ],
        graph: [
          type: :string,
          doc: "Override DOT graph path"
        ],
        timeout: [
          type: :non_neg_integer,
          doc: "Decision pipeline timeout in milliseconds"
        ],
        quorum: [
          type: :string,
          doc: "Consensus quorum override"
        ],
        tier_decision: [
          type: :string,
          doc: "Deprecated; blast-radius tier decision is derived by the classifier"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Council

    def taint_roles do
      %{
        request: :data,
        diff: :data,
        files: :data,
        branch: :control,
        base_ref: :control,
        intent: :data,
        agent_id: :data,
        graph: {:control, requires: [:path_traversal]},
        timeout: :data,
        quorum: :control,
        tier_decision: :data
      }
    end

    def effect_class, do: :network_egress
    def egress_tier(_params, _context), do: :external_provider
    def egress_destination(_params, _context), do: "code-review-council"

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, context) do
      Actions.emit_started(__MODULE__, loggable_params(params))

      with {:ok, request} <- Council.build_code_review_request(params),
           {:ok, decision} <- Council.run_code_review_decision(request, params, context),
           {:ok, verdict} <- Council.verdict_from_review_decision(decision, request) do
        routing = Council.review_routing(verdict, request, decision, context)

        persistence =
          Council.persist_review_verdict(verdict, request, decision, params, context, routing)

        result = Council.review_result(verdict, request, decision, persistence, routing)

        Actions.emit_completed(__MODULE__, %{
          branch: request.branch,
          recommendation: verdict.recommendation,
          decision: result.decision,
          tier_decision: result.tier_decision,
          human_required: result.human_required
        })

        {:ok, result}
      else
        {:error, reason} = error ->
          Actions.emit_failed(__MODULE__, reason)
          error
      end
    end

    defp loggable_params(params) do
      %{
        branch: Council.get_param(params, :branch),
        files_count: params |> Council.get_param(:files) |> List.wrap() |> length()
      }
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

  @doc false
  def build_code_review_request(params) when is_map(params) do
    base =
      case get_param(params, :request) do
        request when is_map(request) -> string_key_map(request)
        nil -> %{}
        other -> %{"request" => other}
      end

    params
    |> Enum.reduce(base, fn {key, value}, acc ->
      normalized = normalize_param_key(key)

      if normalized in ~w(diff files branch base_ref intent agent_id) and not is_nil(value) do
        Map.put(acc, normalized, value)
      else
        acc
      end
    end)
    |> CodeReviewRequest.new()
  end

  @doc false
  def run_code_review_decision(%CodeReviewRequest{} = request, params, context) do
    case Map.get(context, :review_runner) do
      runner when is_function(runner, 3) ->
        runner.(request, params, context)

      runner when is_function(runner, 2) ->
        runner.(request, context)

      nil ->
        default_review_runner(request, params, context)
    end
  end

  @doc false
  def verdict_from_review_decision(decision, %CodeReviewRequest{} = request) do
    with {:ok, decision_atom} <- normalize_decision(decision),
         {:ok, verdict} <-
           Verdict.new(%{
             overall_score: approval_score(decision),
             dimension_scores: dimension_scores(decision),
             strengths: strengths_for_decision(decision_atom),
             weaknesses: primary_concerns(decision),
             recommendation: recommendation_for_decision(decision_atom),
             mode: :verification,
             meta: verdict_meta(decision, request, decision_atom)
           }) do
      {:ok, verdict}
    end
  end

  @doc false
  def persist_review_verdict(
        %Verdict{} = verdict,
        %CodeReviewRequest{} = request,
        decision,
        params,
        context,
        routing
      ) do
    persist_fun = Map.get(context, :persist_verdict)

    cond do
      persist_fun == false ->
        :ok

      is_function(persist_fun, 3) ->
        persist_fun.(verdict, request, decision)

      is_function(persist_fun, 4) ->
        persist_fun.(verdict, request, decision, params)

      true ->
        VerdictLog.record(verdict,
          domain: "code_review",
          source: "code_review_council",
          sample_id: request.branch,
          input: request.diff,
          dataset: "code_review",
          graders: ["code_review_council"],
          result_metadata: review_result_metadata(request, decision, routing)
        )
    end
  rescue
    _ -> :ok
  end

  @doc false
  def review_routing(%Verdict{} = verdict, %CodeReviewRequest{} = request, decision, context) do
    BlastRadius.route(verdict, request.files,
      security_veto?: security_veto?(decision, context),
      authority_widening?: truthy?(context_value(context, :authority_widening?)),
      capability_profile_for_path: context_value(context, :capability_profile_for_path),
      policy: context_value(context, :blast_radius_policy) || %{}
    )
  end

  @doc false
  def review_result(
        %Verdict{} = verdict,
        %CodeReviewRequest{} = request,
        decision,
        persistence,
        routing
      ) do
    %{
      status: "reviewed",
      verdict: verdict,
      recommendation: verdict.recommendation,
      decision: decision_value(decision),
      branch: request.branch,
      files: request.files,
      approve_count: integer_value(decision, "approve_count"),
      reject_count: integer_value(decision, "reject_count"),
      abstain_count: integer_value(decision, "abstain_count"),
      quorum_met: boolean_value(decision, "quorum_met"),
      blast_radius: routing.blast_radius,
      tier_decision: routing.action,
      human_required: routing.human_required,
      security_veto: routing.security_veto,
      authority_widening: routing.authority_widening,
      tier_reasons: routing.reasons,
      persistence: persistence
    }
  end

  @doc false
  def get_param(params, key) when is_map(params) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp default_review_runner(%CodeReviewRequest{} = request, params, action_context) do
    context =
      request
      |> CodeReviewRequest.to_context()
      |> Map.merge(review_context_overlay(action_context))

    question = Map.fetch!(context, "council.question")

    opts =
      [
        graph: get_param(params, :graph) || default_code_review_graph_path(),
        mode: "decision",
        context: context
      ]
      |> put_opt(:timeout, get_param(params, :timeout))
      |> put_opt(:quorum, get_param(params, :quorum))

    Arbor.Consensus.decide(question, opts)
  end

  defp review_context_overlay(context) when is_map(context) do
    case context_value(context, :review_context) do
      overlay when is_map(overlay) -> overlay
      _ -> %{}
    end
  end

  defp review_context_overlay(_context), do: %{}

  defp default_code_review_graph_path do
    candidates = [
      Path.join(File.cwd!(), "apps/arbor_orchestrator/specs/pipelines/code-review-council.dot"),
      Path.join(File.cwd!(), "../arbor_orchestrator/specs/pipelines/code-review-council.dot"),
      Path.join(File.cwd!(), "specs/pipelines/code-review-council.dot")
    ]

    Enum.find(candidates, List.first(candidates), &File.exists?/1)
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_param_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_param_key(key) when is_binary(key), do: key
  defp normalize_param_key(key), do: to_string(key)

  defp string_key_map(map) do
    Map.new(map, fn {key, value} -> {normalize_param_key(key), value} end)
  end

  defp normalize_decision(decision) do
    case decision_value(decision) do
      "approved" -> {:ok, :approved}
      "rejected" -> {:ok, :rejected}
      "deadlock" -> {:ok, :deadlock}
      other -> {:error, {:invalid_review_decision, other}}
    end
  end

  defp decision_value(decision), do: decision |> value("decision") |> to_string()

  defp recommendation_for_decision(:approved), do: :keep
  defp recommendation_for_decision(:rejected), do: :reject
  defp recommendation_for_decision(:deadlock), do: :revise

  defp approval_score(decision) do
    approve = integer_value(decision, "approve_count")
    reject = integer_value(decision, "reject_count")
    abstain = integer_value(decision, "abstain_count")
    total = approve + reject + abstain

    if total > 0, do: Float.round(approve / total, 4), else: 0.0
  end

  defp dimension_scores(decision) do
    %{
      confidence: float_value(decision, "average_confidence")
    }
  end

  defp strengths_for_decision(:approved), do: ["Council majority approved the change"]
  defp strengths_for_decision(_), do: []

  defp primary_concerns(decision) do
    case value(decision, "primary_concerns") do
      list when is_list(list) ->
        Enum.map(list, &to_string/1)

      "[]" ->
        []

      nil ->
        []

      concern when is_binary(concern) ->
        [concern]

      other ->
        [inspect(other)]
    end
  end

  defp verdict_meta(decision, request, decision_atom) do
    %{
      source: "code_review_council",
      decision: decision_atom,
      branch: request.branch,
      base_ref: request.base_ref,
      files: request.files,
      agent_id: request.agent_id,
      approve_count: integer_value(decision, "approve_count"),
      reject_count: integer_value(decision, "reject_count"),
      abstain_count: integer_value(decision, "abstain_count"),
      quorum_met: boolean_value(decision, "quorum_met")
    }
  end

  defp review_result_metadata(request, decision, routing) do
    %{
      "branch" => request.branch,
      "base_ref" => request.base_ref,
      "files" => request.files,
      "intent" => request.intent,
      "agent_id" => request.agent_id,
      "decision" => decision_value(decision),
      "approve_count" => integer_value(decision, "approve_count"),
      "reject_count" => integer_value(decision, "reject_count"),
      "abstain_count" => integer_value(decision, "abstain_count"),
      "quorum_met" => boolean_value(decision, "quorum_met"),
      "blast_radius" => Atom.to_string(routing.blast_radius),
      "tier_decision" => Atom.to_string(routing.action),
      "human_required" => routing.human_required,
      "security_veto" => routing.security_veto,
      "authority_widening" => routing.authority_widening,
      "tier_reasons" => Enum.map(routing.reasons, &Atom.to_string/1)
    }
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp integer_value(map, key) do
    case value(map, key) do
      int when is_integer(int) -> int
      float when is_float(float) -> trunc(float)
      str when is_binary(str) -> parse_int(str)
      _ -> 0
    end
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp float_value(map, key) do
    case value(map, key) do
      float when is_float(float) -> float
      int when is_integer(int) -> int / 1
      str when is_binary(str) -> parse_float(str)
      _ -> 0.0
    end
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {float, _} -> float
      :error -> 0.0
    end
  end

  defp boolean_value(map, key) do
    case value(map, key) do
      bool when is_boolean(bool) -> bool
      "true" -> true
      _ -> false
    end
  end

  defp security_veto?(decision, context) do
    boolean_value(decision, "security_veto") or
      boolean_value(decision, "security_veto?") or
      security_reject_vote?(value(decision, "perspective_votes")) or
      security_veto_list?(value(decision, "vetoes")) or
      truthy?(context_value(context, :security_veto?)) or
      truthy?(context_value(context, :security_veto))
  end

  defp security_reject_vote?(votes) when is_map(votes) do
    votes
    |> value("security")
    |> case do
      :reject -> true
      "reject" -> true
      _ -> false
    end
  end

  defp security_reject_vote?(_votes), do: false

  defp security_veto_list?(vetoes) when is_list(vetoes) do
    Enum.any?(vetoes, fn
      :security -> true
      "security" -> true
      veto when is_map(veto) -> veto_perspective?(veto, "security")
      _ -> false
    end)
  end

  defp security_veto_list?(_vetoes), do: false

  defp veto_perspective?(veto, expected) do
    veto
    |> value("perspective")
    |> to_string()
    |> Kernel.==(expected)
  end

  defp context_value(context, key) when is_map(context) do
    Map.get(context, key) || Map.get(context, Atom.to_string(key))
  end

  defp context_value(_context, _key), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false
end
