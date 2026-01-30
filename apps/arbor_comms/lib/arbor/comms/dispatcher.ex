defmodule Arbor.Comms.Dispatcher do
  @moduledoc """
  Dispatches outbound messages to the appropriate channel implementation.

  Handles message formatting, logging, and signal emission for
  all outbound communications. Maintains separate sender and receiver
  module registries.
  """

  alias Arbor.Comms.ChatLogger
  alias Arbor.Comms.Config
  alias Arbor.Contracts.Comms.Message
  alias Arbor.Contracts.Comms.ResponseEnvelope

  @sender_modules %{
    signal: Arbor.Comms.Channels.Signal,
    email: Arbor.Comms.Channels.Email
  }

  @receiver_modules %{
    signal: Arbor.Comms.Channels.Signal,
    limitless: Arbor.Comms.Channels.Limitless
  }

  @doc """
  Send a message through the specified channel.

  Supports friendly contact names that resolve to channel-specific identifiers.
  For example, "kim" can resolve to "kim@example.com" for email or a phone number for Signal.
  Literal identifiers (containing "@" for email, starting with "+" for Signal) pass through unchanged.
  """
  @spec send(atom(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send(channel, to, content, opts \\ []) do
    case Map.get(@sender_modules, channel) do
      nil ->
        {:error, {:unknown_channel, channel}}

      module ->
        # Resolve friendly name → channel-specific identifier
        resolved_to = Config.resolve_contact(to, channel) || to

        outbound = Message.outbound(channel, resolved_to, content, opts)
        ChatLogger.log_message(outbound)

        case module.send_message(resolved_to, content, opts) do
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

  Resolves the reply channel: if the origin channel can send, replies
  there. Otherwise checks `metadata[:response_channel]`, then falls
  back to `Config.default_response_channel/0`.
  """
  @spec reply(Message.t(), String.t()) :: :ok | {:error, term()}
  def reply(%Message{} = original, response) do
    reply_channel = resolve_reply_channel(original)

    case Map.get(@sender_modules, reply_channel) do
      nil ->
        {:error, {:no_sendable_channel, original.channel}}

      module ->
        to = original.metadata[:response_recipient] || original.from
        opts = reply_opts(original, reply_channel)

        outbound =
          Message.outbound(reply_channel, to, response,
            reply_to: original.id,
            conversation_id: original.conversation_id
          )

        ChatLogger.log_message(outbound)

        case module.send_message(to, response, opts) do
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
  Deliver a response envelope to the resolved channel.

  Resolves the recipient based on whether delivery is on the origin
  channel (reply to sender) or a different channel (use config).
  """
  @spec deliver_envelope(Message.t(), atom(), ResponseEnvelope.t()) :: :ok | {:error, term()}
  def deliver_envelope(%Message{} = original, channel, %ResponseEnvelope{} = envelope) do
    case Map.get(@sender_modules, channel) do
      nil ->
        {:error, {:unknown_channel, channel}}

      module ->
        to = resolve_recipient(original, channel)
        formatted = module.format_for_channel(envelope.body)

        opts =
          []
          |> maybe_add(:subject, envelope.subject)
          |> maybe_add(:attachments, envelope.attachments, [])

        outbound =
          Message.outbound(channel, to, formatted,
            reply_to: original.id,
            conversation_id: original.conversation_id
          )

        ChatLogger.log_message(outbound)

        case module.send_message(to, formatted, opts) do
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
  Returns the sender module for a given channel, if registered.
  """
  @spec sender_module(atom()) :: module() | nil
  def sender_module(channel) do
    Map.get(@sender_modules, channel)
  end

  @doc """
  Returns the receiver module for a given channel, if registered.
  """
  @spec receiver_module(atom()) :: module() | nil
  def receiver_module(channel) do
    Map.get(@receiver_modules, channel)
  end

  @doc """
  Returns the module for a given channel from either registry.

  Checks senders first, then receivers.
  """
  @spec channel_module(atom()) :: module() | nil
  def channel_module(channel) do
    Map.get(@sender_modules, channel) || Map.get(@receiver_modules, channel)
  end

  # ============================================================================
  # Reply Channel Resolution
  # ============================================================================

  defp resolve_reply_channel(%Message{channel: ch} = msg) do
    if Map.has_key?(@sender_modules, ch) do
      ch
    else
      msg.metadata[:response_channel] || Config.default_response_channel()
    end
  end

  defp reply_opts(%Message{} = msg, :email) do
    subject = msg.metadata["subject"] || "Arbor Message"
    [subject: "Re: #{subject}"]
  end

  defp reply_opts(_msg, _channel), do: []

  defp resolve_recipient(%Message{channel: channel, from: from}, channel), do: from

  defp resolve_recipient(%Message{metadata: metadata}, target_channel) do
    metadata[:response_recipient] ||
      Config.channel_config(target_channel)[:to] ||
      "unknown"
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_add(opts, _key, value, default) when value == default, do: opts
  defp maybe_add(opts, key, value, _default), do: Keyword.put(opts, key, value)

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
