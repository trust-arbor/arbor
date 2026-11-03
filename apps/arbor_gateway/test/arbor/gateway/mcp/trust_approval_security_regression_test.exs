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

    defp consult(agent_id, uri) do
      if pid = :persistent_term.get(:mcp_trust_regression_test_pid, nil) do
        send(pid, {:trust_policy_consulted, agent_id, uri})
      end

      :gated
    end
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
        }
      ]
    end

    def call_tool(name, args, pid) do
      send(pid, {:tool_executed, name, args})
      %{"content" => [%{"type" => "text", "text" => "deleted"}], "isError" => false}
    end

    def list_resources(_), do: []
    def read_resource(_, _), do: %{"contents" => []}
    def list_prompts(_), do: []
    def get_prompt(_, _, _), do: %{"messages" => []}
  end

  setup do
    start_supervised!(ClientSupervisor)
    :persistent_term.put(:mcp_trust_regression_test_pid, self())

    prev_policy = Application.get_env(:arbor_trust, :policy_module)
    prev_guard = Application.get_env(:arbor_trust, :approval_guard_enabled)

    Application.put_env(:arbor_trust, :policy_module, SpyPolicy)
    # config/test.exs sets approval_guard_enabled: false; prod defaults to true.
    Application.put_env(:arbor_trust, :approval_guard_enabled, true)

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
      restore(:arbor_trust, :policy_module, prev_policy)
      restore(:arbor_trust, :approval_guard_enabled, prev_guard)

      {:ok, caps} = Arbor.Security.list_capabilities(agent_id)
      for cap <- caps, do: Arbor.Security.revoke_fixture(cap.id)
      :ok = Arbor.Security.deregister_identity_fixture(agent_id)
      if Process.alive?(server_pid), do: GenServer.stop(server_pid, :normal, 1_000)
    end)

    %{agent_id: agent_id}
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
