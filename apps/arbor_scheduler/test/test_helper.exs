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

for child <- [
      {Arbor.Trust.Store, [persistence: :memory]},
      {Arbor.Trust.Manager,
       [circuit_breaker: false, decay: false, event_store: false, persistence: :memory]}
    ] do
  case Supervisor.start_child(Arbor.Trust.ApplicationSupervisor, child) do
    {:ok, _} -> :ok
    {:error, {:already_started, _}} -> :ok
    {:error, reason} -> IO.warn("Failed to start trust test child: #{inspect(reason)}")
  end
end

case Supervisor.start_child(
       Arbor.Scheduler.Supervisor,
       Arbor.Scheduler.RunLeaseSupervisor
     ) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
  {:error, reason} -> IO.warn("Failed to start run lease supervisor: #{inspect(reason)}")
end

ExUnit.start()
