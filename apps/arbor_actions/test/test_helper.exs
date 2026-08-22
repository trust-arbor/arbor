# Add children to the empty app supervisors (start_children: false leaves them empty)
# arbor_actions tests need shell, persistence, and signal processes

for app <- [:arbor_persistence, :arbor_shell, :arbor_kernel_runtime, :arbor_security] do
  {:ok, _started} = Application.ensure_all_started(app)
end

# Memory stores + durable knowledge-graph authority. Five memory-backed action
# test modules call Arbor.Memory.init_for_agent/1, which fails closed without
# the authority. See Arbor.Memory.TestBootstrap for why this is not inline.
:ok = Arbor.Memory.TestBootstrap.start!()

# Test-only Linux baseline materializer Agent + shared WorkspaceLeaseRegistry
# rewire. Production Application starts the registry with Arbor.Shell; tests
# replace that child with the same module, configured only via start opts.
_ = Arbor.Actions.TestLinuxBaselineMaterializer.start_link()

case Supervisor.terminate_child(
       Arbor.Actions.Supervisor,
       Arbor.Actions.Coding.WorkspaceLeaseRegistry
     ) do
  :ok ->
    _ =
      Supervisor.delete_child(
        Arbor.Actions.Supervisor,
        Arbor.Actions.Coding.WorkspaceLeaseRegistry
      )

    {:ok, _} =
      Supervisor.start_child(
        Arbor.Actions.Supervisor,
        {Arbor.Actions.Coding.WorkspaceLeaseRegistry,
         [
           linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer,
           # Never hydrate the application-owned registry from a durable journal
           # under tests (production store is disabled in config/test.exs).
           retention_journal: :disabled
         ]}
      )

  {:error, :not_found} ->
    {:ok, _} =
      Supervisor.start_child(
        Arbor.Actions.Supervisor,
        {Arbor.Actions.Coding.WorkspaceLeaseRegistry,
         [
           linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer,
           retention_journal: :disabled
         ]}
      )

  other ->
    IO.warn("Failed to rewire WorkspaceLeaseRegistry for tests: #{inspect(other)}")
end

Supervisor.start_child(
  Arbor.Shell.Supervisor,
  {Arbor.Shell.ExecutablePolicy, startup_path: System.get_env("PATH", "")}
)

Supervisor.start_child(Arbor.Shell.Supervisor, {Arbor.Shell.ExecutionRegistry, []})

# OwnedTreeRegistry backs Arbor.Shell.create_private_owned_tree/1, which every
# validation resource creation goes through — and Actions Mix/Shell require a
# validation resource before a unit exists. Introduced 2026-08-16 (4d506b378)
# without being added here, so `start_children: false` left it absent and every
# create_private_owned_tree/1 returned :owned_tree_registry_unavailable. That
# cascaded into ~84 failures across the Mix, Shell and Coding suites.
Supervisor.start_child(Arbor.Shell.Supervisor, {Arbor.Shell.OwnedTreeRegistry, []})

Supervisor.start_child(
  Arbor.Shell.Supervisor,
  {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
)

for child <- [
      {Arbor.Persistence.QueryableStore.ETS, name: :jobs},
      {Arbor.Persistence.EventLog.ETS, name: :event_log}
    ] do
  Supervisor.start_child(Arbor.Persistence.Supervisor, child)
end

# Signal system — emit functions need Store + Bus running
for child <- [
      {Arbor.Signals.Store, []},
      {Arbor.Signals.Bus, []}
    ] do
  Supervisor.start_child(Arbor.Signals.Supervisor, child)
end

# Security system — needed for signing integration tests.
#
# Use the Security-owned canonical test tree rather than hand-starting the
# children here. The hand-rolled version started `Arbor.Persistence.BufferedStore`
# under the `:arbor_security_*` names, but `Identity.Registry` hydrates via
# `AuthorityStore.take_hydrated_entries/1`, and BufferedStore has no handler for
# that call — so the store crashed, Registry failed with
# `{:identity_authority, :inventory_unavailable}`, SystemAuthority then died with
# :noproc calling Registry, and CapabilityStore could not restore. That chain
# failed ~300 tests in this suite.
#
# TestBootstrap starts AuthorityStore under those names and proves supervisor
# ownership of each registered name instead of treating name occupancy as
# success. It is in arbor_security's lib/, so it is reusable from here.
:ok = Arbor.Security.TestBootstrap.start!()

ExUnit.start(exclude: [:llm, :llm_local])
