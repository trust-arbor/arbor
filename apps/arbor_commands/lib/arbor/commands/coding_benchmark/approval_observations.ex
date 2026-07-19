defmodule Arbor.Commands.CodingBenchmark.ApprovalObservations do
  @moduledoc false

  @max_count 10_000

  @spec from_signals([map()]) :: :empty | map()
  def from_signals(signals) when is_list(signals) do
    events =
      signals
      |> Enum.filter(&approval_signal?/1)
      |> Enum.sort_by(&sort_key/1)

    if events == [] do
      :empty
    else
      request_ids = request_ids(events)
      count = min(length(request_ids), @max_count)
      resolved = Enum.filter(events, &(signal_type(&1) in [:resolved, "resolved"]))
      status = final_status(resolved, count)

      %{
        "count" => count,
        "requested" => count > 0,
        "required" => count > 0,
        "resumed" => status == "approved",
        "status" => status
      }
    end
  end

  defp request_ids(events) do
    requested =
      events
      |> Enum.filter(&(signal_type(&1) in [:requested, :queued, "requested", "queued"]))
      |> unique_request_ids()

    if requested == [], do: unique_request_ids(events), else: requested
  end

  defp unique_request_ids(events) do
    events
    |> Enum.map(&data_value(&1, :request_id))
    |> Enum.filter(&valid_request_id?/1)
    |> Enum.uniq()
  end

  defp approval_signal?(signal), do: data_value(signal, :kind) in [:approval, "approval"]

  defp final_status(resolved, count) do
    case List.last(resolved) do
      nil when count > 0 ->
        "pending"

      nil ->
        "not_required"

      signal ->
        response = data_value(signal, :response)
        rework? = data_value(signal, :rework) == true

        cond do
          response in [:approved, "approved"] -> "approved"
          rework? or response in [:rework, "rework"] -> "pending"
          response in [:rejected, "rejected"] -> "denied"
          true -> "pending"
        end
    end
  end

  defp signal_type(%{type: type}), do: type
  defp signal_type(%{"type" => type}), do: type
  defp signal_type(_), do: nil

  defp data_value(%{data: data}, key) when is_map(data), do: map_value(data, key)
  defp data_value(%{"data" => data}, key) when is_map(data), do: map_value(data, key)
  defp data_value(_, _key), do: nil

  defp map_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp timestamp_us(%{timestamp: %DateTime{} = timestamp}),
    do: DateTime.to_unix(timestamp, :microsecond)

  defp timestamp_us(%{"timestamp" => %DateTime{} = timestamp}),
    do: DateTime.to_unix(timestamp, :microsecond)

  defp timestamp_us(_), do: 0

  defp sort_key(signal), do: {timestamp_us(signal), event_sequence(signal)}

  defp event_sequence(signal) do
    case data_value(signal, :event_sequence) do
      sequence when is_integer(sequence) and sequence >= 0 -> sequence
      _other -> 0
    end
  end

  defp valid_request_id?(id) when is_binary(id), do: String.trim(id) != ""
  defp valid_request_id?(_), do: false
end
