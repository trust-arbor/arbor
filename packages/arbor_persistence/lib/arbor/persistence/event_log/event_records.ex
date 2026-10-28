defmodule Arbor.Persistence.EventLog.EventRecords do
  @moduledoc false
  alias Arbor.Persistence.{Event, EventLog}

  @maximum 2_147_483_647
  @max_event_bytes 1_048_576
  @max_bytes 4_194_304

  def validate_request(stream_id, ids, opts) do
    with {:ok, opts} <- EventLog.normalize_opts(opts),
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:name, :repo, :max_event_number])),
         true <- bounded_ids?(ids, 0),
         true <- length(ids) == length(Enum.uniq(ids)),
         true <- Enum.all?(ids, &valid_id?/1),
         {:ok, bound} <- EventLog.validate_identity_read(stream_id, hd(ids), opts) do
      {:ok, bound}
    else
      _ -> {:error, :invalid_precondition}
    end
  end

  # Optional missing command transitions are represented by absence. A supplied
  # pin must itself exist; callers validate the command's domain transition chain.
  def validate_result(stream_id, ids, bound, %{events: events, head: head} = result)
      when is_list(events) do
    pinned = if is_nil(head), do: 0, else: Map.get(head, :event_number)

    valid =
      Enum.sort(Map.keys(result)) == [:events, :head] and
        length(events) <= length(ids) and encoded_size(events, head) <= @max_bytes and
        length(Enum.uniq_by(events, &Map.get(&1, :id))) == length(events) and
        length(Enum.uniq_by(events, &Map.get(&1, :event_number))) == length(events) and
        (is_nil(bound) or bound == pinned) and
        (is_nil(head) or valid_event?(head, stream_id, pinned)) and
        Enum.all?(events, &(Map.get(&1, :id) in ids and valid_event?(&1, stream_id, pinned)))

    if valid, do: {:ok, result}, else: {:error, :event_records_invalid}
  rescue
    _ -> {:error, :event_records_invalid}
  end

  def validate_result(_, _, _, _), do: {:error, :event_records_invalid}

  defp valid_event?(%Event{} = event, stream, head) do
    :erlang.external_size(event) <= @max_event_bytes and event.stream_id == stream and
      is_integer(event.event_number) and
      event.event_number in 1..@maximum and event.event_number <= head and
      is_integer(event.global_position) and event.global_position in 1..@maximum and
      is_binary(event.operation_fingerprint) and
      EventLog.event_fingerprint_matches?(stream, event, event.operation_fingerprint)
  end

  defp valid_event?(_, _, _), do: false

  defp encoded_size(events, head) do
    :erlang.external_size({events, head})
  end

  defp valid_id?(id),
    do: is_binary(id) and byte_size(id) in 1..255 and String.valid?(id)

  defp bounded_ids?([], count), do: count in 1..5
  defp bounded_ids?([_ | rest], count) when count < 5, do: bounded_ids?(rest, count + 1)
  defp bounded_ids?(_, _), do: false
end
