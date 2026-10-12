# Security stores + capability authority. Test config intentionally leaves the
# security supervisor empty, so consumer suites must opt into the shared
# bootstrap before any behavioral fixture grants capabilities.
:ok = Arbor.Security.TestBootstrap.start!()
:ok = Arbor.Historian.TestAuditRuntime.start_default_lane!()

# Lease grants use the same preprovisioned service principal in tests and
# production. The supervised owner never creates or grants its own identity.
{:ok, lease_grant_identity} = Arbor.Security.generate_identity()
:ok = Arbor.Security.register_identity_fixture(lease_grant_identity)

:ok =
  Arbor.Security.store_signing_key_fixture(
    lease_grant_identity.agent_id,
    lease_grant_identity.private_key
  )

for resource <- ["arbor://security/grant/**", "arbor://security/revoke/**"] do
  {:ok, _} =
    Arbor.Security.grant_fixture(principal: lease_grant_identity.agent_id, resource: resource)
end

Application.put_env(:arbor_agent, :lease_grant_principal_id, lease_grant_identity.agent_id)

{:ok, cleanup_identity} = Arbor.Security.generate_identity()
:ok = Arbor.Security.register_identity_fixture(cleanup_identity)

:ok =
  Arbor.Security.store_signing_key_fixture(
    cleanup_identity.agent_id,
    cleanup_identity.private_key
  )

for resource <- ["arbor://security/identity/suspend/**", "arbor://security/revoke/**"] do
  {:ok, _} =
    Arbor.Security.grant_fixture(principal: cleanup_identity.agent_id, resource: resource)
end

Application.put_env(:arbor_agent, :activation_failure_principal_id, cleanup_identity.agent_id)

# Add children to the empty app supervisor (start_children: false leaves it empty)
children = [
  {Registry, keys: :unique, name: Arbor.Agent.ExecutorRegistry},
  {Registry, keys: :unique, name: Arbor.Agent.ReasoningLoopRegistry},
  Arbor.Agent.ProfileAuthorityOwner,
  Arbor.Agent.Orchestration.LeaseGrantOwner,
  Arbor.Agent.Registry,
  Arbor.Agent.SessionManager,
  Arbor.Agent.Supervisor
]

for child <- children do
  Supervisor.start_child(Arbor.Agent.AppSupervisor, child)
end

# Memory stores + durable knowledge-graph authority.
#
# Replaces a hand-rolled MemoryGoalsTableOwner that existed only to create the
# :arbor_memory_goals ETS table, on the since-outdated premise that
# "arbor_memory is a sibling app, not a dep of arbor_agent" — it IS a dep.
# GoalStore creates that table in its own init/1, so starting the real store is
# both simpler and closer to production. See Arbor.Memory.TestBootstrap.
Arbor.Memory.TestBootstrap.start!()

if :ets.whereis(:arbor_memory_goals) == :undefined do
  raise "test_helper: :arbor_memory_goals missing after TestBootstrap (GoalStore did not start)"
end

# One shared ExecutablePolicy for the run, as the actions, orchestrator, commands
# and shell suites do. Its init SHA-256-pins every executable in the trusted
# PATH directories (about 4 s idle for ~1300 files), so starting one per test
# (IntentDispatcher suites, 25+ tests) cost minutes and, under full-suite load,
# timed a setup out at 60 s. Per-test setups keep their `unless whereis` guard.
if Process.whereis(Arbor.Shell.ExecutablePolicy) == nil and
     Process.whereis(Arbor.Shell.Supervisor) != nil do
  Supervisor.start_child(
    Arbor.Shell.Supervisor,
    {Arbor.Shell.ExecutablePolicy, startup_path: System.get_env("PATH", "")}
  )
end

# Fixed production-name runtime-admission topology so public Lifecycle.start/2
# callers (Manager, Bootstrap, Reconciler) resolve a ready TaskStore without
# polling a missing store for the ordinary-start readiness deadline.
_ = Arbor.Agent.Test.RuntimeAdmissionTopology.start_fixed_production!()

# :integration/:slow run by default (hermetic — gating CI runs plain `mix test`);
# Isolated Repo fixtures own the canonical Repo name and run separately with
# --include isolated_repo. Fast loop: `mix test.fast`.
ExUnit.start(exclude: [:skip, :database, :isolated_repo, :external, :llm, :llm_local])
