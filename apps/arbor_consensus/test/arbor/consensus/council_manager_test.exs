defmodule Arbor.Consensus.CouncilManagerTest do
  use ExUnit.Case, async: false

  alias Arbor.Consensus.CouncilManager
  alias Arbor.Consensus.EvaluatorAgent
  alias Arbor.Consensus.Evaluators.AdvisoryLLM

  setup do
    # Ensure clean state — stop any running perspective agents
    # stop_all/0 waits for process termination via monitor :DOWN
    CouncilManager.stop_all()

    on_exit(fn ->
      # Clean up after each test so we don't leak agents into other test modules
      CouncilManager.stop_all()
    end)

    :ok
  end

  describe "ensure_started/0" do
    test "starts all 13 perspective agents" do
      assert :ok = CouncilManager.ensure_started()
      assert CouncilManager.running_count() == 13
    end

    test "is idempotent — calling twice doesn't fail" do
      assert :ok = CouncilManager.ensure_started()
      assert :ok = CouncilManager.ensure_started()
      assert CouncilManager.running_count() == 13
    end
  end

  describe "start_perspective/1" do
    test "starts a single perspective agent" do
      assert {:ok, pid} = CouncilManager.start_perspective(:security)
      assert is_pid(pid)

      status = EvaluatorAgent.status(pid)
      assert status.name == :advisory_security
      assert status.perspectives == [:security]
    end

    test "returns error for already running perspective" do
      assert {:ok, _} = CouncilManager.start_perspective(:security)
      assert {:error, :already_started} = CouncilManager.start_perspective(:security)
    end

    test "returns error for unknown perspective" do
      assert {:error, {:unknown_perspective, :nonexistent}} =
               CouncilManager.start_perspective(:nonexistent)
    end

    test "each perspective agent is filtered to its own perspective" do
      assert {:ok, pid1} = CouncilManager.start_perspective(:security)
      assert {:ok, pid2} = CouncilManager.start_perspective(:brainstorming)

      assert EvaluatorAgent.perspectives(pid1) == [:security]
      assert EvaluatorAgent.perspectives(pid2) == [:brainstorming]
    end
  end

  describe "stop_all/0" do
    test "stops all running perspective agents" do
      CouncilManager.ensure_started()
      assert CouncilManager.running_count() == 13

      assert :ok = CouncilManager.stop_all()
      assert CouncilManager.running_count() == 0
    end
  end

  describe "stop_perspective/1" do
    test "stops a specific perspective agent" do
      CouncilManager.start_perspective(:security)
      assert CouncilManager.running_count() == 1

      assert :ok = CouncilManager.stop_perspective(:security)
      assert CouncilManager.running_count() == 0
    end

    test "returns error when perspective not running" do
      assert {:error, :not_found} = CouncilManager.stop_perspective(:security)
    end
  end

  describe "status/0" do
    test "returns empty list when no agents running" do
      assert [] = CouncilManager.status()
    end

    test "returns status for each running agent" do
      CouncilManager.start_perspective(:security)
      CouncilManager.start_perspective(:stability)

      status = CouncilManager.status()
      assert length(status) == 2

      perspectives = Enum.map(status, fn {p, _pid, _s} -> p end) |> Enum.sort()
      assert perspectives == [:security, :stability]

      # Check status shape
      {_p, _pid, s} = hd(status)
      assert is_atom(s.name)
      assert s.evaluator == AdvisoryLLM
      assert is_list(s.perspectives)
      assert is_integer(s.evaluations_processed)
    end
  end

  describe "running_count/0" do
    test "returns 0 when no agents running" do
      assert CouncilManager.running_count() == 0
    end

    test "returns correct count" do
      CouncilManager.start_perspective(:security)
      CouncilManager.start_perspective(:vision)
      assert CouncilManager.running_count() == 2
    end
  end

  describe "perspectives/0" do
    test "returns all 13 advisory perspectives" do
      perspectives = CouncilManager.perspectives()
      assert length(perspectives) == 13
      assert :security in perspectives
      assert :brainstorming in perspectives
      assert :vision in perspectives
    end
  end

  describe "perspective_agent_name/1" do
    test "generates correct agent names" do
      assert CouncilManager.perspective_agent_name(:security) == :advisory_security
      assert CouncilManager.perspective_agent_name(:brainstorming) == :advisory_brainstorming
    end
  end
end
