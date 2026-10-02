defmodule ConversationKit.Arbor.Gateway.Wire do
  @moduledoc false

  @command_keys ~w(id name text principal_id agent_id engagement_id status outcome admitted_cursor updated_cursor)a
  @history_keys ~w(agent_id engagement_id entries cursor head has_more)a
  @page_keys ~w(engagement_id events cursor head has_more)a
  @entry_keys ~w(id role content timestamp entry_ordinal)a
  @event_keys ~w(id cursor kind command)a
  @errors ~w(unauthorized conversation_scope_changed unsupported_conversation_capability not_found command_conflict conversation_unavailable page_too_large invalid_opts invalid_cursor invalid_command invalid_caller_id invalid_agent_id invalid_content invalid_message invalid_sender invalid_engagement_id)a

  def payload(context),
    do:
      Arbor.Client.Protocol.conversation_payload(
        context.operation,
        context.caller,
        context.target,
        context.input,
        context.options
      )

  def frame(context, signed_request: "Signature " <> _ = proof),
    do: {:ok, Jason.encode!(%{payload: payload(context), authorization: proof})}

  def frame(_, _), do: {:error, :unauthorized}

  def session_frame(context),
    do: {:ok, Jason.encode!(%{payload: payload(context), authentication: "conversation_session"})}

  # Map only enumerated keys/statuses. Never intern strings from the network.
  # Semantic bounds, transition checks and dual cursor validation remain in Kit.
  def decode(binary, context) when is_binary(binary) and byte_size(binary) <= 8_388_608 do
    with {:ok, envelope} <- Jason.decode(binary),
         {:ok, reply} <- decode_envelope(envelope, context) do
      reply
    else
      _ -> {:error, :invalid_transport_response}
    end
  rescue
    _ -> {:error, :invalid_transport_response}
  end

  def decode(_, _), do: {:error, :invalid_transport_response}

  defp decode_envelope(%{"type" => "error", "reason" => reason} = map, _)
       when map_size(map) == 2 do
    case Enum.find(@errors, &(Atom.to_string(&1) == reason)) do
      nil when reason == "not_attached" ->
        {:ok, {:error, :transport_not_attached}}

      nil when reason == "server_commands_unavailable" ->
        {:ok, {:error, :unsupported_conversation_capability}}

      nil ->
        :invalid

      atom ->
        {:ok, {:error, atom}}
    end
  end

  defp decode_envelope(
         %{"type" => "conversation_rejected", "data" => data} = map,
         %{operation: :submit, input: %{id: id}}
       )
       when map_size(map) == 2 do
    with %{"id" => ^id, "reason" => reason} when map_size(data) == 2 <- data,
         atom when not is_nil(atom) <-
           Enum.find(
             [:invalid_command, :command_conflict, :unsupported_conversation_capability],
             &(Atom.to_string(&1) == reason)
           ) do
      {:ok, {:error, atom}}
    else
      _ -> :invalid
    end
  end

  defp decode_envelope(%{"type" => type, "data" => data} = map, context)
       when map_size(map) == 2 do
    case {context.operation, type} do
      {:history, "conversation_history"} ->
        with {:ok, page} <- keys(data, @history_keys),
             true <- page.agent_id == context.target,
             {:ok, entries} <- items(page.entries, &keys(&1, @entry_keys)) do
          {:ok, {:ok, page |> Map.delete(:agent_id) |> Map.put(:entries, entries)}}
        end

      {:events, "conversation_events"} ->
        with {:ok, page} <- keys(data, @page_keys),
             {:ok, events} <- items(page.events, &event/1) do
          {:ok, {:ok, %{page | events: events}}}
        end

      {op, "conversation_command"} when op in [:submit, :command] ->
        with {:ok, command} <- command(data), do: {:ok, {:ok, command}}

      _ ->
        :invalid
    end
  end

  defp decode_envelope(_, _), do: :invalid

  defp command(data) do
    with {:ok, command} <- keys(data, @command_keys),
         {:ok, status} <- status(command.status),
         {:ok, outcome} <- outcome(status, command.outcome) do
      {:ok, %{command | status: status, outcome: outcome}}
    end
  end

  defp event(data) do
    with {:ok, event} <- keys(data, @event_keys),
         {:ok, command} <- command(event.command) do
      {:ok, %{event | command: command}}
    end
  end

  defp status("admitted"), do: {:ok, :admitted}
  defp status("dispatch_started"), do: {:ok, :dispatch_started}
  defp status("completed"), do: {:ok, :completed}
  defp status("uncertain"), do: {:ok, :uncertain}
  defp status(_), do: :invalid

  defp outcome(status, nil) when status in [:admitted, :dispatch_started], do: {:ok, nil}

  defp outcome(:completed, %{"status" => "completed", "text" => text} = map)
       when map_size(map) == 2 and is_binary(text),
       do: {:ok, %{status: :completed, text: text}}

  defp outcome(:uncertain, %{"status" => "uncertain", "reason" => "delivery_unknown"} = map)
       when map_size(map) == 2,
       do: {:ok, %{status: :uncertain, reason: :delivery_unknown}}

  defp outcome(_, _), do: :invalid

  defp keys(map, keys) when is_map(map) do
    if map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, Atom.to_string(&1))),
      do: {:ok, Map.new(keys, &{&1, Map.fetch!(map, Atom.to_string(&1))})},
      else: :invalid
  end

  defp keys(_, _), do: :invalid

  defp items(list, fun) when is_list(list) and length(list) <= 100 do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        _ -> {:halt, :invalid}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      other -> other
    end
  end

  defp items(_, _), do: :invalid
end
