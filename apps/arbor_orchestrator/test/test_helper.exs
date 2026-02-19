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

  # Create an unsigned wildcard capability
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
end
