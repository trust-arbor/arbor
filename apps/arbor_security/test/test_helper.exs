Code.require_file("../../../packages/arbor_capabilities/test/test_helper.exs", __DIR__)

Arbor.Signals.Config.Testing.put(:security_module, Arbor.Capabilities.Signals)
Arbor.Signals.Config.Testing.put(:crypto_module, Arbor.Capabilities.Signals)
Arbor.Signals.Config.Testing.put(:identity_registry_module, Arbor.Capabilities.Signals)
