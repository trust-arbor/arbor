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

  # Echoes the context map back in the result so tests can pin what
  # actually arrived at the action — distinct from TestAction which
  # ignores context. Used to verify workspace plumbing end-to-end.
  defmodule ContextEchoAction do
    @moduledoc false

    def to_tool do
      %{
        name: "context_echo",
        description: "Echoes the run context back",
        parameters_schema: %{"type" => "object", "properties" => %{}}
      }
    end

    def run(_params, context) do
      {:ok,
       %{
         workspace: Map.get(context, :workspace),
         agent_id: Map.get(context, :agent_id)
       }}
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

  # Passthrough runner: stands in for authorize-and-execute so plumbing tests
  # can exercise a running action without the full arbor_security/arbor_actions
  # stack. The security regression below deliberately does NOT install this, so
  # it hits the real (fail-closed) authorized_run path.
  defp install_passthrough_runner do
    prev = Application.get_env(:arbor_ai, :acp_action_runner)

    Application.put_env(:arbor_ai, :acp_action_runner, fn module, params, _agent_id, ctx ->
      module.run(params, ctx)
    end)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:arbor_ai, :acp_action_runner, prev),
        else: Application.delete_env(:arbor_ai, :acp_action_runner)
    end)
  end

  describe "MCP protocol over HTTP" do
    setup do
      install_passthrough_runner()
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

  describe "per-handler context propagation" do
    setup do
      install_passthrough_runner()
      :ok
    end

    test "workspace from start opts arrives in action context" do
      {:ok, %{port: port, ref: ref}} =
        ToolServer.start([ContextEchoAction], workspace: "/tmp/agent_workspace_xyz")

      on_exit(fn -> ToolServer.stop(ref) end)

      {:ok, response} =
        mcp_request(port, "tools/call", %{
          "name" => "context_echo",
          "arguments" => %{}
        })

      result = response["result"]
      refute result["isError"]
      [content] = result["content"]
      decoded = Jason.decode!(content["text"])
      assert decoded["workspace"] == "/tmp/agent_workspace_xyz"
    end

    test "absent workspace yields nil in action context" do
      {:ok, %{port: port, ref: ref}} = ToolServer.start([ContextEchoAction])
      on_exit(fn -> ToolServer.stop(ref) end)

      {:ok, response} =
        mcp_request(port, "tools/call", %{
          "name" => "context_echo",
          "arguments" => %{}
        })

      decoded = Jason.decode!(hd(response["result"]["content"])["text"])
      assert decoded["workspace"] == nil
    end
  end

  # Records execution by messaging a test pid stashed in app env. Lets the
  # regression test prove the action body did NOT run when authorization fails.
  defmodule SideEffectAction do
    @moduledoc false

    def to_tool do
      %{
        name: "side_effect",
        description: "Sends a message when run; used to detect unauthorized execution",
        parameters_schema: %{"type" => "object", "properties" => %{}}
      }
    end

    def run(_params, _context) do
      if pid = Application.get_env(:arbor_ai, :test_side_effect_pid),
        do: send(pid, :ACTION_EXECUTED)

      {:ok, %{ran: true}}
    end
  end

  describe "authorization enforcement (AUTHZ-002 / H1 regression)" do
    test "security regression (H1): an action whose authorization is unavailable/denied does NOT execute and fails closed" do
      # Pre-fix, run_action/4 fell through to a direct action_module.run/2 when
      # authorization was unavailable (or explicitly denied, or on rescue/catch),
      # so a spawned CLI agent could run any exposed Jido action with NO grant.
      # In arbor_ai's isolated test env, arbor_actions (L6) is not loaded, so
      # authorized_execution_available?() is false and run_action takes the
      # real (fail-closed) branch — no DI runner is installed here on purpose.
      Application.put_env(:arbor_ai, :test_side_effect_pid, self())
      on_exit(fn -> Application.delete_env(:arbor_ai, :test_side_effect_pid) end)

      {:ok, %{port: port, ref: ref}} = ToolServer.start([SideEffectAction])
      on_exit(fn -> ToolServer.stop(ref) end)

      {:ok, response} =
        mcp_request(port, "tools/call", %{"name" => "side_effect", "arguments" => %{}})

      assert response["result"]["isError"],
             "an unauthorized/unavailable action call must fail closed — got #{inspect(response["result"])}"

      refute_receive :ACTION_EXECUTED, 200
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
