defmodule Arbor.Orchestrator.Handlers.LlmHandlerToolLoopRunAuthorizationSecurityRegressionTest do
  @moduledoc """
  Security regression: LlmHandler must thread the exact validated
  %RunAuthorization{} into ToolLoop opts so nested tool calls retain
  execution-binding lineage (binding_digest / parent_binding_digest).

  Without this, ActionsExecutor cannot project lineage and nested council
  tool calls fail closed with :nested_action_binding_lineage_missing.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Common.ActionRegistry
  alias Arbor.LLM.{Client, ContentPart, Request, Response}
  alias Arbor.Orchestrator.Engine.{Context, RunAuthorization}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.LlmHandler

  defmodule AuthorityAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "llm_tool_loop_run_auth_test"

    @impl true
    def complete(%Request{} = request, _opts) do
      case Enum.find(Enum.reverse(request.messages), &(&1.role == :tool)) do
        nil ->
          {:ok,
           %Response{
             text: "",
             finish_reason: :tool_calls,
             content_parts: [
               ContentPart.tool_call("auth_call", "tool_help", %{"probe" => "lineage"})
             ],
             raw: %{}
           }}

        _tool_result ->
          {:ok, %Response{text: "authority round complete", finish_reason: :stop, raw: %{}}}
      end
    end
  end

  defmodule CapturingExecutor do
    def execute(name, args, workdir, opts) do
      send(self(), {:tool_execution, name, args, workdir, opts})
      {:ok, "captured #{name}"}
    end
  end

  setup do
    unless Process.whereis(ActionRegistry), do: start_supervised!({ActionRegistry, []})

    case ActionRegistry.register_action(Arbor.Actions.Tool.Help) do
      :ok -> :ok
      # Already present (unlocked or core-locked by Registrar.register_core/0)
      {:error, :already_registered} -> :ok
      {:error, :core_locked} -> :ok
    end

    :ok
  end

  test "security regression: exact RunAuthorization reaches capturing tool executor" do
    node =
      %Node{
        id: "run_auth_tool_loop",
        attrs: %{
          "type" => "compute",
          "simulate" => "false",
          "prompt" => "Call the help tool once",
          "use_tools" => "true",
          "tools" => "tool_help",
          "max_turns" => "2",
          "llm_provider" => AuthorityAdapter.provider(),
          "llm_model" => "test"
        }
      }

    graph =
      %Graph{
        id: "run_auth_tool_loop_graph",
        nodes: %{node.id => node},
        edges: [],
        attrs: %{"goal" => "prove run_authorization forwarding"}
      }
      |> Arbor.Orchestrator.IR.Compiler.compile!()

    node = Map.fetch!(graph.nodes, node.id)

    execution_principal = "agent_run_auth_executor"
    caller_id = "human_run_auth_caller"
    author_id = "agent_run_auth_author"
    task_id = "task_run_auth"
    session_id = "session_run_auth"

    {:ok, authority} =
      RunAuthorization.new(graph,
        execution_principal: execution_principal,
        caller_id: caller_id,
        author_id: author_id,
        task_id: task_id,
        session_id: session_id,
        workdir: File.cwd!()
      )

    context =
      Context.new(%{
        "session.llm_provider" => AuthorityAdapter.provider(),
        "session.llm_model" => "test"
      })
      |> RunAuthorization.enforce_context(authority)

    client =
      Client.new(default_provider: AuthorityAdapter.provider())
      |> Client.register_adapter(AuthorityAdapter)

    assert %{status: :success} =
             LlmHandler.execute(node, context, graph,
               authorization: true,
               run_authorization: authority,
               llm_client: client,
               tool_executor: CapturingExecutor,
               workdir: File.cwd!()
             )

    assert_receive {:tool_execution, "tool_help", %{"probe" => "lineage"}, _workdir, exec_opts}

    # Exact validated authority term — not a field-projected reconstruction.
    assert Keyword.fetch!(exec_opts, :run_authorization) === authority
    assert Keyword.fetch!(exec_opts, :execution_principal) == execution_principal
    assert Keyword.fetch!(exec_opts, :agent_id) == execution_principal
    assert Keyword.fetch!(exec_opts, :caller_id) == caller_id
    assert Keyword.fetch!(exec_opts, :author_id) == author_id
    assert Keyword.fetch!(exec_opts, :task_id) == task_id
    assert Keyword.fetch!(exec_opts, :session_id) == session_id
    assert Keyword.fetch!(exec_opts, :execution_manifest) == authority.execution_manifest

    assert Keyword.fetch!(exec_opts, :execution_manifest_digest) ==
             authority.execution_manifest_digest

    assert Keyword.fetch!(exec_opts, :pinned_action_bindings) == authority.pinned_action_bindings
  end

  test "security regression: authorized tool loop fails closed without RunAuthorization" do
    node =
      %Node{
        id: "missing_run_auth",
        attrs: %{
          "type" => "compute",
          "simulate" => "false",
          "prompt" => "should not execute tools",
          "use_tools" => "true",
          "tools" => "tool_help",
          "max_turns" => "2",
          "llm_provider" => AuthorityAdapter.provider(),
          "llm_model" => "test"
        }
      }

    graph =
      %Graph{
        id: "missing_run_auth_graph",
        nodes: %{node.id => node},
        edges: [],
        attrs: %{"goal" => "fail closed"}
      }
      |> Arbor.Orchestrator.IR.Compiler.compile!()

    node = Map.fetch!(graph.nodes, node.id)

    context =
      Context.new(%{
        "session.llm_provider" => AuthorityAdapter.provider(),
        "session.llm_model" => "test"
      })

    client =
      Client.new(default_provider: AuthorityAdapter.provider())
      |> Client.register_adapter(AuthorityAdapter)

    outcome =
      LlmHandler.execute(node, context, graph,
        authorization: true,
        llm_client: client,
        tool_executor: CapturingExecutor,
        workdir: File.cwd!()
      )

    assert outcome.status in [:fail, :error]
    refute_received {:tool_execution, _, _, _, _}
  end
end
