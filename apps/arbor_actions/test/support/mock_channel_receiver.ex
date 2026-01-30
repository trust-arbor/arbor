defmodule Arbor.Actions.Support.MockChannelReceiver do
  @moduledoc false

  @behaviour Arbor.Contracts.Comms.ChannelReceiver

  def channel_info do
    %{
      name: :mock_receiver,
      max_message_length: :unlimited,
      supports_media: false,
      supports_threads: false,
      supports_outbound: false,
      latency: :polling
    }
  end

  @impl Arbor.Contracts.Comms.ChannelReceiver
  def poll do
    Process.get(:mock_poll_result, {:ok, []})
  end
end
