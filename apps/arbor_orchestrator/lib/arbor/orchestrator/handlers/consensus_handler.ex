defmodule Arbor.Orchestrator.Handlers.ConsensusHandler do
  @moduledoc """
  Handler bridging DOT graph nodes to the Arbor.Consensus facade.

  Dispatches by `type` attribute prefix `consensus.*`:

    * `consensus.propose` — submit a proposal for multi-perspective evaluation
    * `consensus.ask`     — advisory query (no binding decision)
    * `consensus.await`   — wait for decision on an existing proposal
    * `consensus.check`   — non-blocking status check
    * `consensus.decide`  — tally votes from parallel results into a CouncilDecision

  ## Node attributes (propose/ask/await/check)

    * `source_key`  — context key for proposal/question text (default: `"session.input"`)
    * `agent_id`    — override agent_id (default: from context `"session.agent_id"`)
    * `timeout`     — ms to wait (default: `"30000"`)
    * `evaluators`  — comma-separated evaluator names
    * `proposal_id` — for await/check, override (default: from context `"consensus.proposal_id"`)

  ## Node attributes (consensus.decide)

    * `quorum`  — "majority" | "supermajority" | "unanimous" | integer (default: `"majority"`)
    * `mode`    — "decision" | "advisory" (default: `"decision"`)

  Uses `Code.ensure_loaded?/1` + `apply/3` for cross-hierarchy calls.
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @read_only ~w(consensus.await consensus.check)
  @consensus_mod Arbor.Consensus

  @impl true
  def execute(node, context, _graph, _opts) do
    type = Map.get(node.attrs, "type", "consensus.propose")
    handle_type(type, node, context)
  rescue
    e -> fail("#{Map.get(node.attrs, "type")}: #{Exception.message(e)}")
  catch
    :exit, reason ->
      fail("#{Map.get(node.attrs, "type")}: process unavailable (#{inspect(reason)})")
  end

  @impl true
  def idempotency, do: :side_effecting

  def idempotency_for(type) when type in @read_only, do: :read_only
  def idempotency_for(_type), do: :side_effecting

  # --- Dispatch ---

  defp handle_type("consensus.propose", node, context) do
    source_key = Map.get(node.attrs, "source_key", "session.input")
    description = Context.get(context, source_key)

    unless description do
      throw({:missing, "no proposal description at context key '#{source_key}'"})
    end

    agent_id =
      Map.get(node.attrs, "agent_id") ||
        Context.get(context, "session.agent_id", "orchestrator")

    opts = build_consensus_opts(node)

    case apply(@consensus_mod, :propose, [
           %{description: description, proposer_id: agent_id},
           opts
         ]) do
      {:ok, proposal} ->
        proposal_id = extract_proposal_id(proposal)

        ok(%{
          "consensus.proposal_id" => proposal_id,
          "consensus.status" => "submitted"
        })

      {:error, reason} ->
        fail("consensus.propose failed: #{inspect(reason)}")
    end
  catch
    {:missing, msg} -> fail(msg)
  end

  defp handle_type("consensus.ask", node, context) do
    source_key = Map.get(node.attrs, "source_key", "session.input")
    question = Context.get(context, source_key)

    unless question do
      throw({:missing, "no question at context key '#{source_key}'"})
    end

    opts = build_consensus_opts(node)

    case apply(@consensus_mod, :ask, [question, opts]) do
      {:ok, decision} ->
        ok(%{
          "consensus.decision" => inspect(decision),
          "consensus.recommendation" => extract_recommendation(decision),
          "consensus.status" => "decided"
        })

      {:error, reason} ->
        fail("consensus.ask failed: #{inspect(reason)}")
    end
  catch
    {:missing, msg} -> fail(msg)
  end

  defp handle_type("consensus.await", node, context) do
    proposal_id =
      Map.get(node.attrs, "proposal_id") ||
        Context.get(context, "consensus.proposal_id")

    unless proposal_id do
      throw({:missing, "no proposal_id in attrs or context"})
    end

    case apply(@consensus_mod, :get_council_decision_for_proposal, [proposal_id]) do
      {:ok, nil} ->
        ok(%{"consensus.status" => "pending"})

      {:ok, decision} ->
        ok(%{
          "consensus.decision" => inspect(decision),
          "consensus.recommendation" => extract_recommendation(decision),
          "consensus.status" => "decided"
        })

      {:error, :not_found} ->
        ok(%{"consensus.status" => "pending"})

      {:error, reason} ->
        fail("consensus.await failed: #{inspect(reason)}")
    end
  catch
    {:missing, msg} -> fail(msg)
  end

  defp handle_type("consensus.check", node, context) do
    proposal_id =
      Map.get(node.attrs, "proposal_id") ||
        Context.get(context, "consensus.proposal_id")

    unless proposal_id do
      throw({:missing, "no proposal_id in attrs or context"})
    end

    case apply(@consensus_mod, :get_proposal_status_by_id, [proposal_id]) do
      {:ok, status} ->
        ok(%{"consensus.status" => to_string(status)})

      {:error, reason} ->
        fail("consensus.check failed: #{inspect(reason)}")
    end
  catch
    {:missing, msg} -> fail(msg)
  end

  defp handle_type("consensus.decide", node, context) do
    results = Context.get(context, "parallel.results", [])

    if results == [] do
      throw({:missing, "no parallel.results in context for consensus.decide"})
    end

    quorum_type = Map.get(node.attrs, "quorum", "majority")
    mode = parse_mode(Map.get(node.attrs, "mode", "decision"))
    question = Context.get(context, "council.question", "")

    # Parse votes from each branch's LLM response
    evaluations =
      results
      |> Enum.with_index()
      |> Enum.map(fn {result, idx} -> parse_vote_result(result, question, idx) end)
      |> Enum.reject(&is_nil/1)

    if evaluations == [] do
      fail("consensus.decide: no valid evaluations parsed from #{length(results)} results")
    else
      quorum = calculate_quorum(quorum_type, length(evaluations))
      proposal = build_decision_proposal(question, mode)

      case call_from_evaluations(proposal, evaluations, quorum: quorum) do
        {:ok, decision} ->
          ok(%{
            "council.decision" => to_string(Map.get(decision, :decision)),
            "council.approve_count" => Map.get(decision, :approve_count, 0),
            "council.reject_count" => Map.get(decision, :reject_count, 0),
            "council.abstain_count" => Map.get(decision, :abstain_count, 0),
            "council.quorum_met" => Map.get(decision, :quorum_met, false),
            "council.average_confidence" => Map.get(decision, :average_confidence, 0.0),
            "council.primary_concerns" => inspect(Map.get(decision, :primary_concerns, [])),
            "consensus.status" => "decided"
          })

        {:error, reason} ->
          fail("consensus.decide failed: #{inspect(reason)}")
      end
    end
  catch
    {:missing, msg} -> fail(msg)
  end

  defp handle_type(type, _node, _context) do
    fail("unknown consensus node type: #{type}")
  end

  # --- Helpers ---

  defp build_consensus_opts(node) do
    opts = []

    timeout = Map.get(node.attrs, "timeout")

    opts =
      if timeout do
        [{:timeout, String.to_integer(timeout)} | opts]
      else
        opts
      end

    evaluators = Map.get(node.attrs, "evaluators")

    if evaluators do
      evaluator_list = String.split(evaluators, ",") |> Enum.map(&String.trim/1)
      [{:evaluators, evaluator_list} | opts]
    else
      opts
    end
  end

  defp extract_proposal_id(%{id: id}), do: id
  defp extract_proposal_id(%{"id" => id}), do: id
  defp extract_proposal_id(proposal) when is_binary(proposal), do: proposal
  defp extract_proposal_id(_), do: "unknown"

  defp extract_recommendation(%{recommendation: rec}), do: to_string(rec)
  defp extract_recommendation(%{"recommendation" => rec}), do: to_string(rec)
  defp extract_recommendation(_), do: ""

  defp ok(context_updates) do
    %Outcome{status: :success, context_updates: context_updates}
  end

  defp fail(reason) do
    %Outcome{status: :fail, failure_reason: reason}
  end

  # --- consensus.decide helpers ---

  @evaluation_mod Arbor.Contracts.Consensus.Evaluation
  @proposal_mod Arbor.Contracts.Consensus.Proposal
  @council_decision_mod Arbor.Contracts.Consensus.CouncilDecision

  defp parse_vote_result(result, _question, index) do
    branch_id = Map.get(result, "id", "perspective_#{index}")
    ctx_updates = Map.get(result, "context_updates", %{})

    # Branch results have context_updates with last_response from CodergenHandler.
    # Also check vote.<perspective> key as fallback (unique per perspective, survives merges).
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

  defp parse_vote_data(text) do
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
        # JSON parse failed or text isn't JSON — try extracting JSON from markdown
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
            # Fall back to text-based vote detection
            {detect_vote_from_text(text), text, 0.5, [], 0.0}
        end
    end
  end

  defp extract_json_from_text(text) do
    # Try to find JSON object in the text (may be wrapped in markdown fence)
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

  defp detect_vote_from_text(text) do
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

  defp parse_vote("approve"), do: :approve
  defp parse_vote("reject"), do: :reject
  defp parse_vote("abstain"), do: :abstain
  defp parse_vote(other) when is_binary(other), do: detect_vote_from_text(other)
  defp parse_vote(_), do: :abstain

  defp parse_confidence(val) when is_float(val), do: min(max(val, 0.0), 1.0)
  defp parse_confidence(val) when is_integer(val), do: min(max(val / 1, 0.0), 1.0)

  defp parse_confidence(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> min(max(f, 0.0), 1.0)
      :error -> 0.5
    end
  end

  defp parse_confidence(_), do: 0.5

  defp parse_concerns(list) when is_list(list) do
    Enum.map(list, &to_string/1)
  end

  defp parse_concerns(_), do: []

  defp parse_float_val(val) when is_float(val), do: val
  defp parse_float_val(val) when is_integer(val), do: val / 1
  defp parse_float_val(_), do: 0.0

  defp sanitize_perspective(id) do
    id
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> String.trim_leading("_")
    |> case do
      "" -> "general"
      other -> other
    end
  end

  defp safe_perspective_atom(name) do
    # Orchestrator is standalone (no arbor_common dep).
    # Perspective names come from DOT graph branch IDs, already sanitized.
    String.to_existing_atom(name)
  rescue
    ArgumentError -> :general
  end

  defp parse_mode("advisory"), do: :advisory
  defp parse_mode(_), do: :decision

  defp calculate_quorum("majority", count), do: div(count, 2) + 1
  defp calculate_quorum("supermajority", count), do: ceil(count * 2 / 3)
  defp calculate_quorum("unanimous", count), do: count

  defp calculate_quorum(value, _count) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> max(n, 1)
      :error -> 1
    end
  end

  defp calculate_quorum(_, _count), do: 1

  defp build_evaluation(attrs) do
    if Code.ensure_loaded?(@evaluation_mod) do
      case apply(@evaluation_mod, :new, [attrs]) do
        {:ok, eval} -> apply(@evaluation_mod, :seal, [eval])
        {:error, _} -> nil
      end
    else
      nil
    end
  end

  defp build_decision_proposal(question, mode) do
    if Code.ensure_loaded?(@proposal_mod) do
      case apply(@proposal_mod, :new, [
             %{
               proposer: "dot_council",
               topic: :general,
               mode: mode,
               description: question,
               target_layer: 4
             }
           ]) do
        {:ok, proposal} -> proposal
        {:error, _} -> nil
      end
    else
      nil
    end
  end

  defp call_from_evaluations(nil, _evaluations, _opts) do
    {:error, :proposal_construction_failed}
  end

  defp call_from_evaluations(proposal, evaluations, opts) do
    if Code.ensure_loaded?(@council_decision_mod) do
      apply(@council_decision_mod, :from_evaluations, [proposal, evaluations, opts])
    else
      {:error, :council_decision_module_unavailable}
    end
  end
end
