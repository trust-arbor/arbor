defmodule Arbor.Contracts.Comms.ChannelSender do
  @moduledoc """
  Behaviour for outbound message sending on a communication channel.

  Channels that support sending (Signal, Email) implement this behaviour.
  Inbound-only channels (Limitless) implement `ChannelReceiver` instead.

  ## Usage via Actions

  The `Arbor.Actions.Comms.SendMessage` action resolves a channel module
  at runtime via config, so `arbor_actions` has no compile-time dependency
  on `arbor_comms`.

  ## Convention: `channel_info/0`

  All channel modules (sender, receiver, or both) define a public
  `channel_info/0` function by convention. It is NOT a callback here
  to avoid conflicting-behaviour warnings when a module implements
  both `ChannelSender` and `ChannelReceiver`.
  """

  @doc "Send a message to a recipient."
  @callback send_message(recipient :: String.t(), message :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc "Format a message for this channel's constraints (length, encoding, etc.)."
  @callback format_for_channel(message :: String.t()) :: String.t()
end
