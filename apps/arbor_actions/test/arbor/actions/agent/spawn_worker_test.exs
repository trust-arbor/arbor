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
    def search("browser wait", _opts), do: [match("arbor://action/browser/wait")]

    def search("browser wait for navigation", _opts),
      do: [match("arbor://action/browser/wait_for_navigation")]

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

    def effective_mode(_agent_id, "arbor://fs/read"), do: :allow
    def effective_mode(_agent_id, "arbor://shell/exec"), do: :block
    def effective_mode(_agent_id, _uri), do: :block
  end

  # Parent with NO trust profile (the edge case behind the fail-open).
  defmodule StubTrustMissing do
    def get_trust_profile(_agent_id), do: {:error, :not_found}
  end

  # Parent that allows only the exact browser wait URI (sibling wait_for_navigation blocked).
  defmodule StubTrustBrowserWaitOnly do
    def get_trust_profile(_agent_id) do
      {:ok,
       %{
         rules: %{"arbor://action/browser/wait" => :allow},
         baseline: :block
       }}
    end

    def effective_mode(_agent_id, "arbor://action/browser/wait"), do: :allow
    def effective_mode(_agent_id, _uri), do: :block
  end

  # Parent profile present but effective_mode returns a non-closed value.
  defmodule StubTrustInvalidMode do
    def get_trust_profile(_agent_id) do
      {:ok, %{rules: %{}, baseline: :allow}}
    end

    def effective_mode(_agent_id, _uri), do: :not_a_real_mode
  end

  # Parent profile present but effective_mode raises (must not bulk fail-open).
  defmodule StubTrustRaises do
    def get_trust_profile(_agent_id) do
      {:ok, %{rules: %{}, baseline: :allow}}
    end

    def effective_mode(_agent_id, _uri), do: raise("effective_mode boom")
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

  describe "security regression: segment-aware capability URI intersection" do
    test "exact browser wait is allowed; sibling wait_for_navigation is denied" do
      Application.put_env(:arbor_actions, :spawn_worker_trust_mod, StubTrustBrowserWaitOnly)

      assert {:ok, rules} =
               SpawnWorker.resolve_and_intersect("parent-agent", ["browser wait"])

      assert Map.has_key?(rules, "arbor://action/browser/wait")

      # Sibling URI shares a textual prefix but is a different segment; raw
      # String.starts_with?/2 would incorrectly admit it under a wait-only rule.
      assert {:error, {:no_capabilities_allowed, ["arbor://action/browser/wait_for_navigation"]}} =
               SpawnWorker.resolve_and_intersect("parent-agent", ["browser wait for navigation"])
    end

    test "invalid effective_mode returns fail closed to :block" do
      Application.put_env(:arbor_actions, :spawn_worker_trust_mod, StubTrustInvalidMode)

      assert {:error, {:no_capabilities_allowed, _}} =
               SpawnWorker.resolve_and_intersect("parent-agent", ["file read"])
    end

    test "effective_mode exception fails closed even when spawn_worker_fail_open=true" do
      Application.put_env(:arbor_actions, :spawn_worker_trust_mod, StubTrustRaises)
      Application.put_env(:arbor_actions, :spawn_worker_fail_open, true)

      # Profile is present; a per-URI exception must NOT reach the outer unbounded
      # fail-open path that would grant bulk :auto capabilities.
      assert {:error, {:no_capabilities_allowed, _}} =
               SpawnWorker.resolve_and_intersect("parent-agent", ["file read", "shell execute"])
    end
  end

  describe "security regression: segment-aware tool exposure coverage" do
    test "scoped wait URI does not cover sibling wait_for_navigation tool URI" do
      # Raw String.starts_with?(".../wait_for_navigation", ".../wait") is true;
      # segment-aware prefix_match?/2 must keep siblings out of tool exposure.
      refute SpawnWorker.tool_uri_covered_by_scoped?(
               "arbor://action/browser/wait_for_navigation",
               "arbor://action/browser/wait"
             )

      assert SpawnWorker.tool_uri_covered_by_scoped?(
               "arbor://action/browser/wait",
               "arbor://action/browser/wait"
             )

      # Legitimate descendant under a real path segment remains covered.
      assert SpawnWorker.tool_uri_covered_by_scoped?(
               "arbor://fs/read/project/file.ex",
               "arbor://fs/read"
             )
    end
  end
end
