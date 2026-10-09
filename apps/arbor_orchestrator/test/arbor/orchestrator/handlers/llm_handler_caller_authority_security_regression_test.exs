defmodule Arbor.Orchestrator.Handlers.LlmHandlerCallerAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :isolated_repo
  @moduletag :security_regression

  alias Arbor.Contracts.Security.{Capability, SignedRequest}
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
          test_pid = Application.fetch_env!(:arbor_orchestrator, :llm_authority_test_pid)
          send(test_pid, {:scoped_tool_result, tool_result.content})
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
    previous_test_pid = Application.get_env(:arbor_orchestrator, :llm_authority_test_pid)
    Application.put_env(:arbor_orchestrator, :security_module, Arbor.Security)
    Application.put_env(:arbor_orchestrator, :llm_authority_test_pid, self())

    on_exit(fn ->
      if previous_security do
        Application.put_env(:arbor_orchestrator, :security_module, previous_security)
      else
        Application.delete_env(:arbor_orchestrator, :security_module)
      end

      if previous_test_pid do
        Application.put_env(:arbor_orchestrator, :llm_authority_test_pid, previous_test_pid)
      else
        Application.delete_env(:arbor_orchestrator, :llm_authority_test_pid)
      end
    end)

    :ok
  end

  test "security regression: scoped LLM tool calls retain caller authority after dispatch" do
    suffix = System.unique_integer([:positive])
    {:ok, executor} = Arbor.Security.generate_identity()
    :ok = Arbor.Security.register_identity_fixture(executor)
    execution_principal = executor.agent_id
    caller_id = "human_tool_caller_#{suffix}"
    author_id = "agent_pipeline_author_#{suffix}"
    task_id = "task_tool_scope_#{suffix}"
    session_id = "session_tool_scope_#{suffix}"
    resource = Arbor.Actions.canonical_uri_for(Arbor.Actions.Tool.Help, %{})

    execution_capability =
      grant_scoped_capability(execution_principal, resource, task_id, session_id)

    caller_capability = grant_scoped_capability(caller_id, resource, task_id, session_id)

    on_exit(fn ->
      Arbor.Security.revoke_fixture(execution_capability.id)
      Arbor.Security.revoke_fixture(caller_capability.id)
      Arbor.Security.deregister_identity_fixture(executor.agent_id)
    end)

    :ok = ensure_grant_owner!()
    previous_enforcer = Application.get_env(:arbor_trust, :policy_enforcer_enabled)
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)

    on_exit(fn ->
      if is_nil(previous_enforcer) do
        Application.delete_env(:arbor_trust, :policy_enforcer_enabled)
      else
        Application.put_env(:arbor_trust, :policy_enforcer_enabled, previous_enforcer)
      end
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

    graph = Arbor.Orchestrator.IR.Compiler.compile!(graph)
    node = Map.fetch!(graph.nodes, node.id)

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
      workdir: File.cwd!(),
      signer: fn payload ->
        SignedRequest.sign(payload, executor.agent_id, executor.private_key)
      end
    ]

    assert %{status: :success} = LlmHandler.execute(node, context, graph, opts)
    assert_receive {:scoped_tool_result, allowed_result}
    assert allowed_result =~ "file_read"
    refute allowed_result =~ "lacks authority"

    assert :ok = Arbor.Security.revoke_fixture(caller_capability.id)

    assert %{status: :success} = LlmHandler.execute(node, context, graph, opts)
    assert_receive {:scoped_tool_result, denied_result}
    assert denied_result =~ "Caller #{caller_id} lacks authority"
    assert denied_result =~ resource
  end

  defp ensure_grant_owner! do
    :ok = Arbor.Trust.restore_runtime_fixture()
    status = Arbor.Trust.CapabilityGrantOwner.status()

    status =
      cond do
        status.state == :ready ->
          status

        is_binary(status.principal_id) ->
          uri = Arbor.Trust.CapabilityGrantOwner.required_capability_uri()

          {:ok, _cap} =
            Arbor.Security.grant_fixture(principal: status.principal_id, resource: uri)

          Arbor.Trust.restart_capability_grant_owner_fixture()

        true ->
          status
      end

    unless match?(%{state: :ready}, status) do
      raise "trust grant owner is not ready: #{inspect(status)}"
    end

    :ok
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

    {:ok, :stored} = Arbor.Security.put_capability_fixture(capability)
    capability
  end

  defp ensure_started(module) do
    unless Process.whereis(module), do: start_supervised!({module, []})
  end

  defp ensure_registered(module) do
    case ActionRegistry.register_action(module) do
      :ok -> :ok
      # Already present (unlocked or core-locked by Registrar.register_core/0)
      {:error, :already_registered} -> :ok
      {:error, :core_locked} -> :ok
    end
  end
end
