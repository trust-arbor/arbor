defmodule Arbor.Gateway.MCP.McpProcessEnvSecurityRegressionTest do
  @moduledoc """
  Security regression (Arbor Exposure Check, 2026-10-19): an approved MCP
  stdio server can still pass process-injection environment variables through
  `:env`. `LD_*` / `DYLD_*` preload attacker code; `NODE_OPTIONS`,
  `PYTHONPATH`, `PYTHONSTARTUP`, and `BASH_ENV` run host language startup
  hooks. Approval of the server config must not make those keys executable.

  Same class as repo-local MCP RCE (CVE-2026-111091 / CVE-2026-88755): the
  configured command line is a program. Env is part of that program.
  """
  use ExUnit.Case, async: false

  alias Arbor.Gateway.MCP.ClientConfigCore
  alias Arbor.Gateway.MCP.ClientSupervisor
  alias ExMCP.Testing.MockServer

  @moduletag :fast

  @denied_exact ~w(NODE_OPTIONS PYTHONPATH PYTHONSTARTUP BASH_ENV)
  @denied_prefixed ~w(LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH)

  setup do
    start_supervised!(ClientSupervisor)
    {:ok, identity} = Arbor.Security.generate_identity(name: "mcp-process-env")
    :ok = Arbor.Security.register_identity_fixture(identity)

    on_exit(fn ->
      if Process.whereis(Arbor.Security.CapabilityStore),
        do: Arbor.Security.revoke_all_fixture(identity.agent_id)
    end)

    %{agent_id: identity.agent_id}
  end

  defp mock_server do
    {:ok, pid} = MockServer.start_link(tools: [MockServer.sample_tool(name: "sample_tool")])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000) end)
    pid
  end

  defp approve!(agent_id, name, config) do
    {:ok, uri} = Arbor.Security.mcp_server_approval_uri(name, config)
    {:ok, _cap} = Arbor.Security.grant_fixture(principal: agent_id, resource: uri)
  end

  test "security regression: process-injection keys are refused even after exact approval",
       %{agent_id: agent_id} do
    for key <- @denied_exact ++ @denied_prefixed do
      config = %{
        transport: :stdio,
        command: ["/bin/true"],
        env: %{key => "/tmp/not-loaded"},
        agent_id: agent_id
      }

      approve!(agent_id, "poisoned-#{key}", config)

      assert {:error, {:forbidden_mcp_env, ^key}} =
               Arbor.Gateway.connect_mcp_server("poisoned-#{key}", config),
             "approved MCP :env #{key} must fail closed"

      assert {:error, :not_found} = Arbor.Gateway.mcp_server_status("poisoned-#{key}")
    end
  end

  test "security regression: atom and string keys are denied the same way" do
    assert {:error, {:forbidden_mcp_env, "NODE_OPTIONS"}} =
             ClientConfigCore.normalize("s", %{
               command: ["/bin/true"],
               env: %{NODE_OPTIONS: "--require /tmp/x"}
             })

    assert {:error, {:forbidden_mcp_env, "LD_PRELOAD"}} =
             ClientConfigCore.normalize("s", %{
               "command" => ["/bin/true"],
               "env" => %{"LD_PRELOAD" => "/tmp/x"}
             })
  end

  test "benign env still normalizes; operator connections without agent_id are gated too" do
    assert {:ok, %{env: %{"GITHUB_TOKEN" => "t"}}} =
             ClientConfigCore.normalize("s", %{
               command: ["/bin/true"],
               env: %{"GITHUB_TOKEN" => "t"}
             })

    assert {:error, {:forbidden_mcp_env, "BASH_ENV"}} =
             Arbor.Gateway.connect_mcp_server("operator-poisoned", %{
               transport: :stdio,
               command: ["/bin/true"],
               env: %{"BASH_ENV" => "/tmp/hook"}
             })
  end

  test "an approved server with only benign env still connects", %{agent_id: agent_id} do
    server = mock_server()
    approved = %{transport: :test, server: server, env: %{"GITHUB_TOKEN" => "t"}}
    approve!(agent_id, "safe", approved)

    assert {:ok, _pid} =
             Arbor.Gateway.connect_mcp_server("safe", Map.put(approved, :agent_id, agent_id))
  end
end
