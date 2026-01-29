defmodule Arbor.Comms.Dispatcher do
  @moduledoc """
  Dispatches outbound messages to the appropriate channel implementation.

  Handles message formatting, logging, and signal emission for
  all outbound communications.
  """

  alias Arbor.Comms.ChatLogger
  alias Arbor.Contracts.Comms.Message

  @channel_modules %{
    signal: Arbor.Comms.Channels.Signal
  }

  @doc """
  Send a message through the specified channel.
  """
  @spec send(atom(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send(channel, to, content, opts \\ []) do
    case Map.get(@channel_modules, channel) do
      nil ->
        {:error, {:unknown_channel, channel}}

      module ->
        outbound = Message.outbound(channel, to, content, opts)
        ChatLogger.log_message(outbound)

        case module.send_message(to, content, opts) do
          :ok ->
            emit_sent_signal(outbound)
            :ok

          {:error, reason} ->
            emit_failed_signal(outbound, reason)
            {:error, reason}
        end
    end
  end

  @doc """
  Reply to an inbound message.
  """
  @spec reply(Message.t(), String.t()) :: :ok | {:error, term()}
  def reply(%Message{} = original, response) do
    case Map.get(@channel_modules, original.channel) do
      nil ->
        {:error, {:unknown_channel, original.channel}}

      module ->
        outbound =
          Message.outbound(original.channel, original.from, response,
            reply_to: original.id,
            conversation_id: original.conversation_id
          )

        ChatLogger.log_message(outbound)

        case module.send_response(original, response) do
          :ok ->
            emit_sent_signal(outbound)
            :ok

          {:error, reason} ->
            emit_failed_signal(outbound, reason)
            {:error, reason}
        end
    end
  end

  @doc """
  Returns the module for a given channel, if registered.
  """
  @spec channel_module(atom()) :: module() | nil
  def channel_module(channel) do
    Map.get(@channel_modules, channel)
  end

  defp emit_sent_signal(%Message{} = msg) do
    Arbor.Signals.emit(:comms, :message_sent, %{
      channel: msg.channel,
      to: msg.to,
      message_id: msg.id
    })
  end

  defp emit_failed_signal(%Message{} = msg, reason) do
    Arbor.Signals.emit(:comms, :message_failed, %{
      channel: msg.channel,
      to: msg.to,
      message_id: msg.id,
      reason: inspect(reason)
    })
  end
end
