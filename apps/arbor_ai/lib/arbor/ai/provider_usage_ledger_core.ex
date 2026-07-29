defmodule Arbor.AI.ProviderUsageLedgerCore do
  @moduledoc """
  Pure CRC reducer for the durable provider usage ledger projection.

  Constructs daily projection state, validates and reduces JSON-clean ledger
  entries, and converts the reduced state into a JSON-clean daily aggregate.
  No persistence, process, ETS, config, clock, or IO dependencies.
  """

  alias Arbor.Contracts.LLM.ProviderUsageEvent

  @schema_version 1
  @event_type "arbor.provider_usage.v1"
  @stream_prefix "provider_usage:v1:"
  @default_page_size 100
  @default_max_events 10_000
  @default_max_providers 256
  @max_page_size 1_000
  @max_events_bound 100_000
  @max_providers_bound 10_000

  @type bounds :: %{
          page_size: pos_integer(),
          max_events: pos_integer(),
          max_providers: pos_integer()
        }

  @type state :: %{
          version: pos_integer(),
          date: String.t(),
          stream_id: String.t(),
          next_event_number: pos_integer(),
          bounds: bounds(),
          totals: map(),
          providers: %{optional(String.t()) => map()}
        }

  @doc "Closed event type written to the daily stream."
  @spec event_type() :: String.t()
  def event_type, do: @event_type

  @doc "Schema version stamped into event metadata."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Construct empty daily projection state.

  Accepts a UTC `Date`, ISO date string (`YYYY-MM-DD`), or UTC `DateTime`.
  Options `:page_size`, `:max_events`, and `:max_providers` must be closed
  positive integers within hard bounds.
  """
  @spec new(term(), keyword() | map()) :: {:ok, state()} | {:error, term()}
  def new(date, opts \\ [])

  def new(date, opts) when is_list(opts) or is_map(opts) do
    with {:ok, date_string} <- normalize_date(date),
         {:ok, bounds} <- normalize_bounds(opts) do
      {:ok,
       %{
         version: @schema_version,
         date: date_string,
         stream_id: stream_id_for_date(date_string),
         next_event_number: 1,
         bounds: bounds,
         totals: empty_bucket(),
         providers: %{}
       }}
    end
  end

  def new(_date, _opts), do: {:error, :invalid_provider_usage_date}

  @doc "UTC daily stream id for a normalized date string."
  @spec stream_id_for_date(String.t() | Date.t() | DateTime.t()) ::
          String.t() | {:error, term()}
  def stream_id_for_date(date) when is_binary(date) do
    case normalize_date(date) do
      {:ok, date_string} -> @stream_prefix <> date_string
      error -> error
    end
  end

  def stream_id_for_date(%Date{} = date), do: @stream_prefix <> Date.to_iso8601(date)

  def stream_id_for_date(%DateTime{} = datetime) do
    case normalize_date(datetime) do
      {:ok, date_string} -> @stream_prefix <> date_string
      error -> error
    end
  end

  def stream_id_for_date(_date), do: {:error, :invalid_provider_usage_date}

  @doc """
  Build the exact JSON-clean append payload for a validated usage event.

  The shell constructs `Arbor.Persistence.Event` values from this map at the
  persistence boundary.
  """
  @spec prepare_append(ProviderUsageEvent.t() | map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def prepare_append(%ProviderUsageEvent{} = event) do
    with {:ok, data} <- map_event(event),
         {:ok, digest} <- ProviderUsageEvent.digest(event),
         {:ok, date_string} <- date_from_occurred_at(event.occurred_at) do
      {:ok,
       %{
         "stream_id" => @stream_prefix <> date_string,
         "type" => @event_type,
         "id" => event.event_id,
         "timestamp" => event.occurred_at,
         "agent_id" => event.principal_id,
         "correlation_id" => event.correlation_id,
         "data" => data,
         "metadata" => %{
           "schema_version" => @schema_version,
           "provider_usage_digest" => digest
         }
       }}
    end
  end

  def prepare_append(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, event} <- ProviderUsageEvent.new(attrs), do: prepare_append(event)
  end

  def prepare_append(_attrs), do: {:error, {:invalid_provider_usage_event, :object_required}}

  @doc """
  Reduce one JSON-clean stream entry into projection state.

  Rejects malformed entries, wrong stream/day/type/schema/digest/identity
  fields, non-contiguous positions, and configured event/provider bounds.
  """
  @spec reduce(state(), map()) :: {:ok, state()} | {:error, term()}
  def reduce(%{next_event_number: next} = state, entry)
      when is_map(entry) and not is_struct(entry) do
    with :ok <- ensure_event_capacity(state),
         {:ok, entry} <- normalize_entry(entry),
         :ok <- verify_stream(state, entry),
         :ok <- verify_type(entry),
         :ok <- verify_position(next, entry),
         :ok <- verify_timestamp_day(state, entry),
         {:ok, usage} <- validate_usage_data(entry),
         :ok <- verify_identity_fields(entry, usage),
         :ok <- verify_metadata(entry, usage),
         :ok <- ensure_provider_capacity(state, usage.provider),
         totals <- accumulate(state.totals, usage),
         providers <- accumulate_provider(state.providers, usage) do
      {:ok,
       %{
         state
         | next_event_number: next + 1,
           totals: totals,
           providers: providers
       }}
    end
  end

  def reduce(_state, _entry), do: {:error, :malformed_provider_usage_entry}

  @doc "Convert projection state into the public JSON-clean daily aggregate."
  @spec show(state()) :: map()
  def show(%{
        version: version,
        date: date,
        stream_id: stream_id,
        totals: totals,
        providers: providers
      }) do
    totals
    |> Map.merge(%{
      "version" => version,
      "date" => date,
      "stream_id" => stream_id,
      "providers" => providers
    })
  end

  @doc "Return closed paging bounds from already-constructed state."
  @spec paging_bounds(state()) :: bounds()
  def paging_bounds(%{bounds: bounds}), do: bounds

  # ── Construct helpers ─────────────────────────────────────────────────────

  defp normalize_date(%Date{} = date), do: {:ok, Date.to_iso8601(date)}

  defp normalize_date(%DateTime{utc_offset: 0, std_offset: 0, calendar: Calendar.ISO} = datetime) do
    {:ok, Date.to_iso8601(DateTime.to_date(datetime))}
  end

  defp normalize_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, Date.to_iso8601(date)}
      _ -> {:error, :invalid_provider_usage_date}
    end
  end

  defp normalize_date(_value), do: {:error, :invalid_provider_usage_date}

  defp normalize_bounds(opts) when is_list(opts) do
    if keyword_list?(opts) do
      normalize_bounds(Map.new(opts))
    else
      {:error, :invalid_provider_usage_bounds}
    end
  end

  defp normalize_bounds(opts) when is_map(opts) do
    page_size = Map.get(opts, :page_size) || Map.get(opts, "page_size")
    max_events = Map.get(opts, :max_events) || Map.get(opts, "max_events")
    max_providers = Map.get(opts, :max_providers) || Map.get(opts, "max_providers")

    with {:ok, page_size} <-
           positive_bound(page_size, :page_size, 1, @max_page_size, @default_page_size),
         {:ok, max_events} <-
           positive_bound(max_events, :max_events, 1, @max_events_bound, @default_max_events),
         {:ok, max_providers} <-
           positive_bound(
             max_providers,
             :max_providers,
             1,
             @max_providers_bound,
             @default_max_providers
           ) do
      {:ok, %{page_size: page_size, max_events: max_events, max_providers: max_providers}}
    end
  end

  defp normalize_bounds(_opts), do: {:error, :invalid_provider_usage_bounds}

  defp positive_bound(nil, _field, _min, _max, default), do: {:ok, default}

  defp positive_bound(value, _field, min, max, _default)
       when is_integer(value) and value >= min and value <= max,
       do: {:ok, value}

  defp positive_bound(_value, field, _min, _max, _default),
    do: {:error, {:invalid_provider_usage_bound, field}}

  defp keyword_list?([]), do: true
  defp keyword_list?([{key, _value} | rest]) when is_atom(key), do: keyword_list?(rest)
  defp keyword_list?(_), do: false

  defp map_event(%ProviderUsageEvent{} = event) do
    case ProviderUsageEvent.to_map(event) do
      %{} = data -> {:ok, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp date_from_occurred_at(occurred_at) when is_binary(occurred_at) do
    # DateTime.from_iso8601/1 always returns a UTC DateTime plus the original offset.
    case DateTime.from_iso8601(occurred_at) do
      {:ok, %DateTime{} = datetime, _offset} ->
        {:ok, Date.to_iso8601(DateTime.to_date(datetime))}

      _ ->
        {:error, {:invalid_field, "occurred_at"}}
    end
  end

  defp date_from_occurred_at(_), do: {:error, {:invalid_field, "occurred_at"}}

  # ── Reduce helpers ────────────────────────────────────────────────────────

  defp empty_bucket do
    %{
      "event_count" => 0,
      "input_tokens" => 0,
      "output_tokens" => 0,
      "total_tokens" => 0,
      "cached_tokens" => 0,
      "marginal_api_cost_usd" => 0,
      "marginal_api_cost_unknown_events" => 0,
      "subscription_usage_units" => 0,
      "subscription_usage_unknown_events" => 0
    }
  end

  defp ensure_event_capacity(%{totals: totals, bounds: %{max_events: max_events}}) do
    if totals["event_count"] < max_events do
      :ok
    else
      {:error, {:provider_usage_event_bound_exceeded, max_events}}
    end
  end

  defp ensure_provider_capacity(
         %{providers: providers, bounds: %{max_providers: max_providers}},
         provider
       ) do
    cond do
      Map.has_key?(providers, provider) ->
        :ok

      map_size(providers) < max_providers ->
        :ok

      true ->
        {:error, {:provider_usage_provider_bound_exceeded, max_providers}}
    end
  end

  defp normalize_entry(entry) do
    required = [
      "id",
      "stream_id",
      "event_number",
      "type",
      "data",
      "metadata",
      "timestamp"
    ]

    if Enum.all?(required, &Map.has_key?(entry, &1)) and is_map(entry["data"]) and
         is_map(entry["metadata"]) and is_integer(entry["event_number"]) and
         entry["event_number"] > 0 and is_binary(entry["id"]) and is_binary(entry["stream_id"]) and
         is_binary(entry["type"]) and is_binary(entry["timestamp"]) do
      {:ok,
       %{
         "id" => entry["id"],
         "stream_id" => entry["stream_id"],
         "event_number" => entry["event_number"],
         "type" => entry["type"],
         "data" => entry["data"],
         "metadata" => entry["metadata"],
         "timestamp" => entry["timestamp"],
         "agent_id" => Map.get(entry, "agent_id"),
         "correlation_id" => Map.get(entry, "correlation_id")
       }}
    else
      {:error, :malformed_provider_usage_entry}
    end
  end

  defp verify_stream(%{stream_id: stream_id}, %{"stream_id" => stream_id}), do: :ok

  defp verify_stream(%{stream_id: expected}, %{"stream_id" => actual}),
    do: {:error, {:provider_usage_stream_mismatch, expected, actual}}

  defp verify_type(%{"type" => @event_type}), do: :ok
  defp verify_type(%{"type" => type}), do: {:error, {:provider_usage_type_mismatch, type}}

  defp verify_position(expected, %{"event_number" => expected}), do: :ok

  defp verify_position(expected, %{"event_number" => actual}),
    do: {:error, {:provider_usage_position_gap, expected, actual}}

  defp verify_timestamp_day(%{date: date}, %{"timestamp" => timestamp}) do
    case date_from_occurred_at(timestamp) do
      {:ok, ^date} -> :ok
      {:ok, other} -> {:error, {:provider_usage_day_mismatch, date, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_usage_data(%{"data" => data}) when is_map(data) and not is_struct(data) do
    case ProviderUsageEvent.new(data) do
      {:ok, event} ->
        case ProviderUsageEvent.to_map(event) do
          %{} = canonical when canonical == data ->
            {:ok, event}

          %{} ->
            {:error, {:malformed_provider_usage_data, :non_canonical_data}}

          {:error, reason} ->
            {:error, {:malformed_provider_usage_data, reason}}
        end

      {:error, reason} ->
        {:error, {:malformed_provider_usage_data, reason}}
    end
  end

  defp validate_usage_data(_entry), do: {:error, :malformed_provider_usage_entry}

  defp verify_identity_fields(entry, %ProviderUsageEvent{} = usage) do
    with :ok <- match_optional(entry["id"], usage.event_id, :event_id),
         :ok <- match_optional(entry["agent_id"], usage.principal_id, :principal_id),
         :ok <- match_optional(entry["correlation_id"], usage.correlation_id, :correlation_id),
         :ok <- verify_usage_day(entry, usage) do
      :ok
    end
  end

  defp match_optional(left, right, _field) when left == right, do: :ok

  defp match_optional(left, right, field),
    do: {:error, {:provider_usage_identity_mismatch, field, left, right}}

  defp verify_usage_day(%{"timestamp" => timestamp}, %ProviderUsageEvent{occurred_at: occurred_at}) do
    with {:ok, entry_day} <- date_from_occurred_at(timestamp),
         {:ok, usage_day} <- date_from_occurred_at(occurred_at) do
      if entry_day == usage_day do
        :ok
      else
        {:error, {:provider_usage_day_mismatch, entry_day, usage_day}}
      end
    end
  end

  # Exact two-key metadata shape only — no extra keys, no missing keys.
  defp verify_metadata(%{"metadata" => metadata}, %ProviderUsageEvent{} = usage)
       when is_map(metadata) do
    case metadata do
      %{"schema_version" => schema_version, "provider_usage_digest" => digest}
      when map_size(metadata) == 2 ->
        cond do
          schema_version != @schema_version ->
            {:error, {:provider_usage_schema_mismatch, schema_version}}

          not is_binary(digest) or digest == "" ->
            {:error, :provider_usage_digest_missing}

          true ->
            case ProviderUsageEvent.digest(usage) do
              {:ok, ^digest} ->
                :ok

              {:ok, other} ->
                {:error, {:provider_usage_digest_mismatch, digest, other}}

              {:error, reason} ->
                {:error, reason}
            end
        end

      _ ->
        {:error, :malformed_provider_usage_metadata}
    end
  end

  defp verify_metadata(_entry, _usage), do: {:error, :malformed_provider_usage_metadata}

  defp accumulate(bucket, %ProviderUsageEvent{} = usage) do
    bucket
    |> Map.update!("event_count", &(&1 + 1))
    |> Map.update!("input_tokens", &(&1 + usage.input_tokens))
    |> Map.update!("output_tokens", &(&1 + usage.output_tokens))
    |> Map.update!("total_tokens", &(&1 + usage.total_tokens))
    |> Map.update!("cached_tokens", &(&1 + usage.cached_tokens))
    |> accumulate_optional(
      "marginal_api_cost_usd",
      "marginal_api_cost_unknown_events",
      usage.marginal_api_cost_usd
    )
    |> accumulate_optional(
      "subscription_usage_units",
      "subscription_usage_unknown_events",
      usage.subscription_usage_units
    )
  end

  defp accumulate_optional(bucket, _value_key, unknown_key, nil) do
    Map.update!(bucket, unknown_key, &(&1 + 1))
  end

  defp accumulate_optional(bucket, value_key, _unknown_key, value) when is_number(value) do
    Map.update!(bucket, value_key, &(&1 + value))
  end

  defp accumulate_provider(providers, %ProviderUsageEvent{} = usage) do
    bucket = Map.get_lazy(providers, usage.provider, fn -> empty_bucket() end)
    Map.put(providers, usage.provider, accumulate(bucket, usage))
  end
end
