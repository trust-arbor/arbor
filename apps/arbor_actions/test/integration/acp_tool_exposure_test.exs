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
      # Bare `arbor://fs/read` is the EXPOSURE cap (drives tool_modules_for_agent);
      # actually reading a file requires a PATH-SCOPED cap. Before the H1
      # fail-open fix, ToolServer ran the action directly after authz denial, so
      # this test passed with only the exposure cap (the capability layer was
      # never really exercised — a false green). Grant both so the call is
      # genuinely authorized end-to-end. NOTE: spawned ACP agents now likewise
      # need a path-scoped fs cap, not just the exposure cap.
      {:ok, _} = Security.grant(principal: agent_id, resource: "arbor://fs/read")
      {:ok, _} = Security.grant(principal: agent_id, resource: "arbor://fs/read#{workspace}/**")

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
      # Broad read cap so the call clears the capability layer and REACHES
      # File.Read — whose workspace constraint (from exec_context) is what this
      # test is verifying. The bound here is enforced by the action's
      # validate_path, not the cap. (See the success test above re: exposure vs
      # path-scoped caps and the H1 fail-open fix.)
      {:ok, _} = Security.grant(principal: agent_id, resource: "arbor://fs/read")

      # Scope the read cap to the workspace's PARENT (normalized — no trailing
      # slash, unlike System.tmp_dir!/0) so BOTH the workspace and the sibling
      # "outside" file clear the capability layer. The point of this test is
      # that File.Read's workspace constraint (not the cap) blocks the
      # out-of-workspace read.
      tmp_parent = Path.dirname(workspace)

      {:ok, _} =
        Security.grant(principal: agent_id, resource: "arbor://fs/read#{tmp_parent}/**")

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

  # Since ex_mcp rc.8 the HttpPlug issues server-owned Streamable HTTP sessions
  # from ExMCP.SessionManager, so a bare request fails closed with
  # "Session ID required" (see Arbor.AI.AcpPool.ToolServer.start/2). Perform the
  # protocol handshake — initialize, then notifications/initialized — and carry
  # the returned mcp-session-id on the real request.
  defp mcp_request(port, method, params) do
    with {:ok, session_id} <- mcp_initialize(port) do
      mcp_post(port, session_id, method, params)
    end
  end

  defp mcp_initialize(port) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "acp-tool-exposure-test", "version" => "1"}
        }
      })

    case http_post(port, [], body) do
      {:ok, {{_, 200, _}, headers, _}} ->
        case session_id_header(headers) do
          nil ->
            {:error, {:no_session_id, headers}}

          session_id ->
            # The server expects the initialized notification before other calls.
            _ =
              mcp_post_raw(
                port,
                session_id,
                Jason.encode!(%{
                  "jsonrpc" => "2.0",
                  "method" => "notifications/initialized",
                  "params" => %{}
                })
              )

            {:ok, session_id}
        end

      other ->
        {:error, {:initialize_failed, other}}
    end
  end

  defp mcp_post(port, session_id, method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    case mcp_post_raw(port, session_id, body) do
      {:ok, {{_, 200, _}, _, response_body}} ->
        {:ok, response_body |> List.to_string() |> Jason.decode!()}

      other ->
        {:error, other}
    end
  end

  defp mcp_post_raw(port, session_id, body) do
    http_post(port, [{~c"mcp-session-id", String.to_charlist(session_id)}], body)
  end

  defp http_post(port, headers, body) do
    :httpc.request(
      :post,
      {~c"http://127.0.0.1:#{port}/", headers, ~c"application/json", String.to_charlist(body)},
      [{:timeout, 5_000}],
      []
    )
  end

  defp session_id_header(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == "mcp-session-id", do: to_string(value)
    end)
  end
end
