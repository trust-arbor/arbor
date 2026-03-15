defmodule Arbor.Historian.Application do
  @moduledoc """
  Supervisor for the Historian subsystem.

  Starts:
  1. Persistence.EventLog.ETS - Unified event storage (fast queries)
  2. StreamRegistry - Tracks stream metadata
  3. Startup replay - Loads durable events from Postgres into ETS
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
          replay_from_postgres()
          emit_started()
        end

        {:ok, pid}

      error ->
        error
    end
  end

  # Replay durable events from Postgres into the ETS EventLog.
  # This populates the fast query cache with events persisted before restart.
  defp replay_from_postgres do
    postgres = Arbor.Persistence.EventLog.Postgres
    ets = Arbor.Persistence.EventLog.ETS
    repo = Arbor.Persistence.Repo

    if Code.ensure_loaded?(postgres) and Code.ensure_loaded?(repo) and Process.whereis(repo) do
      Task.start(fn ->
        try do
          case apply(postgres, :list_streams, [[repo: repo]]) do
            {:ok, streams} ->
              total =
                Enum.reduce(streams, 0, fn stream_id, count ->
                  case apply(postgres, :read_stream, [stream_id, [repo: repo]]) do
                    {:ok, events} ->
                      Enum.each(events, fn event ->
                        ets.append(stream_id, event, name: @event_log_name)
                      end)

                      count + length(events)

                    {:error, _} ->
                      count
                  end
                end)

              if total > 0 do
                Logger.info(
                  "[Historian] Replayed #{total} events from #{length(streams)} streams"
                )
              end

            {:error, reason} ->
              Logger.warning("[Historian] Failed to list streams for replay: #{inspect(reason)}")
          end
        rescue
          e ->
            Logger.warning("[Historian] Startup replay failed: #{Exception.message(e)}")
        end
      end)
    end
  end

  defp emit_started do
    Signals.emit(:historian, :started, %{})
  end
end
