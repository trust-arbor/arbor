# Add children to the empty app supervisors (start_children: false leaves them empty)
# arbor_actions tests need shell, persistence, and signal processes

for app <- [:arbor_persistence, :arbor_shell, :arbor_signals, :arbor_security] do
  {:ok, _started} = Application.ensure_all_started(app)
end

# Memory stores + the durable knowledge-graph authority.
#
# arbor_actions has five memory-backed action test modules that call
# Arbor.Memory.init_for_agent/1. Since the durable graph authority landed
# (2026-08-05, e4509485c / 030f398af) that call admits authority before starting
# an index, and KnowledgeGraphStore fails closed without it — correctly. The
# follow-up test commit updated arbor_memory's own 23 test files and swept no
# other app, so all of these started failing {:error, :store_unavailable}: 103
# failures in this suite, all @moduletag :fast and therefore NOT excluded by the
# gating CI lane.
#
# Starting the processes alone is not sufficient. They all come up and
# get_graph/1 still fails, because what matters is the BufferedStore's BACKEND
# config. The arbor_memory test fixture's shape (backend: QueryableStore.ETS +
# collection + ack_mode) does not work here; production's shape does. That
# fixture also asserts exclusive ownership to force async: false, which its
# graph tests need for isolation and consumer apps do not — consumers just need
# an authority to exist, which is why this lives in test_helper.
#
# arbor_agent, arbor_gateway, and arbor_orchestrator have the same break and
# still need the same treatment; see
# .arbor/roadmap/0-inbox/durable-graph-authority-broke-cross-app-memory-tests.md
{:ok, _} = Application.ensure_all_started(:arbor_memory)

for table <- [
      :arbor_memory_graphs,
      :arbor_working_memory,
      :arbor_memory_proposals,
      :arbor_preferences
    ] do
  if :ets.whereis(table) == :undefined, do: :ets.new(table, [:named_table, :public, :set])
end

{:ok, _} =
  Arbor.Persistence.BufferedStore.start_link(
    name: :arbor_memory_durable,
    backend: Application.get_env(:arbor_memory, :persistence_backend),
    write_mode: :sync
  )

for child <- [
      {Registry, keys: :unique, name: Arbor.Memory.Registry},
      {Arbor.Memory.ArchiveCursorSigner, []},
      {Arbor.Memory.Provenance, []},
      {Arbor.Memory.KnowledgeGraphStore, []},
      {Arbor.Memory.IndexSupervisor, []},
      {Arbor.Memory.GoalStore, []},
      {Arbor.Memory.IntentStore, []},
      {Arbor.Memory.Thinking, []},
      {Arbor.Memory.CodeStore, []}
    ] do
  Supervisor.start_child(Arbor.Memory.Supervisor, child)
end

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

# Security system — needed for signing integration tests
buffered_store = Arbor.Persistence.BufferedStore

security_backend =
  Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

for {name, collection} <- [
      {:arbor_security_capabilities, "capabilities"},
      {:arbor_security_identities, "identities"},
      {:arbor_security_signing_keys, "signing_keys"}
    ] do
  child =
    Supervisor.child_spec(
      {buffered_store,
       name: name, backend: security_backend, write_mode: :sync, collection: collection},
      id: name
    )

  case Supervisor.start_child(Arbor.Security.Supervisor, child) do
    {:ok, _} -> :ok
    {:error, {:already_started, _}} -> :ok
    {:error, reason} -> IO.warn("Failed to start #{name}: #{inspect(reason)}")
  end
end

for child <- [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.Constraint.RateLimiter, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ] do
  case Supervisor.start_child(Arbor.Security.Supervisor, child) do
    {:ok, _} -> :ok
    {:error, {:already_started, _}} -> :ok
    {:error, reason} -> IO.warn("Failed to start #{inspect(child)}: #{inspect(reason)}")
  end
end

ExUnit.start(exclude: [:llm, :llm_local])
