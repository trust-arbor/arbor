defmodule Arbor.Gateway.MCP.SecurityUnavailableSecurityRegressionTest do
  @moduledoc """
  Security regression (2026-09-27): `ToolBridge.authorize/3` and
  `ResourceBridge.authorize/3` returned `:ok` ("permissive mode") whenever the
  security subsystem looked unavailable, meaning the security module was not
  loaded, did not export `authorize/3`, or `Arbor.Security.CapabilityStore` was
  not registered. So while security was down or restarting, every external MCP
  tool call and resource read made through `Arbor.Gateway.call_mcp_tool/4` /
  `read_mcp_resource/3` was granted, even with an `:agent_id` present.

  Asserted through the public facade against a real connected (in-process)
  MCP server: pre-fix these calls return `{:ok, _}` because the tool/resource
  actually runs; post-fix they are denied with
  `{:error, :unauthorized, "security subsystem unavailable..."}`.
  Do not delete as redundant with `bridge_authorize_failclosed_test.exs` — that
  covers a security check that raises/exits, not one that never runs.
  """
  use ExUnit.Case, async: false

  alias Arbor.Gateway.MCP.ClientSupervisor
  alias ExMCP.Testing.MockServer

  @moduletag :integration

  @server "security_unavailable_regression_server"
  @agent_id "agent_security_unavailable_regression"
  @resource_uri "file://sample_data.txt"

  defmodule SecurityWithoutAuthorize do
    @moduledoc false
    # Loaded, but exports no authorize/3 — `security_available?/0` is false.
    def healthy?, do: true
  end

  setup do
    start_supervised!(ClientSupervisor)

    {:ok, server_pid} =
      MockServer.start_link(
        tools: [MockServer.sample_tool(name: "sample_tool")],
        resources: [MockServer.sample_resource(uri: @resource_uri)]
      )

    on_exit(fn ->
      Application.delete_env(:arbor_gateway, :security_module)
      if Process.alive?(server_pid), do: GenServer.stop(server_pid, :normal, 1_000)
    end)

    {:ok, _} =
      ClientSupervisor.start_connection(@server, %{
        transport: :test,
        server: server_pid,
        auto_discover: true
      })

    wait_until_connected!(@server)
    :ok
  end

  # Each scenario makes `security_available?/0` false a different way.
  @unavailable_scenarios [
    {"security module is not loaded", :not_loaded},
    {"security module lacks authorize/3", :no_authorize},
    {"Arbor.Security.CapabilityStore is not running", :capability_store_down}
  ]

  describe "security regression: call_mcp_tool while security is unavailable" do
    for {label, scenario} <- @unavailable_scenarios do
      @scenario scenario
      test "denies when #{label}" do
        result =
          with_security_unavailable(@scenario, fn ->
            Arbor.Gateway.call_mcp_tool(@server, "sample_tool", %{"input" => "x"},
              agent_id: @agent_id
            )
          end)

        assert {:error, :unauthorized, "security subsystem unavailable" <> _} = result
      end
    end
  end

  describe "security regression: read_mcp_resource while security is unavailable" do
    for {label, scenario} <- @unavailable_scenarios do
      @scenario scenario
      test "denies when #{label}" do
        result =
          with_security_unavailable(@scenario, fn ->
            Arbor.Gateway.read_mcp_resource(@server, @resource_uri, agent_id: @agent_id)
          end)

        assert {:error, :unauthorized, "security subsystem unavailable" <> _} = result
      end
    end
  end

  describe "harness control" do
    test "skip_auth: true reaches the tool, so a denial above is the gate, not the wiring" do
      assert {:ok, %{value: _, taint: %{level: :untrusted}}} =
               Arbor.Gateway.call_mcp_tool(@server, "sample_tool", %{"input" => "x"},
                 skip_auth: true
               )
    end
  end

  defp with_security_unavailable(:not_loaded, fun) do
    Application.put_env(:arbor_gateway, :security_module, __MODULE__.NeverDefinedSecurity)
    fun.()
  end

  defp with_security_unavailable(:no_authorize, fun) do
    Application.put_env(:arbor_gateway, :security_module, SecurityWithoutAuthorize)
    fun.()
  end

  # Hides the real CapabilityStore's registered name (what a restart window
  # looks like to `Process.whereis/1`) without stopping the shared supervisor's
  # child, then restores it.
  defp with_security_unavailable(:capability_store_down, fun) do
    name = Arbor.Security.CapabilityStore
    pid = Process.whereis(name) || flunk("#{inspect(name)} must be running for this scenario")

    Application.delete_env(:arbor_gateway, :security_module)
    Process.unregister(name)

    try do
      fun.()
    after
      if Process.alive?(pid) and Process.whereis(name) == nil do
        Process.register(pid, name)
      end
    end
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
