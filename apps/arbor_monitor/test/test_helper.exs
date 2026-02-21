ExUnit.start(exclude: [:slow, :llm, :llm_local])

# Start required processes for tests since start_children: false prevents Application startup
{:ok, _} = Arbor.Monitor.MetricsStore.start_link([])
{:ok, _} = Arbor.Monitor.Poller.start_link([])
