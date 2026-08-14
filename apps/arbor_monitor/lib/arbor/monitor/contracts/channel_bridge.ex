defmodule Arbor.Monitor.Contracts.ChannelBridge do
  @moduledoc """
  Consumer-owned port for ops-channel delivery and room creation.

  Library-specific to `arbor_monitor`. Implementations live above this
  library and are injected via `Arbor.Monitor.Config.channel_bridge_module/0`.
  """

  @type channel_id :: String.t()
  @type sender_type :: :system | :agent | :human
  @type participant :: %{id: String.t(), name: String.t(), type: sender_type()}

  @type deliver_error :: :not_found | :not_member | :rate_limited | :delivery_failed
  @type create_error :: :invalid_participants | :create_failed

  @callback deliver_channel_message(
              channel_id(),
              String.t(),
              String.t(),
              sender_type(),
              String.t()
            ) :: :ok | {:ok, :delivered} | {:error, deliver_error()}

  @callback create_ops_room(String.t(), [participant()]) ::
              {:ok, channel_id()} | {:error, create_error()}
end
