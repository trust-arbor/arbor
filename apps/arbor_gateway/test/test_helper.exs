# Memory processes + durable knowledge-graph authority — the memory router
# tests need them. Shared with the other consumer apps.
Arbor.Memory.TestBootstrap.start!()

# arbor_chat_history is an arbor_agent eval table, not an arbor_memory one, so
# TestBootstrap does not own it.
if :ets.whereis(:arbor_chat_history) == :undefined do
  :ets.new(:arbor_chat_history, [:named_table, :public, :set])
end

# Security stores. Arbor.Security.grant/1 needs the durable capability store
# since 206d06b5d ("make capability replacement durable", 2026-08-06); without
# it the MCP agent-endpoint tests fail with a compound
# :capability_replacement_outcome_unknown error that names the wrong thing.
Arbor.Security.TestBootstrap.start!()

# :integration runs by default (hermetic — gating CI runs plain `mix test`);
# only backend-dependent tags are excluded. Fast loop: `mix test.fast`.
ExUnit.start(exclude: [:llm, :llm_local])
