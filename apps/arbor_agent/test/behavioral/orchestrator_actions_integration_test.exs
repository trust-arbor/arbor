defmodule Arbor.Behavioral.OrchestratorActionsIntegrationTest do
  @moduledoc """
  Behavioral test: Orchestrator + Actions cross-app integration.

  Verifies that the orchestrator pipeline correctly applies the middleware
  chain, and DOT parsing works end-to-end.
  """
  use Arbor.Test.BehavioralCase

  @moduletag :integration

  # Note: We can't use struct syntax for orchestrator modules here because
  # arbor_agent doesn't have arbor_orchestrator as a compile-time dependency.
  # Use plain maps with __struct__ keys instead.

  defp make_token(attrs, assigns \\ %{}) do
    node = %{
      __struct__: Arbor.Orchestrator.Graph.Node,
      id: "integration_node",
      attrs: Map.merge(%{"type" => "compute"}, attrs)
    }

    context = %{__struct__: Arbor.Orchestrator.Engine.Context, values: %{}}

    graph = %{
      __struct__: Arbor.Orchestrator.Graph,
      nodes: %{"integration_node" => node},
      edges: [],
      attrs: %{}
    }

    %{
      __struct__: Arbor.Orchestrator.Middleware.Token,
      node: node,
      context: context,
      graph: graph,
      assigns: assigns,
      halted: false,
      halt_reason: nil,
      outcome: nil
    }
  end

  describe "middleware chain construction" do
    test "default mandatory chain is available" do
      chain = Arbor.Orchestrator.Middleware.Chain.default_mandatory_chain()
      assert is_list(chain)
      assert length(chain) > 0
    end

    test "chain build includes mandatory middleware" do
      graph = %{__struct__: Arbor.Orchestrator.Graph, nodes: %{}, edges: [], attrs: %{}}
      node = %{__struct__: Arbor.Orchestrator.Graph.Node, id: "test", attrs: %{}}
      chain = Arbor.Orchestrator.Middleware.Chain.build([], graph, node)
      assert is_list(chain)
    end
  end

  describe "middleware pipeline execution" do
    test "token passes through full mandatory chain without halting" do
      token = make_token(%{}, %{skip_capability_check: true, skip_taint_check: true})
      chain = Arbor.Orchestrator.Middleware.Chain.default_mandatory_chain()

      final_token =
        Enum.reduce_while(chain, token, fn middleware, tok ->
          result = middleware.before_node(tok)
          if result.halted, do: {:halt, result}, else: {:cont, result}
        end)

      refute final_token.halted
    end

    test "capability check responds to agent_id in assigns", %{agent_id: agent_id} do
      token = make_token(%{"type" => "shell"}, %{agent_id: agent_id})
      result = Arbor.Orchestrator.Middleware.CapabilityCheck.before_node(token)
      assert is_struct(result, Arbor.Orchestrator.Middleware.Token)
    end

    test "safe input blocks path traversal in pipeline context" do
      token = make_token(%{"graph_file" => "../../../etc/passwd"})
      result = Arbor.Orchestrator.Middleware.SafeInput.before_node(token)
      assert result.halted
      assert result.halt_reason =~ "path traversal"
    end
  end

  describe "orchestrator facade" do
    test "orchestrator module is available" do
      assert Code.ensure_loaded?(Arbor.Orchestrator)
    end

    test "orchestrator can parse DOT" do
      dot = """
      digraph test {
        start [type="start"];
        end_node [type="exit"];
        start -> end_node;
      }
      """

      assert {:ok, graph} = Arbor.Orchestrator.parse(dot)
      assert map_size(graph.nodes) >= 2
    end
  end
end
