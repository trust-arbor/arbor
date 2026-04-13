# Add children to the empty app supervisor (start_children: false leaves it empty)
for child <- [
      {Arbor.Persistence.Checkpoint.Store.ETS, []},
      {Arbor.Persistence.QueryableStore.ETS, name: :jobs},
      {Arbor.Persistence.EventLog.ETS, name: :event_log}
    ] do
  Supervisor.start_child(Arbor.Persistence.Supervisor, child)
end

# Start the Ecto Repo when Postgres is configured.
# This is needed because start_children: false prevents automatic startup.
# The Repo must be running for any :database tagged tests across the umbrella.
#
# We use {:shared, self()} mode so ALL processes (including BufferedStore
# backends that aren't part of test setup) can access the database. With
# :manual mode, non-test processes that hit Postgres via BufferedStore
# get OwnershipError because they never called Sandbox.checkout.
if System.get_env("ARBOR_DB") == "postgres" do
  case Supervisor.start_child(Arbor.Persistence.Supervisor, Arbor.Persistence.Repo) do
    {:ok, _} -> Ecto.Adapters.SQL.Sandbox.mode(Arbor.Persistence.Repo, {:shared, self()})
    {:error, {:already_started, _}} -> :ok
    {:error, reason} -> IO.puts("[test_helper] Repo start failed: #{inspect(reason)}")
  end
end

# Exclude database tests by default (require PostgreSQL setup)
# Run with: mix test --include database
ExUnit.start(exclude: [:database, :llm, :llm_local])
