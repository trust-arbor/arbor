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
  Result of parsing an incoming raw message.

    * `{:interaction_response, request_id, response, metadata}` — full
      response with an explicit `request_id`. The router can route it
      to a specific pending interaction without ambiguity. Adapters
      that can always include the id (e.g., dashboard click events
      carry it natively, Signal messages that quote the suggested
      `irq_<hex>`) return this.

    * `{:interaction_response_partial, response, metadata}` — the
      decision is clear but no `request_id` was included. The router
      resolves this against pending interactions for the sender's
      user_id: zero pending → treat as regular chat; one pending →
      use it; multiple pending → adapter-specific disambiguation
      flow (typically an auto-reply listing them by id). Adapters
      use this when the channel UX makes copying the id painful
      (mobile messaging where the operator just wants to type
      "yes" or "approve").

    * `:not_interaction` — regular chat or metadata; the inbound
      router dispatches normally.
  """
  @type parse_result ::
          {:interaction_response, request_id :: String.t(), Interaction.response(), map()}
          | {:interaction_response_partial, Interaction.response(), map()}
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
