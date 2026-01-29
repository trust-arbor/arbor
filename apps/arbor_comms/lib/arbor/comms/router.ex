defmodule Arbor.Comms.Router do
  @moduledoc """
  Routes inbound messages to registered handlers.

  Emits signals for all inbound messages, enabling other parts of
  the system (like Gateway) to react to communications.
  """

  alias Arbor.Contracts.Comms.Message

  @doc """
  Handle an inbound message by emitting a signal and routing to handlers.
  """
  @spec handle_inbound(Message.t()) :: :ok
  def handle_inbound(%Message{} = msg) do
    emit_signal(msg)
    :ok
  end

  defp emit_signal(%Message{} = msg) do
    Arbor.Signals.emit(:comms, :message_inbound, %{
      channel: msg.channel,
      from: msg.from,
      content_preview: String.slice(msg.content, 0, 100),
      message_id: msg.id,
      content_type: msg.content_type,
      metadata: msg.metadata
    })
  end
end
