# Distributed peer tests need the VM booted with one pinned cookie and a
# private EPMD. `mix test` cannot add -setcookie after startup. CI and
# packages/arbor_capabilities/bin/test export that contract before the VM.
ExUnit.start(exclude: [:llm, :llm_local])

for file <-
      ~w(oidc_test_helper.ex loopback_http_server.ex recording_event_log_adapter.ex application_spec_peer.ex template_cas_sandbox.ex capability_persistence_backends.ex) do
  Code.require_file("support/" <> file, __DIR__)
end

:ok = Arbor.Security.TestBootstrap.start!()
Arbor.Security.TestSupport.RecordingEventLogAdapter.setup()

Application.put_env(
  :arbor_capabilities,
  :event_log_adapter,
  Arbor.Security.TestSupport.RecordingEventLogAdapter
)
