ExUnit.start(exclude: [:distributed])

# Test collaborators are explicit; production starts with absent providers.
Arbor.Signals.Config.Testing.put(:crypto_module, Arbor.Signals.Test.MockCrypto)
Arbor.Signals.Config.Testing.put(:auth_context_module, Arbor.Signals.Adapters.AuthContext)
Arbor.Signals.Config.Testing.put(:taint_module, Arbor.Signals.Contracts.Taint)
Arbor.Signals.Config.Testing.put(:taint_envelope_module, Arbor.Signals.Contracts.TaintEnvelope)
Arbor.Signals.Config.Testing.put(:supervision_root, {:application, :arbor_signals})
Arbor.Signals.Config.Testing.put(:supervision_path, [])

{:ok, _apps} = Application.ensure_all_started(:arbor_signals)
:ok = Arbor.Signals.restore_runtime_fixture()
