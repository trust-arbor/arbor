defmodule Arbor.Persistence.Application do
  @moduledoc """
  Optional application for Arbor.Persistence.

  This application does NOT auto-start any processes. Users are expected
  to add persistence adapters (ETS GenServers, etc.) to their own
  supervision trees.

  This module exists only for OTP application metadata.
  """

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: Arbor.Persistence.Supervisor)
  end
end
