defmodule Arbor.Historian.Application do
  @moduledoc """
  Supervisor for the Historian subsystem.

  Starts:
  1. Persistence.EventLog.ETS - In-memory event cache for fast queries
  2. StreamRegistry - Tracks stream metadata
  3. Metadata rehydrate - Aligns the cache's `stream_versions` and
     `global_position` counters with the durable SQL backend
     (Postgres or SQLite3, via the configured Repo adapter). Event payloads
     stay durable, while bounded pages rebuild the compact identity ledger
     required for globally unique, idempotent appends.

  ## Boot behavior

  Pre-2026-06-06: this supervisor used to spawn a background `Task`
  that called `EventLog.ETS.append/3` for every event in the durable
  log. With ~873k events on a hot dev instance, that loaded ~2.3 GB
  into ETS and pinned the boot sequence's RAM curve to the durable
  log's lifetime growth.

  Post-2026-06-06: ETS is bounded by retention (24h default) and
  reads fall through to the durable backend on cache miss
  (`QueryEngine.fetch_events_with_fallthrough`). Boot only needs to
  rehydrate the bookkeeping (max event_number per stream, max
  global_position) and replay only event identities. Payload reads still
  fall through to SQL, so boot retains the compact uniqueness ledger rather
  than every durable event payload.
  """

  use Application

  require Logger

  alias Arbor.Signals

  @event_log_name Arbor.Historian.EventLog.ETS
  @identity_replay_page_size 1_000

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_historian, :start_children, true) do
        [
          {Arbor.Persistence.EventLog.ETS, name: @event_log_name, identity_history: :incomplete},
          {Arbor.Historian.StreamRegistry, name: Arbor.Historian.StreamRegistry}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Historian.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        if children != [] do
          case hydrate_metadata_from_durable() do
            :ok ->
              emit_started()
              {:ok, pid}

            {:error, reason} ->
              Logger.error("[Historian] EventLog startup rehydrate failed: #{inspect(reason)}")
              Supervisor.stop(pid)
              {:error, {:event_log_rehydrate_failed, reason}}
          end
        else
          {:ok, pid}
        end

      error ->
        error
    end
  end

  # Rehydrate the in-memory bookkeeping (stream_versions map +
  # global_position counter) from the durable backend so that
  # subsequent appends use correct, non-colliding values from t=0.
  # Synchronous: aggregate metadata is fast, while the first identity-ledger
  # rebuild after an upgrade is proportional to durable history but reads in
  # fixed-size pages. A configured Repo with incomplete history fails startup
  # closed. If no Repo process exists (ETS-only test/dev instances), the cache
  # starts at zero and is populated by new writes.
  defp hydrate_metadata_from_durable do
    repo =
      Application.get_env(
        :arbor_historian,
        :identity_replay_repo,
        Arbor.Persistence.Repo
      )

    durable_event_log =
      Application.get_env(
        :arbor_historian,
        :identity_replay_durable_event_log,
        Arbor.Persistence.EventLog.Ecto
      )

    cache_event_log =
      Application.get_env(
        :arbor_historian,
        :identity_replay_cache_event_log,
        Arbor.Persistence.EventLog.ETS
      )

    if Process.whereis(repo) do
      try do
        case durable_event_log.metadata_snapshot(repo: repo) do
          {:ok, snapshot} ->
            rehydrate_result =
              cache_event_log.rehydrate_metadata(
                snapshot,
                name: @event_log_name
              )

            stream_count = map_size(snapshot.stream_versions)

            if stream_count > 0 or snapshot.global_position > 0 do
              Logger.info(
                "[Historian] Rehydrated metadata: #{stream_count} streams, global_position=#{snapshot.global_position}"
              )
            end

            case rehydrate_result do
              {:ok, :identity_history_complete} ->
                :ok

              {:ok, {:identity_history_unavailable, details}} ->
                replay_identity_history(
                  durable_event_log,
                  cache_event_log,
                  repo,
                  snapshot,
                  details
                )

              {:error, reason} ->
                {:error, {:metadata_rehydrate_rejected, reason}}
            end

          {:error, reason} ->
            {:error, {:metadata_snapshot_failed, reason}}
        end
      rescue
        e ->
          {:error, {:metadata_rehydrate_exception, e}}
      catch
        :exit, reason ->
          {:error, {:metadata_rehydrate_exit, reason}}
      end
    else
      initialize_empty_identity_history(cache_event_log)
    end
  end

  defp initialize_empty_identity_history(cache_event_log) do
    case cache_event_log.rehydrate_metadata(
           %{stream_versions: %{}, global_position: 0},
           name: @event_log_name
         ) do
      {:ok, :identity_history_complete} -> :ok
      {:ok, status} -> {:error, {:empty_identity_history_incomplete, status}}
      {:error, reason} -> {:error, {:empty_identity_history_rejected, reason}}
      other -> {:error, {:empty_identity_history_invalid_reply, other}}
    end
  end

  defp replay_identity_history(
         durable_event_log,
         cache_event_log,
         repo,
         snapshot,
         details
       ) do
    Logger.info("[Historian] Replaying bounded EventLog identity history: #{inspect(details)}")

    replay_identity_page(
      durable_event_log,
      cache_event_log,
      repo,
      1,
      snapshot.global_position
    )
  end

  defp replay_identity_page(_durable, cache, _repo, from_position, target_position)
       when from_position > target_position do
    case cache.identity_history_status(name: @event_log_name) do
      {:ok, :identity_history_complete} -> :ok
      {:ok, status} -> {:error, {:identity_replay_incomplete, status}}
      {:error, reason} -> {:error, {:identity_replay_status_failed, reason}}
    end
  end

  defp replay_identity_page(durable, cache, repo, from_position, target_position) do
    limit = min(@identity_replay_page_size, target_position - from_position + 1)

    case durable.read_all(repo: repo, from: from_position, limit: limit) do
      {:ok, events} when is_list(events) and events != [] ->
        replay_identity_events(
          durable,
          cache,
          repo,
          events,
          from_position,
          target_position
        )

      {:ok, []} ->
        {:error, {:identity_replay_missing_position, from_position}}

      {:error, reason} ->
        {:error, {:identity_replay_read_failed, reason}}

      other ->
        {:error, {:identity_replay_invalid_read, other}}
    end
  end

  defp replay_identity_events(
         durable,
         cache,
         repo,
         events,
         from_position,
         target_position
       ) do
    case validate_replay_positions(events, from_position, target_position) do
      {:ok, last_position} ->
        complete? = last_position == target_position

        case cache.replay_identity_history(events,
               name: @event_log_name,
               complete: complete?
             ) do
          {:ok, %{status: :identity_history_complete}} when complete? ->
            :ok

          {:ok, %{status: {:identity_history_unavailable, _details}}} when not complete? ->
            replay_identity_page(durable, cache, repo, last_position + 1, target_position)

          {:ok, %{status: status}} ->
            {:error, {:identity_replay_incomplete, status}}

          {:error, reason} ->
            {:error, {:identity_replay_write_failed, reason}}

          other ->
            {:error, {:identity_replay_invalid_write, other}}
        end

      :error ->
        {:error, {:identity_replay_invalid_sequence, from_position}}
    end
  end

  defp validate_replay_positions(events, from_position, target_position) do
    validate_replay_positions(events, from_position, target_position, nil)
  end

  defp validate_replay_positions([], _expected, _target, last_position)
       when is_integer(last_position),
       do: {:ok, last_position}

  defp validate_replay_positions(
         [%{global_position: position} | rest],
         expected,
         target,
         _last_position
       )
       when is_integer(position) and position == expected and position <= target do
    validate_replay_positions(rest, expected + 1, target, position)
  end

  defp validate_replay_positions(_events, _expected, _target, _last_position), do: :error

  defp emit_started do
    Signals.emit(:historian, :started, %{})
  end
end
