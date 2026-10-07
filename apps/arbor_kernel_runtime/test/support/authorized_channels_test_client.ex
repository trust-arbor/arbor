defmodule Arbor.Signals.TestChannelPrincipalAuthorizer do
  @moduledoc false

  alias Arbor.Contracts.Security.AuthContext

  def authorize_channel_principal(
        %AuthContext{principal_id: principal_id, identity_verified: true},
        _operation,
        _channel_id
      )
      when is_binary(principal_id) and principal_id != "",
      do: {:ok, principal_id}

  def authorize_channel_principal(_context, _operation, _channel_id),
    do: {:error, :unauthorized}
end

defmodule Arbor.Signals.AuthorizedChannelsTestClient do
  @moduledoc false

  alias Arbor.Contracts.Security.AuthContext
  alias Arbor.Signals.Channels

  def auth(principal_id),
    do: principal_id |> AuthContext.new() |> AuthContext.mark_verified()

  def create(name, principal_id, opts \\ []), do: Channels.create(name, auth(principal_id), opts)

  def invite(channel_id, invitee_id, keychain),
    do: Channels.invite(channel_id, invitee_id, keychain, auth(keychain.agent_id))

  def accept_invitation(channel_id, agent_id, inviter_id, sealed_key, keychain),
    do:
      Channels.accept_invitation(
        channel_id,
        inviter_id,
        sealed_key,
        keychain,
        auth(agent_id)
      )

  def send(channel_id, principal_id, type, data),
    do: Channels.send(channel_id, auth(principal_id), type, data)

  def leave(channel_id, principal_id), do: Channels.leave(channel_id, auth(principal_id))

  def revoke(channel_id, target_id, principal_id),
    do: Channels.revoke(channel_id, target_id, auth(principal_id))

  def rotate_key(channel_id, principal_id),
    do: Channels.rotate_key(channel_id, auth(principal_id))

  def schedule_rotation(channel_id, principal_id),
    do: Channels.schedule_rotation(channel_id, auth(principal_id))

  def cancel_scheduled_rotation(channel_id, principal_id),
    do: Channels.cancel_scheduled_rotation(channel_id, auth(principal_id))

  def decrypt_for_member(channel_id, principal_id, payload),
    do: Channels.decrypt_for_member(channel_id, auth(principal_id), payload)

  def list_channels(principal_id), do: Channels.list_channels(auth(principal_id))
  defdelegate get(channel_id), to: Channels
  defdelegate get_key(channel_id, principal_id), to: Channels
  defdelegate stats(), to: Channels
end
