defmodule Arbor.AI.AcpPool.ToolServerTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.AcpPool.ToolServer

  @moduletag :fast

  # Define a minimal test action module
  defmodule TestAction do
    @moduledoc false

    def to_tool do
      %{
        name: "test_action",
        description: "A test action for ToolServer tests",
        parameters_schema: %{
          "type" => "object",
          "properties" => %{
            "input" => %{"type" => "string", "description" => "Test input"}
          }
        }
      }
    end

    def run(%{input: input}, _context) do
      {:ok, %{result: "processed: #{input}"}}
    end

    def run(%{"input" => input}, _context) do
      {:ok, %{result: "processed: #{input}"}}
    end

    def run(_params, _context) do
      {:ok, %{result: "no input"}}
    end
  end

  defmodule AnotherAction do
    @moduledoc false

    def to_tool do
      %{
        name: "another_action",
        description: "Another test action",
        parameters_schema: %{
          "type" => "object",
          "properties" => %{
            "value" => %{"type" => "integer"}
          }
        }
      }
    end

    def run(%{value: v}, _context), do: {:ok, %{doubled: v * 2}}
    def run(_params, _context), do: {:ok, %{doubled: 0}}
  end

  describe "start/2 and stop/1" do
    test "starts an HTTP MCP server on a random port" do
      assert {:ok, %{port: port, ref: ref, tool_count: 1}} =
               ToolServer.start([TestAction])

      assert is_integer(port)
      assert port > 0
      assert is_atom(ref)

      :ok = ToolServer.stop(ref)
    end

    test "starts with multiple action modules" do
      assert {:ok, %{port: _port, ref: ref, tool_count: 2}} =
               ToolServer.start([TestAction, AnotherAction])

      :ok = ToolServer.stop(ref)
    end

    test "starts with empty action modules (0 tools)" do
      assert {:ok, %{port: _port, ref: ref, tool_count: 0}} =
               ToolServer.start([])

      :ok = ToolServer.stop(ref)
    end

    test "stop is idempotent" do
      {:ok, %{ref: ref}} = ToolServer.start([TestAction])
      :ok = ToolServer.stop(ref)
      :ok = ToolServer.stop(ref)
    end
  end

  describe "mcp_servers_entry/1" do
    test "returns correctly formatted MCP server list" do
      entries = ToolServer.mcp_servers_entry(12345)
      assert [%{"uri" => "http://127.0.0.1:12345", "name" => "arbor-tools"}] = entries
    end
  end

  describe "MCP protocol over HTTP" do
    setup do
      {:ok, %{port: port, ref: ref}} = ToolServer.start([TestAction, AnotherAction])
      on_exit(fn -> ToolServer.stop(ref) end)
      {:ok, port: port}
    end

    test "responds to initialize", %{port: port} do
      {:ok, response} = mcp_request(port, "initialize", %{})
      assert response["result"]["protocolVersion"]
      assert response["result"]["serverInfo"]["name"] == "arbor-tools"
      assert response["result"]["capabilities"]["tools"]
    end

    test "responds to tools/list", %{port: port} do
      {:ok, response} = mcp_request(port, "tools/list", %{})
      tools = response["result"]["tools"]
      assert length(tools) == 2

      names = Enum.map(tools, & &1["name"])
      assert "test_action" in names
      assert "another_action" in names

      test_tool = Enum.find(tools, &(&1["name"] == "test_action"))
      assert test_tool["description"] == "A test action for ToolServer tests"
      assert test_tool["inputSchema"]["properties"]["input"]
    end

    test "responds to tools/call", %{port: port} do
      {:ok, response} =
        mcp_request(port, "tools/call", %{
          "name" => "test_action",
          "arguments" => %{"input" => "hello"}
        })

      result = response["result"]
      refute result["isError"]
      [content] = result["content"]
      assert content["type"] == "text"
      # Result is JSON-encoded
      decoded = Jason.decode!(content["text"])
      assert decoded["result"] == "processed: hello"
    end

    test "returns error for unknown tool", %{port: port} do
      {:ok, response} =
        mcp_request(port, "tools/call", %{
          "name" => "nonexistent_tool",
          "arguments" => %{}
        })

      result = response["result"]
      assert result["isError"]
    end

    test "responds to ping", %{port: port} do
      {:ok, response} = mcp_request(port, "ping", %{})
      assert response["result"] == %{}
    end

    test "returns method not found for unknown methods", %{port: port} do
      {:ok, response} = mcp_request(port, "unknown/method", %{})
      assert response["error"]["code"] == -32601
    end
  end

  # -- Helpers --

  defp mcp_request(port, method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    url = "http://127.0.0.1:#{port}"

    case Req.post(url,
           body: body,
           headers: [{"content-type", "application/json"}],
           receive_timeout: 5_000
         ) do
      {:ok, %{status: 200, body: response_body}} when is_binary(response_body) ->
        {:ok, Jason.decode!(response_body)}

      {:ok, %{status: 200, body: response_body}} when is_map(response_body) ->
        {:ok, response_body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
