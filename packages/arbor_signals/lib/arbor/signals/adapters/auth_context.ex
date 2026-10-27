defmodule Arbor.Signals.Adapters.AuthContext do
  @moduledoc """
  Exact-type adapter for the package-owned authorization context.

  Arbor and other hosts may configure their own adapter without teaching this
  package about host contract modules.
  """

  @behaviour Arbor.Signals.Contracts.AuthorizationContext

  alias Arbor.Signals.Contracts.AuthContext

  @impl true
  def principal_id(%AuthContext{principal_id: principal_id})
      when is_binary(principal_id) and principal_id != "",
      do: {:ok, principal_id}

  def principal_id(_context), do: {:error, :authenticated_principal_required}

  @impl true
  def signed_request(%AuthContext{principal_id: principal_id, signed_request: signed_request})
      when is_binary(principal_id) and principal_id != "" and not is_nil(signed_request),
      do: {:ok, signed_request}

  def signed_request(_context), do: {:error, :identity_proof_required}
end
