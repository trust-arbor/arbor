defmodule Arbor.Gateway.MCP.IntegrationTest do
  @moduledoc """
  Integration tests for the MCP client infrastructure using ExMCP's
  in-process test transport. Validates the full flow:

    connect → discover tools → call tool → taint result → disconnect

  No external processes or network needed.
  """
  use ExUnit.Case, async: false

  alias Arbor.Gateway.MCP.ClientConnection
  alias Arbor.Gateway.MCP.ClientSupervisor
  alias Arbor.Gateway.MCP.ResourceBridge
  alias Arbor.Gateway.MCP.ToolBridge
  alias ExMCP.Testing.MockServer

  @moduletag :integration

  setup do
    sup = start_supervised!(ClientSupervisor)
    %{supervisor: sup}
  end

  # Start a MockServer and register cleanup
  defp start_mock_server(opts \\ []) do
    {:ok, server_pid} = MockServer.start_link(opts)

    on_exit(fn ->
      if Process.alive?(server_pid), do: GenServer.stop(server_pid, :normal, 1_000)
    end)

    server_pid
  end

  describe "full lifecycle with mock MCP server" do
    test "connects, discovers tools, and calls a tool" do
      server_pid =
        start_mock_server(
          tools: [
            MockServer.sample_tool(
              name: "get_weather",
              description: "Get weather for a city"
            )
          ]
        )

      config = %{
        server_name: "weather_service",
        transport: :test,
        server: server_pid,
        auto_discover: true
      }

      {:ok, conn} = start_supervised({ClientConnection, config}, id: :weather_conn)
      Process.sleep(500)

      # Verify connection status
      {:ok, status} = ClientConnection.status(conn)
      assert status.connection_status == :connected
      assert status.server_name == "weather_service"
      assert status.tool_count == 1
      assert "get_weather" in status.tools

      # List tools
      {:ok, tools} = ClientConnection.list_tools(conn)
      assert length(tools) == 1
      assert hd(tools)["name"] == "get_weather"

      # Convert to Arbor format
      arbor_tools = ToolBridge.to_arbor_tools("weather_service", tools)
      assert length(arbor_tools) == 1
      tool = hd(arbor_tools)
      assert tool.name == "mcp.weather_service.get_weather"
      assert tool.capability_uri == "arbor://mcp/weather_service/get_weather"
      assert tool.source == :mcp

      # Call the tool (MockServer's default_tool_call handles "sample_tool" name,
      # other names return a "Tool not found" message — still a valid response)
      {:ok, result} = ClientConnection.call_tool(conn, "get_weather", %{"input" => "NYC"})
      assert result != nil

      # Taint the result
      tainted = ToolBridge.taint_result(result, "weather_service", "get_weather")
      assert tainted.taint.level == :untrusted
      assert tainted.taint.source == "mcp:weather_service/get_weather"

      # Disconnect
      assert :ok = ClientConnection.disconnect(conn)
      {:ok, status} = ClientConnection.status(conn)
      assert status.connection_status == :disconnected
    end

    test "connection survives disconnect" do
      server_pid = start_mock_server()

      config = %{
        server_name: "ephemeral",
        transport: :test,
        server: server_pid,
        auto_discover: true
      }

      {:ok, conn} = start_supervised({ClientConnection, config}, id: :ephemeral_conn)
      Process.sleep(500)

      {:ok, status} = ClientConnection.status(conn)
      assert status.connection_status == :connected

      # Connection process should survive even if we disconnect
      ClientConnection.disconnect(conn)
      assert Process.alive?(conn)

      {:ok, status} = ClientConnection.status(conn)
      assert status.connection_status == :disconnected
    end

    test "multiple tools discovered from single server" do
      server_pid =
        start_mock_server(
          tools: [
            MockServer.sample_tool(name: "read_file"),
            MockServer.sample_tool(name: "write_file"),
            MockServer.sample_tool(name: "list_dir")
          ]
        )

      config = %{
        server_name: "filesystem",
        transport: :test,
        server: server_pid,
        auto_discover: true
      }

      {:ok, conn} = start_supervised({ClientConnection, config}, id: :fs_conn)
      Process.sleep(500)

      {:ok, status} = ClientConnection.status(conn)
      assert status.tool_count == 3
      assert "read_file" in status.tools
      assert "write_file" in status.tools
      assert "list_dir" in status.tools

      # All convert to Arbor format correctly
      {:ok, tools} = ClientConnection.list_tools(conn)
      arbor_tools = ToolBridge.to_arbor_tools("filesystem", tools)
      names = Enum.map(arbor_tools, & &1.name)
      assert "mcp.filesystem.read_file" in names
      assert "mcp.filesystem.write_file" in names
      assert "mcp.filesystem.list_dir" in names
    end

    test "supervisor manages connections" do
      server_pid =
        start_mock_server(tools: [MockServer.sample_tool(name: "tool_a")])

      config = %{
        transport: :test,
        server: server_pid,
        auto_discover: true
      }

      {:ok, pid} = ClientSupervisor.start_connection("supervised_server", config)
      Process.sleep(500)

      # Find via supervisor
      assert {:ok, ^pid} = ClientSupervisor.find_connection("supervised_server")

      # List shows connection
      connections = ClientSupervisor.list_connections()
      names = Enum.map(connections, fn {name, _, _} -> name end)
      assert "supervised_server" in names

      # Stop via supervisor
      assert :ok = ClientSupervisor.stop_connection("supervised_server")
      Process.sleep(100)
      assert :error = ClientSupervisor.find_connection("supervised_server")
    end

    test "refresh_tools updates cached tool list" do
      server_pid =
        start_mock_server(tools: [MockServer.sample_tool(name: "initial_tool")])

      config = %{
        server_name: "refreshable",
        transport: :test,
        server: server_pid,
        auto_discover: true
      }

      {:ok, conn} = start_supervised({ClientConnection, config}, id: :refresh_conn)
      Process.sleep(500)

      {:ok, tools} = ClientConnection.list_tools(conn)
      assert length(tools) == 1

      # Refresh should succeed (returns same tools since server is static)
      {:ok, refreshed} = ClientConnection.refresh_tools(conn)
      assert length(refreshed) == 1
    end
  end

  describe "facade integration" do
    test "call_mcp_tool wraps result with taint" do
      # Use "sample_tool" name so MockServer's default_tool_call handles it
      server_pid =
        start_mock_server(tools: [MockServer.sample_tool(name: "sample_tool")])

      config = %{transport: :test, server: server_pid, auto_discover: true}
      {:ok, _pid} = ClientSupervisor.start_connection("db_server", config)
      Process.sleep(500)

      # Call through facade — "sample_tool" returns "Processed: <input>"
      {:ok, result} =
        Arbor.Gateway.call_mcp_tool("db_server", "sample_tool", %{"input" => "SELECT 1"})

      assert Map.has_key?(result, :value)
      assert Map.has_key?(result, :taint)
      assert result.taint.level == :untrusted
      assert result.taint.source == "mcp:db_server/sample_tool"
    end

    test "list_mcp_tools returns Arbor-formatted tools" do
      server_pid =
        start_mock_server(
          tools: [
            MockServer.sample_tool(name: "search"),
            MockServer.sample_tool(name: "index")
          ]
        )

      config = %{transport: :test, server: server_pid, auto_discover: true}
      {:ok, _pid} = ClientSupervisor.start_connection("search_engine", config)
      Process.sleep(500)

      tools = Arbor.Gateway.list_mcp_tools("search_engine")
      assert length(tools) == 2

      names = Enum.map(tools, & &1.name)
      assert "mcp.search_engine.search" in names
      assert "mcp.search_engine.index" in names

      # All have capability URIs
      uris = Enum.map(tools, & &1.capability_uri)
      assert "arbor://mcp/search_engine/search" in uris
    end

    test "list_mcp_connections shows connected servers" do
      server_pid = start_mock_server()

      config = %{transport: :test, server: server_pid, auto_discover: true}
      {:ok, _} = ClientSupervisor.start_connection("live_server", config)
      Process.sleep(500)

      connections = Arbor.Gateway.list_mcp_connections()
      server_names = Enum.map(connections, fn {name, _, _} -> name end)
      assert "live_server" in server_names

      statuses = Enum.map(connections, fn {_, _, status} -> status end)
      assert :connected in statuses
    end

    test "mcp_server_status returns detailed status" do
      server_pid =
        start_mock_server(tools: [MockServer.sample_tool(name: "test")])

      config = %{transport: :test, server: server_pid, auto_discover: true}
      {:ok, _} = ClientSupervisor.start_connection("status_server", config)
      Process.sleep(500)

      {:ok, status} = Arbor.Gateway.mcp_server_status("status_server")
      assert status.server_name == "status_server"
      assert status.connection_status == :connected
      assert status.tool_count == 1
    end

    test "call_mcp_tool returns error for unknown server" do
      assert {:error, {:not_connected, "ghost"}} =
               Arbor.Gateway.call_mcp_tool("ghost", "tool", %{})
    end
  end

  # ===========================================================================
  # Resource discovery and access
  # ===========================================================================

  describe "resource discovery" do
    test "resources are discovered on connect" do
      server_pid =
        start_mock_server(
          resources: [
            MockServer.sample_resource(
              uri: "file://config.json",
              name: "Config"
            )
          ]
        )

      config = %{
        server_name: "res_server",
        transport: :test,
        server: server_pid,
        auto_discover: true
      }

      {:ok, conn} = start_supervised({ClientConnection, config}, id: :res_conn)
      Process.sleep(500)

      {:ok, status} = ClientConnection.status(conn)
      assert status.connection_status == :connected
      assert status.resource_count == 1
      assert "Config" in status.resources
    end

    test "multiple resources discovered" do
      server_pid =
        start_mock_server(
          resources: [
            MockServer.sample_resource(uri: "file://config.json", name: "Config"),
            MockServer.sample_resource(uri: "file://schema.sql", name: "Schema"),
            MockServer.sample_resource(uri: "file://readme.md", name: "Readme")
          ]
        )

      config = %{
        server_name: "multi_res",
        transport: :test,
        server: server_pid,
        auto_discover: true
      }

      {:ok, conn} = start_supervised({ClientConnection, config}, id: :multi_res_conn)
      Process.sleep(500)

      {:ok, resources} = ClientConnection.list_resources(conn)
      assert length(resources) == 3
      names = Enum.map(resources, & &1["name"])
      assert "Config" in names
      assert "Schema" in names
      assert "Readme" in names
    end

    test "list_resources returns error when disconnected" do
      server_pid = start_mock_server()

      config = %{
        server_name: "disconn_res",
        transport: :test,
        server: server_pid,
        auto_discover: true
      }

      {:ok, conn} = start_supervised({ClientConnection, config}, id: :disconn_res_conn)
      Process.sleep(500)

      ClientConnection.disconnect(conn)

      assert {:error, {:not_connected, :disconnected}} = ClientConnection.list_resources(conn)
    end

    test "refresh_resources updates cached list" do
      server_pid =
        start_mock_server(resources: [MockServer.sample_resource(name: "InitialResource")])

      config = %{
        server_name: "refresh_res",
        transport: :test,
        server: server_pid,
        auto_discover: true
      }

      {:ok, conn} = start_supervised({ClientConnection, config}, id: :refresh_res_conn)
      Process.sleep(500)

      {:ok, resources} = ClientConnection.list_resources(conn)
      assert length(resources) == 1

      {:ok, refreshed} = ClientConnection.refresh_resources(conn)
      assert length(refreshed) == 1
    end

    test "resources cleared on disconnect" do
      server_pid =
        start_mock_server(resources: [MockServer.sample_resource(name: "Clearable")])

      config = %{
        server_name: "clear_res",
        transport: :test,
        server: server_pid,
        auto_discover: true
      }

      {:ok, conn} = start_supervised({ClientConnection, config}, id: :clear_res_conn)
      Process.sleep(500)

      {:ok, resources} = ClientConnection.list_resources(conn)
      assert length(resources) == 1

      ClientConnection.disconnect(conn)
      {:ok, status} = ClientConnection.status(conn)
      assert status.resource_count == 0
    end
  end

  describe "resource reading" do
    test "read_resource returns content" do
      server_pid =
        start_mock_server(resources: [MockServer.sample_resource()])

      config = %{
        server_name: "readable",
        transport: :test,
        server: server_pid,
        auto_discover: true
      }

      {:ok, conn} = start_supervised({ClientConnection, config}, id: :readable_conn)
      Process.sleep(500)

      # MockServer's default_resource_read returns content for file://sample_data.txt
      {:ok, contents} = ClientConnection.read_resource(conn, "file://sample_data.txt")
      assert is_list(contents)
      assert contents != []

      # Content should have uri and text
      content = hd(contents)
      assert Map.has_key?(content, "uri")
    end

    test "read_resource returns error when disconnected" do
      server_pid = start_mock_server()

      config = %{
        server_name: "unread",
        transport: :test,
        server: server_pid,
        auto_discover: true
      }

      {:ok, conn} = start_supervised({ClientConnection, config}, id: :unread_conn)
      Process.sleep(500)

      ClientConnection.disconnect(conn)

      assert {:error, {:not_connected, :disconnected}} =
               ClientConnection.read_resource(conn, "file://anything")
    end
  end

  describe "resource bridge conversion" do
    test "to_arbor_resources converts MCP resources" do
      mcp_resources = [
        %{"uri" => "file://data.csv", "name" => "Data", "description" => "CSV data"},
        %{"uri" => "db://users", "name" => "Users", "mimeType" => "application/json"}
      ]

      arbor = ResourceBridge.to_arbor_resources("myserver", mcp_resources)
      assert length(arbor) == 2

      data = Enum.find(arbor, &(&1.name == "Data"))
      assert data.uri == "file://data.csv"
      assert data.description == "CSV data"
      assert data.source == :mcp
      assert data.server_name == "myserver"
      assert data.capability_uri == "arbor://mcp/myserver/resource/Data"

      users = Enum.find(arbor, &(&1.name == "Users"))
      assert users.uri == "db://users"
      assert users.mime_type == "application/json"
    end

    test "taint_contents wraps resource content" do
      contents = [%{"uri" => "file://test.txt", "text" => "hello"}]
      tainted = ResourceBridge.taint_contents(contents, "fs", "file://test.txt")

      assert tainted.value == contents
      assert tainted.taint.level == :untrusted
      assert tainted.taint.source == "mcp:fs/resource/file://test.txt"
      assert tainted.taint.sanitizations == 0
    end

    test "capability_uri follows convention" do
      assert ResourceBridge.capability_uri("github", "repo_readme") ==
               "arbor://mcp/github/resource/repo_readme"
    end
  end

  describe "resource facade integration" do
    test "list_mcp_resources returns Arbor-formatted resources" do
      server_pid =
        start_mock_server(
          resources: [
            MockServer.sample_resource(uri: "file://a.txt", name: "FileA"),
            MockServer.sample_resource(uri: "file://b.txt", name: "FileB")
          ]
        )

      config = %{transport: :test, server: server_pid, auto_discover: true}
      {:ok, _} = ClientSupervisor.start_connection("res_facade", config)
      Process.sleep(500)

      resources = Arbor.Gateway.list_mcp_resources("res_facade")
      assert length(resources) == 2

      names = Enum.map(resources, & &1.name)
      assert "FileA" in names
      assert "FileB" in names

      uris = Enum.map(resources, & &1.capability_uri)
      assert "arbor://mcp/res_facade/resource/FileA" in uris
    end

    test "list_mcp_resources aggregates from all servers" do
      server1 = start_mock_server(resources: [MockServer.sample_resource(name: "Res1")])
      server2 = start_mock_server(resources: [MockServer.sample_resource(name: "Res2")])

      {:ok, _} =
        ClientSupervisor.start_connection("srv1", %{
          transport: :test,
          server: server1,
          auto_discover: true
        })

      {:ok, _} =
        ClientSupervisor.start_connection("srv2", %{
          transport: :test,
          server: server2,
          auto_discover: true
        })

      Process.sleep(500)

      resources = Arbor.Gateway.list_mcp_resources()
      names = Enum.map(resources, & &1.name)
      assert "Res1" in names
      assert "Res2" in names
    end

    test "read_mcp_resource wraps result with taint" do
      server_pid = start_mock_server(resources: [MockServer.sample_resource()])

      config = %{transport: :test, server: server_pid, auto_discover: true}
      {:ok, _} = ClientSupervisor.start_connection("taint_res", config)
      Process.sleep(500)

      {:ok, result} = Arbor.Gateway.read_mcp_resource("taint_res", "file://sample_data.txt")

      assert Map.has_key?(result, :value)
      assert Map.has_key?(result, :taint)
      assert result.taint.level == :untrusted
      assert result.taint.source =~ "mcp:taint_res/resource/"
    end

    test "read_mcp_resource returns error for unknown server" do
      assert {:error, {:not_connected, "ghost_res"}} =
               Arbor.Gateway.read_mcp_resource("ghost_res", "file://anything")
    end

    test "mcp_server_status includes resource count" do
      server_pid =
        start_mock_server(
          tools: [MockServer.sample_tool(name: "t1")],
          resources: [MockServer.sample_resource(name: "r1")]
        )

      config = %{transport: :test, server: server_pid, auto_discover: true}
      {:ok, _} = ClientSupervisor.start_connection("status_res", config)
      Process.sleep(500)

      {:ok, status} = Arbor.Gateway.mcp_server_status("status_res")
      assert status.tool_count == 1
      assert status.resource_count == 1
      assert "r1" in status.resources
    end
  end
end
