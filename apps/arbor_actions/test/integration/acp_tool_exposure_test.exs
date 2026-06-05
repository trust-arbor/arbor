defmodule Arbor.Actions.AcpToolExposureTest do
  @moduledoc """
  Integration test for the Phase 4 ACP tool-exposure path. Exercises
  the full chain from capability grant through HTTP MCP boundary:

    Security.grant(agent → arbor://fs/read)
      └─> Arbor.Actions.tool_modules_for_agent/1 (capability filter)
           └─> AcpPool.ToolServer.start/2 (workspace context)
                └─> HTTP MCP `tools/list` (exposes only granted action)
                     └─> HTTP MCP `tools/call` (authorize_and_execute,
                         workspace-scoped path resolution)

  Validates that workspace constraints from File.validate_path/2 are
  actually enforced when the call originates from an MCP request rather
  than direct in-process invocation. Bypasses AcpPool.checkout to keep
  the test focused on the new code paths from Phase 4 — pool semantics
  are covered separately in acp_pool_test.exs.
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  alias Arbor.AI.AcpPool.ToolServer
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security

  setup do
    {:ok, identity} = Identity.generate(name: "acp-tool-exposure-integration")
    agent_id = identity.agent_id
    :ok = Security.register_identity(identity)

    workspace =
      System.tmp_dir!() |> Path.join("acp_tool_exposure_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    on_exit(fn ->
      case Security.list_capabilities(agent_id) do
        {:ok, caps} -> Enum.each(caps, &Security.revoke(&1.id))
        _ -> :ok
      end

      File.rm_rf(workspace)
    end)

    %{agent_id: agent_id, workspace: workspace}
  end

  describe "end-to-end: capability → filter → expose → call" do
    test "agent with arbor://fs/read sees File.Read exposed and can read in-workspace files", %{
      agent_id: agent_id,
      workspace: workspace
    } do
      {:ok, _} = Security.grant(principal: agent_id, resource: "arbor://fs/read")

      # Capability filter picks up File.Read but not Shell.Execute
      tool_modules = Arbor.Actions.tool_modules_for_agent(agent_id)
      assert Arbor.Actions.File.Read in tool_modules
      refute Arbor.Actions.Shell.Execute in tool_modules

      # Boot ToolServer with the filtered set + workspace context
      {:ok, %{port: port, ref: ref}} =
        ToolServer.start(tool_modules, agent_id: agent_id, workspace: workspace)

      on_exit(fn -> ToolServer.stop(ref) end)

      # tools/list shows only the granted action surface
      {:ok, list_response} = mcp_request(port, "tools/list", %{})
      tool_names = list_response["result"]["tools"] |> Enum.map(& &1["name"])
      assert "file_read" in tool_names
      refute "shell_execute" in tool_names

      # Write a file inside the workspace
      target = Path.join(workspace, "hello.txt")
      File.write!(target, "world")

      # tools/call → File.Read with an in-workspace path
      {:ok, call_response} =
        mcp_request(port, "tools/call", %{
          "name" => "file_read",
          "arguments" => %{"path" => target}
        })

      result = call_response["result"]
      refute result["isError"], "expected success, got error: #{inspect(result)}"
      decoded = Jason.decode!(hd(result["content"])["text"])
      assert decoded["content"] == "world"
      assert decoded["path"] == target
    end

    test "workspace constraint blocks out-of-workspace reads through MCP", %{
      agent_id: agent_id,
      workspace: workspace
    } do
      {:ok, _} = Security.grant(principal: agent_id, resource: "arbor://fs/read")

      tool_modules = Arbor.Actions.tool_modules_for_agent(agent_id)

      {:ok, %{port: port, ref: ref}} =
        ToolServer.start(tool_modules, agent_id: agent_id, workspace: workspace)

      on_exit(fn -> ToolServer.stop(ref) end)

      # Write a file OUTSIDE the workspace
      outside =
        System.tmp_dir!() |> Path.join("outside_#{System.unique_integer([:positive])}.txt")

      File.write!(outside, "secret")
      on_exit(fn -> File.rm(outside) end)

      {:ok, call_response} =
        mcp_request(port, "tools/call", %{
          "name" => "file_read",
          "arguments" => %{"path" => outside}
        })

      result = call_response["result"]

      assert result["isError"],
             "expected workspace bound to deny out-of-workspace read, got: #{inspect(result)}"

      error_text = hd(result["content"])["text"]

      assert error_text =~ "Path traversal denied",
             "expected path traversal error, got: #{error_text}"
    end

    test "agent without any grants gets [] tool_modules → empty tool list", %{
      agent_id: agent_id,
      workspace: workspace
    } do
      tool_modules = Arbor.Actions.tool_modules_for_agent(agent_id)
      assert tool_modules == []

      {:ok, %{port: port, ref: ref, tool_count: count}} =
        ToolServer.start(tool_modules, agent_id: agent_id, workspace: workspace)

      on_exit(fn -> ToolServer.stop(ref) end)
      assert count == 0

      {:ok, response} = mcp_request(port, "tools/list", %{})
      assert response["result"]["tools"] == []
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

    case :httpc.request(
           :post,
           {~c"http://127.0.0.1:#{port}/", [], ~c"application/json", String.to_charlist(body)},
           [{:timeout, 5_000}],
           []
         ) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        {:ok, response_body |> List.to_string() |> Jason.decode!()}

      other ->
        {:error, other}
    end
  end
end
