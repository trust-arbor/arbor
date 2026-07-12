defmodule Arbor.Scheduler.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
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

    opts = [strategy: :one_for_one, name: Arbor.Scheduler.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
