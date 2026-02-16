defmodule Arbor.Test.BehavioralCase do
  @moduledoc """
  ExUnit case template for behavioral integration tests.

  Starts full process trees across multiple apps in the correct order,
  configures test-friendly defaults, and cleans up on exit.

  ## Usage

      use Arbor.Test.BehavioralCase

  All tests using this case are tagged with `@moduletag :behavioral`.
  Run them with: `mix test --only behavioral`

  ## What Gets Started

  In dependency order:
  1. Signals (Store + Bus) — event infrastructure
  2. Security (SystemAuthority, CapabilityStore, Reflex.Registry, Identity) — auth layer
  3. Memory (ETS tables, stores, index) — agent memory
  4. Consensus (TopicRegistry, EventStore, Coordinator) — council
  5. Agent (Registry, Supervisor, Executor) — agent runtime

  ## Configuration

  - `capability_signing_required: false` — test capabilities don't need signatures
  - LLM topic classification disabled — prevents sync LLM calls in Coordinator
  - Common test topics pre-registered
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :behavioral
      import Arbor.Test.LLMAssertions
    end
  end

  setup_all do
    # Ensure all required apps are loaded
    for app <- [:arbor_signals, :arbor_security, :arbor_memory, :arbor_consensus, :arbor_agent] do
      Application.ensure_all_started(app)
    end

    :ok
  end

  setup do
    # 1. Signals — event infrastructure
    ensure_started(Arbor.Signals.Supervisor, [
      {Arbor.Signals.Store, []},
      {Arbor.Signals.Bus, []}
    ])

    # 2. Security — auth layer
    ensure_started(Arbor.Security.Supervisor, [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ])

    # 3. Memory — ETS tables + stores
    for table <- [
          :arbor_memory_graphs,
          :arbor_working_memory,
          :arbor_memory_proposals,
          :arbor_chat_history,
          :arbor_preferences
        ] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    ensure_started(Arbor.Memory.Supervisor, [
      {Registry, keys: :unique, name: Arbor.Memory.Registry},
      {Arbor.Memory.IndexSupervisor, []},
      {Arbor.Memory.GoalStore, []},
      {Arbor.Memory.IntentStore, []},
      {Arbor.Memory.Thinking, []},
      {Arbor.Memory.CodeStore, []}
    ])

    # 4. Consensus — topic routing + evaluation
    ensure_started(Arbor.Consensus.Supervisor, [
      Arbor.Consensus.TopicRegistry,
      Arbor.Consensus.EventStore,
      {Registry, keys: :unique, name: Arbor.Consensus.EvaluatorAgent.Registry},
      Arbor.Consensus.EvaluatorAgent.Supervisor,
      Arbor.Consensus.Coordinator
    ])

    # Disable LLM classification in tests
    Application.put_env(:arbor_consensus, :llm_topic_classification_enabled, false)

    # Register common test topics
    for topic <- [:test_topic, :code_modification, :test_change] do
      Arbor.Consensus.TopicRegistry.register_topic(%{
        topic: topic,
        min_quorum: :majority,
        match_patterns: [to_string(topic)]
      })
    end

    # 5. Agent — runtime
    ensure_started(Arbor.Agent.AppSupervisor, [
      {Registry, keys: :unique, name: Arbor.Agent.ExecutorRegistry},
      {Registry, keys: :unique, name: Arbor.Agent.ReasoningLoopRegistry},
      Arbor.Agent.Registry,
      Arbor.Agent.Supervisor
    ])

    # Generate a unique test agent ID
    agent_id = "agent_test_#{:erlang.unique_integer([:positive])}"

    # Grant basic capabilities for the test agent
    grant_test_capabilities(agent_id)

    {:ok, agent_id: agent_id}
  end

  defp ensure_started(supervisor, children) do
    if Process.whereis(supervisor) do
      for child <- children do
        try do
          case Supervisor.start_child(supervisor, child) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, :already_present} -> :ok
            _other -> :ok
          end
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  defp grant_test_capabilities(agent_id) do
    capabilities = [
      "arbor://ai/request/auto",
      "arbor://ai/request/anthropic",
      "arbor://ai/request/openai",
      "arbor://ai/request/gemini",
      "arbor://memory/read",
      "arbor://memory/write",
      "arbor://consensus/propose",
      "arbor://consensus/evaluate"
    ]

    for uri <- capabilities do
      cap = %Arbor.Contracts.Security.Capability{
        id: "cap_behavioral_#{agent_id}_#{URI.encode(uri)}",
        resource_uri: uri,
        principal_id: agent_id,
        granted_at: DateTime.utc_now(),
        expires_at: nil,
        constraints: %{},
        delegation_depth: 0,
        metadata: %{test: true, behavioral: true}
      }

      Arbor.Security.CapabilityStore.put(cap)
    end
  end
end
