defmodule Arbor.Historian.Host.AuthoritySource do
  @moduledoc "Inline journal delegation preserves the registered Historian puller's caller PID."
  @behaviour Arbor.Historian.Contracts.AuthoritySource
  @impl true
  def reconcile_authority_audit, do: Arbor.Security.reconcile_authority_audit()
  @impl true
  def authority_audit_delivery_batch, do: Arbor.Security.authority_audit_delivery_batch()
  @impl true
  def acknowledge_authority_audit(id, digest),
    do: Arbor.Security.acknowledge_authority_audit(id, digest)
end
