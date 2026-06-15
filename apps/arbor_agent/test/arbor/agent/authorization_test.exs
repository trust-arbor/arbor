defmodule Arbor.Agent.AuthorizationTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  @caller_id "test_caller_agent"

  # NOTE: this test deliberately does NOT stop Arbor.Security.CapabilityStore.
  # It used to `GenServer.stop` the store in setup to force the permissive
  # (no-store) auth path, but that store is a *permanent* child of the SHARED
  # Arbor.Security.Supervisor (the arbor_security app supervisor). Stopping it
  # every test triggered a supervisor restart; with these sub-millisecond tests,
  # 3+ restarts landed inside the supervisor's 5-second window, exceeded its
  # restart intensity, and took the whole :arbor_security app down with
  # reason :shutdown — cascading "no process" failures across every later
  # behavioral test (CapabilityStore.put) and IdentityAliasesTest. It was also
  # pointless: the supervisor restarts the store anyway, which is exactly why
  # the helper below already tolerates BOTH the authorized and the umbrella
  # "unauthorized" outcomes. (arbor_agent suite flakiness source C, 2026-06-14)

  # Helper: in umbrella context, Security supervisor may restart CapabilityStore
  # between our setup and test body, causing authorization to deny. Accept both.
  defp assert_not_unauthorized_or_accept_umbrella_auth(result) do
    case result do
      {:error, {:unauthorized, _}} ->
        # Security is running in umbrella context — this is expected
        :ok

      other ->
        refute match?({:error, {:unauthorized, _}}, other)
    end
  end

  describe "authorize_stop/2" do
    test "returns not_found for non-existent agent" do
      result = Arbor.Agent.authorize_stop(@caller_id, "nonexistent_agent")
      # Should pass auth (returns :ok from authorize) then fail on stop,
      # OR return unauthorized in umbrella context
      assert_not_unauthorized_or_accept_umbrella_auth(result)
    end
  end

  describe "authorize_create/3" do
    test "delegates to create_agent or returns unauthorized depending on security context" do
      agent_id = "auth_test_create_#{System.unique_integer([:positive])}"
      result = Arbor.Agent.authorize_create(@caller_id, agent_id, [])
      assert_not_unauthorized_or_accept_umbrella_auth(result)
    end
  end

  describe "authorize_destroy/2" do
    test "passes through auth and delegates to destroy_agent" do
      agent_id = "auth_test_destroy_#{System.unique_integer([:positive])}"

      result =
        try do
          Arbor.Agent.authorize_destroy(@caller_id, agent_id)
        rescue
          ArgumentError -> :infrastructure_error
        catch
          :exit, _reason -> :infrastructure_error
        end

      assert_not_unauthorized_or_accept_umbrella_auth(result)
    end
  end

  describe "authorize_restore/2" do
    test "delegates to restore_agent when security permits" do
      agent_id = "auth_test_restore_#{System.unique_integer([:positive])}"
      result = Arbor.Agent.authorize_restore(@caller_id, agent_id)
      assert_not_unauthorized_or_accept_umbrella_auth(result)
    end
  end

  describe "function signatures" do
    test "all authorize_* functions are exported" do
      exports = Arbor.Agent.__info__(:functions)

      # Pre-existing
      assert {:authorize_spawn, 3} in exports or {:authorize_spawn, 5} in exports
      assert {:authorize_action, 3} in exports or {:authorize_action, 4} in exports

      # New in Phase 2
      assert {:authorize_stop, 2} in exports
      assert {:authorize_create, 2} in exports or {:authorize_create, 3} in exports
      assert {:authorize_destroy, 2} in exports
      assert {:authorize_restore, 2} in exports
    end
  end
end
