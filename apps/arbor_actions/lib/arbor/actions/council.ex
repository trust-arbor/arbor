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

      run_authorization =
        Map.get(context, :run_authorization) || Map.get(context, "run_authorization")

      with {:ok, request} <- Council.build_code_review_request(params),
           :ok <- Council.reject_bound_review_overrides(params, run_authorization),
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

      bound? =
        not is_nil(Map.get(context, :run_authorization) || Map.get(context, "run_authorization"))

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
          prior_candidate_commit delta_diff delta_files finding_ledger
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
    context =
      request
      |> CodeReviewRequest.to_context()
      |> Map.merge(review_context_overlay(action_context))

    question = Map.fetch!(context, "council.question")
    run_authorization = context_value(action_context, :run_authorization)

    with :ok <- reject_bound_review_overrides(params, run_authorization) do
      opts =
        [
          graph: review_graph_path(params, run_authorization),
          context: context
        ]
        |> maybe_put_unbound_review_overrides(params, run_authorization)
        |> put_opt(:timeout, get_param(params, :timeout))
        |> put_opt(:nested_engine_opts, context_value(action_context, :nested_engine_opts))
        |> put_opt(:run_authorization, run_authorization)

      Arbor.Consensus.decide(question, opts)
    end
  end

  @doc false
  def reject_bound_review_overrides(_params, nil), do: :ok

  def reject_bound_review_overrides(params, _run_authorization) do
    case Enum.find([:graph, :quorum], &(not is_nil(get_param(params, &1)))) do
      nil -> :ok
      key -> {:error, {:bound_council_override, key}}
    end
  end

  defp review_graph_path(params, nil),
    do: get_param(params, :graph) || default_code_review_graph_path()

  defp review_graph_path(_params, _run_authorization), do: default_code_review_graph_path()

  defp maybe_put_unbound_review_overrides(opts, params, nil) do
    opts
    |> Keyword.put(:mode, "decision")
    |> put_opt(:quorum, get_param(params, :quorum))
  end

  defp maybe_put_unbound_review_overrides(opts, _params, _run_authorization), do: opts

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
