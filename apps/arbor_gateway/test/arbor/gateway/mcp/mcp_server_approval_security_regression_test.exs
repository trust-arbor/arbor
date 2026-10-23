defmodule Arbor.Gateway.MCP.McpServerApprovalSecurityRegressionTest do
  @moduledoc """
  Security regression (Imp review D7, 2026-09-28): an agent-bound MCP
  connection spawns the configured stdio command or dials the configured URL
  as that agent, and `Arbor.Agent.Manager` connected every `mcp_servers` entry
  in profile metadata with no capability check. Anything that could write that
  metadata got process spawn on the agent's next start.

  `Arbor.Gateway.connect_mcp_server/2` now requires the agent to hold the exact
  approval for the config (`Arbor.Security.mcp_server_approval_uri/2`), which
  the operator's `Arbor.Agent.set_mcp_config/2` grants. Asserted with real
  Security grants and live in-process MCP servers. Pre-fix every refused case
  below returned `{:ok, pid}` and connected.
  """
  use ExUnit.Case, async: false

  alias Arbor.Gateway.MCP.ClientSupervisor
  alias ExMCP.Testing.MockServer

  @moduletag :integration

  setup do
    start_supervised!(ClientSupervisor)
    {:ok, identity} = Arbor.Security.generate_identity(name: "mcp-approval")
    :ok = Arbor.Security.register_identity_fixture(identity)

    on_exit(fn ->
      if Process.whereis(Arbor.Security.CapabilityStore),
        do: Arbor.Security.revoke_all_fixture(identity.agent_id)
    end)

    %{agent_id: identity.agent_id}
  end

  defp mock_server do
    {:ok, pid} = MockServer.start_link(tools: [MockServer.sample_tool(name: "sample_tool")])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000) end)
    pid
  end

  defp approve!(agent_id, name, config) do
    {:ok, uri} = Arbor.Security.mcp_server_approval_uri(name, config)
    {:ok, _cap} = Arbor.Security.grant_fixture(principal: agent_id, resource: uri)
  end

  test "an unapproved agent-bound server is refused and never started", %{agent_id: agent_id} do
    config = %{transport: :test, server: mock_server(), agent_id: agent_id}

    assert {:error, :mcp_server_not_approved} =
             Arbor.Gateway.connect_mcp_server("unapproved", config)

    assert {:error, :not_found} = Arbor.Gateway.mcp_server_status("unapproved")
  end

  test "string-keyed agent binding (profile metadata shape) is gated too", %{agent_id: agent_id} do
    config = %{"transport" => "test", "server" => mock_server(), "agent_id" => agent_id}

    assert {:error, :mcp_server_not_approved} =
             Arbor.Gateway.connect_mcp_server("unapproved_str", config)
  end

  test "an approval for one config does not cover an edited config", %{agent_id: agent_id} do
    approved = %{transport: :test, server: mock_server()}
    approve!(agent_id, "swap", approved)

    edited = %{transport: :test, server: mock_server(), agent_id: agent_id}

    assert {:error, :mcp_server_not_approved} = Arbor.Gateway.connect_mcp_server("swap", edited)
  end

  test "the exact approved config connects", %{agent_id: agent_id} do
    server = mock_server()
    approve!(agent_id, "approved", %{transport: :test, server: server})

    assert {:ok, _pid} =
             Arbor.Gateway.connect_mcp_server("approved", %{
               transport: :test,
               server: server,
               agent_id: agent_id,
               server_name: "approved",
               auto_discover: true
             })
  end

  test "operator connections without an agent binding require actor_authority" do
    assert {:error, :unauthorized} =
             Arbor.Gateway.connect_mcp_server("operator", %{
               transport: :test,
               server: mock_server()
             })
  end
end
