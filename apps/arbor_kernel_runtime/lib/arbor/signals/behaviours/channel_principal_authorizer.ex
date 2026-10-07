defmodule Arbor.Signals.Behaviours.ChannelPrincipalAuthorizer do
  @moduledoc """
  Consumer-owned port for authorizing a channel operation and deriving its
  principal from a trusted authorization envelope.

  Channel callers never supply a separate member identity. The configured
  implementation verifies the envelope, authorizes the exact channel resource,
  and returns the principal bound to that proof. Missing or malformed providers
  fail closed in `Arbor.Signals.Channels`.
  """

  alias Arbor.Contracts.Security.AuthContext

  @type operation ::
          :create
          | :invite
          | :accept_invitation
          | :send
          | :leave
          | :revoke
          | :rotate_key
          | :schedule_rotation
          | :cancel_scheduled_rotation
          | :decrypt
          | :list

  @callback authorize_channel_principal(AuthContext.t(), operation(), String.t() | nil) ::
              {:ok, String.t()} | {:error, term()}
end
