defmodule Arbor.Gateway.MCP.OperatorMcpConnectSecurityRegressionTest do
  @moduledoc """
  Security regression: `Arbor.Gateway.connect_mcp_server/2` used to return
  `:ok` from `authorize_mcp_server_connect/2` when `:agent_id` was nil
  ("Operator connections without :agent_id are not gated"). Manager always
  passes an agent id today, but any other caller that omitted it reached an
  external MCP server with no approval check.

  A connect with no agent binding must carry explicit operator authority —
  the same `:actor_authority` gate `Arbor.Agent.set_mcp_config/3` requires.
  Without it the call is refused and no connection is started. With a live
  caller-owned signing authority the operator connect proceeds.
  """
  use ExUnit.Case, async: false

  alias Arbor.Gateway.MCP.ClientSupervisor
  alias ExMCP.Testing.MockServer

  @moduletag :integration
  @moduletag :security_regression

  setup do
    start_supervised!(ClientSupervisor)
    :ok
  end

  test "a connect with nil agent_id and no operator authority is refused" do
    for config <- [
          %{transport: :test, server: mock_server()},
          %{transport: :test, server: mock_server(), agent_id: nil},
          %{"transport" => "test", "server" => mock_server(), "agent_id" => nil}
        ] do
      assert {:error, :unauthorized} = Arbor.Gateway.connect_mcp_server("ungated", config)
      assert {:error, :not_found} = Arbor.Gateway.mcp_server_status("ungated")
    end
  end

  test "a connect with nil agent_id and operator actor_authority succeeds" do
    server = mock_server()
    authority = operator_authority!()

    assert {:ok, _pid} =
             Arbor.Gateway.connect_mcp_server("operator", %{
               transport: :test,
               server: server,
               actor_authority: authority,
               auto_discover: true
             })

    assert {:ok, %{connection_status: :connected}} =
             wait_until_connected!("operator")
  end

  defp mock_server do
    {:ok, pid} = MockServer.start_link(tools: [MockServer.sample_tool(name: "sample_tool")])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000) end)
    pid
  end

  defp operator_authority! do
    {:ok, identity} = Arbor.Security.generate_identity(name: "mcp-operator-connect")
    :ok = Arbor.Security.register_identity_fixture(identity)

    {:ok, proof} =
      Arbor.Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :mcp_operator_connect,
        owner: self()
      )

    {:ok, authority} =
      Arbor.Security.open_ephemeral_signing_authority(proof, identity.private_key)

    on_exit(fn ->
      _ = Arbor.Security.close_signing_authority(authority)
      _ = Arbor.Security.deregister_identity_fixture(identity.agent_id)
    end)

    authority
  end

  defp wait_until_connected!(server_name, attempts \\ 50)

  defp wait_until_connected!(server_name, 0) do
    flunk("MCP server #{server_name} never reached :connected")
  end

  defp wait_until_connected!(server_name, attempts) do
    case Arbor.Gateway.mcp_server_status(server_name) do
      {:ok, %{connection_status: :connected}} = ok ->
        ok

      _ ->
        Process.sleep(20)
        wait_until_connected!(server_name, attempts - 1)
    end
  end
end
