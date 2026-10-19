defmodule Arbor.AI.AcpSession.McpLaunchCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.AcpPool.ToolServer
  alias Arbor.AI.AcpSession.McpLaunchCore

  @moduletag :fast

  @claude ExMCP.ACP.Adapters.ClaudeSDK
  @codex ExMCP.ACP.Adapters.Codex
  @home "/private/runtime-home"
  @token "tok_0123456789abcdef0123456789abcdef"

  defp entry, do: ToolServer.mcp_servers_entry(%{port: 4321, token: @token})

  describe "ClaudeSDK" do
    test "writes Claude-format servers to a runtime-home file and passes only its path" do
      assert {:ok, plan} = McpLaunchCore.plan(@claude, entry(), @home)

      assert {path, contents} = plan.file
      assert Path.dirname(path) == @home

      assert %{
               "mcpServers" => %{
                 "arbor-tools" => %{
                   "type" => "http",
                   "url" => "http://127.0.0.1:4321",
                   "headers" => %{"Authorization" => "Bearer " <> @token}
                 }
               }
             } = Jason.decode!(contents)

      assert plan.adapter_append == [extra_args: ["--mcp-config", path]]
      assert plan.adapter_put == [strict_mcp_config: true]
      assert :mcp_servers in plan.adapter_delete
      assert plan.allow_tools == ["mcp__arbor-tools"]
    end

    test "security regression: the bearer token never appears in argv-bound options" do
      {:ok, plan} = McpLaunchCore.plan(@claude, entry(), @home)

      {:ok, adapter_opts} =
        McpLaunchCore.apply_adapter_opts([mcp_servers: %{"inline" => @token}], plan)

      refute inspect(adapter_opts) =~ @token
      {_exe, argv} = ExMCP.ACP.Adapters.ClaudeSDK.Protocol.command(adapter_opts)
      refute Enum.any?(argv, &String.contains?(&1, @token))
      assert "--strict-mcp-config" in argv
    end

    test "with no bound servers, ambient MCP is still shut off and nothing is staged" do
      assert {:ok, %{file: nil, allow_tools: [], adapter_put: [strict_mcp_config: true]}} =
               McpLaunchCore.plan(@claude, [], @home)
    end

    test "appends to existing extra_args instead of replacing them" do
      {:ok, plan} = McpLaunchCore.plan(@claude, entry(), @home)
      {path, _contents} = plan.file

      assert {:ok, opts} =
               McpLaunchCore.apply_adapter_opts([extra_args: ["--setting-sources", ""]], plan)

      assert opts[:extra_args] == ["--setting-sources", "", "--mcp-config", path]
    end

    test "translates stdio servers and their env" do
      stdio = %{
        "name" => "local",
        "command" => "/bin/tool",
        "args" => ["--x"],
        "env" => [%{"name" => "K", "value" => "v"}]
      }

      {:ok, %{file: {_path, contents}}} = McpLaunchCore.plan(@claude, [stdio], @home)

      assert %{"local" => %{"type" => "stdio", "command" => "/bin/tool", "env" => %{"K" => "v"}}} =
               Jason.decode!(contents)["mcpServers"]
    end

    test "rejects malformed, duplicate, and oddly named servers" do
      [server] = entry()

      for bad <- [
            [Map.put(server, "url", "ftp://x")],
            [Map.put(server, "headers", [%{"name" => "A"}])],
            [Map.put(server, "name", "has space")],
            [server, server],
            [%{"type" => "websocket", "name" => "x"}]
          ] do
        assert {:error, reason} = McpLaunchCore.plan(@claude, bad, @home)
        assert reason in [:invalid_acp_mcp_server, :duplicate_acp_mcp_server]
      end
    end
  end

  describe "Codex / ZCode" do
    test "trusts exactly the bound list and drops a caller authorizer" do
      for adapter <- [@codex, ExMCP.ACP.Adapters.ZCode] do
        {:ok, plan} = McpLaunchCore.plan(adapter, entry(), @home)

        {:ok, opts} =
          McpLaunchCore.apply_adapter_opts(
            [trusted_mcp_servers: :all, authorize_mcp_server: fn _ -> true end],
            plan
          )

        assert opts[:trusted_mcp_servers] == entry()
        refute Keyword.has_key?(opts, :authorize_mcp_server)
        assert plan.file == nil
      end
    end

    test "security regression: process-injection env on a trusted stdio server is refused" do
      # Overlaps draft PR #24 (ClientConfigCore / Claude pairs_to_map). Codex
      # and ZCode take the ACP list as `trusted_mcp_servers` without that
      # Claude translation, so they bypass #24 unless screened here.
      for {adapter, name} <- [
            {@codex, "NODE_OPTIONS"},
            {ExMCP.ACP.Adapters.ZCode, "LD_PRELOAD"}
          ] do
        stdio = %{
          "name" => "local",
          "command" => "/bin/tool",
          "env" => [%{"name" => name, "value" => "/tmp/not-loaded"}]
        }

        assert {:error, {:forbidden_mcp_env, ^name}} =
                 McpLaunchCore.plan(adapter, [stdio], @home)
      end
    end
  end

  describe "other adapters and native commands" do
    test "an adapter without MCP support fails loudly when servers are bound" do
      assert {:error, {:acp_mcp_servers_unsupported, ExMCP.ACP.Adapters.Pi}} =
               McpLaunchCore.plan(ExMCP.ACP.Adapters.Pi, entry(), @home)

      assert {:ok, %{file: nil, adapter_put: []}} =
               McpLaunchCore.plan(ExMCP.ACP.Adapters.Pi, [], @home)
    end

    test "native ACP commands read session/new and need no launch wiring" do
      assert {:ok, %{file: nil, adapter_put: [], allow_tools: []}} =
               McpLaunchCore.plan(nil, entry(), @home)
    end
  end
end
