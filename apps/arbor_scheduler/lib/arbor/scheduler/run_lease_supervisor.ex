defmodule Arbor.Scheduler.RunLeaseSupervisor do
  @moduledoc false

  use Supervisor

  alias Arbor.Scheduler.RunLease

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: RunLease.Registry},
      RunLease.Store,
      {DynamicSupervisor, strategy: :one_for_one, name: RunLease.DynamicSupervisor}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
