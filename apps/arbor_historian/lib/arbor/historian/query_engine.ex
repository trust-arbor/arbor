defmodule Arbor.Historian.QueryEngine do
  @moduledoc """
  Stateless complete-history queries over an authoritative EventLog.

  The resident Historian EventLog is a disposable projection and is never used
  to establish complete history. By default every operation resolves the
  Config-owned `Arbor.Historian.Config.durable_event_log_target/0` and reads it
  only through the `Arbor.Persistence` facade. Config ownership is the authority
  boundary, so query options cannot replace its name, backend, or static backend
  options. Test builds have one narrow compatibility seam: `:event_log` may
  replace only the name of `Config.hot_event_log_target/0`; Config still owns its
  backend and static options.

  Filtered global queries and signal-id lookup paginate with a finite 10,000-row
  default scan budget. A bounded scan requests one sentinel row beyond the
  bound and fails closed rather than returning a clipped result as complete.
  Integer `:from` cursors remain inclusive; DateTime bounds are post-filters.
  Filtered backward pagination is rejected explicitly because the EventLog
  `read_stream` contract has no descending upper-bound cursor.

  ## Bounded errors

  Complete-history operations can return these closed error families:

    * `{:authoritative_target_unavailable, reason}` — invalid configuration or
      a failed projection-mode probe
    * `{:authoritative_target_rejected, :projection}` — the configured target is
      a projection rather than complete-history authority
    * `{:authoritative_read_failed, reason}` — backend error, exception/exit, or
      malformed successful reply/page
    * `{:invalid_authoritative_page, reason}` — pagination did not advance
    * `{:invalid_query_options, :backward_filtered_scan_unsupported}` — a
      filtered descending scan was requested

  Reasons are bounded atoms; backend terms and event payloads are never included.
  """

  alias Arbor.Historian.Config
  alias Arbor.Historian.EventConverter
  alias Arbor.Historian.HistoryEntry
  alias Arbor.Historian.StreamIds
  alias Arbor.Persistence
  alias Arbor.Signals

  @default_filtered_max_scan 10_000
  @default_durable_page_size 1_000
  @type query_opts :: [
          category: atom(),
          type: atom(),
          source: String.t(),
          correlation_id: String.t(),
          from: DateTime.t() | non_neg_integer(),
          to: DateTime.t(),
          direction: :forward | :backward,
          limit: pos_integer(),
          max_scan: pos_integer(),
          durable_page_size: pos_integer()
        ]

  @type target :: %{name: atom(), backend: module(), opts: keyword()}

  @doc "Read all entries from a specific stream."
  @spec read_stream(String.t(), keyword()) ::
          {:ok, [HistoryEntry.t()]} | {:error, term()}
  def read_stream(stream_id, opts) do
    result =
      with {:ok, target} <- resolve_authoritative_target(opts),
           :ok <- reject_projection_mode(target, stream_id),
           {:ok, events} <- read_authoritative_stream(target, stream_id, opts),
           {:ok, entries} <- convert_events(events) do
        {:ok, entries}
      end

    emit_error(result, :read_stream, stream_id)
  end

  @doc "Read entries for a specific agent."
  @spec read_agent(String.t(), keyword()) ::
          {:ok, [HistoryEntry.t()]} | {:error, term()}
  def read_agent(agent_id, opts), do: read_stream(StreamIds.for_agent(agent_id), opts)

  @doc "Read entries for a specific category."
  @spec read_category(atom(), keyword()) ::
          {:ok, [HistoryEntry.t()]} | {:error, term()}
  def read_category(category, opts), do: read_stream(StreamIds.for_category(category), opts)

  @doc "Read entries for a specific session."
  @spec read_session(String.t(), keyword()) ::
          {:ok, [HistoryEntry.t()]} | {:error, term()}
  def read_session(session_id, opts), do: read_stream(StreamIds.for_session(session_id), opts)

  @doc "Read entries for a specific correlation chain."
  @spec read_correlation(String.t(), keyword()) ::
          {:ok, [HistoryEntry.t()]} | {:error, term()}
  def read_correlation(correlation_id, opts),
    do: read_stream(StreamIds.for_correlation(correlation_id), opts)

  @doc "Read the global stream."
  @spec read_global(keyword()) :: {:ok, [HistoryEntry.t()]} | {:error, term()}
  def read_global(opts), do: read_stream("global", opts)

  @doc """
  Query the global stream with post-filters.

  `:limit` bounds returned matches. `:max_scan` separately bounds rows inspected
  by filtered queries and defaults to 10,000.
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
      |> emit_error(:query, "global")
    end
  end

  @doc "Find a history entry by its original signal ID."
  @spec find_by_signal_id(String.t(), keyword()) ::
          {:ok, HistoryEntry.t()} | {:error, :not_found | term()}
  def find_by_signal_id(signal_id, opts) do
    result =
      opts
      |> scan_complete_history(&(&1.signal_id == signal_id), 1)
      |> emit_error(:find_by_signal_id, signal_id)

    case result do
      {:ok, [entry]} -> {:ok, entry}
      {:ok, []} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  if Mix.env() == :test do
    defp resolve_authoritative_target(opts) do
      case Keyword.fetch(opts, :event_log) do
        {:ok, name} -> configured_test_target(name)
        :error -> configured_target()
      end
    rescue
      _error -> target_error(:invalid_configuration)
    catch
      _kind, _reason -> target_error(:invalid_configuration)
    end

    defp configured_test_target(name) when is_atom(name) and not is_nil(name) do
      case Config.hot_event_log_target() do
        {:ok, target} -> target |> Map.put(:name, name) |> validate_target()
        {:error, _reason} -> target_error(:invalid_configuration)
      end
    end

    defp configured_test_target(_name), do: target_error(:invalid_target)
  else
    defp resolve_authoritative_target(_opts) do
      configured_target()
    rescue
      _error -> target_error(:invalid_configuration)
    catch
      _kind, _reason -> target_error(:invalid_configuration)
    end
  end

  defp configured_target do
    case Config.durable_event_log_target() do
      {:ok, target} -> validate_target(target)
      {:error, _reason} -> target_error(:invalid_configuration)
    end
  end

  defp validate_target(%{name: name, backend: backend, opts: opts} = target)
       when is_atom(name) and not is_nil(name) and is_atom(backend) and not is_nil(backend) and
              is_list(opts) do
    if Keyword.keyword?(opts), do: {:ok, target}, else: target_error(:invalid_target)
  end

  defp validate_target(_target), do: target_error(:invalid_target)

  defp target_error(reason), do: {:error, {:authoritative_target_unavailable, reason}}

  defp reject_projection_mode(target, stream_id) do
    if Persistence.supports_projection?(target.backend) do
      case facade_call(fn ->
             Persistence.resident_projected_stream_version(
               target.name,
               target.backend,
               stream_id,
               target.opts
             )
           end) do
        {:returned, {:error, :projection_mode_required}} ->
          :ok

        {:returned, {:ok, version}} when is_integer(version) and version >= 0 ->
          {:error, {:authoritative_target_rejected, :projection}}

        {:returned, _other} ->
          {:error, {:authoritative_target_unavailable, :malformed_authority_reply}}

        {:failed, failure} ->
          {:error, {:authoritative_target_unavailable, failure}}
      end
    else
      :ok
    end
  end

  defp read_authoritative_stream(target, stream_id, opts) do
    datetime_filter? = datetime_bound?(opts[:from]) or datetime_bound?(opts[:to])
    scan_bound = scan_limit_for_admission(opts, datetime_filter?)
    row_limit = durable_row_limit(opts, datetime_filter?)

    dynamic_opts =
      []
      |> maybe_put_direction(opts[:direction])
      |> Keyword.put(:from, integer_from(opts[:from]))
      |> maybe_put_positive_int(:limit, durable_fetch_limit(row_limit, scan_bound))

    read_opts = merge_target_opts(dynamic_opts, target.opts)

    with {:ok, events} <- facade_read(target, stream_id, read_opts),
         :ok <- validate_event_page(events, opts[:direction]),
         {:ok, admitted} <- admit_page(events, scan_bound) do
      {:ok, admitted}
    end
  end

  defp facade_read(target, stream_id, opts) do
    case facade_call(fn ->
           Persistence.read_stream(target.name, target.backend, stream_id, opts)
         end) do
      {:returned, {:ok, events}} when is_list(events) ->
        {:ok, events}

      {:returned, {:ok, _malformed}} ->
        {:error, {:authoritative_read_failed, :malformed_success_reply}}

      {:returned, {:error, _reason}} ->
        {:error, {:authoritative_read_failed, :backend_error}}

      {:returned, _malformed} ->
        {:error, {:authoritative_read_failed, :malformed_reply}}

      {:failed, failure} ->
        {:error, {:authoritative_read_failed, failure}}
    end
  end

  defp facade_call(fun) do
    {:returned, fun.()}
  rescue
    _error -> {:failed, :backend_exception}
  catch
    :exit, _reason -> {:failed, :backend_exit}
    :throw, _reason -> {:failed, :backend_throw}
    _kind, _reason -> {:failed, :backend_failure}
  end

  defp merge_target_opts(query_opts, target_opts) do
    Keyword.merge(query_opts, target_opts)
  end

  defp admit_page(events, scan_bound)
       when is_integer(scan_bound) and length(events) > scan_bound,
       do: scan_limit_exceeded(scan_bound)

  defp admit_page(events, _scan_bound), do: {:ok, events}

  defp validate_event_page([], _direction), do: :ok

  defp validate_event_page(events, :backward) do
    validate_event_numbers(events, &</2)
  end

  defp validate_event_page(events, _direction) do
    validate_event_numbers(events, &>/2)
  end

  defp validate_event_numbers(events, advances?) do
    Enum.reduce_while(events, nil, fn
      %{event_number: number}, nil when is_integer(number) and number > 0 ->
        {:cont, number}

      %{event_number: number}, previous when is_integer(number) and number > 0 ->
        if advances?.(number, previous), do: {:cont, number}, else: {:halt, :error}

      _event, _previous ->
        {:halt, :error}
    end)
    |> case do
      :error -> {:error, {:authoritative_read_failed, :malformed_event_page}}
      _last_number -> :ok
    end
  end

  defp scan_complete_history(opts, matcher, result_limit) do
    if opts[:direction] == :backward do
      {:error, {:invalid_query_options, :backward_filtered_scan_unsupported}}
    else
      do_scan_complete_history(opts, matcher, result_limit)
    end
  end

  defp do_scan_complete_history(opts, matcher, result_limit) do
    max_scan = positive_int(opts[:max_scan]) || @default_filtered_max_scan

    with {:ok, resolved} <- resolve_authoritative_target(opts),
         :ok <- reject_projection_mode(resolved, "global") do
      state = %{
        target: resolved,
        matcher: matcher,
        result_limit: result_limit,
        max_scan: max_scan,
        page_size: positive_int(opts[:durable_page_size]) || @default_durable_page_size,
        from: integer_from(opts[:from]),
        scanned: 0,
        matches: [],
        match_count: 0
      }

      scan_authoritative_page(state)
    end
  end

  defp scan_authoritative_page(%{scanned: scanned, max_scan: max_scan})
       when scanned >= max_scan,
       do: scan_limit_exceeded(max_scan)

  defp scan_authoritative_page(state) do
    consume_cap = min(state.page_size, state.max_scan - state.scanned)

    read_opts =
      [from: state.from, limit: consume_cap + 1]
      |> merge_target_opts(state.target.opts)

    with {:ok, events} <- facade_read(state.target, "global", read_opts),
         {:ok, extra?} <- validate_forward_page(events, state.from, consume_cap) do
      consume_page(events, state, consume_cap, extra?)
    end
  end

  defp validate_forward_page(events, from, consume_cap) do
    events
    |> Enum.reduce_while({0, nil}, fn
      _event, {count, _previous} when count >= consume_cap + 1 ->
        {:halt, :overflow}

      %{event_number: number}, {0, nil}
      when is_integer(number) and number > 0 and number >= max(from, 1) ->
        {:cont, {1, number}}

      %{event_number: number}, {count, previous}
      when is_integer(number) and number > previous ->
        {:cont, {count + 1, number}}

      _event, _state ->
        {:halt, :malformed}
    end)
    |> case do
      :overflow ->
        {:error, {:authoritative_read_failed, :malformed_event_page}}

      :malformed ->
        {:error, {:invalid_authoritative_page, :non_advancing_cursor}}

      {count, _last} ->
        {:ok, count > consume_cap}
    end
  end

  defp consume_page(events, state, consume_cap, extra?) do
    consumed = Enum.take(events, consume_cap)

    case collect_matches(
           consumed,
           state.matcher,
           state.result_limit,
           state.matches,
           state.match_count
         ) do
      {:proven, next_matches, _next_count} ->
        {:ok, Enum.reverse(next_matches)}

      {:error, _reason} = error ->
        error

      {:continue, next_matches, next_count} ->
        scanned_after = state.scanned + length(consumed)

        cond do
          not extra? ->
            {:ok, Enum.reverse(next_matches)}

          scanned_after >= state.max_scan ->
            scan_limit_exceeded(state.max_scan)

          true ->
            with {:ok, next_from} <- next_cursor(consumed, state.from) do
              scan_authoritative_page(%{
                state
                | from: next_from,
                  scanned: scanned_after,
                  matches: next_matches,
                  match_count: next_count
              })
            end
        end
    end
  end

  defp collect_matches(events, matcher, result_limit, matches, match_count) do
    Enum.reduce_while(events, {:continue, matches, match_count}, fn event, state ->
      case convert_to_history_entry(event) do
        {:ok, entry} -> maybe_collect_match(entry, state, matcher, result_limit)
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

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

  defp next_cursor([], _from),
    do: {:error, {:invalid_authoritative_page, :empty_nonterminal_page}}

  defp next_cursor(events, from) do
    case List.last(events) do
      %{event_number: event_number} when is_integer(event_number) and event_number >= from ->
        {:ok, event_number + 1}

      _ ->
        {:error, {:invalid_authoritative_page, :non_advancing_cursor}}
    end
  end

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

  defp scan_limit_for_admission(opts, datetime_filter?) do
    max_scan = positive_int(opts[:max_scan])
    caller_limit = positive_int(opts[:limit])

    cond do
      is_nil(max_scan) -> nil
      datetime_filter? -> max_scan
      is_nil(caller_limit) -> max_scan
      max_scan < caller_limit -> max_scan
      true -> nil
    end
  end

  defp durable_row_limit(opts, datetime_filter?) do
    caller_limit = positive_int(opts[:limit])
    max_scan = positive_int(opts[:max_scan])

    cond do
      datetime_filter? -> max_scan
      is_integer(caller_limit) and is_integer(max_scan) -> min(caller_limit, max_scan)
      is_integer(caller_limit) -> caller_limit
      true -> max_scan
    end
  end

  defp durable_fetch_limit(row_limit, nil), do: row_limit
  defp durable_fetch_limit(_row_limit, scan_bound), do: scan_bound + 1

  defp integer_from(value) when is_integer(value), do: value
  defp integer_from(_value), do: 0

  defp datetime_bound?(%DateTime{}), do: true
  defp datetime_bound?(_value), do: false

  defp positive_int(value) when is_integer(value) and value > 0, do: value
  defp positive_int(_value), do: nil

  defp maybe_put_positive_int(opts, _key, nil), do: opts
  defp maybe_put_positive_int(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_direction(opts, direction) when direction in [:forward, :backward],
    do: Keyword.put(opts, :direction, direction)

  defp maybe_put_direction(opts, _direction), do: opts

  defp scan_limit_exceeded(max_scan),
    do: {:error, {:scan_limit_exceeded, %{max_scan: max_scan}}}

  defp apply_limit(entries, opts) do
    case positive_int(opts[:limit]) do
      nil -> entries
      limit -> Enum.take(entries, limit)
    end
  end

  defp convert_events(events) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, entries} ->
      case convert_to_history_entry(event) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  defp convert_to_history_entry(persistence_event) do
    case EventConverter.from_persistence_event(persistence_event) do
      {:ok, historian_event} ->
        {:ok, HistoryEntry.from_event(historian_event)}

      {:error, _reason} ->
        {:error, {:authoritative_read_failed, :malformed_event_page}}
    end
  rescue
    _error -> {:error, {:authoritative_read_failed, :malformed_event_page}}
  catch
    _kind, _reason -> {:error, {:authoritative_read_failed, :malformed_event_page}}
  end

  defp emit_error({:error, reason} = error, query_type, details) do
    Signals.emit(:historian, :query_failed, %{
      query_type: query_type,
      query_details: bounded_details(details),
      reason: bounded_reason(reason)
    })

    error
  end

  defp emit_error(result, _query_type, _details), do: result

  defp bounded_details(details) when is_binary(details) do
    details
    |> binary_part(0, min(byte_size(details), 100))
    |> String.replace_invalid("?")
  end

  defp bounded_details(_details), do: "non_binary_identifier"

  defp bounded_reason({:scan_limit_exceeded, _metadata}), do: "scan_limit_exceeded"
  defp bounded_reason({:authoritative_target_unavailable, reason}), do: Atom.to_string(reason)
  defp bounded_reason({:authoritative_target_rejected, reason}), do: Atom.to_string(reason)
  defp bounded_reason({:authoritative_read_failed, reason}), do: Atom.to_string(reason)
  defp bounded_reason({:invalid_authoritative_page, reason}), do: Atom.to_string(reason)
  defp bounded_reason({:invalid_query_options, reason}), do: Atom.to_string(reason)
  defp bounded_reason(_reason), do: "query_failed"
end
