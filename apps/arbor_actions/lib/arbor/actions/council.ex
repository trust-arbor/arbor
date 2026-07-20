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
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Council.BlastRadius
  alias Arbor.Contracts.Consensus.CodeReviewRequest
  alias Arbor.Contracts.Judge.Verdict
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Persistence.VerdictLog

  @feedback_text_limit 1_000
  @feedback_list_limit 20
  @feedback_json_bytes_limit 32_768
  @result_files_limit 100
  @active_finding_states ~w(open new_regression architectural_blocker)

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
        commit_hash: [
          type: :string,
          doc: "Exact candidate commit produced by the coding workflow"
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
        ],
        workspace_id: [type: :string, doc: "Active coding workspace lease under review"],
        test_paths: [type: {:list, :string}, doc: "Selected reviewed security regression tests"],
        validation_profile: [type: :string, doc: "Optional reviewed-tree validation profile"],
        review_cycle: [type: :pos_integer, doc: "Review-loop cycle number"],
        prior_candidate_commit: [
          type: :string,
          doc: "Candidate commit reviewed in the prior cycle"
        ],
        delta_diff: [type: :string, doc: "Diff introduced since the prior review cycle"],
        delta_files: [type: {:list, :string}, doc: "Files changed since the prior review cycle"],
        delta_ranges: [
          type: :any,
          doc: "String-keyed changed-line map validated by CodeReviewRequest"
        ],
        finding_ledger: [
          type: :any,
          doc: "Frozen string-keyed JSON finding ledger for the current cycle"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Council
    alias Arbor.Actions.Coding.Workspace
    alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

    def taint_roles do
      %{
        request: :data,
        diff: :data,
        files: :data,
        branch: :control,
        base_ref: :control,
        intent: :data,
        agent_id: :data,
        commit_hash: :control,
        graph: {:control, requires: [:path_traversal]},
        timeout: :data,
        quorum: :control,
        tier_decision: :data,
        workspace_id: :control,
        test_paths: {:control, requires: [:path_traversal]},
        validation_profile: :control,
        review_cycle: :data,
        prior_candidate_commit: :data,
        delta_diff: :data,
        delta_files: :data,
        delta_ranges: :data,
        finding_ledger: :data
      }
    end

    def effect_class, do: :network_egress
    def egress_tier(_params, _context), do: :external_provider
    def egress_destination(_params, _context), do: "code-review-council"

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, context) do
      Actions.emit_started(__MODULE__, loggable_params(params))

      bound? = Council.bound_review_context?(context)

      with {:ok, request} <- Council.build_code_review_request(params),
           :ok <- Council.reject_bound_review_overrides(params, bound?),
           {:ok, request, decision} <- run_review_with_snapshot(request, params, context),
           :ok <- Council.validate_review_decision_cycle(decision, request),
           {:ok, verdict} <- Council.verdict_from_review_decision(decision, request) do
        routing = Council.review_routing(verdict, request, decision, context)

        persistence =
          Council.persist_review_verdict(verdict, request, decision, params, context, routing)

        result = Council.review_result(verdict, request, decision, persistence, routing)

        with {:ok, result} <-
               maybe_issue_security_regression_attestation(
                 result,
                 decision,
                 request,
                 routing,
                 params,
                 context
               ) do
          Actions.emit_completed(__MODULE__, %{
            branch: request.branch,
            recommendation: verdict.recommendation,
            decision: result.decision,
            tier_decision: result.tier_decision,
            human_required: result.human_required
          })

          {:ok, result}
        end
      else
        {:error, reason} = error ->
          Actions.emit_failed(__MODULE__, reason)
          error
      end
    end

    defp run_review_with_snapshot(request, params, context) do
      case open_review_snapshot(request, params, context) do
        {:ok, nil} ->
          case Council.run_code_review_decision(request, params, context) do
            {:ok, decision} -> {:ok, request, decision}
            {:error, _reason} = error -> error
          end

        {:ok, snapshot} ->
          try do
            with {:ok, bound_request} <-
                   CodeReviewRequest.bind_review_snapshot(request, snapshot),
                 {:ok, decision} <-
                   Council.run_code_review_decision(bound_request, params, context) do
              {:ok, bound_request, decision}
            end
          after
            _ = close_review_snapshot(snapshot, context)
          end

        {:error, _reason} = error ->
          error
      end
    end

    defp open_review_snapshot(request, params, context) do
      workspace_id = Council.get_param(params, :workspace_id)
      candidate_commit = request.candidate_commit
      bound? = Council.bound_review_context?(context)

      cond do
        valid_id?(workspace_id) and valid_id?(candidate_commit) ->
          case Map.get(context, :review_snapshot_opener) do
            opener when is_function(opener, 3) ->
              opener.(workspace_id, candidate_commit, registry_caller(context))

            _ ->
              WorkspaceLeaseRegistry.open_review_snapshot(
                workspace_id,
                candidate_commit,
                registry_caller(context)
              )
          end

        bound? ->
          {:error, :missing_bound_review_snapshot}

        is_nil(workspace_id) and is_nil(candidate_commit) ->
          {:ok, nil}

        true ->
          {:error, :incomplete_review_snapshot_binding}
      end
    end

    defp close_review_snapshot(snapshot, context) do
      snapshot_id =
        Map.get(snapshot, :review_snapshot_id) || Map.get(snapshot, "review_snapshot_id")

      if valid_id?(snapshot_id) do
        case Map.get(context, :review_snapshot_closer) do
          closer when is_function(closer, 2) ->
            closer.(snapshot_id, registry_caller(context))

          _ ->
            WorkspaceLeaseRegistry.close_review_snapshot(snapshot_id, registry_caller(context))
        end
      else
        {:error, :invalid_review_snapshot_id}
      end
    end

    defp valid_id?(value), do: is_binary(value) and value != ""

    defp loggable_params(params) do
      %{
        branch: Council.get_param(params, :branch),
        files_count: params |> Council.get_param(:files) |> List.wrap() |> length()
      }
    end

    defp maybe_issue_security_regression_attestation(
           result,
           decision,
           request,
           routing,
           params,
           context
         ) do
      if Council.get_param(params, :validation_profile) == "security_regression" and
           eligible_for_security_regression?(result) do
        with workspace_id when is_binary(workspace_id) and workspace_id != "" <-
               Council.get_param(params, :workspace_id),
             test_paths when is_list(test_paths) <- Council.get_param(params, :test_paths),
             {:ok, lease} <-
               WorkspaceLeaseRegistry.inspect_lease(workspace_id, registry_caller(context)),
             {:ok, material} <-
               Workspace.materialize_security_regression_material(
                 lease.worktree_path,
                 workspace_id,
                 lease.base_commit,
                 test_paths
               ),
             true <- material.diff == request.diff,
             {:ok, issued} <-
               WorkspaceLeaseRegistry.issue_review_attestation(
                 workspace_id,
                 material,
                 council_decision_digest(result, decision, request, routing),
                 registry_caller(context)
               ) do
          {:ok, Map.put(result, :review_attestation_id, issued.review_attestation_id)}
        else
          false -> {:error, :reviewed_diff_changed}
          _ -> {:error, :security_regression_attestation_failed}
        end
      else
        {:ok, result}
      end
    end

    defp eligible_for_security_regression?(result) do
      result.recommendation == "keep" and result.quorum_met == true and
        result.tier_decision in ["auto_proceed", "human_review"]
    end

    defp registry_caller(context) do
      %{
        task_id: Workspace.context_task_id(context),
        principal_id: Workspace.context_principal_id(context),
        server: Map.get(context, :workspace_registry) || Map.get(context, "workspace_registry")
      }
    end

    defp council_decision_digest(result, decision, request, routing) do
      result
      |> Council.review_attestation_decision_projection(decision, request, routing)
      |> canonical_json()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end

    defp canonical_json(value) when is_map(value) do
      entries =
        value
        |> Enum.map(fn {key, item} -> {to_string(key), item} end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {key, item} -> [Jason.encode!(key), ":", canonical_json(item)] end)

      ["{", Enum.intersperse(entries, ","), "}"]
    end

    defp canonical_json(value) when is_list(value) do
      ["[", Enum.intersperse(Enum.map(value, &canonical_json/1), ","), "]"]
    end

    defp canonical_json(value), do: Jason.encode!(value)
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
        request when is_map(request) ->
          request |> string_key_map() |> Map.delete("review_snapshot_id")

        nil ->
          %{}

        other ->
          %{"request" => other}
      end

    params
    |> Enum.reduce(base, fn {key, value}, acc ->
      normalized = normalize_param_key(key)

      cond do
        normalized == "commit_hash" and not is_nil(value) ->
          Map.put(acc, "candidate_commit", value)

        normalized in ~w(
          diff files branch base_ref candidate_commit intent agent_id review_cycle
          prior_candidate_commit delta_diff delta_files delta_ranges finding_ledger
        ) and
            not is_nil(value) ->
          Map.put(acc, normalized, value)

        true ->
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
    routing =
      BlastRadius.route(verdict, request.files,
        security_veto?: security_veto?(decision, context),
        authority_widening?: truthy?(context_value(context, :authority_widening?)),
        capability_profile_for_path: context_value(context, :capability_profile_for_path),
        policy: context_value(context, :blast_radius_policy) || %{}
      )

    if review_human_required?(decision) do
      %{
        routing
        | action: :human_review,
          human_required: true,
          reasons: Enum.uniq([:ledger_human_required | routing.reasons])
      }
    else
      routing
    end
  end

  @doc false
  def review_attestation_decision_projection(
        result,
        decision,
        %CodeReviewRequest{} = request,
        routing
      ) do
    %{
      "version" => "arbor-council-review-v2",
      "decision" => result.decision,
      "approve_count" => result.approve_count,
      "reject_count" => result.reject_count,
      "abstain_count" => result.abstain_count,
      "quorum_met" => result.quorum_met,
      "routing" => %{
        "action" => Atom.to_string(routing.action),
        "blast_radius" => Atom.to_string(routing.blast_radius)
      },
      "review" => %{
        "review_cycle" => completed_review_cycle(decision, request),
        "finding_ledger" => completed_finding_ledger(decision),
        "review_disposition" => review_disposition(decision),
        "blocking_ids" => review_blocking_ids(decision),
        "blocking_reasons" => review_blocking_reasons(decision),
        "human_required" => result.human_required
      }
    }
  end

  @doc false
  def validate_review_decision_cycle(decision, %CodeReviewRequest{} = request) do
    cond do
      not review_specific_decision?(decision) ->
        :ok

      is_nil(value(decision, "review_cycle")) ->
        :ok

      value(decision, "review_cycle") == request.review_cycle ->
        :ok

      true ->
        {:error, :review_cycle_mismatch}
    end
  end

  @doc false
  def review_result(
        %Verdict{} = verdict,
        %CodeReviewRequest{} = request,
        decision,
        persistence,
        routing
      ) do
    recommendation = enum_string(verdict.recommendation)
    tier_decision = enum_string(routing.action)
    blast_radius = enum_string(routing.blast_radius)
    tier_reasons = bounded_enum_list(routing.reasons)
    verdict = verdict_projection(verdict)
    review = review_metadata(decision, request, routing)

    feedback = %{
      "recommendation" => recommendation,
      "tier" => %{
        "blast_radius" => blast_radius,
        "decision" => tier_decision,
        "reasons" => tier_reasons
      },
      "verdict" => %{
        "weaknesses" => verdict.weaknesses,
        "scores" => verdict.dimension_scores,
        "counts" => %{
          "approve" => integer_value(decision, "approve_count"),
          "reject" => integer_value(decision, "reject_count"),
          "abstain" => integer_value(decision, "abstain_count")
        }
      },
      "flags" => %{
        "security_veto" => routing.security_veto,
        "human_required" => routing.human_required,
        "authority_widening" => routing.authority_widening
      }
    }

    feedback =
      if is_nil(review), do: feedback, else: Map.put(feedback, "review", review_feedback(review))

    {feedback, feedback_json} = bounded_feedback_json(feedback)

    result = %{
      status: "reviewed",
      verdict: verdict,
      recommendation: recommendation,
      decision: decision_value(decision),
      branch: bounded_text(request.branch),
      files: bounded_text_list(request.files, @result_files_limit),
      approve_count: integer_value(decision, "approve_count"),
      reject_count: integer_value(decision, "reject_count"),
      abstain_count: integer_value(decision, "abstain_count"),
      quorum_met: boolean_value(decision, "quorum_met"),
      blast_radius: blast_radius,
      tier_decision: tier_decision,
      human_required: routing.human_required,
      security_veto: routing.security_veto,
      authority_widening: routing.authority_widening,
      tier_reasons: tier_reasons,
      persistence: persistence_metadata(persistence),
      feedback: feedback,
      feedback_json: feedback_json
    }

    if review == nil do
      result
    else
      result
      |> Map.put(:review_cycle, review["review_cycle"])
      |> Map.put(:prior_candidate_commit, review["prior_candidate_commit"])
      |> Map.put(:finding_ledger, review["finding_ledger"])
      |> Map.put(:review_disposition, review["review_disposition"])
      |> Map.put(:blocking_ids, review["blocking_ids"])
      |> Map.put(:blocking_reasons, review["blocking_reasons"])
    end
  end

  @doc false
  def get_param(params, key) when is_map(params) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp default_review_runner(%CodeReviewRequest{} = request, params, action_context) do
    # JSON-clean review context only — never put signing credentials or
    # RunAuthorization into Engine initial_values / checkpoints.
    context =
      request
      |> CodeReviewRequest.to_context()
      |> Map.merge(review_context_overlay(action_context))

    question = Map.fetch!(context, "council.question")

    with {:ok, launch} <- review_launch_mode(params, action_context),
         :ok <- reject_bound_review_overrides(params, launch.bound?) do
      opts =
        [
          graph: review_graph_path(params, launch.bound?),
          context: context
        ]
        |> maybe_put_unbound_review_overrides(params, launch.bound?)
        |> put_opt(:timeout, get_param(params, :timeout))
        |> Keyword.merge(launch.decide_opts)
        # Process-local Consult seam only (same class as review_runner).
        # Never agent/DOT-controlled; never enters initial_values/checkpoints.
        |> put_opt(:engine_runner, review_engine_runner(action_context))

      Arbor.Consensus.decide(question, opts)
    end
  end

  defp review_engine_runner(action_context) do
    case context_value(action_context, :engine_runner) do
      runner when is_function(runner, 2) -> runner
      _other -> nil
    end
  end

  @doc false
  # Pure presence/classification only — no file IO or launch construction.
  # Bound when an inherited RunAuthorization or a root SigningAuthority key is
  # present (even if later validation fails closed at launch time).
  def bound_review_context?(context) when is_map(context) do
    classify_review_launch(context) != :unbound
  end

  def bound_review_context?(_context), do: false

  @doc false
  def reject_bound_review_overrides(_params, bound?) when bound? in [nil, false], do: :ok

  def reject_bound_review_overrides(params, _bound?) do
    case Enum.find([:graph, :quorum], &(not is_nil(get_param(params, &1)))) do
      nil -> :ok
      key -> {:error, {:bound_council_override, key}}
    end
  end

  # Pure launch classifier (no IO, no lease lookup, no authority canonicalize).
  #
  # :inherited — any non-nil run_authorization claim (atom/string spelling)
  # :authorized_root — any signing_authority key presence (including nil/malformed)
  # :unbound — neither selector is present
  #
  # All-values presence only: never Map.get first-wins. Conflicting claims still
  # classify as bound so unbound graph/mode overrides cannot open an escape hatch;
  # launch construction later fails closed on conflict/malformed values.
  # Present-nil run_authorization alone is absence for inheritance (matches
  # resolve_run_authorization_claims/1); present-nil signing_authority binds root.
  defp classify_review_launch(context) when is_map(context) do
    run_auth_values = map_claim_values(context, :run_authorization)
    signing_present? = map_claim_values(context, :signing_authority) != []

    cond do
      Enum.any?(run_auth_values, &(not is_nil(&1))) ->
        :inherited

      signing_present? ->
        :authorized_root

      true ->
        :unbound
    end
  end

  defp classify_review_launch(_context), do: :unbound

  # :inherited — parent Engine RunAuthorization forwarded unchanged
  # :authorized_root — legacy coding path with process-local SigningAuthority
  # :unbound — no authorization lineage (legacy unbound/advisory council)
  #
  # Launch selectors are all-values (never first-wins). Conflicting atom/string
  # spellings of run_authorization / signing_authority fail closed before a
  # launch mode is chosen.
  defp review_launch_mode(params, action_context) do
    with {:ok, run_auth} <- resolve_run_authorization_claims(action_context) do
      case run_auth do
        {:present, authority} ->
          with {:ok, nested_opts} <- resolve_inherited_nested_engine_opts(action_context) do
            decide_opts =
              [run_authorization: authority]
              |> put_opt(:nested_engine_opts, nested_opts)

            {:ok, %{bound?: true, decide_opts: decide_opts}}
          end

        :absent ->
          case map_claim_values(action_context, :signing_authority) do
            [] ->
              {:ok, %{bound?: false, decide_opts: []}}

            _present ->
              # Presence of signing_authority (including nil) binds root path.
              case authorized_root_decide_opts(params, action_context) do
                {:ok, decide_opts} ->
                  {:ok, %{bound?: true, decide_opts: decide_opts}}

                {:error, _reason} = error ->
                  error
              end
          end
      end
    end
  end

  defp authorized_root_decide_opts(params, action_context) do
    with {:ok, authority} <- require_canonical_signing_authority(action_context),
         principal = authority.principal_id,
         :ok <- reject_system_principal(principal),
         :ok <- agree_present_identities(action_context, principal),
         :ok <- reject_root_mixed_credentials(action_context),
         {:ok, task_id} <- require_lineage_task_id(action_context),
         {:ok, workdir} <- review_lease_workdir(params, action_context, principal, task_id),
         {:ok, nested_opts} <- root_nested_engine_opts(action_context),
         {:ok, caller_id} <- optional_lineage_or_default(action_context, :caller_id, principal),
         {:ok, author_id} <- optional_lineage_or_default(action_context, :author_id, principal),
         {:ok, session_id} <- optional_lineage_id(action_context, :session_id) do
      # Authority is top-level for Consult/run_as — never nested discovery.
      # nested_engine_opts may carry only max_depth on the root path.
      decide_opts =
        [
          authorization: true,
          agent_id: principal,
          execution_principal: principal,
          workdir: workdir,
          signing_authority: authority,
          caller_id: caller_id,
          author_id: author_id,
          task_id: task_id
        ]
        |> put_opt(:session_id, session_id)
        |> put_opt(:nested_engine_opts, nested_opts)

      {:ok, decide_opts}
    end
  end

  # All-values for run_authorization: every atom/string spelling is binding.
  # Equal non-nil duplicates collapse; all-nil is absence; mixed/conflict fails.
  defp resolve_run_authorization_claims(action_context) do
    case map_claim_values(action_context, :run_authorization) do
      [] ->
        {:ok, :absent}

      values ->
        case Enum.uniq(values) do
          [nil] ->
            {:ok, :absent}

          [authority] when not is_nil(authority) ->
            {:ok, {:present, authority}}

          _conflict ->
            {:error, :conflicting_run_authorization}
        end
    end
  end

  # Inherited nested_engine_opts: all-values envelopes must be identical lists
  # (exact term equality). Consult.decide then applies its allowlist projection.
  # A string/atom alias therefore cannot smuggle an alternate credential bag.
  defp resolve_inherited_nested_engine_opts(action_context) do
    case map_claim_values(action_context, :nested_engine_opts) do
      [] ->
        {:ok, nil}

      values ->
        case Enum.uniq(values) do
          [nested] when is_list(nested) ->
            if Keyword.keyword?(nested) do
              {:ok, nested}
            else
              {:error, :invalid_nested_engine_opts}
            end

          [nil] ->
            {:ok, nil}

          _conflict ->
            {:error, :conflicting_nested_engine_opts}
        end
    end
  end

  defp require_canonical_signing_authority(action_context) do
    # Presence of the key (including nil) is bound — never downgrade to unbound.
    # Accept only an actual %SigningAuthority{} struct; well-formed maps/lists
    # must not rehydrate via canonicalize/1.
    # All-values: every atom/string spelling is validated; equal canonical
    # duplicates may pass; nil/malformed/conflict fail closed.
    case map_claim_values(action_context, :signing_authority) do
      [] ->
        {:error, :missing_signing_authority}

      values ->
        collapse_signing_authority_claims(values)
    end
  end

  defp collapse_signing_authority_claims(values) do
    Enum.reduce_while(values, :absent, fn raw, acc ->
      case normalize_signing_authority_claim(raw) do
        {:ok, canonical} ->
          case acc do
            :absent ->
              {:cont, {:ok, canonical}}

            {:ok, ^canonical} ->
              {:cont, {:ok, canonical}}

            {:ok, _other} ->
              {:halt, {:error, :conflicting_signing_authority}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      :absent -> {:error, :missing_signing_authority}
      other -> other
    end
  end

  defp normalize_signing_authority_claim(nil), do: {:error, :invalid_signing_authority}

  defp normalize_signing_authority_claim(%SigningAuthority{} = authority) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, %SigningAuthority{} = canonical} -> {:ok, canonical}
      {:error, reason} -> {:error, {:invalid_signing_authority, reason}}
    end
  end

  defp normalize_signing_authority_claim(_other), do: {:error, :invalid_signing_authority}

  defp reject_system_principal(principal) when principal in ["system", "agent_system"],
    do: {:error, :system_principal_forbidden}

  defp reject_system_principal(_principal), do: :ok

  # Every present execution-principal identity claim must equal
  # authority.principal_id. Missing sources are fine; present-but-divergent or
  # malformed sources fail closed. caller_id / author_id / session_id remain
  # distinct lineage and are not compared here.
  # AuthContext uses principal_id (not a nonexistent agent_id field).
  # Engine context carries execution identity in the flat key "session.agent_id"
  # — never infer authority from a nested session map.
  #
  # All-values (never first-wins): enumerate every atom- and string-key spelling
  # of each claim independently. Present nil/malformed fails closed. Conflicting
  # duplicate spellings fail closed; equal duplicates may pass.
  defp agree_present_identities(action_context, principal) do
    with :ok <- agree_direct_identity_claims(action_context, :agent_id, principal),
         :ok <- agree_direct_identity_claims(action_context, :execution_principal, principal),
         :ok <- agree_direct_identity_claims(action_context, :principal_id, principal),
         :ok <- agree_flat_session_agent_id_claims(action_context, principal),
         :ok <-
           agree_nested_identity_claims(action_context, :auth_context, :principal_id, principal),
         :ok <-
           agree_nested_identity_claims(action_context, :signed_request, :agent_id, principal) do
      :ok
    end
  end

  # Direct claims: presence of the key (including nil) binds and must match principal.
  defp agree_direct_identity_claims(action_context, field, principal) do
    action_context
    |> map_claim_values(field)
    |> Enum.reduce_while(:ok, fn raw, :ok ->
      case normalize_present_identity(raw) do
        :absent ->
          {:halt, {:error, :invalid_principal_id}}

        {:ok, ^principal} ->
          {:cont, :ok}

        {:ok, _other} ->
          {:halt, {:error, {:identity_mismatch, field}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # Present flat session.agent_id must validate; present-nil/malformed is not absence.
  # Both atom and string spellings are independent claims (no first-wins).
  defp agree_flat_session_agent_id_claims(action_context, principal)
       when is_map(action_context) do
    action_context
    |> map_claim_values_for_keys([:"session.agent_id", "session.agent_id"])
    |> Enum.reduce_while(:ok, fn raw, :ok ->
      case normalize_present_identity(raw) do
        :absent ->
          {:halt, {:error, :invalid_principal_id}}

        {:ok, ^principal} ->
          {:cont, :ok}

        {:ok, _other} ->
          {:halt, {:error, {:identity_mismatch, :session_agent_id}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp agree_flat_session_agent_id_claims(_action_context, _principal), do: :ok

  # Nested envelopes may omit the identity field (optional). When the nested
  # field is present — including nil — every atom/string spelling is validated
  # independently against the authority principal.
  defp agree_nested_identity_claims(action_context, envelope_key, nested_field, principal) do
    action_context
    |> map_claim_values(envelope_key)
    |> Enum.reduce_while(:ok, fn envelope, :ok ->
      case agree_nested_field_claims(envelope, nested_field, principal, envelope_key) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp agree_nested_field_claims(envelope, nested_field, principal, source)
       when is_map(envelope) do
    envelope
    |> map_claim_values(nested_field)
    |> Enum.reduce_while(:ok, fn raw, :ok ->
      case normalize_present_identity(raw) do
        :absent ->
          # Nested key present with nil is a present-nil claim, not absence.
          {:halt, {:error, :invalid_principal_id}}

        {:ok, ^principal} ->
          {:cont, :ok}

        {:ok, _other} ->
          {:halt, {:error, {:identity_mismatch, source}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # Envelope present but not a map, or present-nil envelope: no nested field
  # claims to validate (optional envelope shape).
  defp agree_nested_field_claims(_envelope, _nested_field, _principal, _source), do: :ok

  defp normalize_present_identity(nil), do: :absent

  defp normalize_present_identity(value) when is_atom(value) and value not in [true, false] do
    normalize_present_identity(Atom.to_string(value))
  end

  # Opaque after validation: blank includes whitespace-only (trim only as
  # predicate). Accepted values are never rewritten before exact comparison.
  defp normalize_present_identity(value) when is_binary(value) do
    cond do
      String.trim(value) == "" ->
        {:error, :invalid_principal_id}

      not String.valid?(value) or String.contains?(value, <<0>>) ->
        {:error, :invalid_principal_id}

      value in ["system", "agent_system"] ->
        {:error, :system_principal_forbidden}

      true ->
        {:ok, value}
    end
  end

  defp normalize_present_identity(_value), do: {:error, :invalid_principal_id}

  # Collect every present value for a logical atom key under both atom and
  # string spellings. Maps cannot duplicate a single key type, but atom+string
  # aliases are independent entries and must all be validated.
  defp map_claim_values(context, key) when is_map(context) and is_atom(key) do
    map_claim_values_for_keys(context, [key, Atom.to_string(key)])
  end

  defp map_claim_values(_context, _key), do: []

  defp map_claim_values_for_keys(context, keys) when is_map(context) and is_list(keys) do
    Enum.reduce(keys, [], fn key, acc ->
      if Map.has_key?(context, key) do
        [Map.get(context, key) | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp map_claim_values_for_keys(_context, _keys), do: []

  # Root launch rejects mixed signer/authorizer/private-key controls by key
  # presence (including nil). Nested signing_authority is forbidden — authority
  # is projected top-level only. Every nested_engine_opts spelling is audited
  # (no first-wins envelope selection).
  defp reject_root_mixed_credentials(action_context) do
    top_level_keys = [:signer, :authorizer, :identity_private_key]
    nested_keys = [:signer, :authorizer, :identity_private_key, :signing_authority]

    top_level = Enum.filter(top_level_keys, &has_context_key?(action_context, &1))

    case map_claim_values(action_context, :nested_engine_opts) do
      [] ->
        if top_level == [] do
          :ok
        else
          {:error, {:root_mixed_credentials, top_level}}
        end

      envelopes ->
        nested_result =
          Enum.reduce_while(envelopes, {:ok, []}, fn nested, {:ok, acc} ->
            case nested do
              nil ->
                {:cont, {:ok, acc}}

              nested when is_list(nested) ->
                if Keyword.keyword?(nested) do
                  forbidden = Enum.filter(nested_keys, &Keyword.has_key?(nested, &1))
                  {:cont, {:ok, acc ++ forbidden}}
                else
                  {:halt, :invalid}
                end

              _other ->
                {:halt, :invalid}
            end
          end)

        case nested_result do
          :invalid ->
            {:error, :invalid_nested_engine_opts}

          {:ok, nested_forbidden} ->
            forbidden = Enum.uniq(top_level ++ nested_forbidden)

            if forbidden == [] do
              :ok
            else
              {:error, {:root_mixed_credentials, forbidden}}
            end
        end
    end
  end

  # Fixed workdir from the exact coding workspace lease — never File.cwd!,
  # process dictionary, or a caller-supplied workdir/cwd scalar.
  # Authority is exact nonblank task_id + principal_id lineage via the registry's
  # lineage-only inspect (owner-PID is deliberately ignored).
  defp review_lease_workdir(params, action_context, principal, task_id)
       when is_binary(principal) and is_binary(task_id) do
    workspace_id = get_param(params, :workspace_id)

    # Opaque after validation: blank includes whitespace-only (trim only as
    # predicate). Never rewrite the accepted workspace_id before lineage lookup.
    if is_binary(workspace_id) and String.trim(workspace_id) != "" and
         String.valid?(workspace_id) and not String.contains?(workspace_id, <<0>>) do
      case inspect_lease_with_exact_lineage(workspace_id, principal, task_id, action_context) do
        {:ok, lease} ->
          extract_lease_worktree_path(lease)

        {:error, reason} ->
          {:error, {:review_lease_inspect_failed, reason}}
      end
    else
      {:error, :missing_review_workspace}
    end
  end

  defp inspect_lease_with_exact_lineage(workspace_id, principal, task_id, action_context) do
    server_opts =
      case Map.get(action_context, :workspace_registry) ||
             Map.get(action_context, "workspace_registry") do
        nil -> []
        server -> [server: server]
      end

    WorkspaceLeaseRegistry.inspect_lease_by_lineage(
      workspace_id,
      task_id,
      principal,
      server_opts
    )
  end

  defp extract_lease_worktree_path(lease) when is_map(lease) do
    path =
      Map.get(lease, :worktree_path) ||
        Map.get(lease, "worktree_path")

    if is_binary(path) and String.trim(path) != "" and String.valid?(path) and
         not String.contains?(path, <<0>>) do
      {:ok, path}
    else
      {:error, :invalid_review_workdir}
    end
  end

  defp extract_lease_worktree_path(_lease), do: {:error, :invalid_review_workdir}

  defp require_lineage_task_id(action_context) do
    case present_lineage_value(action_context, :task_id) do
      :absent ->
        {:error, {:review_lease_inspect_failed, :incomplete_task_principal}}

      {:ok, task_id} ->
        {:ok, task_id}

      {:error, _reason} = error ->
        error
    end
  end

  # Root path nested opts: only max_depth. SigningAuthority is top-level.
  # All-values: every nested_engine_opts spelling is projected to the same
  # sanitized max_depth form; conflicts fail closed. Ignored non-credential
  # duplicate keys cannot alter authority once projected to max_depth-only.
  defp root_nested_engine_opts(action_context) do
    case map_claim_values(action_context, :nested_engine_opts) do
      [] ->
        {:ok, nil}

      values ->
        Enum.reduce_while(values, :absent, fn nested, acc ->
          case project_root_nested_opts(nested) do
            {:ok, projected} ->
              case acc do
                :absent ->
                  {:cont, {:ok, projected}}

                {:ok, ^projected} ->
                  {:cont, {:ok, projected}}

                {:ok, _other} ->
                  {:halt, {:error, :conflicting_nested_engine_opts}}
              end

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)
        |> case do
          :absent -> {:ok, nil}
          other -> other
        end
    end
  end

  defp project_root_nested_opts(nil), do: {:ok, nil}
  defp project_root_nested_opts([]), do: {:ok, nil}

  defp project_root_nested_opts(nested) when is_list(nested) do
    if Keyword.keyword?(nested) do
      # Within one envelope, max_depth may repeat; all occurrences must agree
      # (Keyword.fetch is first-wins and must not hide a later conflict).
      depths =
        nested
        |> Enum.filter(fn {key, _value} -> key == :max_depth end)
        |> Enum.map(fn {_key, value} -> value end)

      case Enum.uniq(depths) do
        [] ->
          {:ok, nil}

        [max_depth] ->
          {:ok, [max_depth: max_depth]}

        _conflict ->
          {:error, :conflicting_nested_engine_opts}
      end
    else
      {:error, :invalid_nested_engine_opts}
    end
  end

  defp project_root_nested_opts(_other), do: {:error, :invalid_nested_engine_opts}

  # Present lineage is forwarded; absent defaults to principal for caller/author.
  # Malformed or system values fail closed rather than being silently dropped.
  defp optional_lineage_or_default(action_context, key, principal) do
    case present_lineage_value(action_context, key) do
      :absent -> {:ok, principal}
      {:ok, id} -> {:ok, id}
      {:error, _reason} = error -> error
    end
  end

  defp optional_lineage_id(action_context, key) do
    case present_lineage_value(action_context, key) do
      :absent -> {:ok, nil}
      {:ok, id} -> {:ok, id}
      {:error, _reason} = error -> error
    end
  end

  # Lineage claims are all-values: every atom/string spelling is validated
  # independently. Present nil/malformed fails closed. Conflicting values fail
  # closed; equal duplicate spellings collapse to the shared opaque value.
  defp present_lineage_value(action_context, key) do
    case map_claim_values(action_context, key) do
      [] ->
        :absent

      values ->
        Enum.reduce_while(values, :absent, fn raw, acc ->
          case normalize_present_identity(raw) do
            :absent ->
              {:halt, {:error, :invalid_principal_id}}

            {:ok, id} ->
              case acc do
                :absent ->
                  {:cont, {:ok, id}}

                {:ok, ^id} ->
                  {:cont, {:ok, id}}

                {:ok, _other} ->
                  {:halt, {:error, {:identity_mismatch, key}}}
              end

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp has_context_key?(context, key) when is_map(context) and is_atom(key) do
    Map.has_key?(context, key) or Map.has_key?(context, Atom.to_string(key))
  end

  defp review_graph_path(params, bound?) when bound? in [nil, false],
    do: get_param(params, :graph) || default_code_review_graph_path()

  defp review_graph_path(_params, _bound?), do: default_code_review_graph_path()

  defp maybe_put_unbound_review_overrides(opts, params, bound?) when bound? in [nil, false] do
    opts
    |> Keyword.put(:mode, "decision")
    |> put_opt(:quorum, get_param(params, :quorum))
  end

  defp maybe_put_unbound_review_overrides(opts, _params, _bound?), do: opts

  defp review_context_overlay(context) when is_map(context) do
    case context_value(context, :review_context) do
      overlay when is_map(overlay) -> overlay
      _ -> %{}
    end
  end

  defp review_context_overlay(_context), do: %{}

  defp default_code_review_graph_path do
    case Arbor.Actions.reviewed_pipeline("code_review_council") do
      {:ok, %{path: path}} -> path
      {:error, reason} -> raise "reviewed code-review pipeline unavailable: #{inspect(reason)}"
    end
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
    meta = %{
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

    case review_compact_metadata(decision, request) do
      nil -> meta
      review -> Map.put(meta, :review, review)
    end
  end

  defp review_result_metadata(request, decision, routing) do
    metadata = %{
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

    case review_metadata(decision, request, routing) do
      nil -> metadata
      review -> Map.put(metadata, "review", review)
    end
  end

  # The action result crosses the Engine checkpoint boundary. Keep this
  # projection intentionally smaller and simpler than the persisted Verdict.
  defp verdict_projection(%Verdict{} = verdict) do
    %{
      overall_score: verdict.overall_score,
      dimension_scores:
        Map.new(verdict.dimension_scores, fn {dimension, score} ->
          {enum_string(dimension), score}
        end),
      strengths: bounded_text_list(verdict.strengths),
      weaknesses: bounded_text_list(verdict.weaknesses),
      recommendation: enum_string(verdict.recommendation),
      mode: enum_string(verdict.mode),
      meta: verdict_meta_projection(verdict.meta)
    }
  end

  defp verdict_meta_projection(meta) when is_map(meta) do
    %{
      "source" => bounded_text(Map.get(meta, :source) || Map.get(meta, "source")),
      "decision" => enum_string(Map.get(meta, :decision) || Map.get(meta, "decision")),
      "branch" => bounded_text(Map.get(meta, :branch) || Map.get(meta, "branch")),
      "base_ref" => bounded_text(Map.get(meta, :base_ref) || Map.get(meta, "base_ref")),
      "files" =>
        bounded_text_list(Map.get(meta, :files) || Map.get(meta, "files"), @result_files_limit),
      "agent_id" => bounded_text(Map.get(meta, :agent_id) || Map.get(meta, "agent_id")),
      "approve_count" => integer_value(meta, "approve_count"),
      "reject_count" => integer_value(meta, "reject_count"),
      "abstain_count" => integer_value(meta, "abstain_count"),
      "quorum_met" => boolean_value(meta, "quorum_met")
    }
    |> maybe_put_review_meta(Map.get(meta, :review) || Map.get(meta, "review"))
  end

  defp verdict_meta_projection(_meta), do: %{}

  defp persistence_metadata({:ok, run_id}) when is_binary(run_id) do
    %{"status" => "recorded", "run_id" => bounded_text(run_id)}
  end

  defp persistence_metadata(:ok), do: %{"status" => "not_recorded"}
  defp persistence_metadata(_persistence), do: %{"status" => "unavailable"}

  defp bounded_enum_list(values),
    do: values |> List.wrap() |> Enum.map(&enum_string/1) |> Enum.take(@feedback_list_limit)

  defp bounded_text_list(values, limit \\ @feedback_list_limit) do
    values
    |> List.wrap()
    |> Enum.map(&bounded_text/1)
    |> Enum.take(limit)
  end

  defp bounded_text(nil), do: nil
  defp bounded_text(value) when is_binary(value), do: String.slice(value, 0, @feedback_text_limit)

  defp bounded_text(value),
    do: value |> inspect(limit: 20, printable_limit: @feedback_text_limit) |> bounded_text()

  defp review_specific_decision?(decision) when is_map(decision) do
    Enum.any?(
      [
        {"finding_ledger", :finding_ledger},
        {"review_disposition", :review_disposition},
        {"disposition", :disposition},
        {"blocking_ids", :blocking_ids},
        {"blocking_reasons", :blocking_reasons},
        {"human_required", :human_required}
      ],
      fn {string_key, atom_key} ->
        Map.has_key?(decision, string_key) or Map.has_key?(decision, atom_key)
      end
    )
  end

  defp review_specific_decision?(_decision), do: false

  defp review_human_required?(decision),
    do: review_specific_decision?(decision) and boolean_value(decision, "human_required")

  defp review_metadata(decision, %CodeReviewRequest{} = request, routing \\ nil) do
    if review_specific_decision?(decision) do
      %{
        "review_cycle" => completed_review_cycle(decision, request),
        "prior_candidate_commit" => bounded_text(request.prior_candidate_commit),
        "finding_ledger" => completed_finding_ledger(decision),
        "review_disposition" => review_disposition(decision),
        "blocking_ids" => review_blocking_ids(decision),
        "blocking_reasons" => review_blocking_reasons(decision),
        "human_required" =>
          if(is_nil(routing),
            do: boolean_value(decision, "human_required"),
            else: routing.human_required
          )
      }
    end
  end

  defp review_compact_metadata(decision, %CodeReviewRequest{} = request) do
    case review_metadata(decision, request) do
      nil -> nil
      review -> Map.take(review, ["review_cycle", "review_disposition", "blocking_ids"])
    end
  end

  defp completed_review_cycle(decision, %CodeReviewRequest{} = request) do
    case value(decision, "review_cycle") do
      cycle when is_integer(cycle) -> cycle
      _ -> request.review_cycle
    end
  end

  defp completed_finding_ledger(decision) do
    case value(decision, "finding_ledger") do
      ledger when is_map(ledger) -> ledger
      _ -> %{}
    end
  end

  defp review_disposition(decision) do
    decision
    |> value("review_disposition")
    |> case do
      nil -> value(decision, "disposition")
      disposition -> disposition
    end
    |> bounded_text()
  end

  defp review_blocking_ids(decision) do
    decision
    |> value("blocking_ids")
    |> bounded_text_list()
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp review_blocking_reasons(decision) do
    decision
    |> value("blocking_reasons")
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn reason ->
      %{
        "id" => bounded_text(value(reason, "id")),
        "reason" => bounded_text(value(reason, "reason"))
      }
    end)
    |> Enum.sort_by(&{&1["id"], &1["reason"]})
    |> Enum.take(@feedback_list_limit)
  end

  defp review_feedback(review) do
    %{
      "review_cycle" => review["review_cycle"],
      "disposition" => review["review_disposition"],
      "blocking_ids" => review["blocking_ids"],
      "blocking_reasons" => review["blocking_reasons"],
      "human_required" => review["human_required"],
      "active_findings" => active_findings(review["finding_ledger"])
    }
  end

  defp bounded_feedback_json(feedback) do
    json = Jason.encode!(feedback)

    if byte_size(json) <= @feedback_json_bytes_limit do
      {feedback, json}
    else
      feedback = compact_feedback(feedback)
      json = Jason.encode!(feedback)

      if byte_size(json) <= @feedback_json_bytes_limit do
        {feedback, json}
      else
        minimal = %{
          "recommendation" => feedback["recommendation"],
          "flags" => feedback["flags"],
          "feedback_truncated" => true
        }

        {minimal, Jason.encode!(minimal)}
      end
    end
  end

  defp compact_feedback(feedback) do
    feedback
    |> update_in(["verdict", "weaknesses"], &compact_text_list(&1, 8))
    |> update_in(["tier", "reasons"], &compact_text_list(&1, 8))
    |> Map.update("review", nil, &compact_review_feedback/1)
  end

  defp compact_review_feedback(nil), do: nil

  defp compact_review_feedback(review) do
    review
    |> Map.update("blocking_ids", [], &compact_text_list(&1, 8))
    |> Map.update("blocking_reasons", [], fn reasons ->
      reasons
      |> List.wrap()
      |> Enum.take(8)
      |> Enum.map(fn reason ->
        %{
          "id" => compact_text(value(reason, "id")),
          "reason" => compact_text(value(reason, "reason"))
        }
      end)
    end)
    |> Map.update("active_findings", [], fn findings ->
      findings
      |> List.wrap()
      |> Enum.take(6)
      |> Enum.map(&compact_active_finding/1)
    end)
  end

  defp compact_active_finding(finding) do
    finding
    |> Map.new(fn {key, value} -> {key, compact_feedback_value(key, value)} end)
  end

  defp compact_feedback_value("anchor", anchor) when is_map(anchor) do
    Map.new(anchor, fn
      {"line", value} -> {"line", value}
      {key, value} -> {key, compact_text(value)}
    end)
  end

  defp compact_feedback_value(_key, value) when is_binary(value), do: compact_text(value)
  defp compact_feedback_value(_key, value), do: value

  defp compact_text_list(values, limit) do
    values
    |> List.wrap()
    |> Enum.take(limit)
    |> Enum.map(&compact_text/1)
  end

  defp compact_text(nil), do: nil
  defp compact_text(value) when is_binary(value), do: String.slice(value, 0, 256)

  defp compact_text(value),
    do: value |> inspect(limit: 10, printable_limit: 256) |> compact_text()

  defp active_findings(ledger) when is_map(ledger) do
    ledger
    |> value("findings")
    |> case do
      findings when is_map(findings) -> Map.values(findings)
      findings when is_list(findings) -> findings
      _ -> []
    end
    |> Enum.filter(&(is_map(&1) and value(&1, "state") in @active_finding_states))
    |> Enum.map(&active_finding_projection/1)
    |> Enum.filter(&(is_binary(&1["id"]) and &1["id"] != ""))
    |> Enum.sort_by(& &1["id"])
    |> Enum.take(@feedback_list_limit)
  end

  defp active_findings(_ledger), do: []

  defp active_finding_projection(finding) do
    %{
      "id" => bounded_text(value(finding, "id")),
      "owner" => bounded_text(value(finding, "owner")),
      "severity" => bounded_text(value(finding, "severity")),
      "state" => bounded_text(value(finding, "state")),
      "title" => bounded_text(value(finding, "title")),
      "required_action" => bounded_text(value(finding, "required_action"))
    }
    |> maybe_put("anchor", active_finding_anchor(value(finding, "anchor")))
    |> maybe_put("evidence", bounded_text(value(finding, "evidence")))
  end

  defp active_finding_anchor(anchor) when is_map(anchor) do
    %{
      "path" => bounded_text(value(anchor, "path")),
      "side" => bounded_text(value(anchor, "side")),
      "line" => integer_value(anchor, "line")
    }
  end

  defp active_finding_anchor(_anchor), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_review_meta(meta, nil), do: meta
  defp maybe_put_review_meta(meta, review), do: Map.put(meta, "review", review)

  defp enum_string(value) when is_atom(value), do: Atom.to_string(value)
  defp enum_string(value) when is_binary(value), do: bounded_text(value)

  defp enum_string(value),
    do: value |> inspect(limit: 20, printable_limit: @feedback_text_limit) |> bounded_text()

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
