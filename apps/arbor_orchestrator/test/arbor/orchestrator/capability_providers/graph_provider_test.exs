defmodule Arbor.Orchestrator.CapabilityProviders.GraphProviderTest do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.CapabilityProviders.GraphProvider
  alias Arbor.Orchestrator.GraphRegistry
  alias Arbor.Contracts.CapabilityDescriptor

  @moduletag :fast

  setup do
    # Save and restore graph state
    saved = GraphRegistry.snapshot()

    GraphRegistry.reset()
    GraphRegistry.register("test-consensus-flow", "digraph G { a -> b; }")
    GraphRegistry.register("test-heartbeat", "digraph H { start -> think -> act; }")

    on_exit(fn -> GraphRegistry.restore(saved) end)

    :ok
  end

  describe "list_capabilities/1" do
    test "returns descriptors for all registered graphs" do
      capabilities = GraphProvider.list_capabilities()
      assert is_list(capabilities)

      ids = Enum.map(capabilities, & &1.id)
      assert "pipeline:test-consensus-flow" in ids
      assert "pipeline:test-heartbeat" in ids
    end

    test "all descriptors are pipeline kind" do
      capabilities = GraphProvider.list_capabilities()
      assert Enum.all?(capabilities, &(&1.kind == :pipeline))
    end

    test "descriptors have correct provider" do
      capabilities = GraphProvider.list_capabilities()
      assert Enum.all?(capabilities, &(&1.provider == GraphProvider))
    end
  end

  describe "describe/1" do
    test "returns descriptor for valid pipeline ID" do
      assert {:ok, %CapabilityDescriptor{} = desc} =
               GraphProvider.describe("pipeline:test-consensus-flow")

      assert desc.name == "Test Consensus Flow"
      assert desc.kind == :pipeline
    end

    test "returns error for non-existent graph" do
      assert {:error, :not_found} = GraphProvider.describe("pipeline:nonexistent")
    end

    test "returns error for wrong ID prefix" do
      assert {:error, :not_found} = GraphProvider.describe("action:test-consensus-flow")
    end
  end

  describe "execute/3" do
    test "returns DOT string for inline graph" do
      assert {:ok, result} =
               GraphProvider.execute("pipeline:test-consensus-flow", %{}, [])

      assert result.graph_name == "test-consensus-flow"
      assert result.dot == "digraph G { a -> b; }"
    end

    test "returns error for non-existent graph" do
      assert {:error, :not_found} = GraphProvider.execute("pipeline:nonexistent", %{}, [])
    end
  end

  describe "graph_to_descriptor/1" do
    test "converts graph name to descriptor" do
      desc = GraphProvider.graph_to_descriptor("my-cool-pipeline")

      assert %CapabilityDescriptor{} = desc
      assert desc.id == "pipeline:my-cool-pipeline"
      assert desc.name == "My Cool Pipeline"
      assert desc.kind == :pipeline
      assert "cool" in desc.tags
      assert "pipeline" in desc.tags
    end

    test "extracts meaningful tags from name" do
      desc = GraphProvider.graph_to_descriptor("consensus-decision-flow")
      assert "consensus" in desc.tags
      assert "decision" in desc.tags
      assert "flow" in desc.tags
    end

    test "filters short tags" do
      desc = GraphProvider.graph_to_descriptor("a-to-b-flow")
      refute "a" in desc.tags
      refute "to" in desc.tags
      refute "b" in desc.tags
      assert "flow" in desc.tags
    end
  end
end
