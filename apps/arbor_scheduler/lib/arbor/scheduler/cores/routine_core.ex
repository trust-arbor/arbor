defmodule Arbor.Scheduler.Cores.RoutineCore do
  @moduledoc false

  @intent_keys ~w(version routine manifest_digest scheduled_at request_id parents)
  @parent_keys ~w(resource_uri capability_id capability_digest)
  @digest ~r/\A[0-9a-f]{64}\z/
  @request_id ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{15,95}\z/
  @cap_id ~r/\Acap_[A-Za-z0-9_-]{16,128}\z/
  @domain "arbor.scheduler.owner-request.v1\0"

  def intent(value) when is_map(value) and map_size(value) == 6 do
    with true <- Enum.sort(Map.keys(value)) == Enum.sort(@intent_keys),
         1 <- value["version"],
         "morning_digest" <- value["routine"],
         true <- digest?(value["manifest_digest"]),
         true <- text?(value["request_id"], 96) and Regex.match?(@request_id, value["request_id"]),
         {:ok, _at} <- scheduled_at(value["scheduled_at"]),
         true <- proper_bounded_list?(value["parents"], 8),
         true <- length(value["parents"]) in 1..8,
         true <- Enum.all?(value["parents"], &parent?/1),
         uris = Enum.map(value["parents"], & &1["resource_uri"]),
         true <- length(Enum.uniq(uris)) == length(uris) do
      {:ok, value}
    else
      _ -> {:error, :invalid_routine_intent}
    end
  end

  def intent(_), do: {:error, :invalid_routine_intent}

  def payload(:enqueue, value) do
    with {:ok, intent} <- intent(value), do: {:ok, @domain <> "enqueue\0" <> canonical(intent)}
  end

  def payload(:list, filters) do
    with {:ok, filters} <- filters(filters), do: {:ok, @domain <> "list\0" <> canonical(filters)}
  end

  def payload(:cancel, id) when is_integer(id) and id > 0 and id < 9_223_372_036_854_775_807,
    do: {:ok, @domain <> "cancel\0" <> Integer.to_string(id)}

  def payload(_, _), do: {:error, :invalid_routine_request}

  def filters(%{} = filters) when map_size(filters) <= 2 do
    limit = Map.get(filters, "limit", 20)
    before_id = Map.get(filters, "before_id")

    if Enum.all?(Map.keys(filters), &(&1 in ["limit", "before_id"])) and
         is_integer(limit) and limit in 1..100 and
         (is_nil(before_id) or (is_integer(before_id) and before_id > 0)) do
      {:ok, %{"limit" => limit, "before_id" => before_id}}
    else
      {:error, :invalid_routine_filters}
    end
  end

  def filters(_), do: {:error, :invalid_routine_filters}

  def scheduled_at(value) when is_binary(value) and byte_size(value) <= 32 do
    case DateTime.from_iso8601(value) do
      {:ok, at, 0} ->
        if DateTime.to_iso8601(DateTime.truncate(at, :second)) == value,
          do: {:ok, at},
          else: {:error, :invalid_schedule}

      _ ->
        {:error, :invalid_schedule}
    end
  end

  def scheduled_at(_), do: {:error, :invalid_schedule}

  def admissible_schedule?(at, now) do
    delta = DateTime.diff(at, now, :second)
    delta >= -60 and delta <= 30 * 24 * 60 * 60
  end

  def digest?(value),
    do: is_binary(value) and byte_size(value) == 64 and Regex.match?(@digest, value)

  def digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  def canonical(value), do: value |> ordered() |> Jason.encode!()

  defp ordered(value) when is_map(value),
    do: value |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {key, val} -> [key, ordered(val)] end)

  defp ordered(value) when is_list(value), do: Enum.map(value, &ordered/1)
  defp ordered(value), do: value

  defp parent?(value) when is_map(value) and map_size(value) == 3 do
    Enum.sort(Map.keys(value)) == Enum.sort(@parent_keys) and
      text?(value["resource_uri"], 4096) and
      text?(value["capability_id"], 132) and Regex.match?(@cap_id, value["capability_id"]) and
      digest?(value["capability_digest"])
  end

  defp parent?(_), do: false

  defp text?(value, limit),
    do: is_binary(value) and byte_size(value) in 1..limit and String.valid?(value)

  defp proper_bounded_list?([], _remaining), do: true

  defp proper_bounded_list?([_ | rest], remaining) when remaining > 0,
    do: proper_bounded_list?(rest, remaining - 1)

  defp proper_bounded_list?(_, _), do: false
end
