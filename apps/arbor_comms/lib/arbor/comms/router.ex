defmodule Arbor.Comms.Router do
  @moduledoc """
  Routes inbound messages to the MessageHandler and emits signals.

  All inbound messages get a signal emitted for external observers.
  If the MessageHandler is enabled, messages are also dispatched
  for AI-powered response generation.
  """

  alias Arbor.Comms.Config
  alias Arbor.Comms.MessageHandler
  alias Arbor.Contracts.Comms.Message

  @doc """
  Handle an inbound message by emitting a signal and dispatching to handler.
  """
  @spec handle_inbound(Message.t()) :: :ok
  def handle_inbound(%Message{} = msg) do
    emit_signal(msg)
    maybe_dispatch(msg)
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

  defp maybe_dispatch(%Message{} = msg) do
    if Config.handler_enabled?() do
      MessageHandler.process(msg)
    end
  end
end
