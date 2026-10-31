defmodule Arbor.Trust.Contracts.ApprovalEvidenceProvider do
  @moduledoc """
  Read-only port for the original request and its winning approval answer.

  Providers read the owning request authority, never caller-supplied response
  metadata. The closed record contains source, request_id, agent_id,
  principal_id, resource_uri and normalized decision. Only a responder verified
  at the winning transition may add verified_human_id. Legacy and recovered
  answers carry no verified-human claim; this port grants no read or answer authority.
  """

  @callback answered_approval(:interaction | :consensus, String.t()) ::
              {:ok, map()} | {:error, :approval_evidence_unavailable}
end
