{:ok, _started} = Application.ensure_all_started(:arbor_kernel_runtime)

defmodule Arbor.Memory.TestSupport.OfflineLLMAdapter do
  @moduledoc false
  @behaviour Arbor.LLM.ProviderAdapter

  def provider, do: "memory_test_offline"
  def complete(_request, _opts), do: {:error, :memory_test_llm_unavailable}
end

# Untagged unit tests exercise local fallback behavior even when the shared
# .env contains valid provider credentials. Keep every default Client route
# offline; a real transport integration must install its own explicit client.
# This changes only the test transport, leaving classification and admission
# enabled. AI's verified :test embedding backend remains independent of Client.
prior_llm_client = :persistent_term.get({Arbor.LLM.Client, :default_client}, :missing)
prior_bridge_client = :persistent_term.get({Arbor.AI.UnifiedBridge, :client}, :missing)

offline_providers = Arbor.LLM.known_providers() ++ ~w(acp openai_oauth xai_oauth)

offline_client =
  Arbor.LLM.Client.new(
    adapters: Map.new(offline_providers, &{&1, Arbor.Memory.TestSupport.OfflineLLMAdapter}),
    default_provider: "openai"
  )

Arbor.LLM.Client.set_default_client(offline_client)
:persistent_term.put({Arbor.AI.UnifiedBridge, :client}, offline_client)

:ok = Arbor.Security.TestBootstrap.start!()
:ok = Arbor.Historian.TestAuditRuntime.start_default_lane!()

Code.require_file("support/durable_graph_authority.ex", __DIR__)
Code.require_file("support/confirming_vector_seam.ex", __DIR__)
Code.require_file("support/durable_event_log.ex", __DIR__)
Code.require_file("support/mutation_admission_fake_backend.ex", __DIR__)
Code.require_file("support/async_writer_hang_backend.ex", __DIR__)
Code.require_file("support/signals_checkpoint_fake.ex", __DIR__)

# Add children to the empty app supervisor (start_children: false leaves it empty)
# Create ETS tables first (same as Application.start/2 does)
tables = [
  :arbor_memory_graphs,
  :arbor_working_memory,
  :arbor_memory_proposals,
  :arbor_preferences
]

for table <- tables do
  if :ets.whereis(table) == :undefined do
    :ets.new(table, [:named_table, :public, :set])
  end
end

for child <- [
      {Registry, keys: :unique, name: Arbor.Memory.Registry},
      {Arbor.Memory.ArchiveCursorSigner, []},
      {Arbor.Memory.Provenance, []},
      {Arbor.Memory.Proposal.Store, []},
      {Arbor.Memory.KnowledgeGraphStore, []},
      {Arbor.Memory.IndexSupervisor, []},
      {Arbor.Persistence.EventLog.ETS, name: :memory_events},
      # Seed/Host Phase 3 stores
      {Arbor.Memory.GoalStore, []},
      {Arbor.Memory.IntentStore, []},
      {Arbor.Memory.Thinking, []},
      {Arbor.Memory.CodeStore, []}
    ] do
  Supervisor.start_child(Arbor.Memory.Supervisor, child)
end

# Signal system — emit functions need Store + Bus running
for child <- [
      {Arbor.Signals.Store, []},
      {Arbor.Signals.Bus, []}
    ] do
  Supervisor.start_child(Arbor.Signals.Supervisor, child)
end

# Admission + async writer without taking :arbor_memory_durable (graph tests
# own that name via DurableGraphAuthority). Injected target only — no global
# mutation_admission_backend fixture config.
:ok = Arbor.Memory.TestBootstrap.start!(authority: false)

# Exclude database tests by default (require postgres + pgvector)
# Run them with: mix test --include database
ExUnit.start(exclude: [:database, :llm, :llm_local])

ExUnit.after_suite(fn _result ->
  for {key, prior} <- [
        {{Arbor.LLM.Client, :default_client}, prior_llm_client},
        {{Arbor.AI.UnifiedBridge, :client}, prior_bridge_client}
      ] do
    if prior == :missing,
      do: :persistent_term.erase(key),
      else: :persistent_term.put(key, prior)
  end
end)
