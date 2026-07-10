defmodule Arbor.Orchestrator.Handlers.LlmHandlerCallerAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Contracts.Security.Capability
  alias Arbor.LLM.{Client, ContentPart, Request, Response}
  alias Arbor.Orchestrator.Engine.{Context, RunAuthorization}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.LlmHandler
  alias Arbor.Common.ActionRegistry
  alias Arbor.Security.CapabilityStore

  defmodule ScopedToolAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "llm_caller_scope_test"

    @impl true
    def complete(%Request{} = request, _opts) do
      case Enum.find(Enum.reverse(request.messages), &(&1.role == :tool)) do
        nil ->
          {:ok,
           %Response{
             text: "",
             finish_reason: :tool_calls,
             content_parts: [
               ContentPart.tool_call("scoped_call", "tool_help", %{"tool_name" => "file_read"})
             ],
             raw: %{}
           }}

        tool_result ->
          send(self(), {:scoped_tool_result, tool_result.content})
          {:ok, %Response{text: "tool round complete", finish_reason: :stop, raw: %{}}}
      end
    end
  end

  setup do
    ensure_started(CapabilityStore)
    ensure_started(ActionRegistry)
    ensure_registered(Arbor.Actions.Tool.Help)
    ensure_registered(Arbor.Actions.File.Read)

    previous_security = Application.get_env(:arbor_orchestrator, :security_module)
    Application.put_env(:arbor_orchestrator, :security_module, Arbor.Security)

    on_exit(fn ->
      if previous_security do
        Application.put_env(:arbor_orchestrator, :security_module, previous_security)
      else
        Application.delete_env(:arbor_orchestrator, :security_module)
      end
    end)

    :ok
  end

  test "security regression: scoped LLM tool calls retain caller authority after dispatch" do
    suffix = System.unique_integer([:positive])
    execution_principal = "agent_tool_executor_#{suffix}"
    caller_id = "human_tool_caller_#{suffix}"
    author_id = "agent_pipeline_author_#{suffix}"
    task_id = "task_tool_scope_#{suffix}"
    session_id = "session_tool_scope_#{suffix}"
    resource = Arbor.Actions.canonical_uri_for(Arbor.Actions.Tool.Help, %{})

    execution_capability =
      grant_scoped_capability(execution_principal, resource, task_id, session_id)

    caller_capability = grant_scoped_capability(caller_id, resource, task_id, session_id)

    on_exit(fn ->
      Arbor.Security.revoke(execution_capability.id)
      Arbor.Security.revoke(caller_capability.id)
    end)

    node =
      %Node{
        id: "scoped_llm_tool",
        attrs: %{
          "type" => "compute",
          "simulate" => "false",
          "prompt" => "Inspect the file_read tool",
          "use_tools" => "true",
          "tools" => "tool_help",
          "llm_provider" => ScopedToolAdapter.provider(),
          "llm_model" => "test"
        }
      }

    graph = %Graph{
      id: "scoped_llm_tool_graph",
      nodes: %{node.id => node},
      edges: [],
      attrs: %{"goal" => "exercise a scoped tool call"}
    }

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
        "session.llm_provider" => ScopedToolAdapter.provider(),
        "session.llm_model" => "test"
      })
      |> RunAuthorization.enforce_context(authority)

    client =
      Client.new(default_provider: ScopedToolAdapter.provider())
      |> Client.register_adapter(ScopedToolAdapter)

    opts = [
      authorization: true,
      run_authorization: authority,
      llm_client: client,
      workdir: File.cwd!()
    ]

    assert %{status: :success} = LlmHandler.execute(node, context, graph, opts)
    assert_receive {:scoped_tool_result, allowed_result}
    assert allowed_result =~ "file_read"
    refute allowed_result =~ "lacks authority"

    assert :ok = Arbor.Security.revoke(caller_capability.id)

    assert %{status: :success} = LlmHandler.execute(node, context, graph, opts)
    assert_receive {:scoped_tool_result, denied_result}
    assert denied_result =~ "Caller #{caller_id} lacks authority"
    assert denied_result =~ resource
  end

  defp grant_scoped_capability(principal_id, resource_uri, task_id, session_id) do
    {:ok, capability} =
      Capability.new(
        resource_uri: resource_uri,
        principal_id: principal_id,
        task_id: task_id,
        session_id: session_id,
        delegation_depth: 0,
        constraints: %{},
        metadata: %{test: true}
      )

    {:ok, :stored} = CapabilityStore.put(capability)
    capability
  end

  defp ensure_started(module) do
    unless Process.whereis(module), do: start_supervised!({module, []})
  end

  defp ensure_registered(module) do
    case ActionRegistry.register_action(module) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
    end
  end
end
