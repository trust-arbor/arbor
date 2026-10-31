defmodule Arbor.Historian.Contracts.Authorizer do
  @moduledoc """
  Capability admission for agent-facing history reads.

  The existing authorization denial vocabulary is forwarded unchanged. Common
  denials include :no_capability, :scope_mismatch and :policy_denied; upstream
  providers have an open error space. Missing or failed bindings return
  :security_provider_unavailable and malformed successes return
  :invalid_authorization_reply. Trusted host queries remain intentionally ungated.
  """
  @type decision :: {:ok, :authorized} | {:ok, :pending_approval, String.t()} | {:error, term()}
  @callback authorize(String.t(), String.t(), atom(), keyword()) :: decision()
  @callback authorize_self_scoped(
              String.t(),
              String.t(),
              String.t(),
              String.t(),
              atom(),
              keyword()
            ) :: decision()
end
