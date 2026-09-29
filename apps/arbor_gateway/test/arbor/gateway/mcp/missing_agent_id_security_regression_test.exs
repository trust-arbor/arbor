defmodule Arbor.Gateway.MCP.MissingAgentIdSecurityRegressionTest do
  @moduledoc """
  Security regression (Imp review D2, 2026-09-27): `Arbor.Gateway.call_mcp_tool/4`
  and `read_mcp_resource/3` skipped capability authorization entirely when
  `:agent_id` was nil (`defp maybe_authorize(nil, ...) -> :ok`), so any caller
  that dropped the option reached a connected external MCP server with no
  check at all. `skip_auth: true` is the one explicit bypass; a missing or
  blank agent id must deny.

  Asserted through the public facade against a real connected (in-process)
  MCP server: pre-fix these calls return `{:ok, _}` because the tool/resource
  actually runs; post-fix they return `{:error, :missing_agent_id}`.
  Do not delete as redundant with `gateway_facade_test.exs` — those cases hit
  an unconnected server and could not show the tool being reached.
  """
  use ExUnit.Case, async: false

  alias Arbor.Gateway.MCP.ClientSupervisor
  alias ExMCP.Testing.MockServer

  @moduletag :integration

  @server "d2_regression_server"

  setup do
    start_supervised!(ClientSupervisor)

    {:ok, server_pid} =
      MockServer.start_link(
        tools: [MockServer.sample_tool(name: "sample_tool")],
        resources: [MockServer.sample_resource()]
      )

    on_exit(fn ->
      if Process.alive?(server_pid), do: GenServer.stop(server_pid, :normal, 1_000)
    end)

    {:ok, _} =
      ClientSupervisor.start_connection(@server, %{
        transport: :test,
        server: server_pid,
        auto_discover: true
      })

    wait_until_connected!(@server)
    :ok
  end

  describe "security regression: call_mcp_tool without agent_id" do
    test "omitted agent_id is denied, not silently authorized" do
      assert {:error, :missing_agent_id} =
               Arbor.Gateway.call_mcp_tool(@server, "sample_tool", %{"input" => "x"})
    end

    test "explicit nil and blank agent_id are denied" do
      for agent_id <- [nil, ""] do
        assert {:error, :missing_agent_id} =
                 Arbor.Gateway.call_mcp_tool(@server, "sample_tool", %{"input" => "x"},
                   agent_id: agent_id
                 )
      end
    end

    test "only the literal skip_auth: true bypasses, truthy look-alikes do not" do
      for skip <- [false, nil, "true", :yes] do
        assert {:error, :missing_agent_id} =
                 Arbor.Gateway.call_mcp_tool(@server, "sample_tool", %{"input" => "x"},
                   skip_auth: skip
                 )
      end
    end

    test "explicit skip_auth: true still reaches the tool (the documented bypass)" do
      assert {:ok, %{value: _, taint: %{level: :untrusted}}} =
               Arbor.Gateway.call_mcp_tool(@server, "sample_tool", %{"input" => "x"},
                 skip_auth: true
               )
    end
  end

  describe "security regression: read_mcp_resource without agent_id" do
    test "omitted agent_id is denied, not silently authorized" do
      assert {:error, :missing_agent_id} =
               Arbor.Gateway.read_mcp_resource(@server, "file://sample_data.txt")
    end

    test "explicit nil and blank agent_id are denied" do
      for agent_id <- [nil, ""] do
        assert {:error, :missing_agent_id} =
                 Arbor.Gateway.read_mcp_resource(@server, "file://sample_data.txt",
                   agent_id: agent_id
                 )
      end
    end

    test "explicit skip_auth: true still reaches the resource" do
      assert {:ok, %{value: _, taint: %{level: :untrusted}}} =
               Arbor.Gateway.read_mcp_resource(@server, "file://sample_data.txt", skip_auth: true)
    end
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
