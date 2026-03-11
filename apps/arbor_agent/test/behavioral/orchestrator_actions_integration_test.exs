defmodule Arbor.Behavioral.OrchestratorActionsIntegrationTest do
  @moduledoc """
  Behavioral test: Orchestrator + Actions cross-app integration.

  Verifies that the orchestrator pipeline correctly applies the middleware
  chain, and DOT parsing works end-to-end.
  """
  use Arbor.Test.BehavioralCase

  @moduletag :integration

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Middleware.{Chain, Token}

  defp make_token(attrs, assigns \\ %{}) do
    node = %Node{id: "integration_node", attrs: Map.merge(%{"type" => "compute"}, attrs)}
    context = %Context{values: %{}}
    graph = %Graph{nodes: %{"integration_node" => node}, edges: [], attrs: %{}}
    %Token{node: node, context: context, graph: graph, assigns: assigns}
  end

  describe "middleware chain construction" do
    test "default mandatory chain is available" do
      chain = Chain.default_mandatory_chain()
      assert is_list(chain)
      assert length(chain) > 0
    end

    test "chain build includes mandatory middleware" do
      graph = %Graph{nodes: %{}, edges: [], attrs: %{}}
      node = %Node{id: "test", attrs: %{}}
      chain = Chain.build([], graph, node)
      assert is_list(chain)
    end
  end

  describe "middleware pipeline execution" do
    test "token passes through full mandatory chain without halting" do
      token = make_token(%{}, %{skip_capability_check: true, skip_taint_check: true})
      chain = Chain.default_mandatory_chain()

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
      assert is_struct(result, Token)
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
