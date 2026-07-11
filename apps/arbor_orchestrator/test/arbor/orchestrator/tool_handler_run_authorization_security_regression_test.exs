defmodule Arbor.Orchestrator.ToolHandlerRunAuthorizationSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.ToolHandler

  @moduletag :fast

  test "security regression: default ToolHandler fails closed without immutable run authority" do
    marker =
      Path.join(
        System.tmp_dir!(),
        "tool_handler_missing_authority_#{System.unique_integer([:positive])}"
      )

    node = %Node{id: "missing_authority", attrs: %{"tool_command" => "touch #{marker}"}}
    graph = %Graph{id: "missing_authority_graph", nodes: %{}, edges: [], attrs: %{}}

    try do
      outcome =
        ToolHandler.execute(
          node,
          Context.new(%{"session.agent_id" => "agent_context_override"}),
          graph,
          agent_id: "agent_opts_override"
        )

      Process.sleep(200)
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "missing_run_authorization"
      refute File.exists?(marker)
    after
      File.rm(marker)
    end
  end
end
