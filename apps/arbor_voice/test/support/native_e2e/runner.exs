# Fresh isolated VM only. First operation seals every native audio/permission
# module; this also loads the real Multimedia/Core/plugin regression suite.
root = Path.expand("../../../../..", __DIR__)
Code.require_file(Path.join(root, "apps/arbor_multimedia/test/native/sealed_runner.exs"))
Code.prepend_paths(Path.wildcard(Path.join([to_string(:code.root_dir()), "lib", "*", "ebin"])))
{:ok, _} = Application.ensure_all_started(:arbor_security)
Code.require_file(Path.join(root, "apps/arbor_security/test/test_helper.exs"))
Application.ensure_all_started(:telemetry)
{:ok, _} = Arbor.Voice.Application.start(:normal, [])
ExUnit.configure(autorun: false, assert_receive_timeout: 2_000)
Code.require_file("desk_checks.exs", __DIR__)
result = ExUnit.run()
System.halt(if result.failures == 0, do: 0, else: 1)
