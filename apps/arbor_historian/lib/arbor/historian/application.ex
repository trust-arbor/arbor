defmodule Arbor.Historian.Application do
  @moduledoc """
  Supervisor for the Historian subsystem.

  Starts:
  1. Persistence.EventLog.ETS - Unified event storage
  2. StreamRegistry - Tracks stream metadata
  """

  use Application

  alias Arbor.Signals

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_historian, :start_children, true) do
        [
          {Arbor.Persistence.EventLog.ETS, name: Arbor.Historian.EventLog.ETS},
          {Arbor.Historian.StreamRegistry, name: Arbor.Historian.StreamRegistry}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Historian.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        if children != [], do: emit_started()
        {:ok, pid}

      error ->
        error
    end
  end

  defp emit_started do
    Signals.emit(:historian, :started, %{})
  end
end
