defmodule Arbor.Gateway.MCP.ClientConnectionCallOutcomeSecurityRegressionTest do
  @moduledoc """
  Security regression (D5, imp-dspy-port review 2026-09-27): external MCP tool
  calls ran inside ClientConnection's `handle_call`, so calls queued behind a
  slow one could still be sent after their callers gave up, and every failure
  came back as ExMCP's raw error with no word on whether the tool may have
  acted. Calls now run in the caller and return a classified CallFailure.
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Tool.CallFailure
  alias Arbor.Gateway.MCP.ClientConnection
  alias ExMCP.Testing.MockServer

  @moduletag :integration
  @moduletag :security_regression

  defmodule ScriptedHandler do
    @moduledoc false

    def list_tools(_state) do
      [
        %{"name" => "slow_tool", "description" => "Slow", "inputSchema" => %{}},
        %{"name" => "failing_tool", "description" => "Fail", "inputSchema" => %{}},
        %{"name" => "claims_refused_tool", "description" => "Claims refused", "inputSchema" => %{}},
        %{"name" => "ok_tool", "description" => "OK", "inputSchema" => %{}}
      ]
    end

    def list_resources(_state), do: []
    def list_prompts(_state), do: []

    def call_tool("slow_tool", _arguments, state) do
      Process.sleep(Map.fetch!(state, :slow_ms))
      %{"content" => [%{"type" => "text", "text" => "finally done"}]}
    end

    def call_tool("failing_tool", _arguments, _state) do
      %{"isError" => true, "content" => [%{"type" => "text", "text" => "disk full"}]}
    end

    def call_tool("claims_refused_tool", _arguments, _state) do
      %{
        "isError" => true,
        "content" => [%{"type" => "text", "text" => "refused (says the tool)"}],
        "structuredContent" => %{"outcome" => "refused"}
      }
    end

    def call_tool("ok_tool", %{"input" => input}, _state) do
      %{"content" => [%{"type" => "text", "text" => "echo: " <> input}]}
    end
  end

  setup do
    {:ok, server} =
      MockServer.start_link(handler: ScriptedHandler, state: %{slow_ms: 1_500})

    # The scripted slow tool keeps the mock server busy; do not wait on it.
    on_exit(fn -> if Process.alive?(server), do: Process.exit(server, :kill) end)

    config = %{
      server_name: "scripted",
      transport: :test,
      server: server,
      auto_discover: true
    }

    conn = start_supervised!({ClientConnection, config}, id: :scripted_conn)
    await_connected(conn)
    %{conn: conn}
  end

  test "security regression: a timed-out call is :unknown and does not block the connection",
       %{conn: conn} do
    task =
      Task.async(fn -> ClientConnection.call_tool(conn, "slow_tool", %{}, timeout: 1_000) end)

    # While the slow call is out, the connection still answers promptly. Before
    # the fix the call ran inside handle_call and this status call timed out.
    Process.sleep(100)
    assert {:ok, %{connection_status: :connected}} = GenServer.call(conn, :status, 400)

    assert {:error, %CallFailure{outcome: :unknown, tool: "slow_tool"} = failure} =
             Task.await(task, 5_000)

    assert CallFailure.indeterminate_effect?(failure)
    assert CallFailure.describe(failure) =~ "may have taken effect"
  end

  test "a tool's error result is :failed with the tool's own text", %{conn: conn} do
    assert {:error, %CallFailure{outcome: :failed, message: message}} =
             ClientConnection.call_tool(conn, "failing_tool", %{})

    assert message =~ "disk full"
  end

  test "security regression: a tool's own claim of refusal does not read as :refused",
       %{conn: conn} do
    assert {:error, %CallFailure{outcome: :failed}} =
             ClientConnection.call_tool(conn, "claims_refused_tool", %{})
  end

  test "a successful answer is unchanged", %{conn: conn} do
    assert {:ok, "echo: hi"} = ClientConnection.call_tool(conn, "ok_tool", %{"input" => "hi"})
  end

  test "a disconnected connection sends nothing: :not_sent", %{conn: conn} do
    :ok = ClientConnection.disconnect(conn)

    assert {:error, %CallFailure{outcome: :not_sent, tool: "ok_tool"}} =
             ClientConnection.call_tool(conn, "ok_tool", %{"input" => "hi"})
  end

  defp await_connected(conn, attempts \\ 50)
  defp await_connected(_conn, 0), do: flunk("MCP test connection never connected")

  defp await_connected(conn, attempts) do
    case ClientConnection.status(conn) do
      {:ok, %{connection_status: :connected}} ->
        :ok

      _other ->
        Process.sleep(20)
        await_connected(conn, attempts - 1)
    end
  end
end
