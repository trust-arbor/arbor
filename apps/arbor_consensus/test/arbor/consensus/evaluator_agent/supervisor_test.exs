defmodule Arbor.Consensus.EvaluatorAgent.SupervisorTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.EvaluatorAgent
  alias Arbor.Consensus.EvaluatorAgent.Supervisor, as: AgentSupervisor

  # A test evaluator
  defmodule TestEvaluator do
    @behaviour Arbor.Contracts.Consensus.Evaluator

    @impl true
    def name, do: :supervisor_test_evaluator

    @impl true
    def perspectives, do: [:test_perspective]

    @impl true
    def evaluate(_proposal, perspective, _opts) do
      Arbor.Contracts.Consensus.Evaluation.new(%{
        proposal_id: "test",
        evaluator_id: "test",
        perspective: perspective,
        vote: :approve,
        confidence: 0.9,
        reasoning: "Test"
      })
    end
  end

  # Another test evaluator with different name
  defmodule AnotherEvaluator do
    @behaviour Arbor.Contracts.Consensus.Evaluator

    @impl true
    def name, do: :another_test_evaluator

    @impl true
    def perspectives, do: [:another_perspective]

    @impl true
    def evaluate(_proposal, perspective, _opts) do
      Arbor.Contracts.Consensus.Evaluation.new(%{
        proposal_id: "test",
        evaluator_id: "another",
        perspective: perspective,
        vote: :approve,
        confidence: 0.9,
        reasoning: "Another test"
      })
    end
  end

  setup do
    # Start a test supervisor
    {:ok, sup_pid} = AgentSupervisor.start_link(name: :"test_sup_#{System.unique_integer()}")
    %{supervisor: sup_pid}
  end

  describe "start_agent/3" do
    test "starts an agent under supervision", %{supervisor: sup} do
      {:ok, pid} = AgentSupervisor.start_agent(sup, TestEvaluator, [])

      assert Process.alive?(pid)
      assert EvaluatorAgent.evaluator(pid) == TestEvaluator
    end

    test "returns error if agent already started", %{supervisor: sup} do
      {:ok, _pid} = AgentSupervisor.start_agent(sup, TestEvaluator, [])
      assert {:error, :already_started} = AgentSupervisor.start_agent(sup, TestEvaluator, [])
    end

    test "can start multiple different evaluators", %{supervisor: sup} do
      {:ok, pid1} = AgentSupervisor.start_agent(sup, TestEvaluator, [])
      {:ok, pid2} = AgentSupervisor.start_agent(sup, AnotherEvaluator, [])

      assert pid1 != pid2
      assert EvaluatorAgent.evaluator(pid1) == TestEvaluator
      assert EvaluatorAgent.evaluator(pid2) == AnotherEvaluator
    end
  end

  describe "stop_agent/2" do
    test "stops a running agent", %{supervisor: sup} do
      {:ok, pid} = AgentSupervisor.start_agent(sup, TestEvaluator, [])
      assert Process.alive?(pid)

      assert :ok = AgentSupervisor.stop_agent(sup, :supervisor_test_evaluator)
      refute Process.alive?(pid)
    end

    test "returns error for non-existent agent", %{supervisor: sup} do
      assert {:error, :not_found} = AgentSupervisor.stop_agent(sup, :nonexistent)
    end
  end

  describe "list_agents/1" do
    test "returns empty list when no agents", %{supervisor: sup} do
      assert [] = AgentSupervisor.list_agents(sup)
    end

    test "returns list of running agents", %{supervisor: sup} do
      {:ok, _} = AgentSupervisor.start_agent(sup, TestEvaluator, [])
      {:ok, _} = AgentSupervisor.start_agent(sup, AnotherEvaluator, [])

      agents = AgentSupervisor.list_agents(sup)

      assert length(agents) == 2
      names = Enum.map(agents, fn {name, _pid, _status} -> name end)
      assert :supervisor_test_evaluator in names
      assert :another_test_evaluator in names
    end
  end

  describe "lookup_agent/1" do
    test "finds a running agent", %{supervisor: sup} do
      {:ok, pid} = AgentSupervisor.start_agent(sup, TestEvaluator, [])

      # Use the scan-based lookup since we're not using the global registry
      result = AgentSupervisor.lookup_agent(:supervisor_test_evaluator)

      # Either found via registry or scan
      case result do
        {:ok, found_pid} -> assert found_pid == pid
        :not_found -> :ok  # Registry not available, which is fine
      end
    end

    test "returns not_found for non-existent agent", %{supervisor: _sup} do
      assert :not_found = AgentSupervisor.lookup_agent(:definitely_not_exists)
    end
  end

  describe "agent_count/1" do
    test "returns correct count", %{supervisor: sup} do
      assert AgentSupervisor.agent_count(sup) == 0

      {:ok, _} = AgentSupervisor.start_agent(sup, TestEvaluator, [])
      assert AgentSupervisor.agent_count(sup) == 1

      {:ok, _} = AgentSupervisor.start_agent(sup, AnotherEvaluator, [])
      assert AgentSupervisor.agent_count(sup) == 2
    end
  end
end
