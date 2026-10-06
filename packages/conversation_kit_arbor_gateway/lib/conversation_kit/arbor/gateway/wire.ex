defmodule ConversationKit.Arbor.Gateway.Wire do
  @moduledoc false

  @command_keys ~w(id name text principal_id agent_id engagement_id status outcome admitted_cursor updated_cursor)a
  @history_keys ~w(agent_id engagement_id entries cursor head has_more)a
  @window_keys ~w(agent_id engagement_id entries head first last has_older has_newer)a
  @page_keys ~w(engagement_id events cursor head has_more)a
  @entry_keys ~w(id role content timestamp entry_ordinal)a
  @assistant_statuses ~w(complete interrupted cancelled failed streaming)
  @event_keys ~w(id cursor kind command)a
  @errors ~w(unauthorized conversation_scope_changed unsupported_conversation_capability not_found command_conflict conversation_unavailable page_too_large invalid_opts invalid_cursor invalid_command agent_not_running invalid_caller_id invalid_agent_id invalid_content invalid_message invalid_sender invalid_engagement_id approval_answer_required invalid_control_request invalid_interaction_answer interaction_not_pending interaction_unavailable notice_subject_required invalid_notice_request notice_unavailable)a

  def payload(context),
    do:
      Arbor.Client.conversation_payload(
        context.operation,
        context.caller,
        context.target,
        context.input,
        context.options
      )

  def frame(context, signed_request: "Signature " <> _ = proof),
    do: encode_frame(context, %{authorization: proof})

  def frame(_, _), do: {:error, :unauthorized}

  def session_frame(context),
    do: encode_frame(context, %{authentication: "conversation_session"})

  defp encode_frame(context, envelope) do
    case payload(context) do
      payload when is_binary(payload) ->
        {:ok, Jason.encode!(Map.put(envelope, :payload, payload))}

      _ ->
        {:error, :invalid_control_request}
    end
  end

  # Map only enumerated keys/statuses. Never intern strings from the network.
  # Semantic bounds, transition checks and dual cursor validation remain in Kit.
  def decode(binary, context) when is_binary(binary) and byte_size(binary) <= 8_388_608 do
    with true <-
           not control?(context && Map.get(context, :operation)) or byte_size(binary) <= 131_648,
         true <- not match?(%{operation: :notices}, context) or byte_size(binary) <= 131_072,
         {:ok, ordered} <- Jason.decode(binary, objects: :ordered_objects),
         {:ok, envelope} <- unique_json(ordered),
         {:ok, reply} <- decode_envelope(envelope, context) do
      reply
    else
      _ -> {:error, response_error(context)}
    end
  rescue
    _ -> {:error, response_error(context)}
  end

  def decode(_, context), do: {:error, response_error(context)}

  defp response_error(%{operation: :notices}), do: :invalid_notice_response
  defp response_error(_), do: :invalid_transport_response

  defp notice_bounds?(page, options) do
    length(page["notices"]) <= (options[:limit] || 50) and
      if(Keyword.has_key?(options, :through),
        do: page["through"] == options[:through],
        else: page["through"] == page["head"]
      ) and
      Enum.all?(page["notices"], fn notice ->
        not Keyword.has_key?(options, :before) or notice["ordinal"] < options[:before]
      end)
  end

  defp control?(operation),
    do:
      operation in [:activity, :cancel, :interactions, :interaction_choice, :interaction_approval]

  defp unique_json(%Jason.OrderedObject{values: values}) do
    if length(values) == length(Enum.uniq_by(values, &elem(&1, 0))) do
      Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case unique_json(value) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          _ -> {:halt, :invalid}
        end
      end)
    else
      :invalid
    end
  end

  defp unique_json(values) when is_list(values), do: items(values, &unique_json/1)
  defp unique_json(value), do: {:ok, value}

  defp decode_envelope(
         %{"type" => "error", "reason" => "notice_subject_required"} = map,
         %{operation: :notices}
       )
       when map_size(map) == 2,
       do: {:ok, {:error, :notice_subject_required}}

  defp decode_envelope(%{"type" => "error", "reason" => "notice_subject_required"}, _),
    do: :invalid

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
             [
               :invalid_command,
               :command_conflict,
               :agent_not_running,
               :unsupported_conversation_capability
             ],
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
      {:notices, "conversation_notices"} ->
        expected = %{
          target_agent_id: context.target,
          engagement_id: context.options[:expected_engagement_id]
        }

        case Arbor.Client.decode_notice_page(data, expected) do
          {:ok, page} ->
            if notice_bounds?(page, context.options), do: {:ok, {:ok, page}}, else: :invalid

          {:error, _} ->
            case Arbor.Client.decode_notice_page(data) do
              {:ok, _} -> {:ok, {:error, :conversation_scope_changed}}
              _ -> :invalid
            end
        end

      {op, type}
      when (op == :activity and type == "conversation_activity") or
             (op == :cancel and type == "conversation_cancellation") or
             (op == :interactions and type == "conversation_interactions") or
             (op in [:interaction_choice, :interaction_approval] and
                type == "conversation_interaction_answer") ->
        with {:ok, value} <- ConversationKit.Arbor.decode_control_response(context, data),
             do: {:ok, {:ok, value}}

      {:window, "conversation_window"} ->
        with {:ok, page} <- keys(data, @window_keys),
             true <- page.agent_id == context.target,
             {:ok, entries} <- items(page.entries, &window_entry/1) do
          {:ok, {:ok, page |> Map.delete(:agent_id) |> Map.put(:entries, entries)}}
        end

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

  defp window_entry(%{"role" => "assistant", "status" => status} = data)
       when status in @assistant_statuses,
       do: keys(data, @entry_keys ++ [:status])

  defp window_entry(%{"status" => _}), do: :invalid
  defp window_entry(data), do: keys(data, @entry_keys)

  defp command(data) do
    with {:ok, command} <- command_keys(data),
         {:ok, status} <- status(command.status),
         {:ok, outcome} <- outcome(status, command.outcome) do
      case Map.fetch(command, :cancellation) do
        :error ->
          {:ok, %{command | status: status, outcome: outcome}}

        {:ok, value} ->
          with {:ok, cancellation} <- cancellation(value),
               do:
                 {:ok, %{command | status: status, outcome: outcome, cancellation: cancellation}}
      end
    end
  end

  defp command_keys(data) do
    if is_map(data) and Map.has_key?(data, "cancellation"),
      do: keys(data, @command_keys ++ [:cancellation]),
      else: keys(data, @command_keys)
  end

  defp cancellation(%{"status" => value} = map)
       when map_size(map) == 1 and value in ["none", "requested"],
       do: {:ok, %{status: if(value == "none", do: :none, else: :requested)}}

  defp cancellation(%{"status" => "confirmed", "termination" => term} = map)
       when map_size(map) == 2 do
    case Enum.find(
           [:never_dispatched, :queued_removed, :engine_terminated],
           &(Atom.to_string(&1) == term)
         ) do
      nil -> :invalid
      atom -> {:ok, %{status: :confirmed, termination: atom}}
    end
  end

  defp cancellation(_), do: :invalid

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
