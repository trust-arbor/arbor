defmodule Arbor.Behavioral.ManagerLifecycleIntegrationTest do
  @moduledoc """
  Behavioral test: Manager lifecycle across subsystems.

  Verifies that Manager functions work correctly and all subsystems
  started by BehavioralCase are running.
  """
  use Arbor.Test.BehavioralCase

  @moduletag :integration

  alias Arbor.Agent.Manager

  describe "manager module availability" do
    test "manager is loaded" do
      assert Code.ensure_loaded?(Arbor.Agent.Manager)
    end

    test "manager exposes lifecycle functions" do
      assert function_exported?(Manager, :start_agent, 1)
      assert function_exported?(Manager, :stop_agent, 1)
      assert function_exported?(Manager, :find_agent, 1)
      assert function_exported?(Manager, :find_first_agent, 0)
    end
  end

  describe "find_agent" do
    test "find_agent returns :not_found for nonexistent agent" do
      result = Manager.find_agent("nonexistent_agent_id")
      assert result == :not_found
    end

    test "find_first_agent returns :not_found or agent tuple" do
      result = Manager.find_first_agent()
      assert result == :not_found or match?({:ok, _, _, _}, result)
    end
  end

  describe "cross-subsystem visibility" do
    test "security capability store is running" do
      assert Process.whereis(Arbor.Security.CapabilityStore) != nil
    end

    test "signals infrastructure is running" do
      assert Process.whereis(Arbor.Signals.Bus) != nil or
               Process.whereis(Arbor.Signals.Supervisor) != nil
    end

    test "memory stores are running" do
      goal_store = Process.whereis(Arbor.Memory.GoalStore)
      intent_store = Process.whereis(Arbor.Memory.IntentStore)
      assert goal_store != nil or intent_store != nil
    end

    test "consensus coordinator is running" do
      assert Process.whereis(Arbor.Consensus.Coordinator) != nil
    end

    test "agent registry is running" do
      assert Process.whereis(Arbor.Agent.Registry) != nil
    end
  end

  describe "chat function" do
    test "chat function exists" do
      Code.ensure_loaded!(Manager)
      funs = Manager.__info__(:functions)
      assert {:chat, 3} in funs
    end
  end
end
