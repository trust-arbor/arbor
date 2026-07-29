defmodule Arbor.AI.ProviderUsageLedger do
  @moduledoc """
  Thin persistence shell for the durable provider usage ledger.

  Validates `ProviderUsageEvent` facts, appends them to the UTC daily EventLog
  stream through the public `Arbor.Persistence` facade, reconciles indeterminate
  appends exactly once, and projects bounded daily aggregates via the pure
  `ProviderUsageLedgerCore` reducer.
  """

  alias Arbor.AI.Config
  alias Arbor.AI.ProviderUsageLedgerCore
  alias Arbor.Contracts.LLM.ProviderUsageEvent
  alias Arbor.Persistence
  alias Arbor.Persistence.Event

  @type target :: %{
          required(:name) => atom(),
          required(:backend) => module(),
          required(:opts) => keyword()
        }

  @doc """
  Validate and persist one provider usage fact.

  Options:
  - `:target` — closed ledger target override (`%{name, backend, opts}`)
  - `:append_timeout_ms` — forwarded to the persistence facade
  """
  @spec record_provider_usage(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def record_provider_usage(attrs, opts \\ [])

  def record_provider_usage(attrs, opts) when is_list(opts) do
    with :ok <- ensure_keyword_options(opts),
         {:ok, event} <- normalize_event(attrs),
         {:ok, target} <- resolve_target(opts),
         {:ok, prepared} <- ProviderUsageLedgerCore.prepare_append(event),
         {:ok, persistence_event} <- build_event(prepared) do
      append_with_reconcile(target, prepared["stream_id"], persistence_event, opts)
    end
  end

  def record_provider_usage(_attrs, _opts), do: {:error, :invalid_options}

  @doc """
  Project one UTC daily aggregate with bounded per-provider buckets.

  Options:
  - `:target` — closed ledger target override
  - `:page_size`, `:max_events`, `:max_providers` — closed positive bounds
  """
  @spec provider_usage_daily(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def provider_usage_daily(date, opts \\ [])

  def provider_usage_daily(date, opts) when is_list(opts) do
    # Core validates bounds and rejects non-keyword lists with typed
    # invalid-bounds errors before any Keyword access in resolve_target/1.
    with {:ok, state} <- ProviderUsageLedgerCore.new(date, opts),
         {:ok, target} <- resolve_target(opts) do
      page_and_project(state, target)
    end
  end

  def provider_usage_daily(_date, _opts), do: {:error, :invalid_options}

  # ── Append path ───────────────────────────────────────────────────────────

  defp append_with_reconcile(target, stream_id, event, opts) do
    backend_opts = backend_opts(target, opts)

    case Persistence.append(target.name, target.backend, stream_id, event, backend_opts) do
      {:ok, [persisted]} ->
        success_receipt(persisted)

      {:error, :event_identity_conflict} ->
        {:error, :event_identity_conflict}

      {:error, {:append_indeterminate, operation}} ->
        reconcile_once(target, stream_id, event, operation, backend_opts)

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_append_result, other}}
    end
  end

  defp reconcile_once(target, stream_id, event, operation, backend_opts) do
    case Persistence.reconcile_append(target.name, target.backend, operation, backend_opts) do
      {:ok, {:committed, [persisted]}} ->
        success_receipt(persisted)

      {:ok, :absent} ->
        retry_exact_append(target, stream_id, event, backend_opts)

      {:error, {:append_indeterminate, still_unknown}} ->
        {:error, {:append_indeterminate, still_unknown}}

      {:error, :event_identity_conflict} ->
        {:error, :event_identity_conflict}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_reconcile_result, other}}
    end
  end

  defp retry_exact_append(target, stream_id, event, backend_opts) do
    case Persistence.append(target.name, target.backend, stream_id, event, backend_opts) do
      {:ok, [persisted]} ->
        success_receipt(persisted)

      {:error, :event_identity_conflict} ->
        {:error, :event_identity_conflict}

      {:error, {:append_indeterminate, operation}} ->
        {:error, {:append_indeterminate, operation}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_append_result, other}}
    end
  end

  defp success_receipt(%Event{} = event) do
    {:ok,
     %{
       "event_id" => event.id,
       "stream_id" => event.stream_id,
       "event_number" => event.event_number,
       "type" => event.type
     }}
  end

  defp success_receipt(other), do: {:error, {:unexpected_persisted_event, other}}

  # ── Projection path ───────────────────────────────────────────────────────

  defp page_and_project(state, target) do
    bounds = ProviderUsageLedgerCore.paging_bounds(state)
    read_pages(state, target, 1, bounds)
  end

  defp read_pages(state, target, from, bounds) do
    backend_opts =
      target.opts
      |> Keyword.put(:from, from)
      |> Keyword.put(:limit, bounds.page_size)
      |> Keyword.put(:direction, :forward)

    case safe_read_stream(target, state.stream_id, backend_opts) do
      {:ok, []} ->
        {:ok, ProviderUsageLedgerCore.show(state)}

      {:ok, events} when is_list(events) ->
        page_size = bounds.page_size

        case take_bounded_page(events, page_size) do
          {:ok, page} ->
            reduce_page(state, target, page, bounds)

          {:error, :provider_usage_page_too_large} ->
            # Do not claim a full backend list length - only page_size is known.
            {:error, {:provider_usage_page_too_large, page_size}}
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_read_result, other}}
    end
  end

  # Inspect at most page_size + 1 cons cells. Never length/1 an arbitrary tail.
  defp take_bounded_page(events, page_size)
       when is_list(events) and is_integer(page_size) and page_size > 0 do
    case split_prefix(events, page_size, []) do
      {:ok, page} -> {:ok, page}
      :oversized -> {:error, :provider_usage_page_too_large}
    end
  end

  defp split_prefix(rest, 0, acc) do
    case rest do
      [] -> {:ok, :lists.reverse(acc)}
      [_ | _] -> :oversized
    end
  end

  defp split_prefix([], _remaining, acc), do: {:ok, :lists.reverse(acc)}

  defp split_prefix([head | tail], remaining, acc),
    do: split_prefix(tail, remaining - 1, [head | acc])

  defp reduce_page(state, target, events, bounds) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, acc} ->
      with {:ok, entry} <- entry_from_event(event),
           {:ok, next} <- ProviderUsageLedgerCore.reduce(acc, entry) do
        {:cont, {:ok, next}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, next_state} ->
        # `events` is already a bounded page of at most page_size entries.
        if length(events) < bounds.page_size do
          {:ok, ProviderUsageLedgerCore.show(next_state)}
        else
          read_pages(next_state, target, next_state.next_event_number, bounds)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp entry_from_event(%Event{} = event) do
    with {:ok, data} <- json_canonical_map(event.data),
         {:ok, metadata} <- json_canonical_map(event.metadata),
         {:ok, timestamp} <- timestamp_string(event.timestamp) do
      {:ok,
       %{
         "id" => event.id,
         "stream_id" => event.stream_id,
         "event_number" => event.event_number,
         "type" => event.type,
         "data" => data,
         "metadata" => metadata,
         "agent_id" => event.agent_id,
         "correlation_id" => event.correlation_id,
         "timestamp" => timestamp
       }}
    end
  end

  defp entry_from_event(_event), do: {:error, :malformed_provider_usage_entry}

  defp timestamp_string(%DateTime{} = datetime), do: {:ok, DateTime.to_iso8601(datetime)}
  defp timestamp_string(value) when is_binary(value), do: {:ok, value}
  defp timestamp_string(_value), do: {:error, :malformed_provider_usage_entry}

  # Persistence.Event data/metadata are already JSON-canonical (string keys).
  # Reject non-canonical maps instead of stringifying arbitrary keys.
  defp json_canonical_map(map) when is_map(map) and not is_struct(map) do
    if Enum.all?(Map.keys(map), &is_binary/1) do
      {:ok, map}
    else
      {:error, :malformed_provider_usage_entry}
    end
  end

  defp json_canonical_map(_value), do: {:error, :malformed_provider_usage_entry}

  defp safe_read_stream(target, stream_id, backend_opts) do
    backend = target.backend

    if is_atom(backend) and not is_nil(backend) and Code.ensure_loaded?(backend) and
         function_exported?(backend, :read_stream, 2) do
      Persistence.read_stream(target.name, backend, stream_id, backend_opts)
    else
      {:error, :backend_unavailable}
    end
  rescue
    UndefinedFunctionError -> {:error, :backend_unavailable}
  end

  # ── Boundary helpers ──────────────────────────────────────────────────────

  defp normalize_event(%ProviderUsageEvent{} = event), do: {:ok, event}

  defp normalize_event(attrs) when is_map(attrs) or is_list(attrs) do
    ProviderUsageEvent.new(attrs)
  end

  defp normalize_event(_attrs), do: {:error, {:invalid_provider_usage_event, :object_required}}

  defp ensure_keyword_options(opts) do
    if keyword_list?(opts), do: :ok, else: {:error, :invalid_options}
  end

  defp keyword_list?([]), do: true
  defp keyword_list?([{key, _value} | rest]) when is_atom(key), do: keyword_list?(rest)
  defp keyword_list?(_), do: false

  defp resolve_target(opts) do
    case Keyword.get(opts, :target) do
      nil -> Config.provider_usage_ledger_target()
      target -> Config.normalize_provider_usage_ledger_target(target)
    end
  end

  defp backend_opts(target, opts) do
    timeout =
      case Keyword.fetch(opts, :append_timeout_ms) do
        {:ok, value} -> [append_timeout_ms: value]
        :error -> []
      end

    Keyword.merge(target.opts, timeout)
  end

  defp build_event(prepared) do
    with {:ok, timestamp} <- parse_timestamp(prepared["timestamp"]) do
      {:ok,
       Event.new(
         prepared["stream_id"],
         prepared["type"],
         prepared["data"],
         id: prepared["id"],
         timestamp: timestamp,
         agent_id: prepared["agent_id"],
         correlation_id: prepared["correlation_id"],
         metadata: prepared["metadata"]
       )}
    end
  end

  defp parse_timestamp(value) when is_binary(value) do
    # DateTime.from_iso8601/1 always returns a UTC DateTime plus the original offset.
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{utc_offset: 0, std_offset: 0} = datetime, _offset} ->
        {:ok, datetime}

      _ ->
        {:error, {:invalid_field, "occurred_at"}}
    end
  end

  defp parse_timestamp(_value), do: {:error, {:invalid_field, "occurred_at"}}
end
