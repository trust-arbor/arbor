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

  describe "TaintTrace" do
    test "schema validates correctly" do
      # Test that schema rejects missing required fields
      assert {:error, _} = Historian.TaintTrace.validate_params(%{})

      # Test that schema accepts valid params for trace_backward
      assert {:ok, _} =
               Historian.TaintTrace.validate_params(%{
                 query_type: :trace_backward,
                 signal_id: "sig_123"
               })

      # Test that schema accepts valid params for summary
      assert {:ok, _} =
               Historian.TaintTrace.validate_params(%{
                 query_type: :summary,
                 agent_id: "agent_001"
               })

      # Test that schema accepts valid params for events query
      assert {:ok, _} =
               Historian.TaintTrace.validate_params(%{
                 query_type: :events,
                 taint_level: :untrusted,
                 limit: 50
               })

      # Test with optional params
      assert {:ok, _} =
               Historian.TaintTrace.validate_params(%{
                 query_type: :trace_forward,
                 signal_id: "sig_123",
                 limit: 25
               })
    end

    test "validates action metadata" do
      assert Historian.TaintTrace.name() == "historian_taint_trace"
      assert Historian.TaintTrace.category() == "historian"
      assert "security" in Historian.TaintTrace.tags()
      assert "taint" in Historian.TaintTrace.tags()
      assert "provenance" in Historian.TaintTrace.tags()
    end

    test "generates tool schema" do
      tool = Historian.TaintTrace.to_tool()
      assert is_map(tool)
      assert tool[:name] == "historian_taint_trace"
      assert tool[:description] =~ "taint"
    end

    test "run with missing required params returns error" do
      # trace_backward requires signal_id
      result =
        Historian.TaintTrace.run(
          %{query_type: :trace_backward},
          %{}
        )

      assert {:error, message} = result
      assert message =~ "Missing required parameter" or message =~ "signal_id"
    end

    test "run with summary requires agent_id" do
      result =
        Historian.TaintTrace.run(
          %{query_type: :summary},
          %{}
        )

      assert {:error, message} = result
      assert message =~ "Missing required parameter" or message =~ "agent_id"
    end
  end

  describe "module structure" do
    test "modules compile and are usable" do
      assert Code.ensure_loaded?(Historian.QueryEvents)
      assert Code.ensure_loaded?(Historian.CausalityTree)
      assert Code.ensure_loaded?(Historian.ReconstructState)
      assert Code.ensure_loaded?(Historian.TaintTrace)

      assert function_exported?(Historian.QueryEvents, :run, 2)
      assert function_exported?(Historian.CausalityTree, :run, 2)
      assert function_exported?(Historian.ReconstructState, :run, 2)
      assert function_exported?(Historian.TaintTrace, :run, 2)
    end
  end
end
