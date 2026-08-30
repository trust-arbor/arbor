defmodule Arbor.Orchestrator.CodingPlan.WorkerPhaseCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Orchestrator.CodingPlan.WorkerPhaseCore

  test "empty or unusable completed_nodes are unknown" do
    assert WorkerPhaseCore.project([]) == :unknown
    assert WorkerPhaseCore.project(nil) == :unknown
    assert WorkerPhaseCore.project(%{}) == :unknown
    assert WorkerPhaseCore.project([self(), 1, :implement]) == :unknown
    assert WorkerPhaseCore.to_status(:unknown) == nil
  end

  test "design subgraph milestones prove design before implementation" do
    for nodes <- [
          ["init_design_defaults"],
          ["init_worker_phase"],
          ["build_design_prompt"],
          ["init_worker_phase", "build_design_prompt", "implement"]
        ] do
      assert WorkerPhaseCore.project(nodes) == :design
      assert WorkerPhaseCore.to_status(:design) == "design"
    end
  end

  test "mark_implementation_phase proves implement even when the implement node is reused" do
    nodes = [
      "init_worker_phase",
      "build_design_prompt",
      "implement",
      "mark_implementation_phase",
      "build_implement_prompt"
    ]

    assert WorkerPhaseCore.project(nodes) == :implement
    assert WorkerPhaseCore.to_status(:implement) == "implement"
  end

  test "direct-plan build_implement_prompt without mark_implementation_phase is implement" do
    assert WorkerPhaseCore.project(["open_worker", "build_implement_prompt"]) == :implement
  end

  test "mark_implementation_phase dominates later build_implement_prompt" do
    assert WorkerPhaseCore.project(["mark_implementation_phase", "build_implement_prompt"]) ==
             :implement
  end

  test "open_worker and hoist_worker_provider_session_id are not phase evidence" do
    assert WorkerPhaseCore.project(["open_worker", "hoist_worker_provider_session_id"]) ==
             :unknown
  end

  test "derivation node inventory is closed and bounded" do
    assert WorkerPhaseCore.derivation_nodes() == [
             "mark_implementation_phase",
             "build_implement_prompt",
             "init_design_defaults",
             "init_worker_phase",
             "build_design_prompt"
           ]

    overflow = Enum.map(1..300, &"node_#{&1}")
    admitted = WorkerPhaseCore.admit_completed_nodes(overflow)
    assert length(admitted) == 256
    assert hd(admitted) == "node_1"
    assert List.last(admitted) == "node_256"
    assert Enum.all?(admitted, &is_binary/1)

    padded = List.duplicate(self(), 256) ++ ["mark_implementation_phase"]
    assert WorkerPhaseCore.admit_completed_nodes(padded) == []
    assert WorkerPhaseCore.project(padded) == :unknown

    assert WorkerPhaseCore.admit_completed_nodes(["init_worker_phase" | :corrupt]) == []
    assert WorkerPhaseCore.project(["init_worker_phase" | :corrupt]) == :unknown
  end
end
