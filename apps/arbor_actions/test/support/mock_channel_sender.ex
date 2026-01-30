defmodule Arbor.Actions.Support.MockChannelSender do
  @moduledoc false

  @behaviour Arbor.Contracts.Comms.ChannelSender

  def channel_info do
    %{
      name: :mock,
      max_message_length: 100,
      supports_media: false,
      supports_threads: false,
      supports_outbound: true,
      latency: :realtime
    }
  end

  @impl Arbor.Contracts.Comms.ChannelSender
  def send_message(recipient, message, opts) do
    send(self(), {:mock_send, recipient, message, opts})
    Process.get(:mock_send_result, :ok)
  end

  @impl Arbor.Contracts.Comms.ChannelSender
  def format_for_channel(message) do
    # Simulate truncation at 100 chars for testing
    if String.length(message) > 100 do
      String.slice(message, 0, 97) <> "..."
    else
      message
    end
  end
end
