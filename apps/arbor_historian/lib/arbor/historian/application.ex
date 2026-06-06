defmodule Arbor.Historian.Application do
  @moduledoc """
  Supervisor for the Historian subsystem.

  Starts:
  1. Persistence.EventLog.ETS - In-memory event cache for fast queries
  2. StreamRegistry - Tracks stream metadata
  3. Metadata rehydrate - Aligns the cache's `stream_versions` and
     `global_position` counters with the durable SQL backend
     (Postgres or SQLite3, via the configured Repo adapter), without
     replaying any events. The cache starts empty; reads for historical
     events fall through to the durable backend at the query layer.

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
  global_position) so subsequent appends don't collide. That's two
  SQL aggregate queries — order-of-magnitude faster boot, bounded
  RAM, no semantic change for callers.
  """

  use Application

  require Logger

  alias Arbor.Signals

  @event_log_name Arbor.Historian.EventLog.ETS

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_historian, :start_children, true) do
        [
          {Arbor.Persistence.EventLog.ETS, name: @event_log_name},
          {Arbor.Historian.StreamRegistry, name: Arbor.Historian.StreamRegistry}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Historian.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        if children != [] do
          hydrate_metadata_from_durable()
          emit_started()
        end

        {:ok, pid}

      error ->
        error
    end
  end

  # Rehydrate the in-memory bookkeeping (stream_versions map +
  # global_position counter) from the durable backend so that
  # subsequent appends use correct, non-colliding values from t=0.
  # Synchronous — boot blocks until done (~1s on a hot DB). If the
  # Repo isn't available (some test setups, ETS-only dev instances),
  # the cache starts at the zero state and is populated by new
  # writes; historical queries return empty until events are written.
  defp hydrate_metadata_from_durable do
    durable = Arbor.Persistence.EventLog.Ecto
    ets = Arbor.Persistence.EventLog.ETS
    repo = Arbor.Persistence.Repo

    if Code.ensure_loaded?(durable) and Code.ensure_loaded?(repo) and Process.whereis(repo) do
      try do
        case apply(durable, :metadata_snapshot, [[repo: repo]]) do
          {:ok, snapshot} ->
            apply(ets, :rehydrate_metadata, [snapshot, [name: @event_log_name]])
            stream_count = map_size(snapshot.stream_versions)

            if stream_count > 0 or snapshot.global_position > 0 do
              Logger.info(
                "[Historian] Rehydrated metadata: #{stream_count} streams, global_position=#{snapshot.global_position}"
              )
            end

          {:error, reason} ->
            Logger.warning(
              "[Historian] Metadata rehydrate failed: #{inspect(reason)}; cache starts at zero state"
            )
        end
      rescue
        e ->
          Logger.warning(
            "[Historian] Metadata rehydrate exception: #{Exception.message(e)}; cache starts at zero state"
          )
      catch
        :exit, reason ->
          Logger.warning(
            "[Historian] Metadata rehydrate exit: #{inspect(reason)}; cache starts at zero state"
          )
      end
    end
  end

  defp emit_started do
    Signals.emit(:historian, :started, %{})
  end
end
