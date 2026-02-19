ExUnit.start(exclude: [:live_local])

# Grant "agent_system" the wildcard capability for orchestrator execution.
# This is the default principal used by CapabilityCheck middleware when no
# agent_id is set in token assigns. Without this grant, mandatory middleware
# blocks all handler execution in tests.
if Code.ensure_loaded?(Arbor.Security) and
     function_exported?(Arbor.Security, :grant, 1) do
  try do
    Arbor.Security.grant(
      principal: "agent_system",
      resource: "arbor://orchestrator/execute/**",
      action: :execute
    )
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
