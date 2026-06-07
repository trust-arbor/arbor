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
  alias Arbor.Comms.InteractionRegistry
  alias Arbor.Comms.InteractionRouter
  alias Arbor.Comms.MessageHandler
  alias Arbor.Contracts.Comms.{Interaction, Message}

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
        route_explicit_response(request_id, response, metadata, from)

      {:interaction_response_partial, response, metadata} ->
        route_partial_response(response, metadata, from)

      :not_interaction ->
        :not_interaction
    end
  end

  defp maybe_route_as_interaction(_), do: :not_interaction

  defp route_explicit_response(request_id, response, metadata, from) do
    metadata = Map.merge(metadata, %{from: from})

    case InteractionRouter.respond(request_id, response, metadata) do
      :ok ->
        Logger.info("[Router] Signal interaction response: #{request_id} → #{inspect(response)}")

        :routed

      {:error, :not_found} ->
        # Operator replied with APPROVE/DENY + a request_id, but the
        # interaction is unknown (already resolved, expired, typo).
        # Pass through to chat — better than swallowing silently.
        Logger.info(
          "[Router] Signal response references unknown request_id #{request_id}; passing through"
        )

        :not_interaction
    end
  end

  # Partial response handling. Operator replied "APPROVE"/"DENY"/"yes"/
  # "no" without an id. Look up pending for their user_id; resolve or
  # disambiguate.
  defp route_partial_response(response, metadata, from) do
    user_id = signal_user_id()

    if is_binary(user_id) do
      case InteractionRegistry.list_pending_for_user(user_id) do
        [] ->
          # No pending → operator's "yes"/"approve" is just chat.
          # Pass through so the AI handler sees it.
          :not_interaction

        [%Interaction{request_id: rid}] ->
          # Exactly one pending. Use it.
          metadata = Map.merge(metadata, %{from: from, resolution: :sole_pending})
          route_explicit_response(rid, response, metadata, from)

        [%Interaction{} | _] = pending ->
          # Multi-pending. Ask the operator to disambiguate by sending
          # a Signal reply listing them. Treat as :routed so the chat
          # handler doesn't ALSO process the ambiguous "yes."
          send_disambiguation(from, response, pending)
          :routed
      end
    else
      # No user_id configured for the Signal account — can't resolve.
      :not_interaction
    end
  end

  # Format and send the multi-pending disambiguation reply. Best-effort
  # — if signal-cli fails (account misconfigured, network), we log and
  # return :routed anyway so the bad reply doesn't ricochet through the
  # chat handler.
  defp send_disambiguation(recipient, decision, pending) do
    lines =
      pending
      |> Enum.map(fn %Interaction{request_id: rid, description: desc, agent_id: agent} ->
        "  • #{decision_to_verb(decision)} #{rid} — #{short_desc(desc, agent)}"
      end)

    body = """
    You have #{length(pending)} pending approvals. Reply with the id of the one you meant:

    #{Enum.join(lines, "\n")}
    """

    case Signal.send_message(recipient, String.trim(body)) do
      :ok ->
        Logger.info(
          "[Router] Signal partial response from #{recipient} — sent disambiguation for #{length(pending)} pending"
        )

      {:error, reason} ->
        Logger.warning(
          "[Router] Signal disambiguation send failed: #{inspect(reason)} (decision=#{inspect(decision)}, pending=#{length(pending)})"
        )
    end
  end

  defp decision_to_verb(:approved), do: "APPROVE"
  defp decision_to_verb(:rejected), do: "DENY"
  defp decision_to_verb(_), do: "REPLY"

  defp short_desc(nil, agent), do: "agent #{agent}"

  defp short_desc(desc, _agent) do
    desc
    |> to_string()
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, 60)
  end

  defp signal_user_id do
    case Application.get_env(:arbor_comms, :signal, []) do
      kw when is_list(kw) -> Keyword.get(kw, :interaction_user_id)
      _ -> nil
    end
  end

  defp maybe_dispatch(%Message{} = msg) do
    if Config.handler_enabled?() do
      MessageHandler.process(msg)
    end
  end
end
