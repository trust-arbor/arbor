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
    def run(params, _context) do
      description = params[:description] || params["description"]

      unless description && description != "" do
        raise ArgumentError, "description is required"
      end

      agent_id = params[:agent_id] || params["agent_id"] || "orchestrator"
      opts = build_opts(params)

      case Arbor.Consensus.propose(
             %{description: description, proposer_id: agent_id},
             opts
           ) do
        {:ok, proposal_id} ->
          {:ok, %{proposal_id: to_string(proposal_id), status: "submitted"}}

        {:error, reason} ->
          {:error, "consensus.propose failed: #{inspect(reason)}"}
      end
    rescue
      e -> {:error, "consensus.propose error: #{Exception.message(e)}"}
    catch
      :exit, reason -> {:error, "consensus.propose unavailable: #{inspect(reason)}"}
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
    def run(params, _context) do
      question = params[:question] || params["question"]

      unless question && question != "" do
        raise ArgumentError, "question is required"
      end

      opts = build_opts(params)

      case Arbor.Consensus.ask(question, opts) do
        {:ok, decision} ->
          {:ok,
           %{
             decision: inspect(decision),
             recommendation: extract_recommendation(decision),
             status: "decided"
           }}

        {:error, reason} ->
          {:error, "consensus.ask failed: #{inspect(reason)}"}
      end
    rescue
      e -> {:error, "consensus.ask error: #{Exception.message(e)}"}
    catch
      :exit, reason -> {:error, "consensus.ask unavailable: #{inspect(reason)}"}
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
          {:error, "consensus.await failed: #{inspect(reason)}"}
      end
    rescue
      e -> {:error, "consensus.await error: #{Exception.message(e)}"}
    catch
      :exit, reason -> {:error, "consensus.await unavailable: #{inspect(reason)}"}
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
          {:error, "consensus.check failed: #{inspect(reason)}"}
      end
    rescue
      e -> {:error, "consensus.check error: #{Exception.message(e)}"}
    catch
      :exit, reason -> {:error, "consensus.check unavailable: #{inspect(reason)}"}
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
        quorum = calculate_quorum(quorum_type, length(evaluations))
        proposal = build_decision_proposal(question, mode)

        case call_from_evaluations(proposal, evaluations, quorum: quorum) do
          {:ok, decision} ->
            {:ok,
             %{
               decision: to_string(Map.get(decision, :decision)),
               approve_count: Map.get(decision, :approve_count, 0),
               reject_count: Map.get(decision, :reject_count, 0),
               abstain_count: Map.get(decision, :abstain_count, 0),
               quorum_met: Map.get(decision, :quorum_met, false),
               average_confidence: Map.get(decision, :average_confidence, 0.0),
               primary_concerns: inspect(Map.get(decision, :primary_concerns, [])),
               status: "decided"
             }}

          {:error, reason} ->
            {:error, "consensus.decide failed: #{inspect(reason)}"}
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

    defp parse_concerns(list) when is_list(list), do: Enum.map(list, &to_string/1)
    defp parse_concerns(_), do: []

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
  end
end
