# Tests that touch arbor_security primitives (Identity.Registry, IssuerRegistry,
# BufferedStore) need those children running: the umbrella test config sets
# `:arbor_security, start_children: false`, so each app's test_helper opts in.
#
# Use the canonical bootstrap rather than hand-rolling the tree. The previous
# hand-rolled block started the four stores with a durable JSONFile backend and
# then ignored every `Supervisor.start_child/2` result, so when the stores failed
# to resolve their authority root the failure was silent — `Identity.Registry`
# never started and 82 tests died with "no process" pointing at the registry
# rather than at the store that actually failed. `TestBootstrap` freezes the
# canonical authority root (so the root does not depend on the caller's cwd),
# starts a strict superset of what this file used to, and raises instead of
# warning. See its moduledoc for why it lives in lib/.
:ok = Arbor.Security.TestBootstrap.start!()

# The Store and Manager belong under Arbor.Trust.Supervisor. Starting them
# directly under ApplicationSupervisor leaves registered processes with the
# wrong owner for later umbrella apps and their canonical Trust fixture.
:ok = Arbor.Trust.restore_runtime_fixture()

scheduler_mutation_token = make_ref()

Application.put_env(
  :arbor_scheduler,
  :test_scheduler_mutation_token,
  scheduler_mutation_token
)

case Supervisor.start_child(
       Arbor.Scheduler.Supervisor,
       {Arbor.Scheduler.RunLeaseSupervisor, scheduler_mutation_token: scheduler_mutation_token}
     ) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
  {:error, reason} -> IO.warn("Failed to start run lease supervisor: #{inspect(reason)}")
end

ExUnit.start(exclude: [:isolated_repo])
