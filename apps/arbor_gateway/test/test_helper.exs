# Memory processes + durable knowledge-graph authority — the memory router
# tests need them. Shared with the other consumer apps.
Arbor.Memory.TestBootstrap.start!()

# arbor_chat_history is an arbor_agent eval table, not an arbor_memory one, so
# TestBootstrap does not own it.
if :ets.whereis(:arbor_chat_history) == :undefined do
  :ets.new(:arbor_chat_history, [:named_table, :public, :set])
end

# :integration runs by default (hermetic — gating CI runs plain `mix test`);
# only backend-dependent tags are excluded. Fast loop: `mix test.fast`.
ExUnit.start(exclude: [:llm, :llm_local])
