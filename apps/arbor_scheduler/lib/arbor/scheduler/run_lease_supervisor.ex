defmodule Arbor.Scheduler.RunLeaseSupervisor do
  @moduledoc false

  use Supervisor

  alias Arbor.Scheduler.RunLease

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    scheduler_mutation_token = Keyword.fetch!(opts, :scheduler_mutation_token)

    children = [
      {RunLease.StateOwner, scheduler_mutation_token: scheduler_mutation_token},
      RunLease.Store,
      {Registry, keys: :unique, name: RunLease.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: RunLease.DynamicSupervisor},
      {RunLease.Reconciler, scheduler_mutation_token: scheduler_mutation_token}
    ]

    # A StateOwner failure legitimately restarts all five children. OTP counts
    # each dependent restart against the intensity budget.
    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 10, max_seconds: 5)
  end
end
