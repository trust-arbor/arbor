defmodule Arbor.Actions.HistorianTest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions.Historian

  @moduletag :fast

  describe "QueryEvents" do
    test "schema validates correctly" do
      # All params are optional
      assert {:ok, _} = Historian.QueryEvents.validate_params(%{})

      # Test with various optional params
      assert {:ok, _} =
               Historian.QueryEvents.validate_params(%{
                 category: "agent",
                 limit: 50
               })

      assert {:ok, _} =
               Historian.QueryEvents.validate_params(%{
                 stream: "global",
                 from: "2025-01-01T00:00:00Z",
                 to: "2025-01-31T23:59:59Z"
               })
    end

    test "validates action metadata" do
      assert Historian.QueryEvents.name() == "historian_query_events"
      assert Historian.QueryEvents.category() == "historian"
      assert "historian" in Historian.QueryEvents.tags()
      assert "query" in Historian.QueryEvents.tags()
    end

    test "generates tool schema" do
      tool = Historian.QueryEvents.to_tool()
      assert is_map(tool)
      assert tool[:name] == "historian_query_events"
      assert tool[:description] =~ "Query"
    end
  end

  describe "CausalityTree" do
    test "schema validates correctly" do
      # Test that schema rejects missing required fields
      assert {:error, _} = Historian.CausalityTree.validate_params(%{})

      # Test that schema accepts valid params
      assert {:ok, _} = Historian.CausalityTree.validate_params(%{event_id: "evt_123"})

      # Test with optional max_depth
      assert {:ok, _} =
               Historian.CausalityTree.validate_params(%{
                 event_id: "evt_123",
                 max_depth: 5
               })
    end

    test "validates action metadata" do
      assert Historian.CausalityTree.name() == "historian_causality_tree"
      assert Historian.CausalityTree.category() == "historian"
      assert "causality" in Historian.CausalityTree.tags()
      assert "debug" in Historian.CausalityTree.tags()
    end

    test "generates tool schema" do
      tool = Historian.CausalityTree.to_tool()
      assert is_map(tool)
      assert tool[:name] == "historian_causality_tree"
      assert tool[:description] =~ "causal"
    end
  end

  describe "ReconstructState" do
    test "schema validates correctly" do
      # Test that schema rejects missing required fields
      assert {:error, _} = Historian.ReconstructState.validate_params(%{})
      assert {:error, _} = Historian.ReconstructState.validate_params(%{stream: "agent:001"})

      # Test that schema accepts valid params
      assert {:ok, _} =
               Historian.ReconstructState.validate_params(%{
                 stream: "agent:agent_001",
                 as_of: "2025-01-15T12:00:00Z"
               })

      # Test with optional include_events
      assert {:ok, _} =
               Historian.ReconstructState.validate_params(%{
                 stream: "agent:agent_001",
                 as_of: "2025-01-15T12:00:00Z",
                 include_events: true
               })
    end

    test "validates action metadata" do
      assert Historian.ReconstructState.name() == "historian_reconstruct_state"
      assert Historian.ReconstructState.category() == "historian"
      assert "state" in Historian.ReconstructState.tags()
      assert "replay" in Historian.ReconstructState.tags()
    end

    test "generates tool schema" do
      tool = Historian.ReconstructState.to_tool()
      assert is_map(tool)
      assert tool[:name] == "historian_reconstruct_state"
      assert tool[:description] =~ "Reconstruct"
    end
  end

  describe "module structure" do
    test "modules compile and are usable" do
      assert Code.ensure_loaded?(Historian.QueryEvents)
      assert Code.ensure_loaded?(Historian.CausalityTree)
      assert Code.ensure_loaded?(Historian.ReconstructState)

      assert function_exported?(Historian.QueryEvents, :run, 2)
      assert function_exported?(Historian.CausalityTree, :run, 2)
      assert function_exported?(Historian.ReconstructState, :run, 2)
    end
  end
end
