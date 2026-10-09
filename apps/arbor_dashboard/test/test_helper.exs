Application.ensure_all_started(:arbor_dashboard)
{:ok, _} = Arbor.Dashboard.Endpoint.start_link()
ExUnit.start(exclude: [:database, :llm, :llm_local])
