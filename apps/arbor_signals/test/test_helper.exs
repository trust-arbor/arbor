# Ensure the arbor_signals application is started
Application.ensure_all_started(:arbor_signals)

# Use MockCrypto since Arbor.Security.Crypto is not available
# (arbor_signals and arbor_security are at the same hierarchy level)
Application.put_env(:arbor_signals, :crypto_module, Arbor.Signals.Test.MockCrypto)

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
    {:ok, _pid} -> :ok
    {:error, {:already_started, _pid}} -> :ok
    {:error, :already_present} ->
      # Child spec exists but process died — delete and re-add
      {mod, _} = child
      Supervisor.delete_child(Arbor.Signals.Supervisor, mod)
      Supervisor.start_child(Arbor.Signals.Supervisor, child)
    {:error, reason} ->
      IO.puts("[arbor_signals test_helper] Failed to start #{inspect(elem(child, 0))}: #{inspect(reason)}")
  end
end

ExUnit.start(exclude: [:llm, :llm_local, :distributed])
