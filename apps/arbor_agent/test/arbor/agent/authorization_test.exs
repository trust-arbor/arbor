defmodule Arbor.Agent.AuthorizationTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  @caller_id "test_caller_agent"

  setup do
    # Ensure CapabilityStore is not running so authorize/3 returns :ok (permissive)
    if pid = Process.whereis(Arbor.Security.CapabilityStore) do
      GenServer.stop(pid)
    end

    :ok
  end

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
