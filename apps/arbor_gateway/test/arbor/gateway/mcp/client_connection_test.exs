defmodule Arbor.Gateway.MCP.ClientConnectionTest do
  use ExUnit.Case, async: true

  alias Arbor.Gateway.MCP.ClientConnection

  @moduletag :fast

  # Helper: start a connection that won't actually connect to anything.
  # The process stays alive in :disconnected state since ExMCP fails gracefully.
  defp start_test_connection(name, extra \\ %{}) do
    config =
      Map.merge(
        %{
          server_name: name,
          transport: :stdio,
          command: ["false"],
          auto_discover: false
        },
        extra
      )

    {:ok, pid} = start_supervised({ClientConnection, config}, id: name)

    # Wait for the async connect attempt to fail
    Process.sleep(200)

    {:ok, pid}
  end

  describe "start_link/1 and status" do
    test "initializes and survives failed connection" do
      {:ok, pid} = start_test_connection("test_server")

      assert Process.alive?(pid)
      {:ok, status} = ClientConnection.status(pid)
      assert status.server_name == "test_server"
      # Connection failed but process survived
      assert status.connection_status == :disconnected
    end

    test "reports server_name" do
      {:ok, pid} = start_test_connection("my_server")
      assert ClientConnection.server_name(pid) == "my_server"
    end

    test "stores agent_id from config" do
      {:ok, pid} = start_test_connection("scoped", %{agent_id: "agent_abc123"})
      {:ok, status} = ClientConnection.status(pid)
      assert status.agent_id == "agent_abc123"
    end

    test "tracks connect attempts" do
      {:ok, pid} = start_test_connection("retry_tracker")
      {:ok, status} = ClientConnection.status(pid)
      assert status.connect_attempts >= 1
    end

    test "records last error" do
      {:ok, pid} = start_test_connection("error_tracker")
      {:ok, status} = ClientConnection.status(pid)
      assert status.last_error != nil
    end
  end

  describe "list_tools/1 when disconnected" do
    test "returns not_connected error" do
      {:ok, pid} = start_test_connection("offline_tools")
      assert {:error, {:not_connected, :disconnected}} = ClientConnection.list_tools(pid)
    end
  end

  describe "call_tool/4 when disconnected" do
    test "returns not_connected error" do
      {:ok, pid} = start_test_connection("offline_call")

      assert {:error, {:not_connected, :disconnected}} =
               ClientConnection.call_tool(pid, "some_tool", %{}, timeout: 1_000)
    end
  end

  describe "refresh_tools/1 when disconnected" do
    test "returns not_connected error" do
      {:ok, pid} = start_test_connection("offline_refresh")
      assert {:error, {:not_connected, :disconnected}} = ClientConnection.refresh_tools(pid)
    end
  end

  describe "disconnect/1" do
    test "can be called when already disconnected" do
      {:ok, pid} = start_test_connection("already_disconnected")
      assert :ok = ClientConnection.disconnect(pid)
      {:ok, status} = ClientConnection.status(pid)
      assert status.connection_status == :disconnected
    end
  end

  describe "child_spec/1" do
    test "builds correct child spec" do
      config = %{server_name: "test"}
      spec = ClientConnection.child_spec(config)

      assert spec.id == {ClientConnection, "test"}
      assert spec.restart == :transient
      assert spec.shutdown == 5_000
    end
  end
end
