defmodule Arbor.Actions.Agent.SpawnWorkerTest do
  @moduledoc """
  Behavioral tests for the SECURITY invariant of SpawnWorker: a worker's capabilities are
  the intersection of the parent's permissions and what's requested — "a worker can never
  have more than the parent." SpawnWorker was unwired/uncallable until it was registered in
  Arbor.Actions.list_actions (2026-07-02); these guard the intersection now that agents can
  actually spawn workers with scoped capabilities.

  Deps (trust + resolver) are stubbed via config so the invariant is tested without a live
  trust system or a real worker/LLM. A full end-to-end spawn test (a coordinator spawning a
  worker that runs against a LOCAL model) is a worthwhile integration follow-up.
  """
  use ExUnit.Case, async: false

  alias Arbor.Actions.Agent.SpawnWorker

  # Maps capability intents -> URIs, mimicking CapabilityResolver.search/2 shape.
  defmodule StubResolver do
    def search("file read", _opts), do: [match("arbor://fs/read")]
    def search("shell execute", _opts), do: [match("arbor://shell/exec")]
    def search(_intent, _opts), do: []
    defp match(uri), do: %{descriptor: %{metadata: %{capability_uri: uri}}}
  end

  # Parent whose profile ALLOWS fs/read but BLOCKS shell/exec.
  defmodule StubTrustScoped do
    def get_trust_profile(_agent_id) do
      {:ok,
       %{
         rules: %{"arbor://fs/read" => :allow, "arbor://shell/exec" => :block},
         baseline: :block
       }}
    end
  end

  # Parent with NO trust profile (the edge case behind the fail-open).
  defmodule StubTrustMissing do
    def get_trust_profile(_agent_id), do: {:error, :not_found}
  end

  setup do
    Application.put_env(:arbor_actions, :spawn_worker_resolver_mod, StubResolver)

    on_exit(fn ->
      Application.delete_env(:arbor_actions, :spawn_worker_resolver_mod)
      Application.delete_env(:arbor_actions, :spawn_worker_trust_mod)
      Application.delete_env(:arbor_actions, :spawn_worker_fail_open)
    end)

    :ok
  end

  describe "capability intersection (the security invariant)" do
    test "a capability the PARENT blocks is excluded from the worker — worker <= parent" do
      Application.put_env(:arbor_actions, :spawn_worker_trust_mod, StubTrustScoped)

      # The worker requests BOTH a permitted (file read) and a parent-blocked (shell) cap.
      assert {:ok, rules} =
               SpawnWorker.resolve_and_intersect("parent-agent", ["file read", "shell execute"])

      # It gets the permitted one...
      assert Map.has_key?(rules, "arbor://fs/read")
      # ...and CANNOT get the parent-blocked one. This is the invariant: a compromised or
      # over-eager coordinator cannot grant a worker more than it holds itself.
      refute Map.has_key?(rules, "arbor://shell/exec")
    end

    test "requesting ONLY a parent-blocked capability yields no capabilities (denied)" do
      Application.put_env(:arbor_actions, :spawn_worker_trust_mod, StubTrustScoped)

      assert {:error, {:no_capabilities_allowed, _}} =
               SpawnWorker.resolve_and_intersect("parent-agent", ["shell execute"])
    end
  end

  describe "fail-closed by default when the parent's permissions are unknowable" do
    test "missing parent trust profile is DENIED by default (fail closed)" do
      # The parent has no trust profile → we can't bound the worker by the parent, so we
      # must NOT grant it capabilities. This is the security regression test for the
      # previously fail-OPEN intersection (a worker could exceed the parent).
      Application.put_env(:arbor_actions, :spawn_worker_trust_mod, StubTrustMissing)

      assert {:error, {:no_parent_trust_profile, :not_found}} =
               SpawnWorker.resolve_and_intersect("orphan-agent", ["shell execute"])
    end

    test "operators who accept the risk can opt into fail-OPEN via config" do
      Application.put_env(:arbor_actions, :spawn_worker_trust_mod, StubTrustMissing)
      Application.put_env(:arbor_actions, :spawn_worker_fail_open, true)

      assert {:ok, rules} =
               SpawnWorker.resolve_and_intersect("orphan-agent", ["shell execute"])

      assert Map.has_key?(rules, "arbor://shell/exec")
    end
  end
end
