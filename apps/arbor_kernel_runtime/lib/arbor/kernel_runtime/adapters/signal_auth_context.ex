defmodule Arbor.KernelRuntime.Adapters.SignalAuthContext do
  @moduledoc """
  Adapts Arbor's authorization context to the Signals credential port.

  Only the host-owned context struct is admitted. Signals retains the original
  signed request and asks the configured security provider to verify it.
  """

  @behaviour Arbor.Signals.Contracts.AuthorizationContext

  alias Arbor.Contracts.Security.AuthContext

  @impl true
  def principal_id(%AuthContext{principal_id: id}) when is_binary(id) and id != "",
    do: {:ok, id}

  def principal_id(_context), do: {:error, :authenticated_principal_required}

  @impl true
  def signed_request(%AuthContext{signed_request: request}) when not is_nil(request),
    do: {:ok, request}

  def signed_request(_context), do: {:error, :identity_proof_required}
end
