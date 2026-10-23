defmodule Arbor.Gateway.MCP.ClientConfigRegressionTest do
  @moduledoc """
  Regression (Imp review D7, 2026-09-28), asserted through the public
  `Arbor.Gateway` facade against live in-process MCP servers:

  - String-keyed configs, which is how persisted agent profile metadata
    arrives, were read atom-keys-only: the transport fell back to `:stdio`
    with `command: []`, and a URL-less HTTP config was accepted and crashed
    later inside the connection process.
  - `list_mcp_tools/0` / `list_mcp_resources/0` used a single-clause
    `fn {name, pid, :connected}`, so any disconnected (retrying) server raised
    `FunctionClauseError` for every caller.
  """
  use ExUnit.Case, async: false

  alias Arbor.Gateway.MCP.ClientSupervisor
  alias ExMCP.Testing.MockServer

  @moduletag :integration

  setup do
    start_supervised!(ClientSupervisor)
    %{authority: operator_authority!()}
  end

  defp operator_authority! do
    {:ok, identity} = Arbor.Security.generate_identity(name: "mcp-config-operator")
    :ok = Arbor.Security.register_identity_fixture(identity)

    {:ok, proof} =
      Arbor.Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :mcp_operator_connect,
        owner: self()
      )

    {:ok, authority} =
      Arbor.Security.open_ephemeral_signing_authority(proof, identity.private_key)

    on_exit(fn ->
      _ = Arbor.Security.close_signing_authority(authority)
      _ = Arbor.Security.deregister_identity_fixture(identity.agent_id)
    end)

    authority
  end

  defp mock_server do
    {:ok, pid} =
      MockServer.start_link(
        tools: [MockServer.sample_tool(name: "sample_tool")],
        resources: [MockServer.sample_resource()]
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000) end)
    pid
  end

  defp wait_for_status(name, wanted, attempts \\ 100)
  defp wait_for_status(name, wanted, 0), do: flunk("#{name} never reached #{inspect(wanted)}")

  defp wait_for_status(name, wanted, attempts) do
    case Arbor.Gateway.mcp_server_status(name) do
      {:ok, %{connection_status: ^wanted}} ->
        :ok

      _ ->
        Process.sleep(20)
        wait_for_status(name, wanted, attempts - 1)
    end
  end

  test "a string-keyed config (profile metadata shape) connects with its transport", %{
    authority: authority
  } do
    server = mock_server()

    assert {:ok, _pid} =
             Arbor.Gateway.connect_mcp_server("strkeys", %{
               "transport" => "test",
               "server" => server,
               "auto_discover" => true,
               "actor_authority" => authority
             })

    wait_for_status("strkeys", :connected)

    assert ["mcp.strkeys.sample_tool"] =
             Enum.map(Arbor.Gateway.list_mcp_tools("strkeys"), & &1.name)
  end

  test "a config missing its transport's required field is refused before starting", %{
    authority: authority
  } do
    assert {:error, {:invalid_mcp_config, :url}} =
             Arbor.Gateway.connect_mcp_server("nourl", %{
               "transport" => "http",
               "actor_authority" => authority
             })

    assert {:error, {:invalid_mcp_config, :command}} =
             Arbor.Gateway.connect_mcp_server("nocmd", %{
               "transport" => "stdio",
               "actor_authority" => authority
             })

    assert {:error, :not_found} = Arbor.Gateway.mcp_server_status("nourl")
  end

  test "one disconnected server does not break listing for the connected ones", %{
    authority: authority
  } do
    server = mock_server()

    {:ok, _} =
      Arbor.Gateway.connect_mcp_server("live", %{
        transport: :test,
        server: server,
        actor_authority: authority
      })

    wait_for_status("live", :connected)

    # A server whose process is already gone stays :disconnected and retries.
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

    {:ok, _} =
      Arbor.Gateway.connect_mcp_server("dead", %{
        transport: :test,
        server: dead,
        actor_authority: authority
      })

    wait_for_status("dead", :disconnected)

    assert ["mcp.live.sample_tool"] = Enum.map(Arbor.Gateway.list_mcp_tools(), & &1.name)
    assert [_resource] = Arbor.Gateway.list_mcp_resources()
  end
end
