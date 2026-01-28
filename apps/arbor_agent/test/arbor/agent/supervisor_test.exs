defmodule Arbor.Agent.SupervisorTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.Supervisor, as: AgentSupervisor
  alias Arbor.Agent.Test.TestAgent

  @moduletag :fast

  setup do
    Process.sleep(10)
    :ok
  end

  describe "start_agent/1" do
    test "starts an agent under supervision" do
      {:ok, pid} =
        AgentSupervisor.start_agent(
          agent_id: "sup-test-1",
          agent_module: TestAgent,
          initial_state: %{value: 0}
        )

      assert Process.alive?(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: AgentSupervisor.stop_agent(pid)
      end)
    end

    test "agent appears in which_agents" do
      {:ok, pid} =
        AgentSupervisor.start_agent(
          agent_id: "sup-test-which",
          agent_module: TestAgent
        )

      Process.sleep(50)

      agents = AgentSupervisor.which_agents()
      assert pid in agents

      on_exit(fn ->
        if Process.alive?(pid), do: AgentSupervisor.stop_agent(pid)
      end)
    end
  end

  describe "stop_agent/1" do
    test "stops a supervised agent" do
      {:ok, pid} =
        AgentSupervisor.start_agent(
          agent_id: "sup-stop-1",
          agent_module: TestAgent
        )

      assert :ok = AgentSupervisor.stop_agent(pid)
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "returns error for non-supervised process" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      assert {:error, :not_found} = AgentSupervisor.stop_agent(pid)
      Process.exit(pid, :kill)
    end
  end

  describe "stop_agent_by_id/1" do
    test "stops agent by ID" do
      {:ok, pid} =
        AgentSupervisor.start_agent(
          agent_id: "sup-stop-id",
          agent_module: TestAgent
        )

      Process.sleep(50)

      assert :ok = AgentSupervisor.stop_agent_by_id("sup-stop-id")
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "returns error for unknown agent ID" do
      assert {:error, :not_found} = AgentSupervisor.stop_agent_by_id("nonexistent")
    end
  end

  describe "count/0" do
    test "counts active agents" do
      initial_count = AgentSupervisor.count()

      {:ok, pid1} =
        AgentSupervisor.start_agent(
          agent_id: "sup-count-1",
          agent_module: TestAgent
        )

      {:ok, pid2} =
        AgentSupervisor.start_agent(
          agent_id: "sup-count-2",
          agent_module: TestAgent
        )

      Process.sleep(50)

      assert AgentSupervisor.count() == initial_count + 2

      on_exit(fn ->
        if Process.alive?(pid1), do: AgentSupervisor.stop_agent(pid1)
        if Process.alive?(pid2), do: AgentSupervisor.stop_agent(pid2)
      end)
    end
  end

  describe "supervision" do
    test "agent restarts on crash (transient restart)" do
      {:ok, pid} =
        AgentSupervisor.start_agent(
          agent_id: "sup-crash-test",
          agent_module: TestAgent,
          restart: :temporary
        )

      Process.sleep(50)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000
    end
  end
end
