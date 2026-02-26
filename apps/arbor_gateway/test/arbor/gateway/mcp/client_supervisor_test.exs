defmodule Arbor.Gateway.MCP.ClientSupervisorTest do
  use ExUnit.Case, async: false

  alias Arbor.Gateway.MCP.ClientSupervisor

  @moduletag :fast

  setup do
    # Start a fresh supervisor for each test
    sup = start_supervised!(ClientSupervisor)
    %{supervisor: sup}
  end

  # Helper: start a connection that survives (command fails but GenServer stays alive)
  defp start_test_connection(name) do
    config = %{
      transport: :stdio,
      command: ["false"],
      auto_discover: false
    }

    {:ok, pid} = ClientSupervisor.start_connection(name, config)
    # Wait for the async connect attempt to fail
    Process.sleep(200)
    {:ok, pid}
  end

  describe "start_connection/2" do
    test "starts a connection child" do
      {:ok, pid} = start_test_connection("test_server")
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "each connection gets a unique process" do
      {:ok, pid1} = start_test_connection("server_a")
      {:ok, pid2} = start_test_connection("server_b")
      assert pid1 != pid2
    end
  end

  describe "list_connections/0" do
    test "returns empty list when no connections" do
      assert ClientSupervisor.list_connections() == []
    end

    test "includes started connections" do
      {:ok, _pid} = start_test_connection("listed_server")

      connections = ClientSupervisor.list_connections()
      names = Enum.map(connections, fn {name, _, _} -> name end)
      assert "listed_server" in names
    end

    test "shows disconnected status for failed connections" do
      {:ok, _pid} = start_test_connection("failed_conn")

      connections = ClientSupervisor.list_connections()

      case Enum.find(connections, fn {name, _, _} -> name == "failed_conn" end) do
        {_, _, status} -> assert status == :disconnected
        nil -> flunk("Connection not found in list")
      end
    end
  end

  describe "find_connection/1" do
    test "finds existing connection by name" do
      {:ok, pid} = start_test_connection("findable")
      assert {:ok, ^pid} = ClientSupervisor.find_connection("findable")
    end

    test "returns :error for unknown server" do
      assert :error = ClientSupervisor.find_connection("nonexistent")
    end
  end

  describe "stop_connection/1" do
    test "stops an existing connection" do
      {:ok, pid} = start_test_connection("stoppable")

      assert :ok = ClientSupervisor.stop_connection("stoppable")

      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "returns error for unknown server" do
      assert {:error, :not_found} = ClientSupervisor.stop_connection("ghost")
    end
  end
end
