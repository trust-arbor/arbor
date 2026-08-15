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

# Start required Monitor processes for tests since start_children: false prevents
# Application startup from adding them to the (empty) Monitor supervisor.
{:ok, _} = Arbor.Monitor.MetricsStore.start_link([])
{:ok, _} = Arbor.Monitor.Poller.start_link([])

ExUnit.start(exclude: [:llm, :llm_local, :distributed])
