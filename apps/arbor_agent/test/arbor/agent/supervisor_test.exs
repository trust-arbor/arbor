defmodule Arbor.Agent.SupervisorTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.Supervisor, as: AgentSupervisor

  @moduletag :fast

  describe "start_agent/1 (deprecated)" do
    test "returns deprecation error" do
      assert {:error, :deprecated_use_lifecycle} =
               AgentSupervisor.start_agent(agent_id: "sup-test-1", agent_module: SomeModule)
    end
  end

  describe "stop_agent/1" do
    test "returns error for non-supervised process" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      assert {:error, :not_found} = AgentSupervisor.stop_agent(pid)
      Process.exit(pid, :kill)
    end
  end

  describe "stop_agent_by_id/1" do
    test "returns error for unknown agent ID" do
      assert {:error, :not_found} = AgentSupervisor.stop_agent_by_id("nonexistent")
    end
  end

  describe "count/0" do
    test "returns non-negative count" do
      assert AgentSupervisor.count() >= 0
    end
  end

  describe "which_agents/0" do
    test "returns list" do
      assert is_list(AgentSupervisor.which_agents())
    end
  end
end
