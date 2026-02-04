# Add children to the empty app supervisors (start_children: false leaves them empty)
# Order matters: TopicRegistry first (for topic-based routing), Registry, then Supervisor,
# then EventStore, then Coordinator
children = [
  Arbor.Consensus.TopicRegistry,
  Arbor.Consensus.EventStore,
  {Registry, keys: :unique, name: Arbor.Consensus.EvaluatorAgent.Registry},
  Arbor.Consensus.EvaluatorAgent.Supervisor,
  Arbor.Consensus.Coordinator
]

for child <- children do
  Supervisor.start_child(Arbor.Consensus.Supervisor, child)
end

# Disable LLM topic classification in tests by default.
# Without this, unmatched topics trigger synchronous Arbor.AI.generate_text
# calls inside the Coordinator's handle_call, causing 5-second GenServer timeouts.
# Tests that specifically need LLM classification can re-enable it.
Application.put_env(:arbor_consensus, :llm_topic_classification_enabled, false)

# Register common test topics so proposals don't trigger LLM classification.
# Without this, submitting a proposal with topic: :code_modification triggers
# TopicMatcher -> Arbor.AI.generate_text synchronously inside the Coordinator's
# handle_call, causing 5-second GenServer.call timeouts.
alias Arbor.Consensus.TopicRegistry

for topic <- [:code_modification, :test_change] do
  TopicRegistry.register_topic(%{
    topic: topic,
    min_quorum: :majority,
    match_patterns: [to_string(topic)]
  })
end

# Deterministic evaluator tests need shell processes
Supervisor.start_child(Arbor.Shell.Supervisor, {Arbor.Shell.ExecutionRegistry, []})

ExUnit.start()
