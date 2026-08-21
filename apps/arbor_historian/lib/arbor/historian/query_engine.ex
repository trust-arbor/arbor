defmodule Arbor.Historian.QueryEngine do
  @moduledoc """
  Stateless query module over the EventLog.

  Reads events from EventLog streams and converts them to HistoryEntries.
  Provides convenience functions for common access patterns.

  ## Cache-miss fallthrough

  The ETS EventLog is bounded by time-based retention (24h default). When
  a read requests events older than what's in cache, this module falls
  through to the durable Ecto-backed EventLog for the full requested
  range and returns those results. Complete/default reads and DateTime
  filters also fall through when the payload cache is empty or partial;
  DateTime bounds are applied as post-filters, never as event-number
  cursors. Durable backends honor `:limit` (Ecto ignores `:max_scan`), so
  QueryEngine maps scan bounds onto `:limit`. Unfiltered complete/default
  reads keep the caller's `:limit` and/or explicit `:max_scan`. Filtered
  global queries and signal-id lookup paginate durable rows with a finite
  10,000-row default scan budget, apply result limits after filtering, and
  accept `:max_scan` as an override. A bounded scan reads one sentinel row
  beyond the bound and fails closed with
  `{:error, {:scan_limit_exceeded, %{max_scan: n}}}` rather than returning
  a clipped page as complete history. The cache stays authoritative for
  complete recent reads; older or incomplete filtered reads paginate the
  durable backend until the requested result is proved or the stream ends.

  The durable backend is adapter-agnostic — it dispatches via
  `Arbor.Persistence.Repo` to whichever Ecto adapter is configured
  (PostgreSQL or SQLite3). The fallthrough fires regardless of adapter
  choice.

  Fallthrough is best-effort: if the durable backend is unavailable or
  errors, the cache result is returned unchanged. Configurations without
  a started Repo (some test setups, ETS-only dev instances) get
  cache-only semantics, same as before.
  """

  require Logger

  alias Arbor.Historian.EventConverter
  alias Arbor.Historian.HistoryEntry
  alias Arbor.Historian.StreamIds
  alias Arbor.Persistence.EventLog.Ecto, as: PersistenceDurable
  alias Arbor.Persistence.EventLog.ETS, as: PersistenceETS
  alias Arbor.Signals

  @default_filtered_max_scan 10_000
  @default_durable_page_size 1_000

  @type query_opts :: [
          event_log: GenServer.server(),
          durable_event_log: module(),
          repo: atom(),
          category: atom(),
          type: atom(),
          source: String.t(),
          correlation_id: String.t(),
          from: DateTime.t() | non_neg_integer(),
          to: DateTime.t(),
          limit: pos_integer(),
          max_scan: pos_integer()
        ]

  @doc """
  Read all entries from a specific stream.
  """
  @spec read_stream(String.t(), keyword()) ::
          {:ok, [HistoryEntry.t()]} | {:error, term()}
  def read_stream(stream_id, opts) do
    event_log = Keyword.get(opts, :event_log, Arbor.Historian.EventLog.ETS)

    case fetch_events_with_fallthrough(stream_id, opts, event_log) do
      {:ok, persistence_events} ->
        entries =
          persistence_events
          |> Enum.map(&convert_to_history_entry/1)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      {:error, reason} = error ->
        emit_query_failed(:read_stream, stream_id, reason)
        error
    end
  end

  # Try ETS first. If the cache's oldest event_number is greater than the
  # requested `from`, events in [from..oldest-1] have aged past retention
  # and only exist in the durable backend — fetch the full range from
  # there. The durable backend is Ecto-based and adapter-agnostic; this
  # works for both PostgreSQL and SQLite3 configurations.
  #
  # Complete/default reads (no integer cursor) and DateTime `:from`/`:to`
  # bounds also consult durable storage when the payload cache is empty or
  # partial. DateTime values stay post-filters; they are never durable
  # event-number cursors.
  #
  # Cache-only fallback when the Repo isn't running (some test setups,
  # ETS-only dev instances) — return whatever ETS gave us, log at debug
  # level so the divergence is observable without spamming.
  defp fetch_events_with_fallthrough(stream_id, opts, event_log) do
    # Forward :max_scan so the ETS read can bound how much of the stream it
    # walks into memory (DoS backstop — codex resource-exhaustion.historian
    # -taint-query-full-scan). nil = unbounded (existing behavior).
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    ets_opts =
      [name: event_log, max_scan: Keyword.get(opts, :max_scan)]
      |> maybe_put_positive_int(:limit, positive_int(Keyword.get(opts, :limit)))
      |> maybe_put_integer(:from, from)
      |> maybe_put_direction(Keyword.get(opts, :direction))

    ets_result = PersistenceETS.read_stream(stream_id, ets_opts)

    cond do
      is_integer(from) ->
        maybe_fallthrough(stream_id, opts, from, event_log, ets_result)

      is_nil(from) or match?(%DateTime{}, from) or match?(%DateTime{}, to) ->
        maybe_complete_fallthrough(stream_id, opts, event_log, ets_result)

      true ->
        ets_result
    end
  end

  defp maybe_fallthrough(stream_id, opts, from, event_log, ets_result) do
    scan_bound = scan_limit_for_admission(opts, false)

    with {:ok, _events} <- ets_result,
         {:ok, oldest} <- PersistenceETS.oldest_event_number(stream_id, name: event_log),
         true <- cache_misses_range?(oldest, from),
         true <- durable_backend_available?(opts) do
      read_durable_stream(
        stream_id,
        ecto_scan_opts(opts, scan_bound),
        ets_result,
        scan_bound
      )
    else
      _ -> ets_result
    end
  end

  defp maybe_complete_fallthrough(stream_id, opts, event_log, ets_result) do
    datetime_filter? =
      datetime_bound?(Keyword.get(opts, :from)) or datetime_bound?(Keyword.get(opts, :to))

    scan_bound = scan_limit_for_admission(opts, datetime_filter?)

    with {:ok, _events} <- ets_result,
         {:ok, oldest} <- PersistenceETS.oldest_event_number(stream_id, name: event_log),
         true <- cache_misses_range?(oldest, 0),
         true <- durable_backend_available?(opts) do
      read_durable_stream(
        stream_id,
        complete_history_durable_opts(opts, scan_bound),
        ets_result,
        scan_bound
      )
    else
      _ -> ets_result
    end
  end

  defp complete_history_durable_opts(opts, scan_bound) do
    datetime_filter? =
      datetime_bound?(Keyword.get(opts, :from)) or datetime_bound?(Keyword.get(opts, :to))

    base =
      opts
      |> Keyword.take([:repo, :direction, :durable_event_log])
      |> Keyword.put(:from, 0)

    # Ecto.read_stream/2 honors `:limit` and ignores `:max_scan`. DateTime
    # result limits stay post-filters; only an explicit `:max_scan` becomes
    # a durable row bound, with no silent default cap.
    row_limit = durable_row_limit(opts, datetime_filter?)
    maybe_put_positive_int(base, :limit, durable_fetch_limit(row_limit, scan_bound))
  end

  defp ecto_scan_opts(opts, scan_bound) do
    row_limit = durable_row_limit(opts, false)
    maybe_put_positive_int(opts, :limit, durable_fetch_limit(row_limit, scan_bound))
  end

  defp durable_fetch_limit(row_limit, nil), do: row_limit
  defp durable_fetch_limit(_row_limit, scan_bound), do: scan_bound + 1

  defp datetime_bound?(%DateTime{}), do: true
  defp datetime_bound?(_value), do: false

  defp durable_row_limit(opts, datetime_filter?) do
    caller_limit = positive_int(Keyword.get(opts, :limit))
    max_scan = positive_int(Keyword.get(opts, :max_scan))

    cond do
      datetime_filter? ->
        max_scan

      is_integer(caller_limit) and is_integer(max_scan) ->
        min(caller_limit, max_scan)

      is_integer(caller_limit) ->
        caller_limit

      true ->
        max_scan
    end
  end

  defp positive_int(value) when is_integer(value) and value > 0, do: value
  defp positive_int(_value), do: nil

  defp maybe_put_positive_int(opts, _key, nil), do: opts
  defp maybe_put_positive_int(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_integer(opts, key, value) when is_integer(value),
    do: Keyword.put(opts, key, value)

  defp maybe_put_integer(opts, _key, _value), do: opts

  defp maybe_put_direction(opts, direction) when direction in [:forward, :backward],
    do: Keyword.put(opts, :direction, direction)

  defp maybe_put_direction(opts, _direction), do: opts

  # `:max_scan` is a completeness bound, not a result size. Fetch one sentinel
  # row beyond it so exactly `max_scan` rows are admitted while a proven extra
  # row fails closed.
  # A caller `:limit` that is the binding page size is a successful bounded read.
  defp scan_limit_for_admission(opts, datetime_filter?) do
    max_scan = positive_int(Keyword.get(opts, :max_scan))
    caller_limit = positive_int(Keyword.get(opts, :limit))

    cond do
      is_nil(max_scan) -> nil
      datetime_filter? -> max_scan
      is_nil(caller_limit) -> max_scan
      max_scan < caller_limit -> max_scan
      true -> nil
    end
  end

  defp read_durable_stream(stream_id, opts, ets_result, scan_bound) do
    durable = Keyword.get(opts, :durable_event_log, PersistenceDurable)

    case durable.read_stream(stream_id, opts) do
      {:ok, durable_events} ->
        admit_durable_page(durable_events, scan_bound)

      {:error, reason} ->
        Logger.debug(
          "QueryEngine: fallthrough to durable backend failed for #{stream_id}: #{inspect(reason)}; serving cache result"
        )

        ets_result
    end
  end

  defp admit_durable_page(events, scan_bound)
       when is_integer(scan_bound) and length(events) > scan_bound do
    {:error, {:scan_limit_exceeded, %{max_scan: scan_bound}}}
  end

  defp admit_durable_page(events, _scan_bound), do: {:ok, events}

  # The cache misses the requested range when:
  #   * `oldest` is `nil` — the stream isn't in cache at all. Could be a
  #     stream whose events all aged past retention (boot scenario after
  #     2026-06-06: ETS starts empty; durable backend may have events),
  #     OR a stream that genuinely doesn't exist. Either way the durable
  #     backend is the authoritative source; an extra DB roundtrip on a
  #     nonexistent stream is acceptable.
  #   * `oldest > max(from, 1)` — EventLog positions start at 1 and `:from`
  #     is inclusive, so any later oldest position proves a requested row is
  #     missing from cache.
  defp cache_misses_range?(nil, _from), do: true

  defp cache_misses_range?(oldest, from) when is_integer(oldest) and is_integer(from),
    do: oldest > max(from, 1)

  # The Repo dispatches to whichever Ecto adapter is configured
  # (Postgres or SQLite3 — see `Arbor.Persistence.Repo`). This check
  # is adapter-agnostic; the only thing we need is a running Repo
  # process to talk to.
  defp durable_backend_available?(opts) do
    repo = Keyword.get(opts, :repo, Arbor.Persistence.Repo)
    is_atom(repo) and not is_nil(repo) and Process.whereis(repo) != nil
  end

  @doc """
  Read entries for a specific agent.
  """
  @spec read_agent(String.t(), keyword()) :: {:ok, [HistoryEntry.t()]}
  def read_agent(agent_id, opts) do
    read_stream(StreamIds.for_agent(agent_id), opts)
  end

  @doc """
  Read entries for a specific category.
  """
  @spec read_category(atom(), keyword()) :: {:ok, [HistoryEntry.t()]}
  def read_category(category, opts) do
    read_stream(StreamIds.for_category(category), opts)
  end

  @doc """
  Read entries for a specific session.
  """
  @spec read_session(String.t(), keyword()) :: {:ok, [HistoryEntry.t()]}
  def read_session(session_id, opts) do
    read_stream(StreamIds.for_session(session_id), opts)
  end

  @doc """
  Read entries for a specific correlation chain.
  """
  @spec read_correlation(String.t(), keyword()) :: {:ok, [HistoryEntry.t()]}
  def read_correlation(correlation_id, opts) do
    read_stream(StreamIds.for_correlation(correlation_id), opts)
  end

  @doc """
  Read the global stream (all entries).
  """
  @spec read_global(keyword()) :: {:ok, [HistoryEntry.t()]} | {:error, term()}
  def read_global(opts) do
    read_stream("global", opts)
  end

  @doc """
  Query the global stream with filters applied.

  ## Options
  - `:category` - Filter by category atom
  - `:type` - Filter by type atom
  - `:source` - Filter by source string
  - `:correlation_id` - Filter by correlation ID
  - `:from` - Filter entries after this time
  - `:to` - Filter entries before this time
  - `:limit` - Maximum number of entries to return
  - `:max_scan` - Maximum rows to inspect for filtered queries (default: 10,000)
  """
  @spec query(query_opts()) :: {:ok, [HistoryEntry.t()]} | {:error, term()}
  def query(opts) do
    filters = query_filters(opts)

    if map_size(filters) == 0 do
      case read_global(opts) do
        {:ok, entries} -> {:ok, apply_limit(entries, opts)}
        {:error, _reason} = error -> error
      end
    else
      opts
      |> scan_complete_history(&HistoryEntry.matches?(&1, filters), positive_int(opts[:limit]))
      |> emit_scan_error(:query, "global")
    end
  end

  @doc """
  Find a history entry by its original signal ID.

  Scans the global stream for a matching signal_id.
  """
  @spec find_by_signal_id(String.t(), keyword()) ::
          {:ok, HistoryEntry.t()} | {:error, :not_found | term()}
  def find_by_signal_id(signal_id, opts) do
    result =
      opts
      |> scan_complete_history(&(&1.signal_id == signal_id), 1)
      |> emit_scan_error(:find_by_signal_id, signal_id)

    case result do
      {:ok, [entry]} -> {:ok, entry}
      {:ok, []} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  # Private

  defp query_filters(opts) do
    Enum.reduce(opts, %{}, fn
      {:from, %DateTime{} = value}, filters ->
        Map.put(filters, :from, value)

      {:to, %DateTime{} = value}, filters ->
        Map.put(filters, :to, value)

      {key, value}, filters
      when key in [:category, :type, :source, :correlation_id] and not is_nil(value) ->
        Map.put(filters, key, value)

      _, filters ->
        filters
    end)
  end

  defp scan_complete_history(opts, matcher, result_limit) do
    event_log = Keyword.get(opts, :event_log, Arbor.Historian.EventLog.ETS)
    max_scan = positive_int(Keyword.get(opts, :max_scan)) || @default_filtered_max_scan

    ets_result =
      PersistenceETS.read_stream("global", name: event_log, max_scan: max_scan + 1)

    with {:ok, _events} <- ets_result,
         {:ok, oldest} <- PersistenceETS.oldest_event_number("global", name: event_log),
         true <- cache_misses_range?(oldest, 0),
         true <- durable_backend_available?(opts) do
      scan_durable_history(opts, matcher, result_limit, max_scan, ets_result)
    else
      _ -> scan_cached_history(ets_result, matcher, result_limit, max_scan)
    end
  end

  defp scan_cached_history({:error, _reason} = error, _matcher, _result_limit, _max_scan),
    do: error

  defp scan_cached_history({:ok, events}, matcher, result_limit, max_scan) do
    consumed = Enum.take(events, max_scan)

    case collect_matches(consumed, matcher, result_limit, [], 0) do
      {:proven, matches, _count} ->
        {:ok, Enum.reverse(matches)}

      {:continue, matches, _count} when length(events) <= max_scan ->
        {:ok, Enum.reverse(matches)}

      {:continue, _matches, _count} ->
        scan_limit_exceeded(max_scan)
    end
  end

  defp scan_durable_history(opts, matcher, result_limit, max_scan, ets_result) do
    durable = Keyword.get(opts, :durable_event_log, PersistenceDurable)

    state = %{
      repo: Keyword.get(opts, :repo, Arbor.Persistence.Repo),
      matcher: matcher,
      result_limit: result_limit,
      max_scan: max_scan,
      page_size:
        positive_int(Keyword.get(opts, :durable_page_size)) || @default_durable_page_size,
      from: 0,
      scanned: 0,
      matches: [],
      match_count: 0,
      ets_result: ets_result
    }

    scan_durable_page(durable, state)
  end

  defp scan_durable_page(_durable, %{scanned: scanned, max_scan: max_scan})
       when scanned >= max_scan,
       do: scan_limit_exceeded(max_scan)

  defp scan_durable_page(durable, state) do
    consume_cap = min(state.page_size, state.max_scan - state.scanned)
    read_opts = [repo: state.repo, from: state.from, limit: consume_cap + 1]

    case durable.read_stream("global", read_opts) do
      {:ok, events} when is_list(events) ->
        consume_durable_page(events, durable, state, consume_cap)

      {:error, reason} ->
        durable_scan_fallback(reason, state)

      other ->
        durable_scan_fallback({:invalid_read_result, other}, state)
    end
  end

  defp consume_durable_page(events, durable, state, consume_cap) do
    consumed = Enum.take(events, consume_cap)
    extra? = length(events) > consume_cap

    case collect_matches(
           consumed,
           state.matcher,
           state.result_limit,
           state.matches,
           state.match_count
         ) do
      {:proven, next_matches, _next_count} ->
        {:ok, Enum.reverse(next_matches)}

      {:continue, next_matches, next_count} ->
        scanned_after = state.scanned + length(consumed)

        cond do
          not extra? ->
            {:ok, Enum.reverse(next_matches)}

          scanned_after >= state.max_scan ->
            scan_limit_exceeded(state.max_scan)

          true ->
            case next_durable_cursor(consumed, state.from) do
              {:ok, next_from} ->
                next_state = %{
                  state
                  | from: next_from,
                    scanned: scanned_after,
                    matches: next_matches,
                    match_count: next_count
                }

                scan_durable_page(durable, next_state)

              {:error, reason} ->
                {:error, {:invalid_durable_page, reason}}
            end
        end
    end
  end

  defp collect_matches(events, matcher, result_limit, matches, match_count) do
    Enum.reduce_while(events, {:continue, matches, match_count}, fn event, state ->
      event
      |> convert_to_history_entry()
      |> maybe_collect_match(state, matcher, result_limit)
    end)
  end

  defp maybe_collect_match(nil, state, _matcher, _result_limit), do: {:cont, state}

  defp maybe_collect_match(entry, state, matcher, result_limit) do
    if matcher.(entry) do
      collect_matched_entry(state, entry, result_limit)
    else
      {:cont, state}
    end
  end

  defp collect_matched_entry({:continue, matches, count}, entry, result_limit) do
    next_count = count + 1
    next_matches = [entry | matches]

    if result_limit_reached?(result_limit, next_count) do
      {:halt, {:proven, next_matches, next_count}}
    else
      {:cont, {:continue, next_matches, next_count}}
    end
  end

  defp result_limit_reached?(result_limit, count) when is_integer(result_limit),
    do: count >= result_limit

  defp result_limit_reached?(_result_limit, _count), do: false

  defp next_durable_cursor([], _from), do: {:error, :empty_nonterminal_page}

  defp next_durable_cursor(events, from) do
    case List.last(events) do
      %{event_number: event_number} when is_integer(event_number) and event_number >= from ->
        {:ok, event_number + 1}

      _ ->
        {:error, :non_advancing_cursor}
    end
  end

  defp durable_scan_fallback(reason, state) do
    Logger.debug(
      "QueryEngine: filtered fallthrough to durable backend failed: #{inspect(reason)}; serving cache result"
    )

    scan_cached_history(
      state.ets_result,
      state.matcher,
      state.result_limit,
      state.max_scan
    )
  end

  defp scan_limit_exceeded(max_scan),
    do: {:error, {:scan_limit_exceeded, %{max_scan: max_scan}}}

  defp emit_scan_error({:error, reason} = error, query_type, details) do
    emit_query_failed(query_type, details, reason)
    error
  end

  defp emit_scan_error(result, _query_type, _details), do: result

  defp apply_limit(entries, opts) do
    case Keyword.get(opts, :limit) do
      nil -> entries
      limit -> Enum.take(entries, limit)
    end
  end

  defp convert_to_history_entry(persistence_event) do
    case EventConverter.from_persistence_event(persistence_event) do
      {:ok, historian_event} -> HistoryEntry.from_event(historian_event)
      {:error, _} -> nil
    end
  end

  # Signal emission helper

  defp emit_query_failed(query_type, query_details, reason) do
    Signals.emit(:historian, :query_failed, %{
      query_type: query_type,
      query_details: truncate_details(query_details),
      reason: truncate_reason(reason)
    })
  end

  defp truncate_details(details) when is_binary(details) do
    if String.length(details) > 100 do
      String.slice(details, 0, 97) <> "..."
    else
      details
    end
  end

  defp truncate_details(details), do: inspect(details)

  defp truncate_reason(reason) do
    inspected = inspect(reason)

    if String.length(inspected) > 200 do
      String.slice(inspected, 0, 197) <> "..."
    else
      inspected
    end
  end
end
