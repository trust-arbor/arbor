defmodule Arbor.Orchestrator.Handlers.ConsensusHandler do
  @moduledoc """
  Handler bridging DOT graph nodes to the Arbor.Consensus facade.

  Dispatches by `type` attribute prefix `consensus.*`:

    * `consensus.propose` — submit a proposal for multi-perspective evaluation
    * `consensus.ask`     — advisory query (no binding decision)
    * `consensus.await`   — wait for decision on an existing proposal
    * `consensus.check`   — non-blocking status check

  ## Node attributes

    * `source_key`  — context key for proposal/question text (default: `"session.input"`)
    * `agent_id`    — override agent_id (default: from context `"session.agent_id"`)
    * `timeout`     — ms to wait (default: `"30000"`)
    * `evaluators`  — comma-separated evaluator names
    * `proposal_id` — for await/check, override (default: from context `"consensus.proposal_id"`)

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
end
