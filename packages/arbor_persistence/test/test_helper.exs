ExUnit.start(exclude: [:database, :isolated_repo, :llm, :llm_local, :external])

# These are explicit test fixtures, not implicit core-application resources.
{:ok, _fixture_supervisor} =
  Supervisor.start_link(
    [
      {Arbor.Persistence.Checkpoint.Store.ETS, []},
      {Arbor.Persistence.QueryableStore.ETS, name: :jobs},
      {Arbor.Persistence.EventLog.ETS, name: :event_log}
    ],
    strategy: :one_for_one,
    name: Arbor.Persistence.TestSupport.Supervisor
  )
