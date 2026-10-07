defmodule Arbor.Scheduler.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    scheduler_mutation_token = make_ref()
    start_children? = Application.get_env(:arbor_scheduler, :start_children, true)

    runtime_children =
      if start_children? do
        [
          # Identity must start BEFORE Oban so the scheduler has its stable
          # SigningAuthority before workers can dispatch pipelines.
          {Arbor.Scheduler.Identity, scheduler_mutation_token: scheduler_mutation_token},
          {Arbor.Scheduler.RunLeaseSupervisor,
           scheduler_mutation_token: scheduler_mutation_token},

          # Reaping is authority-decreasing but still authenticated. It runs
          # after Identity so cleanup uses the scheduler's owner-bound
          # authority rather than an ambient Security mutation API.
          {Arbor.Scheduler.RunIdentityReaper, scheduler_mutation_token: scheduler_mutation_token},

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

    case Supervisor.start_link(children,
           strategy: :rest_for_one,
           max_restarts: 5,
           max_seconds: 5,
           name: Arbor.Scheduler.ApplicationSupervisor
         ) do
      {:ok, supervisor} = started ->
        if start_children? do
          case Arbor.Scheduler.Identity.await_ready() do
            :ok ->
              case Arbor.Scheduler.RunIdentityReaper.await_ready() do
                :ok ->
                  started

                {:error, reason} ->
                  Supervisor.stop(supervisor, :shutdown)
                  {:error, {:run_identity_reaper_start_failed, reason}}
              end

            {:error, reason} ->
              Supervisor.stop(supervisor, :shutdown)
              {:error, {:scheduler_identity_start_failed, reason}}
          end
        else
          started
        end

      error ->
        error
    end
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
