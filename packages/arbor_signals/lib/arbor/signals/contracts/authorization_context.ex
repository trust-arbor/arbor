defmodule Arbor.Signals.Contracts.AuthorizationContext do
  @moduledoc """
  Trusted host adapter for an opaque authorization context.

  Implementations must recognize their exact context type. Merely containing a
  `principal_id` or `signed_request` map key is not sufficient. These callbacks
  extract proof-bound fields; the configured security provider still verifies
  the request and authorizes the exact operation.
  """

  @callback principal_id(term()) :: {:ok, String.t()} | {:error, term()}
  @callback signed_request(term()) :: {:ok, term()} | {:error, term()}
end
