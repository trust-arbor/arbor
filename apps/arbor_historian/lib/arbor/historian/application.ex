defmodule Arbor.Historian.Application do
  @moduledoc """
  Supervisor for the Historian subsystem.

  Starts:
  1. Persistence.EventLog.ETS - Disposable in-memory projection for fast queries
  2. StreamRegistry - Tracks stream metadata

  ## Boot behavior

  The ETS child starts empty in projection mode. It never replays durable
  payloads, metadata, or identities during startup. QueryEngine reads fall
  through to the durable backend when projected rows are absent.
  """

  use Application

  alias Arbor.Signals

  # Host-injected Arbor.Historian.Adapters.SecurityEventLog persists Security
  # events onto this same EventLog stream (`security:events`).
  @event_log_name Arbor.Historian.EventLog.ETS

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_historian, :start_children, true) do
        [
          {Arbor.Persistence.EventLog.ETS, name: @event_log_name, mode: :projection},
          {Arbor.Historian.StreamRegistry, name: Arbor.Historian.StreamRegistry}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Historian.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        if children != [] do
          emit_started()
          {:ok, pid}
        else
          {:ok, pid}
        end

      error ->
        error
    end
  end

  defp emit_started do
    Signals.emit(:historian, :started, %{})
  end
end
