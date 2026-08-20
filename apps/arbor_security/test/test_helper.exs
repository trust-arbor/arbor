# Add children to the empty app supervisor (start_children: false leaves it empty)
Code.require_file("support/oidc_test_helper.ex", __DIR__)
Code.require_file("support/loopback_http_server.ex", __DIR__)

# K1F: Signals authorization/crypto/identity ports default to nil. Security
# tests inject the public facade so restricted-topic emit/decrypt and
# CapabilityAuthorizer keep the production provider shape.
Arbor.Signals.Config.Testing.put(:security_module, Arbor.Security)
Arbor.Signals.Config.Testing.put(:crypto_module, Arbor.Security)
Arbor.Signals.Config.Testing.put(:identity_registry_module, Arbor.Security)

# Populate the empty app supervisor (start_children: false) with the canonical
# Security-owned test tree. TestBootstrap proves supervisor ownership of each
# registered name rather than treating name occupancy as success.
:ok = Arbor.Security.TestBootstrap.start!()

ExUnit.start(exclude: [:llm, :llm_local])
