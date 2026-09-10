defmodule Arbor.Trust.Contracts.ApprovalEvidenceProvider do
  @moduledoc """
  Read-only port for the original request and its winning approval answer.

  Providers read the owning request authority, never caller-supplied response
  metadata. Legacy answers carry no verified-human claim.
  """

  @callback answered_approval(:interaction | :consensus, String.t()) ::
              {:ok, map()} | {:error, :approval_evidence_unavailable}
end
