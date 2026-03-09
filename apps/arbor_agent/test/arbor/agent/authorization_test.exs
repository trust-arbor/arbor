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

  describe "authorize_stop/2" do
    test "returns not_found for non-existent agent" do
      result = Arbor.Agent.authorize_stop(@caller_id, "nonexistent_agent")
      # Should pass auth (returns :ok from authorize) then fail on stop
      assert result == {:error, :not_found}
    end
  end

  describe "authorize_create/3" do
    test "delegates to create_agent when security permits" do
      agent_id = "auth_test_create_#{System.unique_integer([:positive])}"
      # create_agent without template options — may succeed or fail,
      # but should not return unauthorized
      result = Arbor.Agent.authorize_create(@caller_id, agent_id, [])
      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  describe "authorize_destroy/2" do
    test "passes through auth and delegates to destroy_agent" do
      agent_id = "auth_test_destroy_#{System.unique_integer([:positive])}"

      # destroy_agent may raise because Memory.Registry isn't started in
      # the agent test env — what we're testing is that the auth layer
      # does NOT return {:error, {:unauthorized, _}} before reaching destroy.
      result =
        try do
          Arbor.Agent.authorize_destroy(@caller_id, agent_id)
        rescue
          ArgumentError -> :infrastructure_error
        end

      refute match?({:error, {:unauthorized, _}}, result)
    end
  end

  describe "authorize_restore/2" do
    test "delegates to restore_agent when security permits" do
      agent_id = "auth_test_restore_#{System.unique_integer([:positive])}"
      result = Arbor.Agent.authorize_restore(@caller_id, agent_id)
      # Should not return unauthorized — may fail because profile doesn't exist
      refute match?({:error, {:unauthorized, _}}, result)
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
