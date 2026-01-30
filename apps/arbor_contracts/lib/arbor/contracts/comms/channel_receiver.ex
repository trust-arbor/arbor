defmodule Arbor.Contracts.Comms.ChannelReceiver do
  @moduledoc """
  Behaviour for inbound message polling on a communication channel.

  Channels that support receiving (Signal, Limitless) implement this
  behaviour. Outbound-only channels (Email) implement `ChannelSender`
  instead.

  ## Usage via Actions

  The `Arbor.Actions.Comms.PollMessages` action resolves a channel module
  at runtime via config, so `arbor_actions` has no compile-time dependency
  on `arbor_comms`.

  ## Convention: `channel_info/0`

  All channel modules (sender, receiver, or both) define a public
  `channel_info/0` function by convention. It is NOT a callback here
  to avoid conflicting-behaviour warnings when a module implements
  both `ChannelSender` and `ChannelReceiver`.
  """

  alias Arbor.Contracts.Comms.Message

  @doc "Poll for new inbound messages."
  @callback poll() :: {:ok, [Message.t()]} | {:error, term()}
end
