defmodule Arbor.Comms.Supervisor do
  @moduledoc """
  Supervises comms channel workers and polling processes.
  """

  use Supervisor

  alias Arbor.Comms.Channels.Signal
  alias Arbor.Comms.Config

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = build_children()
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_children do
    # Only start enabled channels
    []
    |> maybe_add_signal()
  end

  defp maybe_add_signal(children) do
    if Config.channel_enabled?(:signal) do
      children ++ [{Signal.Poller, []}]
    else
      children
    end
  end
end
