defmodule Arbor.Contracts.Comms.ChannelAdapter do
  @moduledoc """
  Behaviour for channels that can deliver `Interaction` requests to a
  human and parse responses back.

  Each channel (dashboard, Signal, Telegram, Discord, voice, ...)
  implements this so the `Arbor.Comms.InteractionRouter` can route to
  any of them uniformly. The adapter doesn't track which agent is
  waiting — it just delivers and recognizes. The router handles
  request-to-agent correlation via the persisted `InteractionRegistry`.
  """

  alias Arbor.Contracts.Comms.Interaction

  @typedoc "Identifier the adapter recognizes for the human in its channel."
  @type channel_user :: term()

  @typedoc """
  Result of parsing an incoming raw message. `:not_interaction` lets
  the adapter ignore traffic that isn't a response (regular chat,
  metadata, etc.).
  """
  @type parse_result ::
          {:interaction_response, request_id :: String.t(), Interaction.response(), map()}
          | :not_interaction

  @doc """
  Send an interaction request to the user via this channel.

  Adapters format the interaction appropriately (LiveView banner,
  Signal message with APPROVE/DENY instruction, Telegram inline
  buttons, etc.). Should return quickly — long-running I/O belongs in
  a dedicated process the adapter owns.
  """
  @callback send_interaction(channel_user(), Interaction.t()) :: :ok | {:error, term()}

  @doc """
  Parse a raw incoming message and decide whether it's a response to
  an outstanding interaction request. Returns
  `{:interaction_response, request_id, response, metadata}` if the
  adapter recognizes it as a response, or `:not_interaction` for
  regular traffic.

  The `metadata` map carries adapter-specific context the router may
  forward to audit signals or replay logic (e.g.
  `%{channel: :signal, replier_phone: "+1..."}`).
  """
  @callback parse_response(raw_message :: term()) :: parse_result()

  @doc """
  Identify the channel kind. Used by `InteractionRouter` for routing
  policy and by `PresenceTracker` for presence keying.
  """
  @callback channel_kind() :: atom()
end
