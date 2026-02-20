ExUnit.start(exclude: [:live_local])

# Start CapabilityStore and insert a wildcard capability for "agent_system".
# This is the default principal used by CapabilityCheck middleware when no
# agent_id is set in token assigns. Without this grant, mandatory middleware
# blocks all handler execution in tests.
#
# We bypass Security.grant/1 because it requires SystemAuthority (for signing)
# which requires Identity.Registry — too many dependencies. Instead we start
# just CapabilityStore and insert an unsigned capability directly.
# capability_signing_required: false in test.exs allows unsigned caps.
if Code.ensure_loaded?(Arbor.Security.CapabilityStore) and
     Code.ensure_loaded?(Arbor.Contracts.Security.Capability) do
  # Start CapabilityStore if not already running
  case Arbor.Security.CapabilityStore.start_link([]) do
    {:ok, _} -> :ok
    {:error, {:already_started, _}} -> :ok
    _ -> :ok
  end

  # Create an unsigned wildcard capability for agent_system
  {:ok, cap} =
    Arbor.Contracts.Security.Capability.new(
      resource_uri: "arbor://orchestrator/execute/**",
      principal_id: "agent_system",
      delegation_depth: 0,
      constraints: %{},
      metadata: %{test: true}
    )

  # Insert directly (unsigned — accepted because capability_signing_required: false)
  Arbor.Security.CapabilityStore.put(cap)

  # Grant orchestrator execute for all test agent IDs used across the suite.
  # Session gate check (authorize/3) requires this capability for send_message
  # and heartbeat operations.
  test_agents = [
    "agent_test123",
    "agent_gs_test",
    "agent_int_test",
    "agent_sup_test",
    "agent_001",
    "agent_abc123",
    "agent_abc",
    "agent_untrusted",
    "agent_42",
    "agent_test",
    "agent_id",
    "agent_loop"
  ]

  for test_agent <- test_agents do
    {:ok, agent_cap} =
      Arbor.Contracts.Security.Capability.new(
        resource_uri: "arbor://orchestrator/execute",
        principal_id: test_agent,
        delegation_depth: 0,
        constraints: %{},
        metadata: %{test: true}
      )

    Arbor.Security.CapabilityStore.put(agent_cap)
  end
end

# Test helper for granting orchestrator access to dynamically generated agent IDs.
# Tests with dynamic agent IDs should call this in their setup block.
defmodule Arbor.Orchestrator.TestCapabilities do
  @moduledoc false

  @doc """
  Grant arbor://orchestrator/execute capability to a test agent.
  Call in test setup for dynamically generated agent IDs.
  """
  def grant_orchestrator_access(agent_id) when is_binary(agent_id) do
    if Code.ensure_loaded?(Arbor.Security.CapabilityStore) and
         Code.ensure_loaded?(Arbor.Contracts.Security.Capability) do
      {:ok, cap} =
        Arbor.Contracts.Security.Capability.new(
          resource_uri: "arbor://orchestrator/execute",
          principal_id: agent_id,
          delegation_depth: 0,
          constraints: %{},
          metadata: %{test: true}
        )

      Arbor.Security.CapabilityStore.put(cap)
      :ok
    else
      :ok
    end
  end
end
