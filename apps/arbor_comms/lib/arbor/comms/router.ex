defmodule Arbor.Comms.Router do
  @moduledoc """
  Routes inbound messages to the MessageHandler and emits signals.

  All inbound messages get a signal emitted for external observers.
  If the message is recognized as a response to a pending HITL
  interaction request (e.g., "APPROVE irq_<hex>" on Signal), it's
  routed via `InteractionRouter.respond/3` instead of the chat
  handler — so an operator's approval reply doesn't double-dispatch
  to the chat path.

  Otherwise, if the MessageHandler is enabled, messages are dispatched
  for AI-powered response generation.
  """

  require Logger

  alias Arbor.Comms.Channels.Signal
  alias Arbor.Comms.Config
  alias Arbor.Comms.InteractionRouter
  alias Arbor.Comms.MessageHandler
  alias Arbor.Contracts.Comms.Message

  @doc """
  Handle an inbound message by emitting a signal and dispatching to
  either the InteractionRouter (if it parses as an HITL response) or
  the chat MessageHandler.
  """
  @spec handle_inbound(Message.t()) :: :ok
  def handle_inbound(%Message{} = msg) do
    emit_signal(msg)

    case maybe_route_as_interaction(msg) do
      :routed -> :ok
      :not_interaction -> maybe_dispatch(msg)
    end

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

  # Per-channel interaction-response routing. Currently only Signal —
  # dashboard responses come via LiveView click events, not raw chat
  # text, so the dashboard adapter's `parse_response/1` always returns
  # `:not_interaction`. Other channel adapters (Telegram, Discord)
  # would add their own dispatch arm here.
  defp maybe_route_as_interaction(%Message{channel: :signal, content: content, from: from})
       when is_binary(content) do
    case Signal.InteractionAdapter.parse_response(content) do
      {:interaction_response, request_id, response, metadata} ->
        metadata = Map.merge(metadata, %{from: from})

        case InteractionRouter.respond(request_id, response, metadata) do
          :ok ->
            Logger.info(
              "[Router] Signal interaction response: #{request_id} → #{inspect(response)}"
            )

            :routed

          {:error, :not_found} ->
            # Operator replied with APPROVE/DENY + a request_id, but
            # the interaction is unknown (already resolved, expired,
            # or typo). Treat as not_interaction so the chat handler
            # can still see it — better than swallowing silently.
            Logger.info(
              "[Router] Signal response references unknown request_id #{request_id}; passing through"
            )

            :not_interaction
        end

      :not_interaction ->
        :not_interaction
    end
  end

  defp maybe_route_as_interaction(_), do: :not_interaction

  defp maybe_dispatch(%Message{} = msg) do
    if Config.handler_enabled?() do
      MessageHandler.process(msg)
    end
  end
end
