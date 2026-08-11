defmodule Arbor.Memory.KnowledgeGraph.OperationTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.KnowledgeGraph
  alias Arbor.Memory.KnowledgeGraph.Operation

  @moduletag :fast

  describe "add_node outcome through Operation.apply/2" do
    test "first apply reports :created, second (different operation_id, same content) reports :deduplicated with the same node_id" do
      graph = KnowledgeGraph.new("agent_op_test", auto_embed: false)

      {:ok, op1} = Operation.add_node("op1", %{type: :fact, content: "duplicate content"})
      {:ok, graph, %{node_id: id1, outcome: :created}, :changed} = Operation.apply(op1, graph)

      {:ok, op2} = Operation.add_node("op2", %{type: :fact, content: "duplicate content"})

      {:ok, graph, %{node_id: id2, outcome: :deduplicated}, :changed} =
        Operation.apply(op2, graph)

      assert id1 == id2
      assert map_size(graph.nodes) == 1
    end

    test "replaying the original operation_id returns the originally-decided :created outcome, even after the graph gained a duplicate" do
      graph = KnowledgeGraph.new("agent_op_test", auto_embed: false)

      {:ok, op1} = Operation.add_node("op1", %{type: :fact, content: "replay truthfulness"})
      {:ok, graph, %{node_id: id1, outcome: :created}, :changed} = Operation.apply(op1, graph)

      {:ok, op2} = Operation.add_node("op2", %{type: :fact, content: "replay truthfulness"})
      {:ok, graph, %{outcome: :deduplicated}, :changed} = Operation.apply(op2, graph)

      # Re-apply op1 (same operation_id + fingerprint) -- this must hit the
      # replay path and return the outcome that was actually decided the
      # first time, not a fresh (now-wrong) dedup check against the graph
      # that has since gained a duplicate of this exact content.
      {:ok, _graph, %{node_id: ^id1, outcome: :created}, :replayed} = Operation.apply(op1, graph)
    end
  end

  describe "add_node replay defensive legacy fallback" do
    test "a directly-constructed bare-string add_node receipt replays as outcome :unknown, never a guessed :created" do
      graph = KnowledgeGraph.new("agent_op_legacy_test", auto_embed: false)

      {:ok, op} = Operation.add_node("op_legacy", %{type: :fact, content: "legacy receipt fact"})

      {:ok, graph, %{node_id: node_id, outcome: :created}, :changed} = Operation.apply(op, graph)

      # Simulate a pre-migration durable receipt: rewrite the stored
      # receipt's result to a bare node-id string, exactly the shape
      # add_node receipts had before outcome-tracking existed. This
      # bypasses Codec entirely, exercising Operation.replay_result/4's
      # belt-and-suspenders fallback in isolation.
      legacy_receipts =
        Map.update!(graph.operation_receipts, "op_legacy", fn receipt ->
          %{receipt | result: node_id}
        end)

      legacy_graph = %{graph | operation_receipts: legacy_receipts}

      {:ok, _graph, %{node_id: ^node_id, outcome: :unknown}, :replayed} =
        Operation.apply(op, legacy_graph)
    end

    test "a malformed outcome receipt fails closed instead of replaying untrusted data" do
      graph = KnowledgeGraph.new("agent_op_invalid_receipt", auto_embed: false)

      {:ok, op} = Operation.add_node("op_invalid", %{type: :fact, content: "invalid receipt"})
      {:ok, graph, %{node_id: node_id}, :changed} = Operation.apply(op, graph)

      malformed_receipts =
        Map.update!(graph.operation_receipts, "op_invalid", fn receipt ->
          %{receipt | result: %{node_id: node_id, outcome: :forged}}
        end)

      assert {:error, :invalid_graph} =
               Operation.apply(op, %{graph | operation_receipts: malformed_receipts})
    end
  end
end
