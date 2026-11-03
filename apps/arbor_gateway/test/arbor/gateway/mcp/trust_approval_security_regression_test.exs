defmodule Arbor.Gateway.MCP.TrustApprovalSecurityRegressionTest do
  @moduledoc """
  Security regression: agent-initiated MCP tool calls through
  `Arbor.Gateway.call_mcp_tool/4` only checked `Arbor.Security.authorize/3`
  (ToolBridge.authorize/3). They never reached `Arbor.Trust.authorize/4` or
  ApprovalGuard, so the default `:cautious` baseline `:ask` never applied.

  A destructive mock tool with `destructiveHint: true` must not run unless
  Trust has been consulted. This test fails on the capability-only path
  (tool executes; spy policy is never called) and passes once the gateway
  routes MCP calls through Trust.
  """
  use ExUnit.Case, async: false

  alias Arbor.Gateway.MCP.ClientSupervisor
  alias ExMCP.Testing.MockServer

  @moduletag :integration

  @server "mcp_trust_regression_server"
  @tool "delete_everything"

  defmodule SpyPolicy do
    @moduledoc false

    def confirmation_mode(agent_id, uri, _opts), do: consult(agent_id, uri)
    def confirmation_mode(agent_id, uri), do: consult(agent_id, uri)

    def approve(agent_id, uri) do
      approved = :persistent_term.get(:mcp_trust_regression_approved, MapSet.new())
      :persistent_term.put(:mcp_trust_regression_approved, MapSet.put(approved, {agent_id, uri}))
    end

    defp consult(agent_id, uri) do
      if pid = :persistent_term.get(:mcp_trust_regression_test_pid, nil) do
        send(pid, {:trust_policy_consulted, agent_id, uri})
      end

      approved = :persistent_term.get(:mcp_trust_regression_approved, MapSet.new())

      # :cautious baseline :ask maps to ApprovalGuard :gated.
      if MapSet.member?(approved, {agent_id, uri}), do: :auto, else: :gated
    end
  end

  defmodule CapturingConsensus do
    @moduledoc false

    def submit(proposal, _opts \\ []) do
      id = "proposal_mcp_trust_#{System.unique_integer([:positive])}"

      send(
        :persistent_term.get(:mcp_trust_regression_test_pid, self()),
        {:proposal, id, proposal}
      )

      {:ok, id}
    end

    def healthy?, do: true
  end

  defmodule DestructiveHandler do
    @moduledoc false

    def list_tools(_pid) do
      [
        %{
          "name" => "delete_everything",
          "description" => "Deletes all data",
          "inputSchema" => %{"type" => "object", "properties" => %{}},
          "annotations" => %{"destructiveHint" => true, "readOnlyHint" => false}
        },
        %{
          "name" => "looks_readonly",
          "description" => "Server claims this is read-only",
          "inputSchema" => %{"type" => "object", "properties" => %{}},
          "annotations" => %{"destructiveHint" => false, "readOnlyHint" => true}
        },
        %{
          "name" => "unannotated",
          "description" => "No MCP hints",
          "inputSchema" => %{"type" => "object", "properties" => %{}}
        }
      ]
    end

    def call_tool(name, args, pid) do
      send(pid, {:tool_executed, name, args})
      %{"content" => [%{"type" => "text", "text" => "ran:#{name}"}], "isError" => false}
    end

    def list_resources(_) do
      [%{"uri" => "file://secret.txt", "name" => "secret.txt", "description" => "Secret"}]
    end

    def read_resource(uri, pid) do
      send(pid, {:resource_read, uri})
      %{"contents" => [%{"uri" => uri, "text" => "secret"}]}
    end

    def list_prompts(_), do: []
    def get_prompt(_, _, _), do: %{"messages" => []}
  end

  setup do
    start_supervised!(ClientSupervisor)
    :persistent_term.put(:mcp_trust_regression_test_pid, self())

    prev_policy = Application.get_env(:arbor_trust, :policy_module)
    prev_guard = Application.get_env(:arbor_trust, :approval_guard_enabled)
    prev_escalation = Application.get_env(:arbor_capabilities, :consensus_escalation_enabled)
    prev_consensus = Application.get_env(:arbor_capabilities, :consensus_module)
    prev_router = Application.get_env(:arbor_capabilities, :use_interaction_router_for_approval)

    Application.put_env(:arbor_trust, :policy_module, SpyPolicy)
    # config/test.exs sets approval_guard_enabled: false; prod defaults to true.
    Application.put_env(:arbor_trust, :approval_guard_enabled, true)
    :persistent_term.put(:mcp_trust_regression_approved, MapSet.new())

    {:ok, server_pid} =
      MockServer.start_link(handler: DestructiveHandler, state: self())

    {:ok, _} =
      ClientSupervisor.start_connection(@server, %{
        transport: :test,
        server: server_pid,
        auto_discover: true
      })

    wait_until_connected!(@server)

    {:ok, identity} = Arbor.Security.generate_identity(name: "mcp-trust-regression")
    :ok = Arbor.Security.register_identity_fixture(identity)
    agent_id = identity.agent_id

    on_exit(fn ->
      :persistent_term.erase(:mcp_trust_regression_test_pid)
      :persistent_term.erase(:mcp_trust_regression_approved)
      restore(:arbor_trust, :policy_module, prev_policy)
      restore(:arbor_trust, :approval_guard_enabled, prev_guard)
      restore(:arbor_capabilities, :consensus_escalation_enabled, prev_escalation)
      restore(:arbor_capabilities, :consensus_module, prev_consensus)
      restore(:arbor_capabilities, :use_interaction_router_for_approval, prev_router)

      {:ok, caps} = Arbor.Security.list_capabilities(agent_id)
      for cap <- caps, do: Arbor.Security.revoke_fixture(cap.id)
      :ok = Arbor.Security.deregister_identity_fixture(agent_id)
      if Process.alive?(server_pid), do: GenServer.stop(server_pid, :normal, 1_000)
    end)

    %{
      agent_id: agent_id,
      enable_consensus: fn ->
        Application.put_env(:arbor_capabilities, :consensus_escalation_enabled, true)
        Application.put_env(:arbor_capabilities, :consensus_module, CapturingConsensus)
        Application.put_env(:arbor_capabilities, :use_interaction_router_for_approval, false)
      end
    }
  end

  test "security regression: destructive MCP tool does not run without consulting Trust",
       %{agent_id: agent_id} do
    uri = "arbor://mcp/#{@server}/#{@tool}"
    {:ok, _cap} = Arbor.Security.grant_fixture(principal: agent_id, resource: uri)

    result = Arbor.Gateway.call_mcp_tool(@server, @tool, %{}, agent_id: agent_id)

    refute match?({:ok, %{value: _}}, result),
           "destructive MCP tool ran on a capability-only grant: #{inspect(result, limit: 8)}"

    assert_receive {:trust_policy_consulted, ^agent_id, ^uri}, 1_000
    refute_received {:tool_executed, _, _}
  end

  test "listed MCP tools keep server hint annotations" do
    tools = Arbor.Gateway.list_mcp_tools(@server)
    destructive = Enum.find(tools, &(&1.mcp_tool_name == @tool))
    readonly = Enum.find(tools, &(&1.mcp_tool_name == "looks_readonly"))
    unannotated = Enum.find(tools, &(&1.mcp_tool_name == "unannotated"))

    assert destructive.annotations["destructiveHint"] == true
    assert destructive.annotations["readOnlyHint"] == false
    assert readonly.annotations["readOnlyHint"] == true
    assert unannotated.annotations == %{}
  end

  test "under :cautious, a gateway tool call is pending until approved",
       %{agent_id: agent_id, enable_consensus: enable_consensus} do
    enable_consensus.()
    uri = "arbor://mcp/#{@server}/#{@tool}"
    {:ok, _cap} = Arbor.Security.grant_fixture(principal: agent_id, resource: uri)

    assert {:ok, :pending_approval, proposal_id} =
             Arbor.Gateway.call_mcp_tool(@server, @tool, %{}, agent_id: agent_id)

    assert is_binary(proposal_id) and proposal_id != ""
    assert_receive {:trust_policy_consulted, ^agent_id, ^uri}, 1_000
    refute_received {:tool_executed, _, _}

    SpyPolicy.approve(agent_id, uri)

    assert {:ok, %{value: _, taint: %{level: :untrusted}}} =
             Arbor.Gateway.call_mcp_tool(@server, @tool, %{}, agent_id: agent_id)

    assert_receive {:tool_executed, @tool, _}, 1_000
  end

  test "under :cautious, a gateway resource read is pending until approved",
       %{agent_id: agent_id, enable_consensus: enable_consensus} do
    enable_consensus.()
    uri = "arbor://mcp/#{@server}/resource/secret.txt"
    {:ok, _cap} = Arbor.Security.grant_fixture(principal: agent_id, resource: uri)

    assert {:ok, :pending_approval, proposal_id} =
             Arbor.Gateway.read_mcp_resource(@server, "file://secret.txt", agent_id: agent_id)

    assert is_binary(proposal_id) and proposal_id != ""
    assert_receive {:trust_policy_consulted, ^agent_id, ^uri}, 1_000
    refute_received {:resource_read, _}

    SpyPolicy.approve(agent_id, uri)

    assert {:ok, %{value: _, taint: %{level: :untrusted}}} =
             Arbor.Gateway.read_mcp_resource(@server, "file://secret.txt", agent_id: agent_id)

    assert_receive {:resource_read, "file://secret.txt"}, 1_000
  end

  test "readOnlyHint is advisory and never skips Trust approval",
       %{agent_id: agent_id, enable_consensus: enable_consensus} do
    enable_consensus.()
    uri = "arbor://mcp/#{@server}/looks_readonly"
    {:ok, _cap} = Arbor.Security.grant_fixture(principal: agent_id, resource: uri)

    assert {:ok, :pending_approval, _id} =
             Arbor.Gateway.call_mcp_tool(@server, "looks_readonly", %{}, agent_id: agent_id)

    assert_receive {:trust_policy_consulted, ^agent_id, ^uri}, 1_000
    refute_received {:tool_executed, _, _}
  end

  test "missing MCP hints are treated as destructive and stay gated",
       %{agent_id: agent_id, enable_consensus: enable_consensus} do
    enable_consensus.()
    uri = "arbor://mcp/#{@server}/unannotated"
    {:ok, _cap} = Arbor.Security.grant_fixture(principal: agent_id, resource: uri)

    assert {:ok, :pending_approval, _id} =
             Arbor.Gateway.call_mcp_tool(@server, "unannotated", %{}, agent_id: agent_id)

    assert_receive {:trust_policy_consulted, ^agent_id, ^uri}, 1_000
    refute_received {:tool_executed, _, _}
  end

  test "capability denial still refuses the tool without invoking it", %{agent_id: agent_id} do
    result =
      Arbor.Gateway.call_mcp_tool(@server, @tool, %{}, agent_id: agent_id)

    assert {:error, :unauthorized, _reason} = result
    refute_received {:tool_executed, _, _}
  end

  test "security regression: a receipt for args A cannot authorize args B",
       %{agent_id: agent_id} do
    uri = "arbor://mcp/#{@server}/#{@tool}"
    {:ok, _cap} = Arbor.Security.grant_fixture(principal: agent_id, resource: uri)

    args_a = %{"target" => "scratch"}
    args_b = %{"target" => "production"}
    {:ok, digest_a} = Arbor.Security.approval_argument_digest(args_a)

    {:ok, receipt} =
      Arbor.Security.issue_approval_receipt_fixture(
        agent_id,
        uri,
        :execute,
        digest_a,
        "irq_mcp_arg_binding"
      )

    mismatched =
      Arbor.Gateway.call_mcp_tool(@server, @tool, args_b,
        agent_id: agent_id,
        approved_invocation: receipt,
        argument_digest: digest_a
      )

    refute match?({:ok, %{value: _}}, mismatched),
           "receipt for #{inspect(args_a)} authorized different args: #{inspect(mismatched, limit: 8)}"

    refute_received {:tool_executed, @tool, ^args_b}

    assert {:ok, %{value: _, taint: %{level: :untrusted}}} =
             Arbor.Gateway.call_mcp_tool(@server, @tool, args_a,
               agent_id: agent_id,
               approved_invocation: receipt,
               argument_digest: digest_a
             )

    assert_receive {:tool_executed, @tool, ^args_a}, 1_000
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp wait_until_connected!(name, attempts \\ 100)
  defp wait_until_connected!(name, 0), do: flunk("#{name} never connected")

  defp wait_until_connected!(name, attempts) do
    case Arbor.Gateway.mcp_server_status(name) do
      {:ok, %{connection_status: :connected}} -> :ok
      _ -> Process.sleep(20) && wait_until_connected!(name, attempts - 1)
    end
  end
end
