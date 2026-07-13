defmodule Arbor.Actions.Consensus do
  @moduledoc """
  Consensus operations as Jido actions.

  These actions wrap the `Arbor.Consensus` facade so consensus operations can be
  invoked via `exec target="action"` in DOT pipelines instead of domain-specific
  handler types.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Propose` | Submit a proposal for multi-perspective evaluation |
  | `Ask` | Advisory query (non-binding) |
  | `Await` | Wait for decision on an existing proposal |
  | `Check` | Non-blocking status check |
  | `Decide` | Tally votes from parallel results into a CouncilDecision |
  """

  @doc false
  def format_reason(reason) when is_binary(reason), do: reason
  def format_reason(:not_found), do: "Proposal not found. Verify the proposal_id is correct."
  def format_reason(:timeout), do: "Operation timed out. Try again or increase the timeout."
  def format_reason({:unauthorized, detail}), do: "Unauthorized: #{inspect(detail)}"
  def format_reason(reason) when is_atom(reason), do: "#{reason}"
  def format_reason(reason), do: inspect(reason)

  # ============================================================================
  # Propose
  # ============================================================================

  defmodule Propose do
    @moduledoc """
    Submit a proposal for multi-perspective evaluation.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `description` | string | yes | Proposal description |
    | `agent_id` | string | no | Override agent ID (default: "orchestrator") |
    | `timeout` | integer | no | Timeout in ms |
    | `evaluators` | string | no | Comma-separated evaluator names |
    """
    use Jido.Action,
      name: "consensus_propose",
      description: "Submit a proposal for multi-perspective consensus evaluation",
      schema: [
        description: [type: :string, required: true, doc: "Proposal description"],
        agent_id: [type: :string, required: false, doc: "Agent ID"],
        timeout: [type: :integer, required: false, doc: "Timeout in ms"],
        evaluators: [type: :string, required: false, doc: "Comma-separated evaluator names"]
      ]

    @impl true
    def run(params, context) do
      description = params[:description] || params["description"]

      unless description && description != "" do
        raise ArgumentError, "description is required"
      end

      agent_id = params[:agent_id] || params["agent_id"] || "orchestrator"
      caller_id = context[:agent_id]
      opts = build_opts(params)
      attrs = %{description: description, proposer_id: agent_id}

      result =
        if context[:agent_id] do
          Arbor.Consensus.authorize_propose(caller_id || agent_id, attrs, opts)
        else
          Arbor.Consensus.propose(attrs, opts)
        end

      case result do
        {:ok, proposal_id} ->
          {:ok, %{proposal_id: to_string(proposal_id), status: "submitted"}}

        {:error, {:unauthorized, _}} ->
          {:error,
           "Consensus propose unauthorized. You may not have the required trust level for this operation."}

        {:error, reason} ->
          {:error, "Consensus propose failed: #{Arbor.Actions.Consensus.format_reason(reason)}"}
      end
    rescue
      e -> {:error, "Consensus propose error: #{Exception.message(e)}"}
    catch
      :exit, _reason ->
        {:error,
         "Consensus system is not available. It may still be starting up — try again in a moment."}
    end

    defp build_opts(params) do
      opts = []

      opts =
        case params[:timeout] || params["timeout"] do
          nil -> opts
          t when is_integer(t) -> [{:timeout, t} | opts]
          t when is_binary(t) -> [{:timeout, String.to_integer(t)} | opts]
          _ -> opts
        end

      case params[:evaluators] || params["evaluators"] do
        nil ->
          opts

        evaluators when is_binary(evaluators) ->
          list = evaluators |> String.split(",") |> Enum.map(&String.trim/1)
          [{:evaluators, list} | opts]

        _ ->
          opts
      end
    end
  end

  # ============================================================================
  # Ask
  # ============================================================================

  defmodule Ask do
    @moduledoc """
    Advisory query through the consensus system (non-binding).

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `question` | string | yes | The question to ask |
    | `timeout` | integer | no | Timeout in ms |
    | `evaluators` | string | no | Comma-separated evaluator names |
    """
    use Jido.Action,
      name: "consensus_ask",
      description: "Ask an advisory question through the consensus system",
      schema: [
        question: [type: :string, required: true, doc: "Question to ask"],
        timeout: [type: :integer, required: false, doc: "Timeout in ms"],
        evaluators: [type: :string, required: false, doc: "Comma-separated evaluator names"]
      ]

    @impl true
    def run(params, context) do
      question = params[:question] || params["question"]

      unless question && question != "" do
        raise ArgumentError, "question is required"
      end

      caller_id = context[:agent_id]
      opts = build_opts(params)

      result =
        if context[:agent_id] do
          Arbor.Consensus.authorize_ask(caller_id, question, opts)
        else
          Arbor.Consensus.ask(question, opts)
        end

      case result do
        {:ok, decision} ->
          {:ok,
           %{
             decision: inspect(decision),
             recommendation: extract_recommendation(decision),
             status: "decided"
           }}

        {:error, {:unauthorized, _}} ->
          {:error,
           "Consensus ask unauthorized. You may not have the required trust level for this operation."}

        {:error, reason} ->
          {:error, "Consensus ask failed: #{Arbor.Actions.Consensus.format_reason(reason)}"}
      end
    rescue
      e -> {:error, "Consensus ask error: #{Exception.message(e)}"}
    catch
      :exit, _reason ->
        {:error,
         "Consensus system is not available. It may still be starting up — try again in a moment."}
    end

    defp extract_recommendation(%{recommendation: rec}), do: to_string(rec)
    defp extract_recommendation(%{"recommendation" => rec}), do: to_string(rec)
    defp extract_recommendation(_), do: ""

    defp build_opts(params) do
      opts = []

      opts =
        case params[:timeout] || params["timeout"] do
          nil -> opts
          t when is_integer(t) -> [{:timeout, t} | opts]
          t when is_binary(t) -> [{:timeout, String.to_integer(t)} | opts]
          _ -> opts
        end

      case params[:evaluators] || params["evaluators"] do
        nil ->
          opts

        evaluators when is_binary(evaluators) ->
          list = evaluators |> String.split(",") |> Enum.map(&String.trim/1)
          [{:evaluators, list} | opts]

        _ ->
          opts
      end
    end
  end

  # ============================================================================
  # Await
  # ============================================================================

  defmodule Await do
    @moduledoc """
    Wait for decision on an existing proposal.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `proposal_id` | string | yes | The proposal ID to await |
    """
    use Jido.Action,
      name: "consensus_await",
      description: "Wait for a council decision on an existing proposal",
      schema: [
        proposal_id: [type: :string, required: true, doc: "Proposal ID"]
      ]

    @impl true
    def run(params, _context) do
      proposal_id = params[:proposal_id] || params["proposal_id"]

      unless proposal_id && proposal_id != "" do
        raise ArgumentError, "proposal_id is required"
      end

      case Arbor.Consensus.get_council_decision_for_proposal(proposal_id) do
        {:ok, nil} ->
          {:ok, %{status: "pending"}}

        {:ok, decision} ->
          {:ok,
           %{
             decision: inspect(decision),
             recommendation: extract_recommendation(decision),
             status: "decided"
           }}

        {:error, :not_found} ->
          {:ok, %{status: "pending"}}

        {:error, reason} ->
          {:error, "Consensus await failed: #{Arbor.Actions.Consensus.format_reason(reason)}"}
      end
    rescue
      e -> {:error, "Consensus await error: #{Exception.message(e)}"}
    catch
      :exit, _reason ->
        {:error,
         "Consensus system is not available. It may still be starting up — try again in a moment."}
    end

    defp extract_recommendation(%{recommendation: rec}), do: to_string(rec)
    defp extract_recommendation(%{"recommendation" => rec}), do: to_string(rec)
    defp extract_recommendation(_), do: ""
  end

  # ============================================================================
  # Check
  # ============================================================================

  defmodule Check do
    @moduledoc """
    Non-blocking status check on a proposal.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `proposal_id` | string | yes | The proposal ID to check |
    """
    use Jido.Action,
      name: "consensus_check",
      description: "Check the status of an existing proposal",
      schema: [
        proposal_id: [type: :string, required: true, doc: "Proposal ID"]
      ]

    @impl true
    def run(params, _context) do
      proposal_id = params[:proposal_id] || params["proposal_id"]

      unless proposal_id && proposal_id != "" do
        raise ArgumentError, "proposal_id is required"
      end

      case Arbor.Consensus.get_proposal_status_by_id(proposal_id) do
        {:ok, status} ->
          {:ok, %{status: to_string(status)}}

        {:error, reason} ->
          {:error, "Consensus check failed: #{Arbor.Actions.Consensus.format_reason(reason)}"}
      end
    rescue
      e -> {:error, "Consensus check error: #{Exception.message(e)}"}
    catch
      :exit, _reason ->
        {:error,
         "Consensus system is not available. It may still be starting up — try again in a moment."}
    end
  end

  # ============================================================================
  # Decide
  # ============================================================================

  defmodule Decide do
    @moduledoc """
    Tally votes from parallel branch results into a CouncilDecision.

    Parses vote data (JSON, markdown-fenced JSON, or text-based detection) from
    each parallel branch result and applies quorum rules to produce a decision.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `results` | list | yes | Parallel branch results to tally |
    | `question` | string | no | The question being decided |
    | `quorum` | string | no | "majority" / "supermajority" / "unanimous" / integer string |
    | `mode` | string | no | "decision" / "advisory" |

    When called from DOT pipelines via `exec target="action"` with `context_keys`,
    params may contain full context key names (e.g. `"parallel.results"` instead of `"results"`).
    """
    use Jido.Action,
      name: "consensus_decide",
      description: "Tally votes from parallel results into a council decision",
      schema: [
        results: [type: {:list, :map}, required: false, doc: "Parallel branch results"],
        question: [type: :string, required: false, doc: "Question being decided"],
        quorum: [type: :string, required: false, doc: "Quorum type"],
        mode: [type: :string, required: false, doc: "Decision or advisory mode"]
      ]

    alias Arbor.Contracts.Consensus.{CouncilDecision, Evaluation, Proposal}

    @impl true
    def run(params, _context) do
      # Accept both short param names and full context key names from DOT pipelines
      results =
        params["parallel.results"] || params[:results] || params["results"] || []

      question =
        params["council.question"] || params[:question] || params["question"] || ""

      quorum_type = params[:quorum] || params["quorum"] || "majority"
      mode = parse_mode(params[:mode] || params["mode"] || "decision")

      if results == [] do
        {:error, "consensus.decide: no results to tally"}
      else
        decide(results, question, quorum_type, mode)
      end
    end

    defp decide(results, question, quorum_type, mode) do
      evaluations =
        results
        |> Enum.with_index()
        |> Enum.map(fn {result, idx} -> parse_vote_result(result, idx) end)
        |> Enum.reject(&is_nil/1)

      if evaluations == [] do
        {:error, "consensus.decide: no valid evaluations parsed from #{length(results)} results"}
      else
        quorum = decision_quorum(quorum_type, evaluations)
        proposal = build_decision_proposal(question, mode)

        case call_from_evaluations(proposal, evaluations, quorum: quorum) do
          {:ok, decision} ->
            perspective_votes = perspective_votes(decision.evaluations)
            vetoes = vetoes(decision.evaluations)

            {:ok,
             %{
               decision: to_string(Map.get(decision, :decision)),
               approve_count: Map.get(decision, :approve_count, 0),
               reject_count: Map.get(decision, :reject_count, 0),
               abstain_count: Map.get(decision, :abstain_count, 0),
               quorum_met: Map.get(decision, :quorum_met, false),
               average_confidence: Map.get(decision, :average_confidence, 0.0),
               primary_concerns: Map.get(decision, :primary_concerns, []),
               perspective_votes: perspective_votes,
               security_veto: "security" in vetoes,
               vetoes: vetoes,
               status: "decided"
             }}

          {:error, reason} ->
            {:error, "Consensus decide failed: #{Arbor.Actions.Consensus.format_reason(reason)}"}
        end
      end
    end

    # --- Vote parsing ---

    defp parse_vote_result(result, index) do
      branch_id = Map.get(result, "id", "perspective_#{index}")
      ctx_updates = Map.get(result, "context_updates", %{})

      response_text =
        Map.get(ctx_updates, "last_response") ||
          Map.get(ctx_updates, "vote.#{branch_id}") ||
          Map.get(result, "notes", "")

      if is_binary(response_text) and response_text != "" do
        {vote, reasoning, confidence, concerns, risk_score} = parse_vote_data(response_text)

        build_evaluation(%{
          proposal_id: "dot_council",
          evaluator_id: branch_id,
          perspective: safe_perspective_atom(sanitize_perspective(branch_id)),
          vote: vote,
          reasoning: reasoning,
          confidence: confidence,
          concerns: concerns,
          risk_score: risk_score
        })
      else
        nil
      end
    end

    @doc false
    def parse_vote_data(text) do
      case Jason.decode(text) do
        {:ok, json} when is_map(json) ->
          {
            parse_vote(Map.get(json, "vote", "abstain")),
            Map.get(json, "reasoning", text),
            parse_confidence(Map.get(json, "confidence", 0.5)),
            parse_concerns(Map.get(json, "concerns", [])),
            parse_float_val(Map.get(json, "risk_score", 0.0))
          }

        _ ->
          case extract_json_from_text(text) do
            {:ok, json} ->
              {
                parse_vote(Map.get(json, "vote", "abstain")),
                Map.get(json, "reasoning", text),
                parse_confidence(Map.get(json, "confidence", 0.5)),
                parse_concerns(Map.get(json, "concerns", [])),
                parse_float_val(Map.get(json, "risk_score", 0.0))
              }

            :error ->
              {detect_vote_from_text(text), text, 0.5, [], 0.0}
          end
      end
    end

    @doc false
    def extract_json_from_text(text) do
      case Regex.run(~r/\{[^{}]*"vote"[^{}]*\}/s, text) do
        [json_str] ->
          case Jason.decode(json_str) do
            {:ok, json} when is_map(json) -> {:ok, json}
            _ -> :error
          end

        _ ->
          :error
      end
    end

    @doc false
    def detect_vote_from_text(text) do
      lower = String.downcase(text)

      cond do
        String.contains?(lower, "\"vote\":") or String.contains?(lower, "\"vote\" :") ->
          cond do
            String.contains?(lower, "\"approve\"") -> :approve
            String.contains?(lower, "\"reject\"") -> :reject
            true -> :abstain
          end

        has_only_word?(lower, "approve") and not has_only_word?(lower, "reject") ->
          :approve

        has_only_word?(lower, "reject") and not has_only_word?(lower, "approve") ->
          :reject

        true ->
          :abstain
      end
    end

    defp has_only_word?(text, word) do
      Regex.match?(~r/\b#{word}\b/, text)
    end

    @doc false
    def parse_vote("approve"), do: :approve
    def parse_vote("reject"), do: :reject
    def parse_vote("abstain"), do: :abstain
    def parse_vote(other) when is_binary(other), do: detect_vote_from_text(other)
    def parse_vote(_), do: :abstain

    @doc false
    def parse_confidence(val) when is_float(val), do: min(max(val, 0.0), 1.0)
    def parse_confidence(val) when is_integer(val), do: min(max(val / 1, 0.0), 1.0)

    def parse_confidence(val) when is_binary(val) do
      case Float.parse(val) do
        {f, _} -> min(max(f, 0.0), 1.0)
        :error -> 0.5
      end
    end

    def parse_confidence(_), do: 0.5

    defp parse_concerns(list) when is_list(list), do: Enum.map(list, &normalize_concern/1)
    defp parse_concerns(_), do: []

    defp normalize_concern(concern) when is_binary(concern), do: concern

    defp normalize_concern(concern) do
      case Jason.encode(concern) do
        {:ok, encoded} -> encoded
        {:error, _reason} -> inspect(concern, limit: 20, printable_limit: 1_024)
      end
    end

    defp parse_float_val(val) when is_float(val), do: val
    defp parse_float_val(val) when is_integer(val), do: val / 1
    defp parse_float_val(_), do: 0.0

    defp sanitize_perspective(id) do
      id
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
      |> String.trim_leading("_")
      |> case do
        "" -> "adversarial"
        other -> other
      end
    end

    defp safe_perspective_atom(name) do
      String.to_existing_atom(name)
    rescue
      ArgumentError -> :adversarial
    end

    defp parse_mode("advisory"), do: :advisory
    defp parse_mode(_), do: :decision

    @doc false
    def calculate_quorum("majority", count), do: div(count, 2) + 1
    def calculate_quorum("supermajority", count), do: ceil(count * 2 / 3)
    def calculate_quorum("unanimous", count), do: count

    def calculate_quorum(value, _count) when is_binary(value) do
      case Integer.parse(value) do
        {n, _} -> max(n, 1)
        :error -> 1
      end
    end

    def calculate_quorum(_, _count), do: 1

    defp decision_quorum(quorum_type, evaluations)
         when quorum_type in ["majority", "supermajority", "unanimous"] do
      active_vote_count = Enum.count(evaluations, &(&1.vote in [:approve, :reject]))

      if active_vote_count == 0 do
        1
      else
        calculate_quorum(quorum_type, active_vote_count)
      end
    end

    defp decision_quorum(quorum_type, evaluations) do
      calculate_quorum(quorum_type, length(evaluations))
    end

    defp build_evaluation(attrs) do
      case Evaluation.new(attrs) do
        {:ok, eval} -> Evaluation.seal(eval)
        {:error, _} -> nil
      end
    end

    defp build_decision_proposal(question, mode) do
      case Proposal.new(%{
             proposer: "dot_council",
             topic: :general,
             mode: mode,
             description: question,
             target_layer: 4
           }) do
        {:ok, proposal} -> proposal
        {:error, _} -> nil
      end
    end

    defp call_from_evaluations(nil, _evaluations, _opts) do
      {:error, :proposal_construction_failed}
    end

    defp call_from_evaluations(proposal, evaluations, opts) do
      CouncilDecision.from_evaluations(proposal, evaluations, opts)
    end

    defp perspective_votes(evaluations) do
      Map.new(evaluations, fn eval ->
        {eval.evaluator_id, to_string(eval.vote)}
      end)
    end

    defp vetoes(evaluations) do
      evaluations
      |> Enum.filter(&(&1.vote == :reject))
      |> Enum.map(& &1.evaluator_id)
      |> Enum.filter(&(&1 == "security"))
      |> Enum.uniq()
    end
  end

  # ============================================================================
  # DecideReview
  # ============================================================================

  defmodule DecideReview do
    @moduledoc """
    Reduce strict reviewer reports into a frozen code-review finding ledger.

    Unlike `Decide`, this action accepts only a JSON object matching
    `ReviewLedgerCore`'s report contract. It never infers votes or findings from
    prose. Missing, failed, malformed, and unknown branch reports remain
    abstentions through the ledger's complete-perspective vote set.
    """
    use Jido.Action,
      name: "consensus_decide_review",
      description: "Apply strict code-review reports to a frozen finding ledger",
      schema:
        Zoi.object(%{
          results:
            Zoi.array(
              Zoi.map(Zoi.string(), Zoi.json()),
              description: "Parallel reviewer branch results"
            )
            |> Zoi.optional(),
          review_cycle:
            Zoi.union([Zoi.integer(), Zoi.string()], description: "Next review cycle")
            |> Zoi.optional(),
          finding_ledger:
            Zoi.map(Zoi.string(), Zoi.json(), description: "Frozen finding ledger")
            |> Zoi.optional(),
          delta_ranges:
            Zoi.map(Zoi.string(), Zoi.json(), description: "Changed line ranges for a recheck")
            |> Zoi.optional()
        })

    # Jido's strict converter closes nested objects, but these three values are dynamic JSON maps.
    defoverridable to_tool: 0

    def to_tool do
      tool = Jido.Action.Tool.to_tool(__MODULE__)
      Map.update!(tool, :parameters_schema, &Map.put(&1, :additionalProperties, false))
    end

    alias Arbor.Actions.Coding.ReviewLedgerCore

    @impl true
    def run(params, _context) when is_map(params) do
      with {:ok, results} <- results_param(params),
           {:ok, review_cycle} <- review_cycle_param(params),
           {:ok, finding_ledger} <- finding_ledger_param(params),
           {:ok, delta_ranges} <- delta_ranges_param(params),
           {:ok, ledger} <- ReviewLedgerCore.new(finding_ledger),
           {:ok, reports} <- strict_reports(results, ledger, review_cycle, delta_ranges),
           {:ok, completed_ledger} <-
             ReviewLedgerCore.apply_cycle(ledger, review_cycle, %{
               "reports" => reports,
               "delta_ranges" => delta_ranges
             }) do
        {:ok, result_for(completed_ledger)}
      else
        {:error, reason} -> review_error(reason)
      end
    end

    def run(_params, _context), do: review_error(:invalid_params)

    defp results_param(params) do
      case param(params, ["parallel.results", :results, "results"], []) do
        results when is_list(results) -> {:ok, results}
        _other -> {:error, :invalid_parallel_results}
      end
    end

    defp review_cycle_param(params) do
      params
      |> param(["review_cycle", "review.cycle", :review_cycle], :missing)
      |> parse_review_cycle()
    end

    defp finding_ledger_param(params) do
      case param(params, ["finding_ledger", "review.finding_ledger", :finding_ledger], %{}) do
        ledger when is_map(ledger) -> {:ok, ledger}
        _other -> {:error, :invalid_finding_ledger}
      end
    end

    defp delta_ranges_param(params) do
      case param(params, ["delta_ranges", "review.delta_ranges", :delta_ranges], %{}) do
        ranges when is_map(ranges) -> {:ok, ranges}
        _other -> {:error, :invalid_delta_ranges}
      end
    end

    defp param(params, keys, default) do
      Enum.find_value(keys, default, fn key ->
        case Map.fetch(params, key) do
          {:ok, value} -> {:found, value}
          :error -> false
        end
      end)
      |> case do
        {:found, value} -> value
        value -> value
      end
    end

    defp parse_review_cycle(cycle) when is_integer(cycle) and cycle > 0, do: {:ok, cycle}

    defp parse_review_cycle(cycle) when is_binary(cycle) do
      case Integer.parse(cycle) do
        {number, ""} when number > 0 ->
          if Integer.to_string(number) == cycle,
            do: {:ok, number},
            else: {:error, :invalid_review_cycle}

        _ ->
          {:error, :invalid_review_cycle}
      end
    end

    defp parse_review_cycle(_cycle), do: {:error, :invalid_review_cycle}

    defp strict_reports(results, ledger, review_cycle, delta_ranges) do
      Enum.reduce_while(results, {:ok, %{}}, fn branch, {:ok, reports} ->
        case strict_report(branch, ledger, review_cycle, delta_ranges) do
          {:ok, perspective, report} ->
            if Map.has_key?(reports, perspective) do
              {:halt, {:error, :ambiguous_duplicate_perspective_report}}
            else
              {:cont, {:ok, Map.put(reports, perspective, report)}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}

          :abstain ->
            {:cont, {:ok, reports}}
        end
      end)
    end

    defp strict_report(branch, ledger, review_cycle, delta_ranges) when is_map(branch) do
      with {:ok, perspective} <- branch_perspective(branch),
           true <- perspective in ledger["perspectives"],
           true <- Map.get(branch, "status") in ["success", "partial_success"],
           %{} = context_updates <- Map.get(branch, "context_updates"),
           response when is_binary(response) <- Map.get(context_updates, "last_response"),
           {:ok, report} when is_map(report) <- Jason.decode(response),
           true <- valid_report?(ledger, review_cycle, delta_ranges, perspective, report) do
        {:ok, perspective, report}
      else
        {:error, :ambiguous_branch_perspective} -> {:error, :ambiguous_branch_perspective}
        _other -> :abstain
      end
    end

    defp strict_report(_branch, _ledger, _review_cycle, _delta_ranges), do: :abstain

    defp branch_perspective(branch) do
      case {Map.get(branch, "id"), Map.get(branch, "perspective")} do
        {id, nil} when is_binary(id) ->
          {:ok, id}

        {nil, perspective} when is_binary(perspective) ->
          {:ok, perspective}

        {id, id} when is_binary(id) ->
          {:ok, id}

        {id, perspective} when is_binary(id) and is_binary(perspective) ->
          {:error, :ambiguous_branch_perspective}

        _other ->
          :abstain
      end
    end

    defp valid_report?(ledger, review_cycle, delta_ranges, perspective, report) do
      match?(
        {:ok, _},
        ReviewLedgerCore.apply_cycle(ledger, review_cycle, %{
          "reports" => %{perspective => report},
          "delta_ranges" => delta_ranges
        })
      )
    end

    defp result_for(ledger) do
      context = ReviewLedgerCore.to_context(ledger)
      decision = context["review.decision"]
      counts = decision["vote_counts"]
      disposition = decision["disposition"]

      %{
        "decision" => top_level_decision(disposition),
        "approve_count" => counts["approve"],
        "reject_count" => counts["reject"],
        "abstain_count" => counts["abstain"],
        "quorum_met" => disposition == "accept",
        "perspective_votes" => context["review.perspective_votes"],
        "security_veto" => decision["security_veto"],
        "status" => "decided",
        "review_cycle" => ledger["review_cycle"],
        "finding_ledger" => ledger,
        "findings" => context["review.findings"],
        "out_of_scope" => context["review.out_of_scope"],
        "review_disposition" => disposition,
        "blocking_ids" => decision["blocking_ids"],
        "blocking_reasons" => decision["blocking_reasons"],
        "human_required" => disposition == "human_review"
      }
    end

    defp top_level_decision("accept"), do: "approved"
    defp top_level_decision("human_review"), do: "rejected"
    defp top_level_decision(_disposition), do: "deadlock"

    defp review_error(reason) do
      {:error,
       %{
         "code" => "consensus_decide_review_failed",
         "reason" => error_reason(reason)
       }}
    end

    defp error_reason(:ambiguous_duplicate_perspective_report),
      do: "ambiguous_duplicate_perspective_report"

    defp error_reason(:ambiguous_branch_perspective), do: "ambiguous_branch_perspective"

    defp error_reason(:invalid_delta_ranges), do: "invalid_delta_ranges"
    defp error_reason(:invalid_finding_ledger), do: "invalid_finding_ledger"
    defp error_reason(:invalid_ledger), do: "invalid_finding_ledger"
    defp error_reason(:invalid_ledger_options), do: "invalid_finding_ledger"
    defp error_reason(:ledger_perspectives_mismatch), do: "invalid_finding_ledger"
    defp error_reason(:invalid_parallel_results), do: "invalid_parallel_results"
    defp error_reason(:invalid_params), do: "invalid_params"
    defp error_reason(:invalid_review_cycle), do: "invalid_review_cycle"
    defp error_reason(:unexpected_review_cycle), do: "unexpected_review_cycle"
    defp error_reason(_reason), do: "invalid_review_input"
  end
end
