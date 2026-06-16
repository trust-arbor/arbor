# :slow runs by default (hermetic — gating CI runs plain `mix test`);
# only backend-dependent tags are excluded. Fast loop: `mix test.fast`.
ExUnit.start(exclude: [:llm, :llm_local])

# Start required processes for tests since start_children: false prevents Application startup
{:ok, _} = Arbor.Monitor.MetricsStore.start_link([])
{:ok, _} = Arbor.Monitor.Poller.start_link([])
