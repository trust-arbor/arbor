defmodule Arbor.Gateway.MCP.HandlerUntrustedLabelSecurityRegressionTest do
  @moduledoc """
  Security regression (Exposure Check AH / Log-To-Leak, 2026-10-29):

  `Handler.run_mcp_tool/4` pattern-matched `{:ok, %{value: value}}` and formatted
  only the inner value, dropping the untrusted label/taint envelope that
  `ToolBridge.taint_result/3` attached. The MCP success text that re-enters
  an agent or operator prompt must keep that label.
  """
  use ExUnit.Case, async: false

  alias Arbor.Gateway.MCP.ClientSupervisor
  alias Arbor.Gateway.MCP.Handler
  alias ExMCP.Testing.MockServer

  @moduletag :integration
  @moduletag :security_regression

  @server "untrusted_label_regression_server"

  setup do
    start_supervised!(ClientSupervisor)

    {:ok, server_pid} =
      MockServer.start_link(tools: [MockServer.sample_tool(name: "sample_tool")])

    {:ok, _} =
      ClientSupervisor.start_connection(@server, %{
        transport: :test,
        server: server_pid,
        auto_discover: true
      })

    wait_until_connected!(@server)

    {:ok, identity} = Arbor.Security.generate_identity(name: "mcp-untrusted-label")
    :ok = Arbor.Security.register_identity_fixture(identity)
    agent_id = identity.agent_id

    uri = "arbor://mcp/#{@server}/sample_tool"
    {:ok, _} = Arbor.Security.grant_fixture(principal: agent_id, resource: uri)

    Process.put(:arbor_authenticated_agent_id, agent_id)

    on_exit(fn ->
      Process.delete(:arbor_authenticated_agent_id)
      {:ok, caps} = Arbor.Security.list_capabilities(agent_id)
      for cap <- caps, do: Arbor.Security.revoke_fixture(cap.id)
      :ok = Arbor.Security.deregister_identity_fixture(agent_id)
      if Process.alive?(server_pid), do: GenServer.stop(server_pid, :normal, 1_000)
    end)

    %{agent_id: agent_id}
  end

  test "security regression: arbor_run MCP success keeps the untrusted label" do
    {:ok, %{content: [%{type: "text", text: text}]}, _state} =
      Handler.handle_call_tool(
        "arbor_run",
        %{
          "action" => "mcp.#{@server}.sample_tool",
          "params" => %{"input" => "hello"}
        },
        %{}
      )

    assert text =~ "Success"
    assert text =~ ~r/UNTRUSTED/i
    assert text =~ @server
    assert text =~ "sample_tool"
  end

  defp wait_until_connected!(server_name, attempts \\ 50)

  defp wait_until_connected!(server_name, 0) do
    flunk("MCP server #{server_name} never reached :connected")
  end

  defp wait_until_connected!(server_name, attempts) do
    case Arbor.Gateway.mcp_server_status(server_name) do
      {:ok, %{connection_status: :connected}} ->
        :ok

      _ ->
        Process.sleep(20)
        wait_until_connected!(server_name, attempts - 1)
    end
  end
end
