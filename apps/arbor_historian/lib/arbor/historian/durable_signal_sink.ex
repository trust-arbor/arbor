defmodule Arbor.Historian.DurableSignalSink do
  @moduledoc false

  require Logger

  alias Arbor.Historian.Config
  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog

  @spec persist(String.t(), term(), map(), keyword()) :: :ok | {:error, :persist_failed}
  def persist(stream_id, event_type, data, opts) do
    case construct(stream_id, event_type, data, opts) do
      {:ok, event} ->
        case persist_durable(stream_id, event) do
          {:ok, committed_events} ->
            # Durable acknowledgement is authoritative; projection gaps are observability-only.
            project_hot(stream_id, committed_events)
            :ok

          {:error, :persist_failed} = error ->
            error
        end

      {:error, :persist_failed} = error ->
        error
    end
  rescue
    _ ->
      {:error, :persist_failed}
  catch
    kind, _reason when kind in [:throw, :exit] ->
      {:error, :persist_failed}
  end

  defp construct(stream_id, event_type, data, opts) do
    {:ok, build_event(stream_id, event_type, data, opts)}
  rescue
    _ ->
      log_gap(stream_id, :event_construction_failed)
      {:error, :persist_failed}
  catch
    kind, _reason when kind in [:throw, :exit] ->
      log_gap(stream_id, :event_construction_failed)
      {:error, :persist_failed}
  end

  defp build_event(stream_id, event_type, data, opts) do
    Event.new(
      stream_id,
      to_string(event_type),
      Map.put(data, :timestamp, DateTime.utc_now()),
      event_opts(opts)
    )
  end

  defp event_opts(opts) when is_list(opts) do
    caller_meta =
      case Keyword.get(opts, :metadata, %{}) do
        meta when is_map(meta) -> meta
        _ -> %{}
      end

    metadata =
      caller_meta
      |> Map.drop([:source_node, "source_node"])
      |> Map.put(:source_node, node())

    [metadata: metadata]
    |> put_present(:correlation_id, Keyword.get(opts, :correlation_id))
    |> put_present(:causation_id, Keyword.get(opts, :cause_id))
    |> put_present(:agent_id, Keyword.get(opts, :agent_id))
  end

  defp put_present(kw, _key, nil), do: kw
  defp put_present(kw, key, value), do: Keyword.put(kw, key, value)

  defp project_hot(stream_id, committed_events) do
    case Config.hot_event_log_target() do
      {:error, _} ->
        log_gap(stream_id, :hot_target_invalid)
        :ok

      {:ok, target} ->
        cond do
          is_nil(Process.whereis(target.name)) ->
            log_gap(stream_id, :hot_unavailable)
            :ok

          true ->
            dispatch_hot(stream_id, committed_events, target)
        end
    end
  rescue
    _ ->
      log_gap(stream_id, :hot_projection_failed)
      :ok
  catch
    kind, _reason when kind in [:throw, :exit] ->
      log_gap(stream_id, :hot_projection_failed)
      :ok
  end

  defp dispatch_hot(stream_id, committed_events, target) do
    case Persistence.project_committed_events(
           target.name,
           target.backend,
           committed_events,
           target.opts
         ) do
      {:ok, _} -> :ok
      _ -> log_gap(stream_id, :hot_projection_failed)
    end

    :ok
  end

  defp persist_durable(stream_id, event) do
    case Config.durable_event_log_target() do
      {:error, _} ->
        log_gap(stream_id, :durable_target_invalid)
        {:error, :persist_failed}

      {:ok, target} ->
        case durable_ready?(target) do
          :ok ->
            commit_durable(stream_id, event, target)

          {:gap, reason} ->
            log_gap(stream_id, reason)
            {:error, :persist_failed}
        end
    end
  end

  defp durable_ready?(target) do
    cond do
      Keyword.has_key?(target.opts, :repo) ->
        if is_pid(Process.whereis(Keyword.get(target.opts, :repo))) do
          :ok
        else
          {:gap, :durable_repo_unavailable}
        end

      is_pid(Process.whereis(target.name)) ->
        :ok

      true ->
        {:gap, :durable_unavailable}
    end
  end

  # In-process observe-before-:ok (P1C-B). Persistence.append applies
  # EventLog's operation deadline; do not wrap in Task.start.
  defp commit_durable(stream_id, event, target) do
    case Persistence.append(target.name, target.backend, stream_id, event, target.opts) do
      {:ok, committed_events} ->
        if valid_committed_reply?(committed_events, stream_id, event) do
          {:ok, committed_events}
        else
          log_gap(stream_id, :durable_append_malformed)
          {:error, :persist_failed}
        end

      _ ->
        log_gap(stream_id, :durable_append_failed)
        {:error, :persist_failed}
    end
  rescue
    _ ->
      log_gap(stream_id, :durable_append_raised)
      {:error, :persist_failed}
  catch
    kind, _reason when kind in [:throw, :exit] ->
      log_gap(stream_id, :durable_append_raised)
      {:error, :persist_failed}
  end

  defp valid_committed_reply?(
         [
           %Event{
             id: committed_id,
             stream_id: committed_stream_id,
             event_number: event_number,
             global_position: global_position,
             operation_fingerprint: fingerprint
           } = committed
         ],
         stream_id,
         %Event{id: submitted_id} = submitted
       )
       when committed_id == submitted_id and committed_stream_id == stream_id and
              is_integer(event_number) and event_number > 0 and
              is_integer(global_position) and global_position > 0 and is_binary(fingerprint) do
    expected_fingerprint = EventLog.event_fingerprint(stream_id, submitted)

    is_binary(expected_fingerprint) and
      fingerprint == expected_fingerprint and
      EventLog.event_fingerprint_matches?(stream_id, committed, expected_fingerprint)
  rescue
    _ -> false
  end

  defp valid_committed_reply?(_events, _stream_id, _submitted), do: false

  @stream_id_log_max_bytes 64

  defp log_gap(stream_id, reason) do
    Logger.warning(
      "[Historian.durable_sink] persistence gap stream=#{format_stream_id(stream_id)} reason=#{reason}"
    )
  end

  defp format_stream_id(stream_id) when is_binary(stream_id) do
    take = min(byte_size(stream_id), @stream_id_log_max_bytes)
    prefix = binary_part(stream_id, 0, take)
    rendered = sanitize_stream_prefix(prefix)

    if byte_size(stream_id) > @stream_id_log_max_bytes do
      rendered <> "..."
    else
      rendered
    end
  rescue
    _ -> "<invalid>"
  end

  defp format_stream_id(_stream_id), do: "<invalid>"

  defp sanitize_stream_prefix(prefix) do
    for <<byte <- prefix>>, into: <<>> do
      if stream_id_log_byte?(byte), do: <<byte>>, else: "?"
    end
  end

  defp stream_id_log_byte?(byte)
       when byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in [?_, ?., ?:, ?-],
       do: true

  defp stream_id_log_byte?(_byte), do: false
end
