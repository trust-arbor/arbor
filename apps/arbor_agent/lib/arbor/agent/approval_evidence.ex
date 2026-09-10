defmodule Arbor.Agent.ApprovalEvidence do
  @moduledoc """
  Trust's read-only adapter to the committed approval owners.

  Scope comes from the original request and decision from the owning terminal
  transition. Response actor/from/human metadata is deliberately not evidence
  of a verified responder. Configured by the umbrella, not by API callers.
  """

  @behaviour Arbor.Trust.Contracts.ApprovalEvidenceProvider

  @impl true
  def answered_approval(:interaction, request_id) do
    case Arbor.Comms.get_answered_approval(request_id) do
      {:ok, evidence} -> {:ok, evidence}
      _ -> {:error, :approval_evidence_unavailable}
    end
  end

  def answered_approval(:consensus, request_id) do
    with {:ok, proposal} <- Arbor.Consensus.get_proposal(request_id),
         true <- proposal.id == request_id,
         true <- proposal.topic in [:authorization_request, "authorization_request"],
         {:ok, decision} <- Arbor.Consensus.get_decision(request_id),
         true <- decision[:proposal_id] == request_id,
         requested when requested in [:approve, :deny, :rework] <- decision[:requested_decision],
         true <- terminal_matches?(proposal.status, requested) do
      metadata = proposal.metadata || %{}
      context = proposal.context || %{}

      evidence = %{
        source: :consensus,
        request_id: request_id,
        agent_id: proposal.proposer,
        principal_id: value(metadata, :principal_id) || proposal.proposer,
        resource_uri: value(metadata, :resource_uri) || value(context, :resource_uri),
        decision: requested
      }

      case decision[:verified_human_id] do
        human_id when is_binary(human_id) ->
          {:ok, Map.put(evidence, :verified_human_id, human_id)}

        _ ->
          {:ok, evidence}
      end
    else
      _ -> {:error, :approval_evidence_unavailable}
    end
  end

  def answered_approval(_source, _request_id), do: {:error, :approval_evidence_unavailable}

  defp terminal_matches?(status, :approve), do: status in [:approved, "approved"]

  defp terminal_matches?(status, decision) when decision in [:deny, :rework],
    do: status in [:rejected, "rejected"]

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
