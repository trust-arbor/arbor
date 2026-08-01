defmodule Arbor.AI.ProviderRouteEvidenceCore do
  @moduledoc """
  Pure CRC core for exact OAuth provider-route evidence.

  The authority is deliberately exact-route scoped with no account dimension,
  so a valid failure or cooldown may conservatively overblock another account
  using the same route. Its EventLog history survives node restart, but each
  node's in-memory projection observes only its own replay/write cycle; shared
  persistence alone is not live cluster-wide convergence.

  Failure evidence retains one deterministic candidate per closed failure class
  for each route. This is bounded and preserves a longer-lived lower-severity
  candidate when a shorter-lived severe candidate expires.
  """

  @routes ~w(openai_oauth xai_oauth)
  @failure_classes ~w(auth tier_denied outage protocol transport)
  @failure_codes_by_class %{
    "auth" => ~w(unauthorized forbidden),
    "tier_denied" => ~w(xai_oauth_tier_denied),
    "outage" => ~w(server_error),
    "protocol" =>
      ~w(unexpected_status response_bytes_exceeded invalid_response_headers invalid_stream),
    "transport" => ~w(request_timeout deadline_exceeded connection_failed)
  }
  @severity %{
    "auth" => 50,
    "tier_denied" => 40,
    "outage" => 30,
    "protocol" => 20,
    "transport" => 10
  }
  @failure_ttl_ms %{
    "auth" => 300_000,
    "tier_denied" => 3_600_000,
    "outage" => 120_000,
    "protocol" => 300_000,
    "transport" => 60_000
  }
  @max_evidence_ttl_ms 86_400_000
  @event_types %{
    "route_failure" => "arbor.provider_route_failure.v1",
    "quota" => "arbor.provider_route_quota.v1"
  }

  @type state :: %{failures: map(), quotas: map()}

  @spec new() :: state()
  def new, do: %{failures: %{}, quotas: %{}}

  @spec prepare_failure(map(), DateTime.t()) :: {:ok, map()} | {:error, atom()}
  def prepare_failure(attrs, %DateTime{} = now) when is_map(attrs) do
    with {:ok, route} <- route(attrs),
         {:ok, class} <- member(attrs, :class, @failure_classes),
         {:ok, code} <- failure_code(attrs, class),
         {:ok, retryable} <- boolean(attrs, :retryable),
         {:ok, observed_at} <- observed_at(attrs, now),
         {:ok, expires_at} <- failure_expiry(attrs, class, observed_at, now),
         {:ok, prepared} <-
           validate_failure(%{
             "route" => route,
             "class" => class,
             "code" => code,
             "retryable" => retryable,
             "observed_at" => iso(observed_at),
             "expires_at" => iso(expires_at)
           }) do
      {:ok, prepared}
    end
  end

  def prepare_failure(_, _), do: {:error, :malformed}

  @spec prepare_quota(map(), DateTime.t()) :: {:ok, map()} | {:error, atom()}
  def prepare_quota(attrs, %DateTime{} = now) when is_map(attrs) do
    with {:ok, route} <- route(attrs),
         {:ok, observed_at} <- observed_at(attrs, now),
         {:ok, expires_at} <- expiry(attrs, now),
         {:ok, prepared} <-
           validate_quota(%{
             "route" => route,
             "observed_at" => iso(observed_at),
             "available_at" => iso(expires_at)
           }) do
      {:ok, prepared}
    end
  end

  def prepare_quota(_, _), do: {:error, :malformed}

  @spec event_data(String.t() | atom(), map()) ::
          {:ok, String.t(), map()} | {:error, atom()}
  def event_data("route_failure", data) when is_map(data),
    do: {:ok, @event_types["route_failure"], data}

  def event_data(:failure, data) when is_map(data),
    do: {:ok, @event_types["route_failure"], data}

  def event_data("quota", data) when is_map(data), do: {:ok, @event_types["quota"], data}
  def event_data(:quota, data) when is_map(data), do: {:ok, @event_types["quota"], data}
  def event_data(_, _), do: {:error, :malformed}

  @spec event_id(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, :malformed}
  def event_id(stream_id, type, data)
      when is_binary(stream_id) and is_binary(type) and is_map(data) do
    with {:ok, canonical_data} <- canonical_event_data(type, data) do
      digest =
        :crypto.hash(
          :sha256,
          Jason.encode!(%{"stream_id" => stream_id, "type" => type, "data" => canonical_data})
        )

      {:ok, "evt_provider_route_" <> Base.encode16(digest, case: :lower)}
    else
      _ -> {:error, :malformed}
    end
  end

  def event_id(_, _, _), do: {:error, :malformed}

  @spec reduce(state(), map(), DateTime.t()) :: {:ok, state()} | {:error, atom()}
  def reduce(state, event, %DateTime{} = now) when is_map(state) and is_map(event) do
    with :ok <- validate_event_envelope(event),
         {:ok, type} <- event_type(event),
         {:ok, data} <- event_data_from_event(event, type),
         {:ok, next} <- reduce_data(state, type, data, now) do
      {:ok, next}
    end
  end

  def reduce(_, _, _), do: {:error, :malformed}

  @spec snapshot(state(), DateTime.t()) :: {:ok, map()} | {:error, :malformed}
  def snapshot(state, %DateTime{} = now) when is_map(state) do
    with {:ok, failures} <- snapshot_failures(state, now),
         {:ok, quotas} <- snapshot_quotas(state, now) do
      {:ok, %{failures: failures, quotas: quotas}}
    end
  end

  def snapshot(_, _), do: {:error, :malformed}

  @spec snapshot_failures(state(), DateTime.t()) ::
          {:ok, map()} | {:error, :malformed}
  def snapshot_failures(%{failures: failures}, %DateTime{} = now),
    do: active_failure_map(failures, now)

  def snapshot_failures(_, _), do: {:error, :malformed}

  @spec snapshot_quotas(state(), DateTime.t()) :: {:ok, map()} | {:error, :malformed}
  def snapshot_quotas(%{quotas: quotas}, %DateTime{} = now), do: active_quota_map(quotas, now)
  def snapshot_quotas(_, _), do: {:error, :malformed}

  defp event_type(%{"type" => "arbor.provider_route_failure.v1"}),
    do: {:ok, "arbor.provider_route_failure.v1"}

  defp event_type(%{"type" => "arbor.provider_route_quota.v1"}),
    do: {:ok, "arbor.provider_route_quota.v1"}

  defp event_type(_), do: {:error, :malformed}

  defp event_data_from_event(%{"data" => data}, "arbor.provider_route_failure.v1"),
    do: validate_failure(data)

  defp event_data_from_event(%{"data" => data}, "arbor.provider_route_quota.v1"),
    do: validate_quota(data)

  defp event_data_from_event(_, _), do: {:error, :malformed}

  defp canonical_event_data("arbor.provider_route_failure.v1", data),
    do: validate_failure(data)

  defp canonical_event_data("arbor.provider_route_quota.v1", data), do: validate_quota(data)
  defp canonical_event_data(_, _), do: {:error, :malformed}

  defp reduce_data(state, "arbor.provider_route_failure.v1", data, now) do
    with {:ok, entry} <- validate_failure(data),
         :ok <- observed_at_not_future(entry["observed_at"], now) do
      if active?(entry["expires_at"], now) do
        {:ok, %{state | failures: merge_failure(state.failures, entry)}}
      else
        {:ok, state}
      end
    else
      _ -> {:error, :malformed}
    end
  end

  defp reduce_data(state, "arbor.provider_route_quota.v1", data, now) do
    with {:ok, entry} <- validate_quota(data),
         :ok <- observed_at_not_future(entry["observed_at"], now) do
      if active?(entry["available_at"], now) do
        {:ok, %{state | quotas: merge_quota(state.quotas, entry)}}
      else
        {:ok, state}
      end
    else
      _ -> {:error, :malformed}
    end
  end

  defp merge_failure(failures, entry) do
    route = entry["route"]
    class = entry["class"]
    bucket = Map.get(failures, route, %{})

    next_entry =
      case Map.get(bucket, class) do
        nil -> entry
        existing -> choose_failure(existing, entry)
      end

    Map.put(failures, route, Map.put(bucket, class, next_entry))
  end

  defp choose_failure(old, new) do
    old_rank = Map.fetch!(@severity, old["class"])
    new_rank = Map.fetch!(@severity, new["class"])

    cond do
      new_rank > old_rank -> new
      new_rank < old_rank -> old
      new["observed_at"] > old["observed_at"] -> new
      new["observed_at"] < old["observed_at"] -> old
      new["expires_at"] > old["expires_at"] -> new
      new["expires_at"] < old["expires_at"] -> old
      new["code"] > old["code"] -> new
      new["code"] < old["code"] -> old
      new["retryable"] and not old["retryable"] -> new
      true -> old
    end
  end

  defp merge_quota(quotas, entry) do
    route = entry["route"]

    case Map.get(quotas, route) do
      nil ->
        Map.put(quotas, route, entry)

      old ->
        if entry["available_at"] > old["available_at"],
          do: Map.put(quotas, route, entry),
          else: quotas
    end
  end

  defp active_failure_map(map, now) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {route, bucket}, {:ok, acc} ->
      with {:ok, entries} <- validate_failure_bucket(route, bucket),
           {:ok, active} <- active_failures(entries, now) do
        case active do
          nil -> {:cont, {:ok, acc}}
          entry -> {:cont, {:ok, Map.put(acc, route, entry)}}
        end
      else
        _ -> {:halt, {:error, :malformed}}
      end
    end)
  end

  defp active_failure_map(_, _), do: {:error, :malformed}

  defp active_quota_map(map, now) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {route, entry}, {:ok, acc} ->
      with {:ok, validated} <- validate_quota(entry),
           true <- validated["route"] == route do
        if active?(validated["available_at"], now),
          do: {:cont, {:ok, Map.put(acc, route, validated)}},
          else: {:cont, {:ok, acc}}
      else
        _ -> {:halt, {:error, :malformed}}
      end
    end)
  end

  defp active_quota_map(_, _), do: {:error, :malformed}

  defp validate_failure_bucket(route, bucket) when is_binary(route) and is_map(bucket) do
    if map_size(bucket) > length(@failure_classes) do
      {:error, :malformed}
    else
      Enum.reduce_while(bucket, {:ok, []}, fn {class, entry}, {:ok, acc} ->
        with true <- class in @failure_classes,
             {:ok, validated} <- validate_failure(entry),
             true <- validated["route"] == route,
             true <- validated["class"] == class do
          {:cont, {:ok, [validated | acc]}}
        else
          _ -> {:halt, {:error, :malformed}}
        end
      end)
    end
  end

  defp validate_failure_bucket(_, _), do: {:error, :malformed}

  defp active_failures(entries, now) do
    Enum.reduce_while(entries, {:ok, nil}, fn entry, {:ok, current} ->
      if active?(entry["expires_at"], now) do
        winner = if current == nil, do: entry, else: choose_failure(current, entry)
        {:cont, {:ok, winner}}
      else
        {:cont, {:ok, current}}
      end
    end)
  end

  defp validate_failure(data) when is_map(data) do
    with true <- exact_keys?(data, ~w(route class code retryable observed_at expires_at)),
         {:ok, route} <- route(data),
         {:ok, class} <- member(data, "class", @failure_classes),
         {:ok, code} <- failure_code(data, class),
         {:ok, retryable} <- boolean(data, "retryable"),
         {:ok, observed_at} <- datetime(Map.get(data, "observed_at")),
         {:ok, expires_at} <- datetime(Map.get(data, "expires_at")),
         ttl_ms = DateTime.diff(expires_at, observed_at, :millisecond),
         true <- DateTime.compare(expires_at, observed_at) == :gt,
         true <- ttl_ms <= @max_evidence_ttl_ms do
      {:ok,
       %{
         "route" => route,
         "class" => class,
         "code" => code,
         "retryable" => retryable,
         "observed_at" => iso(observed_at),
         "expires_at" => iso(expires_at)
       }}
    else
      _ -> {:error, :malformed}
    end
  end

  defp validate_failure(_), do: {:error, :malformed}

  defp validate_quota(data) when is_map(data) do
    with true <- exact_keys?(data, ~w(route observed_at available_at)),
         {:ok, route} <- route(data),
         {:ok, observed_at} <- datetime(Map.get(data, "observed_at")),
         {:ok, available_at} <- datetime(Map.get(data, "available_at")),
         ttl_ms = DateTime.diff(available_at, observed_at, :millisecond),
         true <- DateTime.compare(available_at, observed_at) == :gt,
         true <- ttl_ms <= @max_evidence_ttl_ms do
      {:ok,
       %{
         "route" => route,
         "observed_at" => iso(observed_at),
         "available_at" => iso(available_at)
       }}
    else
      _ -> {:error, :malformed}
    end
  end

  defp validate_quota(_), do: {:error, :malformed}

  defp validate_event_envelope(%{
         "id" => id,
         "stream_id" => stream_id,
         "event_number" => event_number,
         "type" => type,
         "data" => data,
         "metadata" => metadata
       })
       when is_binary(id) and byte_size(id) > 0 and is_binary(stream_id) and
              byte_size(stream_id) > 0 and is_integer(event_number) and event_number > 0 and
              is_binary(type) and byte_size(type) > 0 and is_map(data) and is_map(metadata) do
    if metadata == %{"schema_version" => 1}, do: :ok, else: {:error, :malformed}
  end

  defp validate_event_envelope(_), do: {:error, :malformed}

  defp route(attrs) do
    value = Map.get(attrs, :route) || Map.get(attrs, "route")
    value = if is_atom(value), do: Atom.to_string(value), else: value
    if value in @routes, do: {:ok, value}, else: {:error, :malformed}
  end

  defp member(attrs, key, values) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
    normalized = if is_atom(value), do: Atom.to_string(value), else: value
    if normalized in values, do: {:ok, normalized}, else: {:error, :malformed}
  end

  defp failure_code(attrs, class) do
    value = Map.get(attrs, :code) || Map.get(attrs, "code")
    normalized = if is_atom(value), do: Atom.to_string(value), else: value

    if normalized in Map.fetch!(@failure_codes_by_class, class),
      do: {:ok, normalized},
      else: {:error, :malformed}
  end

  defp boolean(attrs, key) do
    value =
      if Map.has_key?(attrs, key),
        do: Map.get(attrs, key),
        else: Map.get(attrs, Atom.to_string(key))

    if is_boolean(value), do: {:ok, value}, else: {:error, :malformed}
  end

  defp exact_keys?(map, keys) when is_map(map),
    do: Map.keys(map) |> Enum.sort() == Enum.sort(keys)

  defp exact_keys?(_, _), do: false

  defp expiry(attrs, now) do
    value =
      Map.get(attrs, :expires_at) || Map.get(attrs, "expires_at") || Map.get(attrs, :available_at) ||
        Map.get(attrs, "available_at")

    with {:ok, dt} <- datetime(value),
         ttl_ms = DateTime.diff(dt, now, :millisecond),
         true <- DateTime.compare(dt, now) == :gt,
         true <- ttl_ms <= @max_evidence_ttl_ms do
      {:ok, dt}
    else
      _ -> {:error, :malformed}
    end
  end

  defp observed_at(attrs, now) do
    case Map.get(attrs, :observed_at) || Map.get(attrs, "observed_at") do
      nil ->
        {:ok, now}

      value ->
        with {:ok, observed} <- datetime(value),
             false <- DateTime.compare(observed, now) == :gt do
          {:ok, observed}
        else
          _ -> {:error, :malformed}
        end
    end
  end

  defp failure_expiry(attrs, class, observed_at, now) do
    case Map.get(attrs, :retry_after_ms) || Map.get(attrs, "retry_after_ms") do
      ms when is_integer(ms) and ms > 0 and ms <= @max_evidence_ttl_ms ->
        validate_expiry(DateTime.add(now, ms, :millisecond), observed_at, now)

      0 ->
        default_failure_expiry(class, observed_at, now)

      nil ->
        case Map.get(attrs, :expires_at) || Map.get(attrs, "expires_at") do
          nil -> default_failure_expiry(class, observed_at, now)
          value -> validate_expiry(value, observed_at, now)
        end

      _ ->
        {:error, :malformed}
    end
  end

  defp datetime(%DateTime{} = value), do: DateTime.shift_zone(value, "Etc/UTC")
  defp datetime(value) when is_binary(value), do: parse_dt(value)
  defp datetime(_), do: {:error, :malformed}

  defp parse_dt(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> DateTime.shift_zone(dt, "Etc/UTC")
      _ -> {:error, :malformed}
    end
  end

  defp parse_dt(_), do: {:error, :malformed}
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(_), do: nil

  defp active?(value, now) do
    case parse_dt(value) do
      {:ok, dt} -> DateTime.compare(dt, now) == :gt
      _ -> false
    end
  end

  defp observed_at_not_future(value, now) do
    with {:ok, observed_at} <- parse_dt(value),
         false <- DateTime.compare(observed_at, now) == :gt do
      :ok
    else
      _ -> {:error, :malformed}
    end
  end

  defp default_failure_expiry(class, observed_at, now) do
    validate_expiry(
      DateTime.add(now, Map.fetch!(@failure_ttl_ms, class), :millisecond),
      observed_at,
      now
    )
  end

  defp validate_expiry(value, observed_at, now) do
    with {:ok, expires_at} <- datetime(value),
         ttl_ms = DateTime.diff(expires_at, observed_at, :millisecond),
         true <- DateTime.compare(expires_at, observed_at) == :gt,
         true <- DateTime.compare(expires_at, now) == :gt,
         true <- ttl_ms <= @max_evidence_ttl_ms do
      {:ok, expires_at}
    else
      _ -> {:error, :malformed}
    end
  end
end
