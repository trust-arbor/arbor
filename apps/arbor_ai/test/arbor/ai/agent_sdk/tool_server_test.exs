defmodule Arbor.AI.AgentSDK.ToolServerTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.AgentSDK.ToolServer

  # Define test tools module
  defmodule ServerTestTools do
    use Arbor.AI.AgentSDK.Tool

    deftool :echo, "Echo back the input" do
      param(:message, :string, required: true)

      def execute(%{message: msg}) do
        {:ok, msg}
      end
    end

    deftool :upper, "Uppercase a string" do
      param(:text, :string, required: true)

      def execute(%{text: text}) do
        {:ok, String.upcase(text)}
      end
    end
  end

  defmodule NotAToolModule do
    def hello, do: :world
  end

  setup do
    # Start a fresh tool server for each test - using pid directly, no named registration
    {:ok, pid} = ToolServer.start_link(name: nil)
    %{server: pid, pid: pid}
  end

  describe "register_tools/2" do
    test "registers a valid tool module", %{server: server} do
      assert :ok = ToolServer.register_tools(ServerTestTools, server)
    end

    test "rejects non-tool module", %{server: server} do
      assert {:error, {:not_a_tool_module, NotAToolModule}} =
               ToolServer.register_tools(NotAToolModule, server)
    end
  end

  describe "call_tool/3" do
    setup %{server: server} do
      :ok = ToolServer.register_tools(ServerTestTools, server)
      :ok
    end

    test "calls registered tool", %{server: server} do
      assert {:ok, "hello"} = ToolServer.call_tool("echo", %{message: "hello"}, server)
    end

    test "handles string-keyed args", %{server: server} do
      assert {:ok, "HELLO"} = ToolServer.call_tool("upper", %{"text" => "hello"}, server)
    end

    test "returns error for unknown tool", %{server: server} do
      assert {:error, {:unknown_tool, "unknown"}} =
               ToolServer.call_tool("unknown", %{}, server)
    end

    test "catches exceptions from tool execution", %{server: server} do
      # echo tool requires :message key - will raise on missing key
      assert {:error, _msg} = ToolServer.call_tool("echo", %{}, server)
    end
  end

  describe "has_tool?/2" do
    test "returns false before registration", %{server: server} do
      refute ToolServer.has_tool?("echo", server)
    end

    test "returns true after registration", %{server: server} do
      :ok = ToolServer.register_tools(ServerTestTools, server)
      assert ToolServer.has_tool?("echo", server)
    end
  end

  describe "list_tools/1" do
    test "empty when no tools registered", %{server: server} do
      assert [] = ToolServer.list_tools(server)
    end

    test "returns JSON schemas after registration", %{server: server} do
      :ok = ToolServer.register_tools(ServerTestTools, server)
      tools = ToolServer.list_tools(server)
      assert length(tools) == 2
      names = Enum.map(tools, & &1["name"])
      assert "echo" in names
      assert "upper" in names
    end
  end

  describe "tool_names/1" do
    test "returns tool names", %{server: server} do
      :ok = ToolServer.register_tools(ServerTestTools, server)
      names = ToolServer.tool_names(server)
      assert "echo" in names
      assert "upper" in names
    end
  end

  describe "unregister_tools/2" do
    test "removes tools from module", %{server: server} do
      :ok = ToolServer.register_tools(ServerTestTools, server)
      assert ToolServer.has_tool?("echo", server)

      :ok = ToolServer.unregister_tools(ServerTestTools, server)
      refute ToolServer.has_tool?("echo", server)
    end
  end
end
