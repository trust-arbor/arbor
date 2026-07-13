defmodule Arbor.Scheduler.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    runtime_children =
      if Application.get_env(:arbor_scheduler, :start_children, true) do
        [
          Arbor.Scheduler.RunLeaseSupervisor,
          Arbor.Scheduler.RunIdentityReaper,

          # Identity must start BEFORE Oban so the scheduler has its stable
          # SigningAuthority before workers can dispatch pipelines.
          Arbor.Scheduler.Identity,

          # Oban — scheduling substrate. Repo lives in arbor_persistence.
          # Cron jobs configured under :arbor_scheduler, Oban; see
          # config/config.exs for the cron table.
          {Oban, Application.fetch_env!(:arbor_scheduler, Oban)}
        ]
      else
        []
      end

    children = [
      Arbor.Scheduler.RunLease.JournalOwner,
      {Arbor.Scheduler.RuntimeSupervisor, runtime_children}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Arbor.Scheduler.ApplicationSupervisor
    )
  end
end

defmodule Arbor.Scheduler.RuntimeSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(children) do
    Supervisor.start_link(__MODULE__, children, name: Arbor.Scheduler.Supervisor)
  end

  @impl true
  def init(children) do
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 5)
  end
end
