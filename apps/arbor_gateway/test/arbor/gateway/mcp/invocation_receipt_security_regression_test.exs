defmodule Arbor.Gateway.MCP.InvocationReceiptSecurityRegressionTest do
  @moduledoc """
  Security regression (2026-09-28): `ToolBridge.authorize/3` and
  `ResourceBridge.authorize/3` passed `%{action: :execute}` / `%{action: :read}`
  as the `action` argument of `Arbor.Security.authorize/4`, which takes an atom.
  The allow/deny decision ignored it, but `InvocationReceipt.signing_payload/1`
  calls `to_string(action)`, which raises for a map. `maybe_emit_receipt/6`
  rescues to `:ok`, so with `invocation_receipts_enabled` every authorized MCP
  tool call and resource read silently produced no signed invocation receipt.

  Asserted through the public facade: a granted agent's call succeeds and
  exactly that call's receipt is emitted. Pre-fix the call still succeeds but
  no receipt arrives. This also covers the authorized path, which the denial
  tests beside it do not.
  """
  use ExUnit.Case, async: false

  alias Arbor.Gateway.MCP.ClientSupervisor
  alias ExMCP.Testing.MockServer

  @moduletag :integration

  @server "receipt_regression_server"
  @resource_uri "file://sample_data.txt"
  @resource_name "sample_data"

  setup do
    start_supervised!(ClientSupervisor)

    {:ok, server_pid} =
      MockServer.start_link(
        tools: [MockServer.sample_tool(name: "sample_tool")],
        resources: [MockServer.sample_resource(uri: @resource_uri, name: @resource_name)]
      )

    {:ok, _} =
      ClientSupervisor.start_connection(@server, %{
        transport: :test,
        server: server_pid,
        auto_discover: true
      })

    wait_until_connected!(@server)

    previous = Application.get_env(:arbor_security, :invocation_receipts_enabled)
    Application.put_env(:arbor_security, :invocation_receipts_enabled, true)

    agent_id = "agent_mcp_receipt_regression_#{System.unique_integer([:positive])}"
    parent = self()
    handler_id = "mcp-receipt-regression-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:arbor, :security, :invocation_receipt],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:invocation_receipt, metadata.data})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      if is_nil(previous),
        do: Application.delete_env(:arbor_security, :invocation_receipts_enabled),
        else: Application.put_env(:arbor_security, :invocation_receipts_enabled, previous)

      {:ok, caps} = Arbor.Security.list_capabilities(agent_id)
      for cap <- caps, do: Arbor.Security.revoke_fixture(cap.id)
      if Process.alive?(server_pid), do: GenServer.stop(server_pid, :normal, 1_000)
    end)

    %{agent_id: agent_id}
  end

  test "security regression: an authorized MCP tool call emits its invocation receipt",
       %{agent_id: agent_id} do
    uri = "arbor://mcp/#{@server}/sample_tool"
    {:ok, _} = Arbor.Security.grant_fixture(principal: agent_id, resource: uri)

    assert {:ok, %{value: _, taint: %{level: :untrusted}}} =
             Arbor.Gateway.call_mcp_tool(@server, "sample_tool", %{"input" => "x"},
               agent_id: agent_id
             )

    assert_receive {:invocation_receipt,
                    %{principal_id: ^agent_id, resource_uri: ^uri, result: :granted}},
                   1_000
  end

  test "security regression: an authorized MCP resource read emits its invocation receipt",
       %{agent_id: agent_id} do
    uri = "arbor://mcp/#{@server}/resource/#{@resource_name}"
    {:ok, _} = Arbor.Security.grant_fixture(principal: agent_id, resource: uri)

    assert {:ok, %{value: _, taint: %{level: :untrusted}}} =
             Arbor.Gateway.read_mcp_resource(@server, @resource_uri, agent_id: agent_id)

    assert_receive {:invocation_receipt,
                    %{principal_id: ^agent_id, resource_uri: ^uri, result: :granted}},
                   1_000
  end

  defp wait_until_connected!(server_name, attempts \\ 50)

  defp wait_until_connected!(server_name, 0) do
    flunk("MCP server #{server_name} never reached :connected")
  end

  defp wait_until_connected!(server_name, attempts) do
    case Arbor.Gateway.mcp_server_status(server_name) do
      {:ok, %{connection_status: :connected}} ->
        :ok

      _ ->
        Process.sleep(20)
        wait_until_connected!(server_name, attempts - 1)
    end
  end
end
