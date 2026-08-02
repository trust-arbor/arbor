defmodule Arbor.Voice.RealtimeBackendTest do
  # async: false — this module mutates global Application env
  # (:arbor_voice, :backend) in a test below. ExUnit's async only
  # parallelizes across modules, not within one, so this mutation is safe
  # against itself either way — but opting this module out of async keeps
  # it safe against any future module that reads/writes the same key
  # concurrently, without relying on that never happening.
  use ExUnit.Case, async: false

  alias Arbor.Voice.Test.FakeBackend

  @moduletag :fast

  # Partial VOICE-5 proof: a backend implementing every
  # Arbor.Voice.RealtimeBackend callback compiles and exports each callback
  # with no warnings, and Config.backend_module/0 returns the configured
  # module rather than a hardcoded one. The remaining half of VOICE-5
  # ("Session never references a concrete backend except through
  # configuration") is proven in VP-04 once Arbor.Voice.Session exists; the
  # statement stays `(planned)` in VOICE-1.0.md until then.
  @tag spec: "VOICE-5"
  test "a conforming backend implements every RealtimeBackend callback" do
    Code.ensure_loaded!(FakeBackend)

    for {fun, arity} <- Arbor.Voice.RealtimeBackend.behaviour_info(:callbacks) do
      assert function_exported?(FakeBackend, fun, arity),
             "FakeBackend does not export #{fun}/#{arity}"
    end
  end

  @tag spec: "VOICE-5"
  test "Config.backend_module/0 returns the configured module" do
    # fetch_env/2, not get_env/2: preserves absent-vs-explicit-nil so
    # restore below can't collapse an explicit `nil` config into deletion.
    previous = Application.fetch_env(:arbor_voice, :backend)
    Application.put_env(:arbor_voice, :backend, FakeBackend)

    on_exit(fn -> restore_backend_env(previous) end)

    assert Arbor.Voice.Config.backend_module() == FakeBackend
  end

  test "Config.backend_module/0 defaults to the xAI Realtime backend name" do
    previous = Application.fetch_env(:arbor_voice, :backend)
    Application.delete_env(:arbor_voice, :backend)

    on_exit(fn -> restore_backend_env(previous) end)

    assert Arbor.Voice.Config.backend_module() == Arbor.Voice.Backend.XaiRealtime
  end

  defp restore_backend_env({:ok, value}),
    do: Application.put_env(:arbor_voice, :backend, value)

  defp restore_backend_env(:error), do: Application.delete_env(:arbor_voice, :backend)
end
