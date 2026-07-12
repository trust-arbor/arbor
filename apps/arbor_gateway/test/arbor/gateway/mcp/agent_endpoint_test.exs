defmodule Arbor.Gateway.MCP.AgentEndpointTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Gateway.MCP.{ActionBridge, AgentEndpoint, EndpointRegistry}

  # ============================================================================
  # Test Action Modules
  # ============================================================================

  defmodule EchoAction do
    use Jido.Action,
      name: "echo",
      description: "Returns the input as output",
      schema: [
        message: [type: :string, required: true, doc: "Message to echo"]
      ]

    @impl true
    def run(params, _context) do
      {:ok, %{echoed: params.message}}
    end
  end

  defmodule AddAction do
    use Jido.Action,
      name: "add",
      description: "Adds two numbers",
      schema: [
        a: [type: :integer, required: true, doc: "First number"],
        b: [type: :integer, required: true, doc: "Second number"]
      ]

    @impl true
    def run(params, _context) do
      {:ok, %{sum: params.a + params.b}}
    end
  end

  defmodule FailAction do
    use Jido.Action,
      name: "fail",
      description: "Always fails",
      schema: [
        reason: [type: :string, required: true, doc: "Failure reason"]
      ]

    @impl true
    def run(params, _context) do
      {:error, params.reason}
    end
  end

  defmodule NestedCodingValidationAction do
    use Jido.Action,
      name: "nested_coding_validation",
      description: "Runs the shell validation used by a coding action",
      schema: [
        command: [type: :string, required: true, doc: "Validation command"]
      ]

    @impl true
    def run(params, context) do
      Arbor.Actions.authorize_and_execute(
        Map.fetch!(context, :agent_id),
        Arbor.Actions.Shell.Execute,
        %{command: params.command, sandbox: :none},
        context
      )
    end
  end

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    # Ensure EndpointRegistry is available
    if :ets.info(:arbor_mcp_endpoints) == :undefined do
      start_supervised!({EndpointRegistry, []})
    end

    ensure_security_started()

    prev_identity = Application.get_env(:arbor_security, :identity_verification)
    prev_signing = Application.get_env(:arbor_security, :capability_signing_required)
    prev_strict = Application.get_env(:arbor_security, :strict_identity_mode)
    prev_uri = Application.get_env(:arbor_security, :uri_registry_enforcement)
    prev_reflex = Application.get_env(:arbor_security, :reflex_checking_enabled)
    prev_escalation = Application.get_env(:arbor_security, :consensus_escalation_enabled)
    prev_security_approval = Application.get_env(:arbor_security, :approval_guard_enabled)
    prev_trust_approval = Application.get_env(:arbor_trust, :approval_guard_enabled)
    prev_trust_enforcer = Application.get_env(:arbor_trust, :policy_enforcer_enabled)

    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_trust, :approval_guard_enabled, false)
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, false)

    on_exit(fn ->
      restore_env(:arbor_security, :identity_verification, prev_identity)
      restore_env(:arbor_security, :capability_signing_required, prev_signing)
      restore_env(:arbor_security, :strict_identity_mode, prev_strict)
      restore_env(:arbor_security, :uri_registry_enforcement, prev_uri)
      restore_env(:arbor_security, :reflex_checking_enabled, prev_reflex)
      restore_env(:arbor_security, :consensus_escalation_enabled, prev_escalation)
      restore_env(:arbor_security, :approval_guard_enabled, prev_security_approval)
      restore_env(:arbor_trust, :approval_guard_enabled, prev_trust_approval)
      restore_env(:arbor_trust, :policy_enforcer_enabled, prev_trust_enforcer)
    end)

    :ok
  end

  # ============================================================================
  # ActionBridge
  # ============================================================================

  describe "ActionBridge.to_mcp_tool/1" do
    test "converts action module to MCP tool definition" do
      tool = ActionBridge.to_mcp_tool(EchoAction)

      assert tool["name"] == "echo"
      assert tool["description"] == "Returns the input as output"
      assert tool["inputSchema"]["type"] == "object"
      assert tool["inputSchema"]["required"] == ["message"]
      assert tool["inputSchema"]["properties"]["message"]["type"] == "string"
    end

    test "converts multiple actions" do
      tools = ActionBridge.to_mcp_tools([EchoAction, AddAction])

      assert length(tools) == 2
      names = Enum.map(tools, & &1["name"])
      assert "echo" in names
      assert "add" in names
    end

    test "handles action with multiple required params" do
      tool = ActionBridge.to_mcp_tool(AddAction)

      assert tool["name"] == "add"
      assert "a" in tool["inputSchema"]["required"]
      assert "b" in tool["inputSchema"]["required"]
      assert tool["inputSchema"]["properties"]["a"]["type"] == "integer"
    end
  end

  # ============================================================================
  # AgentEndpoint Lifecycle
  # ============================================================================

  describe "AgentEndpoint lifecycle" do
    test "starts with specified actions" do
      {:ok, pid} =
        AgentEndpoint.start_link(
          agent_id: "test-agent-1",
          actions: [EchoAction, AddAction]
        )

      assert Process.alive?(pid)
      tools = AgentEndpoint.list_tools(pid)
      assert length(tools) == 2

      GenServer.stop(pid)
    end

    test "status reports agent info" do
      {:ok, pid} =
        AgentEndpoint.start_link(
          agent_id: "test-agent-2",
          actions: [EchoAction]
        )

      status = AgentEndpoint.status(pid)
      assert status.agent_id == "test-agent-2"
      assert status.tool_count == 1
      assert status.connected == false
      assert status.initialized == false

      GenServer.stop(pid)
    end

    test "starts with empty actions list" do
      {:ok, pid} =
        AgentEndpoint.start_link(
          agent_id: "test-agent-3",
          actions: []
        )

      tools = AgentEndpoint.list_tools(pid)
      assert tools == []

      GenServer.stop(pid)
    end
  end

  # ============================================================================
  # MCP Protocol (via ExMCP.Client)
  # ============================================================================

  describe "MCP protocol via ExMCP.Client" do
    test "client connects and discovers tools" do
      {:ok, endpoint} =
        AgentEndpoint.start_link(
          agent_id: "proto-agent-1",
          actions: [EchoAction, AddAction]
        )

      {:ok, client} = ExMCP.Client.start_link(transport: :beam, server: endpoint)

      # Client should have connected
      status = AgentEndpoint.status(endpoint)
      assert status.connected == true

      # List tools
      {:ok, %{tools: tools}} = ExMCP.Client.list_tools(client)
      assert length(tools) == 2

      tool_names = Enum.map(tools, & &1.name)
      assert "echo" in tool_names
      assert "add" in tool_names

      ExMCP.Client.stop(client)
      GenServer.stop(endpoint)
    end

    test "client calls tool and gets result" do
      {agent_id, endpoint} = start_authorized_endpoint([EchoAction])

      {:ok, client} = ExMCP.Client.start_link(transport: :beam, server: endpoint)

      {:ok, result} = ExMCP.Client.call_tool(client, "echo", %{"message" => "hello"})

      assert result != nil

      # Result should contain content with the echoed message
      content = get_tool_result_text(result)
      assert content =~ "hello"

      ExMCP.Client.stop(client)
      Arbor.Gateway.stop_agent_endpoint(agent_id)
    end

    test "client calls tool with integer params" do
      {agent_id, endpoint} = start_authorized_endpoint([AddAction])

      {:ok, client} = ExMCP.Client.start_link(transport: :beam, server: endpoint)

      {:ok, result} = ExMCP.Client.call_tool(client, "add", %{"a" => 3, "b" => 7})

      content = get_tool_result_text(result)
      assert content =~ "10"

      ExMCP.Client.stop(client)
      Arbor.Gateway.stop_agent_endpoint(agent_id)
    end

    test "client gets error for unknown tool" do
      {:ok, endpoint} =
        AgentEndpoint.start_link(
          agent_id: "proto-agent-4",
          actions: [EchoAction]
        )

      {:ok, client} = ExMCP.Client.start_link(transport: :beam, server: endpoint)

      {:ok, result} = ExMCP.Client.call_tool(client, "nonexistent", %{})

      # Should return an error result (isError: true in MCP protocol)
      content = get_tool_result_text(result)
      assert content =~ "unknown_tool" or content =~ "Error"

      ExMCP.Client.stop(client)
      GenServer.stop(endpoint)
    end

    test "client handles tool failure" do
      {agent_id, endpoint} = start_authorized_endpoint([FailAction])

      {:ok, client} = ExMCP.Client.start_link(transport: :beam, server: endpoint)

      {:ok, result} = ExMCP.Client.call_tool(client, "fail", %{"reason" => "test failure"})

      content = get_tool_result_text(result)
      assert content =~ "test failure" or content =~ "Error"

      ExMCP.Client.stop(client)
      Arbor.Gateway.stop_agent_endpoint(agent_id)
    end
  end

  # ============================================================================
  # EndpointRegistry
  # ============================================================================

  describe "EndpointRegistry" do
    test "register and lookup" do
      {:ok, endpoint} =
        AgentEndpoint.start_link(
          agent_id: "reg-agent-1",
          actions: [EchoAction]
        )

      tools = AgentEndpoint.list_tools(endpoint)
      :ok = EndpointRegistry.register("reg-agent-1", endpoint, tools)

      assert {:ok, ^endpoint, ^tools} = EndpointRegistry.lookup("reg-agent-1")

      GenServer.stop(endpoint)
    end

    test "unregister removes entry" do
      {:ok, endpoint} =
        AgentEndpoint.start_link(
          agent_id: "reg-agent-2",
          actions: [EchoAction]
        )

      EndpointRegistry.register("reg-agent-2", endpoint, [])
      assert {:ok, _, _} = EndpointRegistry.lookup("reg-agent-2")

      EndpointRegistry.unregister("reg-agent-2")
      assert :error = EndpointRegistry.lookup("reg-agent-2")

      GenServer.stop(endpoint)
    end

    test "lookup returns error for dead process" do
      {:ok, endpoint} =
        AgentEndpoint.start_link(
          agent_id: "reg-agent-3",
          actions: []
        )

      EndpointRegistry.register("reg-agent-3", endpoint, [])
      GenServer.stop(endpoint)

      # Dead process should return :error
      Process.sleep(50)
      assert :error = EndpointRegistry.lookup("reg-agent-3")
    end

    test "list returns alive endpoints only" do
      {:ok, ep1} =
        AgentEndpoint.start_link(
          agent_id: "list-1",
          actions: [EchoAction]
        )

      {:ok, ep2} =
        AgentEndpoint.start_link(
          agent_id: "list-2",
          actions: [EchoAction, AddAction]
        )

      tools1 = AgentEndpoint.list_tools(ep1)
      tools2 = AgentEndpoint.list_tools(ep2)
      EndpointRegistry.register("list-1", ep1, tools1)
      EndpointRegistry.register("list-2", ep2, tools2)

      list = EndpointRegistry.list()
      assert length(list) >= 2

      ids = Enum.map(list, &elem(&1, 0))
      assert "list-1" in ids
      assert "list-2" in ids

      # Kill one, list should filter it
      GenServer.stop(ep1)
      Process.sleep(50)

      list2 = EndpointRegistry.list()
      ids2 = Enum.map(list2, &elem(&1, 0))
      refute "list-1" in ids2
      assert "list-2" in ids2

      GenServer.stop(ep2)
    end
  end

  # ============================================================================
  # Gateway Facade
  # ============================================================================

  describe "Gateway facade" do
    test "start_agent_endpoint registers in registry" do
      {:ok, pid} =
        Arbor.Gateway.start_agent_endpoint("facade-1",
          actions: [EchoAction, AddAction]
        )

      assert Process.alive?(pid)
      assert {:ok, ^pid, tools} = EndpointRegistry.lookup("facade-1")
      assert length(tools) == 2

      Arbor.Gateway.stop_agent_endpoint("facade-1")
    end

    test "stop_agent_endpoint cleans up" do
      {:ok, pid} =
        Arbor.Gateway.start_agent_endpoint("facade-2",
          actions: [EchoAction]
        )

      assert :ok = Arbor.Gateway.stop_agent_endpoint("facade-2")
      refute Process.alive?(pid)
      assert :error = EndpointRegistry.lookup("facade-2")
    end

    test "stop_agent_endpoint returns error for unknown agent" do
      assert {:error, :not_found} = Arbor.Gateway.stop_agent_endpoint("nonexistent")
    end

    test "list_agent_endpoints shows active endpoints" do
      {:ok, _} =
        Arbor.Gateway.start_agent_endpoint("facade-3",
          actions: [EchoAction]
        )

      list = Arbor.Gateway.list_agent_endpoints()
      ids = Enum.map(list, &elem(&1, 0))
      assert "facade-3" in ids

      Arbor.Gateway.stop_agent_endpoint("facade-3")
    end

    test "connect_to_agent creates client for registered endpoint" do
      {:ok, _} =
        Arbor.Gateway.start_agent_endpoint("facade-4",
          actions: [EchoAction]
        )

      {:ok, client} = Arbor.Gateway.connect_to_agent("facade-4")
      assert Process.alive?(client)

      # Use the client
      {:ok, %{tools: tools}} = ExMCP.Client.list_tools(client)
      assert length(tools) == 1
      assert hd(tools).name == "echo"

      ExMCP.Client.stop(client)
      Arbor.Gateway.stop_agent_endpoint("facade-4")
    end

    test "connect_to_agent returns error for unknown agent" do
      assert {:error, {:agent_endpoint_not_found, "unknown-agent"}} =
               Arbor.Gateway.connect_to_agent("unknown-agent")
    end
  end

  # ============================================================================
  # Agent-to-Agent Communication
  # ============================================================================

  describe "agent-to-agent communication" do
    test "full agent-to-agent tool call lifecycle" do
      # Agent A starts an endpoint exposing its actions
      {agent_id, _endpoint} = start_authorized_endpoint([EchoAction, AddAction])

      # Agent B connects to Agent A
      {:ok, client} = Arbor.Gateway.connect_to_agent(agent_id)

      # Agent B discovers Agent A's tools
      {:ok, %{tools: tools}} = ExMCP.Client.list_tools(client)
      assert length(tools) == 2

      # Agent B calls Agent A's echo tool
      {:ok, echo_result} = ExMCP.Client.call_tool(client, "echo", %{"message" => "from B"})
      echo_text = get_tool_result_text(echo_result)
      assert echo_text =~ "from B"

      # Agent B calls Agent A's add tool
      {:ok, add_result} = ExMCP.Client.call_tool(client, "add", %{"a" => 5, "b" => 3})
      add_text = get_tool_result_text(add_result)
      assert add_text =~ "8"

      # Cleanup
      ExMCP.Client.stop(client)
      Arbor.Gateway.stop_agent_endpoint(agent_id)
    end

    test "multiple clients can connect to same endpoint" do
      {:ok, _endpoint} =
        Arbor.Gateway.start_agent_endpoint("multi-agent",
          actions: [EchoAction]
        )

      # Note: Local transport uses last-connected client_pid
      # This test verifies the endpoint doesn't crash with multiple connections
      {:ok, client1} = Arbor.Gateway.connect_to_agent("multi-agent")
      {:ok, client2} = Arbor.Gateway.connect_to_agent("multi-agent")

      # The last client (client2) should work
      {:ok, %{tools: tools}} = ExMCP.Client.list_tools(client2)
      assert length(tools) == 1

      ExMCP.Client.stop(client1)
      ExMCP.Client.stop(client2)
      Arbor.Gateway.stop_agent_endpoint("multi-agent")
    end
  end

  describe "security regression: endpoint principal authority" do
    test "registered typed endpoint executes childless Shell and drops authority after ownership removal" do
      ensure_shell_started()

      {agent_id, endpoint} =
        start_authorized_endpoint(
          [Arbor.Actions.Shell.Execute],
          ["arbor://shell/exec/echo"]
        )

      {:ok, client} = Arbor.Gateway.connect_to_agent(agent_id)

      {:ok, result} =
        ExMCP.Client.call_tool(client, "shell_execute", %{
          "command" => "echo endpoint-fallback-authorized"
        })

      assert get_tool_result_text(result) =~ "endpoint-fallback-authorized"

      :ok = EndpointRegistry.unregister(agent_id)

      {:ok, denied} =
        ExMCP.Client.call_tool(client, "shell_execute", %{
          "command" => "echo endpoint-authority-leaked"
        })

      denied_text = get_tool_result_text(denied)
      assert denied_text =~ "endpoint_principal_unbound"
      refute denied_text =~ "endpoint-authority-leaked\n"

      ExMCP.Client.stop(client)
      GenServer.stop(endpoint)
    end

    test "unregistered endpoint cannot mint authority from a forged scalar agent id" do
      ensure_shell_started()
      agent_id = unique_agent_id("forged-shell")

      {:ok, endpoint} =
        AgentEndpoint.start_link(
          agent_id: agent_id,
          actions: [Arbor.Actions.Shell.Execute]
        )

      :ok = EndpointRegistry.register(agent_id, self(), [])
      {:ok, client} = ExMCP.Client.start_link(transport: :beam, server: endpoint)

      {:ok, denied} =
        ExMCP.Client.call_tool(client, "shell_execute", %{
          "command" => "echo forged-endpoint-authority"
        })

      denied_text = get_tool_result_text(denied)
      assert denied_text =~ "endpoint_principal_unbound"
      refute denied_text =~ "forged-endpoint-authority\n"

      ExMCP.Client.stop(client)
      EndpointRegistry.unregister(agent_id)
      GenServer.stop(endpoint)
    end

    test "registered privileged scalar without typed endpoint proof cannot execute Shell" do
      ensure_shell_started()
      agent_id = unique_agent_id("scalar-only-shell")
      authorize_agent(agent_id, ["arbor://shell/exec/echo"])

      {:ok, _endpoint} =
        Arbor.Gateway.start_agent_endpoint(agent_id,
          actions: [Arbor.Actions.Shell.Execute]
        )

      {:ok, client} = Arbor.Gateway.connect_to_agent(agent_id)

      {:ok, denied} =
        ExMCP.Client.call_tool(client, "shell_execute", %{
          "command" => "echo scalar-endpoint-impersonation"
        })

      denied_text = get_tool_result_text(denied)
      assert denied_text =~ "endpoint_authentication_required"
      refute denied_text =~ "scalar-endpoint-impersonation\n"

      ExMCP.Client.stop(client)
      Arbor.Gateway.stop_agent_endpoint(agent_id)
      Arbor.Security.CapabilityStore.revoke_all(agent_id)
      Arbor.Trust.Store.delete_profile(agent_id)
    end

    test "typed endpoint proof cannot be rebound to a mismatched scalar principal" do
      {signed_agent_id, signed_request} = authenticated_identity("proof-owner")
      other_agent_id = unique_agent_id("proof-mismatch")
      previous_trap_exit = Process.flag(:trap_exit, true)

      try do
        assert {:error, {:endpoint_authentication_failed, :endpoint_signed_request_mismatch}} =
                 Arbor.Gateway.start_agent_endpoint(other_agent_id,
                   actions: [EchoAction],
                   signed_request: signed_request
                 )
      after
        Process.flag(:trap_exit, previous_trap_exit)
      end

      refute signed_agent_id == other_agent_id
      assert :error = EndpointRegistry.lookup(other_agent_id)
    end
  end

  # ============================================================================
  # Security regression — capability gate on MCP tool execution
  # ============================================================================
  #
  # Every endpoint tool call uses the same normal Actions authorization path.
  # A typed endpoint proof authenticates identity, while Trust policy and the
  # exact capability independently decide whether the action may execute.
  describe "security regression: MCP tool execution is capability-gated" do
    setup do
      unless Arbor.Security.healthy?() do
        raise "Security.healthy?() returned false after starting security subsystem"
      end

      :ok
    end

    test "an agent without the capability cannot execute a tool (gate denies; no direct-run bypass)" do
      # Precondition: a missing CapabilityStore would silently route through the
      # unauthenticated fallback path. Make that a LOUD failure, not a fall-through.
      assert Process.whereis(Arbor.Security.CapabilityStore) != nil,
             "CapabilityStore must be alive or the gate falls open to the unauthenticated path"

      assert Arbor.Security.healthy?(),
             "Security must be healthy or authorize/4 runs in permissive mode"

      {agent_id, signed_request} = authenticated_identity("no-cap")

      {:ok, endpoint} =
        Arbor.Gateway.start_agent_endpoint(agent_id,
          actions: [EchoAction],
          signed_request: signed_request
        )

      {:ok, client} = ExMCP.Client.start_link(transport: :beam, server: endpoint)

      {:ok, result} = ExMCP.Client.call_tool(client, "echo", %{"message" => "TOPSECRET"})

      content = get_tool_result_text(result)

      # The action must NOT have run: the echoed payload must be absent and the
      # call must surface as an error (unauthorized).
      refute content =~ "TOPSECRET",
             "Gate failed OPEN: echo payload leaked, meaning the action ran without a capability. Got: #{content}"

      assert content =~ "Error" or content =~ "unauthorized",
             "Expected an authorization error result, got: #{content}"

      ExMCP.Client.stop(client)
      Arbor.Gateway.stop_agent_endpoint(agent_id)
    end

    test "an agent WITH the capability can execute the tool (gate permits)" do
      assert Process.whereis(Arbor.Security.CapabilityStore) != nil
      assert Arbor.Security.healthy?()

      {agent_id, signed_request} = authenticated_identity("with-cap")

      # The test EchoAction is not in the canonical URI map, so it resolves to
      # the legacy fallback URI. Grant exactly that resource for :execute.
      resource = Arbor.Actions.canonical_uri_for(EchoAction, %{})

      authorize_agent(agent_id, [resource])

      {:ok, endpoint} =
        Arbor.Gateway.start_agent_endpoint(agent_id,
          actions: [EchoAction],
          signed_request: signed_request
        )

      {:ok, client} = ExMCP.Client.start_link(transport: :beam, server: endpoint)

      {:ok, result} = ExMCP.Client.call_tool(client, "echo", %{"message" => "AUTHORIZED"})

      content = get_tool_result_text(result)

      assert content =~ "AUTHORIZED",
             "Gate failed CLOSED: an authorized agent's echo did not run. Got: #{content}"

      ExMCP.Client.stop(client)
      Arbor.Gateway.stop_agent_endpoint(agent_id)

      if Process.whereis(Arbor.Security.CapabilityStore) do
        Arbor.Security.CapabilityStore.revoke_all(agent_id)
      end
    end

    test "registered normal endpoint authenticates direct Shell execution" do
      ensure_shell_started()
      {agent_id, signed_request} = authenticated_identity("normal-shell")
      authorize_agent(agent_id, ["arbor://shell/exec/echo"])

      {:ok, _endpoint} =
        Arbor.Gateway.start_agent_endpoint(agent_id,
          actions: [Arbor.Actions.Shell.Execute],
          signed_request: signed_request
        )

      {:ok, client} = Arbor.Gateway.connect_to_agent(agent_id)

      {:ok, result} =
        ExMCP.Client.call_tool(client, "shell_execute", %{
          "command" => "echo endpoint-normal-authorized"
        })

      assert get_tool_result_text(result) =~ "endpoint-normal-authorized"

      ExMCP.Client.stop(client)
      Arbor.Gateway.stop_agent_endpoint(agent_id)
      Arbor.Security.CapabilityStore.revoke_all(agent_id)
    end

    test "registered endpoint keeps principal scope through nested coding validation" do
      ensure_shell_started()
      {agent_id, signed_request} = authenticated_identity("nested-coding")

      authorize_agent(agent_id, [
        Arbor.Actions.canonical_uri_for(NestedCodingValidationAction, %{}),
        "arbor://shell/exec/echo"
      ])

      {:ok, _endpoint} =
        Arbor.Gateway.start_agent_endpoint(agent_id,
          actions: [NestedCodingValidationAction],
          signed_request: signed_request
        )

      {:ok, client} = Arbor.Gateway.connect_to_agent(agent_id)

      {:ok, result} =
        ExMCP.Client.call_tool(client, "nested_coding_validation", %{
          "command" => "echo nested-coding-validation-authorized"
        })

      assert get_tool_result_text(result) =~ "nested-coding-validation-authorized"

      ExMCP.Client.stop(client)
      Arbor.Gateway.stop_agent_endpoint(agent_id)
      Arbor.Security.CapabilityStore.revoke_all(agent_id)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp unique_agent_id(tag) do
    "agent_endpoint_#{tag}_#{System.unique_integer([:positive])}"
  end

  defp start_authorized_endpoint(actions, resources \\ nil) do
    {agent_id, signed_request} = authenticated_identity("authorized")

    resources =
      resources || Enum.map(actions, &Arbor.Actions.canonical_uri_for(&1, %{}))

    authorize_agent(agent_id, resources)

    {:ok, endpoint} =
      Arbor.Gateway.start_agent_endpoint(agent_id,
        actions: actions,
        signed_request: signed_request
      )

    {agent_id, endpoint}
  end

  defp authenticated_identity(tag) do
    {:ok, identity} = Arbor.Security.generate_identity(name: "gateway-endpoint-#{tag}")
    :ok = Arbor.Security.register_identity(identity)
    payload = Arbor.Gateway.agent_endpoint_authentication_payload(identity.agent_id)
    {:ok, signed_request} = SignedRequest.sign(payload, identity.agent_id, identity.private_key)

    on_exit(fn ->
      if Process.whereis(Arbor.Security.CapabilityStore) do
        Arbor.Security.CapabilityStore.revoke_all(identity.agent_id)
      end

      if Process.whereis(Arbor.Trust.Store) do
        Arbor.Trust.Store.delete_profile(identity.agent_id)
      end

      Arbor.Security.deregister_identity(identity.agent_id)
    end)

    {identity.agent_id, signed_request}
  end

  defp ensure_security_started do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)

    security_children = [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.Constraint.RateLimiter, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ]

    for {module, opts} <- security_children do
      unless Process.whereis(module) do
        case Supervisor.start_child(Arbor.Security.Supervisor, {module, opts}) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to start #{inspect(module)}: #{inspect(reason)}"
        end
      end
    end

    unless Process.whereis(Arbor.Trust.Store), do: start_supervised!(Arbor.Trust.Store)
  end

  defp ensure_shell_started do
    unless Process.whereis(Arbor.Shell.ExecutablePolicy) do
      start_supervised!({Arbor.Shell.ExecutablePolicy, startup_path: System.get_env("PATH", "")})
    end

    unless Process.whereis(Arbor.Shell.ExecutionRegistry) do
      start_supervised!(Arbor.Shell.ExecutionRegistry)
    end

    unless Process.whereis(Arbor.Shell.PortSessionSupervisor) do
      start_supervised!(
        {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
      )
    end
  end

  defp authorize_agent(agent_id, resources) do
    unless Process.whereis(Arbor.Trust.Store) do
      start_supervised!(Arbor.Trust.Store)
    end

    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(agent_id)

    rules = Enum.reduce(resources, profile.rules, &Map.put(&2, &1, :auto))
    :ok = Arbor.Trust.Store.store_profile(%{profile | rules: rules})

    Enum.each(resources, fn resource ->
      assert {:ok, _capability} =
               Arbor.Security.grant(principal: agent_id, resource: resource)
    end)
  end

  # Extract text content from MCP tool result
  defp get_tool_result_text(result) do
    cond do
      is_map(result) and is_list(result[:content]) ->
        Enum.map_join(result[:content], fn
          %{text: text} -> text
          %{"text" => text} -> text
          _ -> ""
        end)

      is_map(result) and is_list(result["content"]) ->
        Enum.map_join(result["content"], fn
          %{"text" => text} -> text
          _ -> ""
        end)

      is_map(result) ->
        inspect(result)

      true ->
        inspect(result)
    end
  end
end
