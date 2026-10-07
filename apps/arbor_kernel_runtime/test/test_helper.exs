# Ensure the arbor_kernel_runtime application is started
Application.ensure_all_started(:arbor_kernel_runtime)

# Use a test-local crypto fake. arbor_signals is L1 and must not depend on
# arbor_security (L2); the production provider is injected only outside test.
Arbor.Signals.Config.Testing.put(:crypto_module, Arbor.Signals.Test.MockCrypto)

# Add children to the supervisor (start_children: false leaves it empty in test config)
children = [
  {Arbor.Signals.Store, []},
  {Arbor.Signals.TopicKeys, []},
  {Arbor.Signals.Channels, []},
  {Arbor.Signals.SubscriptionRegistry, []},
  {Arbor.Signals.TelemetryBridge, []},
  {Arbor.Signals.Bus, []},
  {Arbor.Signals.Relay, []}
]

for child <- children do
  case Supervisor.start_child(Arbor.Signals.Supervisor, child) do
    {:ok, _pid} ->
      :ok

    {:error, {:already_started, _pid}} ->
      :ok

    {:error, :already_present} ->
      # Child spec exists but process died — delete and re-add
      {mod, _} = child
      Supervisor.delete_child(Arbor.Signals.Supervisor, mod)
      Supervisor.start_child(Arbor.Signals.Supervisor, child)

    {:error, reason} ->
      IO.puts(
        "[arbor_kernel_runtime test_helper] Failed to start #{inspect(elem(child, 0))}: #{inspect(reason)}"
      )
  end
end

# Start required Monitor processes under their real owner. Starting them with
# start_link/1 here leaves them attached to the transient test bootstrap process;
# runtime lifecycle tests can then stop them without Monitor.Supervisor restoring
# their ETS tables, cascading into unrelated monitor tests.
monitor_children = [
  {Arbor.Monitor.MetricsStore, []},
  {Arbor.Monitor.Poller, []}
]

for child <- monitor_children do
  case Supervisor.start_child(Arbor.Monitor.Supervisor, child) do
    {:ok, _pid} ->
      :ok

    {:error, {:already_started, _pid}} ->
      :ok

    {:error, :already_present} ->
      {mod, _opts} = child
      :ok = Supervisor.delete_child(Arbor.Monitor.Supervisor, mod)
      {:ok, _pid} = Supervisor.start_child(Arbor.Monitor.Supervisor, child)
  end
end

ExUnit.start(exclude: [:llm, :llm_local, :distributed])
