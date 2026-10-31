defmodule Arbor.Historian.Contracts.AuthoritySource do
  @moduledoc """
  Source-owned authority mutation journal, called in the actual puller's PID.

  Journal/storage denials remain source-owned and open-ended, including
  :unauthorized_audit_consumer, :audit_content_conflict and
  :audit_content_unavailable. Provider failures return :security_provider_unavailable;
  malformed responses return :invalid_authority_source_reply. No callback may
  move the source call into a Task, proxy process or remote node.
  """
  @callback reconcile_authority_audit() :: :ok | {:error, term()}
  @callback authority_audit_delivery_batch() :: {:ok, [map()]} | {:error, term()}
  @callback acknowledge_authority_audit(String.t(), String.t()) ::
              {:ok, term()} | {:error, term()}
end
