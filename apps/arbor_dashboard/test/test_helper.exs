Application.ensure_all_started(:arbor_dashboard)
# Same Trust.Store subscription requirement as the agent and orchestrator
# suites: the signals bus must be a supervised child before any test starts Store.
:ok = Arbor.Signals.restore_runtime_fixture()
{:ok, _} = Arbor.Dashboard.Endpoint.start_link()
ExUnit.start(exclude: [:database, :llm, :llm_local])
