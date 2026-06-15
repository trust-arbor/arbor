defmodule Arbor.Orchestrator.Engine.TaintBoundaryTest do
  @moduledoc """
  Taint inheritance across pipeline boundaries (taint-rebuild Phase 3 nuance):
  a top-level run can be seeded with provenance and reports its final
  provenance, and parallel branches don't silently drop it.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  describe "Engine.run taint I/O (the foundation subgraph/parallel rely on)" do
    test "initial_taint is inherited and the final taint map is returned" do
      dot = """
      digraph T {
        start [shape=Mdiamond]
        done [shape=Msquare]
        start -> done
      }
      """

      {:ok, result} =
        Arbor.Orchestrator.run(dot, initial_taint: %{"seed" => :untrusted})

      assert result.taint["seed"].level == :untrusted
    end
  end

  describe "parallel branches inherit parent provenance" do
    test "aggregated parallel results carry the worst parent taint" do
      dot = """
      digraph Flow {
        start [shape=Mdiamond]
        parallel [shape=component, join_policy="wait_all", fan_out="false"]
        branch_a [label="A", simulate="true"]
        branch_b [label="B", simulate="true"]
        join [shape=tripleoctagon]
        exit [shape=Msquare]

        start -> parallel
        parallel -> branch_a
        parallel -> branch_b
        branch_a -> join
        branch_b -> join
        join -> exit
      }
      """

      branch_executor = fn branch_node_id, _ctx, _graph, _opts ->
        %{"id" => branch_node_id, "status" => "success", "score" => 0.5}
      end

      {:ok, result} =
        Arbor.Orchestrator.run(dot,
          parallel_branch_executor: branch_executor,
          initial_taint: %{"seed" => :untrusted}
        )

      # Branches read the full parent snapshot, so the fan-in output is at least
      # as tainted as the most-tainted parent key — not silently untainted.
      assert result.taint["parallel.results"].level == :untrusted
    end
  end

  describe "human-review reduction end-to-end (Phase 4)" do
    test "approving a gate reduces the reviewed key's taint via :human_review" do
      dot = """
      digraph H {
        start [shape=Mdiamond]
        gate [shape=hexagon, label="Approve use of fetched data?", reviews_keys="seed", review_on_choice="approve"]
        done [shape=Msquare]

        start -> gate
        gate -> done [label="approve"]
      }
      """

      interviewer = fn _q, _o -> %Arbor.Orchestrator.Human.Answer{value: "approve"} end

      {:ok, result} =
        Arbor.Orchestrator.run(dot,
          initial_taint: %{"seed" => :untrusted},
          interviewer: interviewer
        )

      # A human approved -> the reviewed key is reduced from :untrusted to :trusted.
      assert result.taint["seed"].level == :trusted
    end
  end
end
