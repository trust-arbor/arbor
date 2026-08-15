# :integration_lm_studio tests require a running LM Studio with a model loaded
# (they make real LLM calls); excluded by default like :llm/:llm_local. Run them
# explicitly with `--include integration_lm_studio` when LM Studio is up.
#
# :distributed tests require LocalCluster / multi-BEAM setup. Run them
# explicitly with `--include distributed`.
# Memory stores + durable knowledge-graph authority — cross_session_memory_test
# calls Arbor.Memory.init_for_agent/1, which fails closed without the authority.
Arbor.Memory.TestBootstrap.start!()
:ok = Arbor.Security.TestBootstrap.start!()

ExUnit.start(exclude: [:llm, :llm_local, :integration_lm_studio, :distributed])

if Process.whereis(Arbor.Shell.ExecutablePolicy) == nil and
     Process.whereis(Arbor.Shell.Supervisor) != nil do
  Supervisor.start_child(
    Arbor.Shell.Supervisor,
    {Arbor.Shell.ExecutablePolicy, startup_path: System.get_env("PATH", "")}
  )
end

# Arbor.Actions.Git shells out through Arbor.Shell.execute_direct/3, which
# requires ExecutionRegistry (start_children: false leaves the app childless
# in test). Coding-plan dependency-baseline readiness observes real git blobs
# in-process, so the registry must be present the same way arbor_actions'
# test_helper.exs starts it.
if Process.whereis(Arbor.Shell.ExecutionRegistry) == nil and
     Process.whereis(Arbor.Shell.Supervisor) != nil do
  Supervisor.start_child(Arbor.Shell.Supervisor, {Arbor.Shell.ExecutionRegistry, []})
end

# Insert a wildcard capability for "agent_system".
# This is the default principal used by CapabilityCheck middleware when no
# agent_id is set in token assigns. Without this grant, mandatory middleware
# blocks all handler execution in tests.
#
# Security.TestBootstrap owns the required store/process startup order. We
# bypass Security.grant/1 only to insert an unsigned test capability directly.
# capability_signing_required: false in test.exs allows unsigned caps.
if Code.ensure_loaded?(Arbor.Security.CapabilityStore) and
     Code.ensure_loaded?(Arbor.Contracts.Security.Capability) do
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
        resource_uri: "arbor://orchestrator/execute/**",
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
          resource_uri: "arbor://orchestrator/execute/**",
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

  @doc false
  def grant_shell_access(agent_id, command_name)
      when is_binary(agent_id) and is_binary(command_name) do
    grant_capability(agent_id, "arbor://shell/exec/#{command_name}")
  end

  @doc false
  def grant_capability(agent_id, resource_uri)
      when is_binary(agent_id) and is_binary(resource_uri) do
    {:ok, cap} =
      Arbor.Contracts.Security.Capability.new(
        resource_uri: resource_uri,
        principal_id: agent_id,
        delegation_depth: 0,
        constraints: %{},
        metadata: %{test: true}
      )

    {:ok, :stored} = Arbor.Security.CapabilityStore.put(cap)
    :ok
  end

  @doc """
  Revoke every capability currently listed for `agent_id`.

  Use in `on_exit` after `grant_orchestrator_access/1` so generated fixtures
  do not leak across the suite.
  """
  def revoke_all(agent_id) when is_binary(agent_id) do
    if Code.ensure_loaded?(Arbor.Security.CapabilityStore) and
         function_exported?(Arbor.Security.CapabilityStore, :revoke_all, 1) do
      _ = Arbor.Security.CapabilityStore.revoke_all(agent_id)
      :ok
    else
      :ok
    end
  end
end
