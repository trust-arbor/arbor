defmodule Arbor.Gateway.MCP.HandlerTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Gateway.MCP.Handler

  setup do
    # Ensure ETS tables exist for memory/security lookups
    for table <- [
          :arbor_memory_graphs,
          :arbor_working_memory,
          :arbor_memory_proposals,
          :arbor_chat_history,
          :arbor_preferences
        ] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    {:ok, state: %{}}
  end

  # ===========================================================================
  # Initialization
  # ===========================================================================

  describe "handle_initialize/2" do
    test "returns server info and capabilities", %{state: state} do
      params = %{"protocolVersion" => "2024-11-05"}
      {:ok, result, new_state} = Handler.handle_initialize(params, state)

      assert result.protocolVersion == "2024-11-05"
      assert result.serverInfo.name == "arbor"
      assert result.serverInfo.version == "0.1.0"
      assert is_map(result.capabilities.tools)
      assert new_state == state
    end

    test "defaults protocol version when not provided", %{state: state} do
      {:ok, result, _state} = Handler.handle_initialize(%{}, state)
      assert result.protocolVersion == "2024-11-05"
    end
  end

  # ===========================================================================
  # Tool Listing
  # ===========================================================================

  describe "handle_list_tools/2" do
    test "returns 4 tools", %{state: state} do
      {:ok, tools, nil, _state} = Handler.handle_list_tools(nil, state)
      assert length(tools) == 4

      names = Enum.map(tools, & &1.name) |> Enum.sort()
      assert names == ["arbor_actions", "arbor_help", "arbor_run", "arbor_status"]
    end

    test "all tools have required fields", %{state: state} do
      {:ok, tools, _, _} = Handler.handle_list_tools(nil, state)

      for tool <- tools do
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_map(tool.inputSchema)
        assert tool.inputSchema.type == "object"
      end
    end

    test "arbor_help requires 'action' parameter", %{state: state} do
      {:ok, tools, _, _} = Handler.handle_list_tools(nil, state)
      help_tool = Enum.find(tools, &(&1.name == "arbor_help"))
      assert "action" in help_tool.inputSchema.required
    end

    # agent_id is no longer in inputSchema — it comes from SignedRequestAuth
    test "arbor_run requires 'action' and 'params' (agent_id via auth)", %{state: state} do
      {:ok, tools, _, _} = Handler.handle_list_tools(nil, state)
      run_tool = Enum.find(tools, &(&1.name == "arbor_run"))
      assert "action" in run_tool.inputSchema.required
      assert "params" in run_tool.inputSchema.required
      refute "agent_id" in run_tool.inputSchema.required
    end

    test "arbor_status requires 'component'", %{state: state} do
      {:ok, tools, _, _} = Handler.handle_list_tools(nil, state)
      status_tool = Enum.find(tools, &(&1.name == "arbor_status"))
      assert "component" in status_tool.inputSchema.required
    end
  end

  # ===========================================================================
  # arbor_actions tool
  # ===========================================================================

  describe "arbor_actions" do
    # These tests require Arbor.Actions to be loaded (cross-app dependency).
    # They pass from umbrella root but not from gateway app in isolation.
    @describetag :integration

    test "lists all categories with no filter", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_actions", %{}, state)

      assert text =~ "# Arbor Actions"
      # Should contain at least some well-known categories
      assert text =~ "shell"
      assert text =~ "file"
    end

    test "filters to a specific category", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_actions", %{"category" => "shell"}, state)

      assert text =~ "shell"
      assert text =~ "shell_execute"
    end

    test "returns error for unknown category", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_actions", %{"category" => "nonexistent_xyz"}, state)

      assert text =~ "Unknown category"
      assert text =~ "Available:"
    end
  end

  # ===========================================================================
  # arbor_help tool
  # ===========================================================================

  describe "arbor_help" do
    # These tests require Arbor.Actions to be loaded (cross-app dependency).
    @describetag :integration

    test "returns schema for known action", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_help", %{"action" => "shell_execute"}, state)

      assert text =~ "# shell_execute"
      assert text =~ "## Parameters"
      assert text =~ "command"
      assert text =~ "## Taint Roles"
    end

    test "returns schema for file action", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_help", %{"action" => "file_exists"}, state)

      assert text =~ "# file_exists"
      assert text =~ "## Parameters"
      assert text =~ "path"
    end

    test "returns not found for unknown action", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_help", %{"action" => "totally_fake_action"}, state)

      assert text =~ "not found"
      assert text =~ "arbor_actions"
    end

    test "shows category and tags", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_help", %{"action" => "shell_execute"}, state)

      assert text =~ "## Category:"
      assert text =~ "## Tags:"
    end
  end

  # ===========================================================================
  # arbor_run tool
  # ===========================================================================

  describe "arbor_run" do
    # L1: All arbor_run tests now include agent_id (C1/C2 fix)
    test "executes file_exists action with agent_id", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool(
          "arbor_run",
          %{
            "action" => "file_exists",
            "params" => %{"path" => "/tmp"},
            "agent_id" => "test_agent_001"
          },
          state
        )

      # With authorization, may get Success or Unauthorized depending on test setup
      assert text =~ "Success" or text =~ "Unauthorized" or text =~ "Error"
    end

    test "handles action not found with authenticated agent", %{state: state} do
      # Simulate SignedRequestAuth having verified the agent
      Process.put(:arbor_authenticated_agent_id, "test_agent_001")

      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool(
          "arbor_run",
          %{
            "action" => "nonexistent_action",
            "params" => %{}
          },
          state
        )

      assert text =~ "not found" or text =~ "Unauthorized" or text =~ "Error"
    after
      Process.delete(:arbor_authenticated_agent_id)
    end

    test "rejects execution without authenticated agent_id", %{state: state} do
      # No Process.put — simulates unauthenticated request
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool(
          "arbor_run",
          %{"action" => "file_exists", "params" => %{"path" => "/tmp"}},
          state
        )

      # Must reject when no authenticated agent_id in process dict
      assert text =~ "SignedRequest authentication" or text =~ "agent_id"
    end

    test "rejects execution when agent_id passed in params instead of auth", %{state: state} do
      # agent_id in params is ignored — must come from SignedRequestAuth
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool(
          "arbor_run",
          %{
            "action" => "file_exists",
            "params" => %{"path" => "/tmp"},
            "agent_id" => "test_agent_sneaky"
          },
          state
        )

      # Should still reject — agent_id in params is not trusted
      assert text =~ "SignedRequest authentication" or text =~ "agent_id"
    end

    test "handles missing params gracefully", %{state: state} do
      Process.put(:arbor_authenticated_agent_id, "test_agent_001")

      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool(
          "arbor_run",
          %{"action" => "file_exists"},
          state
        )

      # Should error since path is required
      assert text =~ "Error" or text =~ "not found" or text =~ "Unauthorized"
    after
      Process.delete(:arbor_authenticated_agent_id)
    end
  end

  # ===========================================================================
  # arbor_status tool
  # ===========================================================================

  describe "arbor_status" do
    test "overview returns structured status", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "overview"}, state)

      assert text =~ "# Arbor System Status"
      assert text =~ "## Agents"
      assert text =~ "## Memory"
      assert text =~ "## Signals"
    end

    test "agents component works", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "agents"}, state)

      assert text =~ "Agent" or text =~ "running" or text =~ "unavailable"
    end

    test "signals component works", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "signals"}, state)

      assert text =~ "Signal"
    end

    test "unknown component returns helpful message", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "foobar"}, state)

      assert text =~ "Unknown component"
      assert text =~ "agents"
      assert text =~ "overview"
    end

    test "memory component returns status", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "memory"}, state)

      # Might be "No agent running" or actual memory data
      assert is_binary(text) and byte_size(text) > 0
    end

    test "goals component returns status", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "goals"}, state)

      assert is_binary(text) and byte_size(text) > 0
    end

    test "capabilities component returns status", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "capabilities"}, state)

      assert is_binary(text) and byte_size(text) > 0
    end
  end

  # ===========================================================================
  # Unknown tool
  # ===========================================================================

  describe "unknown tools" do
    test "returns error for unknown tool name", %{state: state} do
      {:ok, result, _state} =
        Handler.handle_call_tool("totally_unknown_tool", %{}, state)

      assert result.isError == true
      assert [%{type: "text", text: text}] = result.content
      assert text =~ "Unknown tool"
    end
  end

  # ===========================================================================
  # MCP client integration in handler
  # ===========================================================================

  describe "MCP status component" do
    test "returns no connections message when no MCP servers", %{state: state} do
      {:ok, result, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "mcp"}, state)

      [%{type: "text", text: text}] = result.content
      assert text =~ "No external MCP servers connected"
      assert text =~ "No agent endpoints active"
    end
  end

  describe "MCP tool dispatch via arbor_run" do
    test "returns not connected error for disconnected MCP tool", %{state: state} do
      {:ok, result, _state} =
        Handler.handle_call_tool(
          "arbor_run",
          %{
            "action" => "mcp.nonexistent.some_tool",
            "params" => %{},
            "agent_id" => "test_agent"
          },
          state
        )

      [%{type: "text", text: text}] = result.content
      # Identity Registry may reject unknown agent_id before MCP dispatch
      assert text =~ "not connected" or text =~ "Error" or text =~ "Unauthorized"
    end
  end

  describe "MCP category in arbor_actions" do
    test "returns no servers message when filtering by mcp category", %{state: state} do
      {:ok, result, _state} =
        Handler.handle_call_tool("arbor_actions", %{"category" => "mcp"}, state)

      [%{type: "text", text: text}] = result.content
      assert text =~ "No MCP servers connected"
    end
  end

  # ===========================================================================
  # init/1
  # ===========================================================================

  describe "init/1" do
    test "returns empty state" do
      assert {:ok, %{}} = Handler.init([])
    end
  end

  describe "signed_request threading (H1 regression)" do
    setup do
      Process.delete(:arbor_authenticated_signed_request)
      :ok
    end

    test "security regression (H1): signed_request from process dict reaches action context" do
      # H1: pre-fix, Arbor.Gateway.SignedRequestAuth stashed only agent_id in
      # the process dict — the signed_request struct it had just verified was
      # discarded. The MCP handler then called Arbor.Actions.authorize_and_execute
      # with no :signed_request in the context, so action-layer
      # `verify_identity: true` failed with :missing_signed_request even
      # though the gateway HAD verified the request. The fix stashes the
      # signed_request alongside agent_id and threads it through.
      fake_signed_request = %{
        agent_id: "human_h1",
        signature: "fake-signature",
        bound_payload: "fake-payload"
      }

      Process.put(:arbor_authenticated_signed_request, fake_signed_request)

      result = Handler.maybe_put_signed_request(%{workspace: "/tmp"})

      assert result[:signed_request] == fake_signed_request,
             "Authenticated signed_request must reach the action context — H1 regression"

      assert result[:workspace] == "/tmp",
             "Existing context keys must be preserved"
    end

    test "no signed_request in process dict → context unchanged" do
      context = %{workspace: "/tmp"}

      assert Handler.maybe_put_signed_request(context) == context,
             "Without a signed_request the context must pass through unchanged"
    end
  end

  describe "arbor_status access control (M8 regression)" do
    setup do
      # Handler reads :arbor_authenticated_agent_id from the request process's
      # dict (set by SignedRequestAuth). Clear between tests.
      Process.delete(:arbor_authenticated_agent_id)
      :ok
    end

    test "security regression (M8): omitting agent_id no longer defaults to first agent for memory",
         %{state: state} do
      # M8: previously, calling arbor_status with component=memory and no
      # agent_id silently picked the first registered agent and returned
      # their working memory. Any authenticated MCP client could enumerate
      # state without naming a target. The fix requires an explicit agent_id.
      Process.put(:arbor_authenticated_agent_id, "caller_m8_test")

      {:ok, result, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "memory"}, state)

      [%{type: "text", text: text}] = result.content

      assert text =~ "requires an explicit `agent_id`",
             "Expected the M8 denial message about explicit agent_id, got: #{inspect(text)}"

      refute text =~ ~r/^# Memory for/,
             "Memory detail leaked despite missing agent_id — M8 regression"
    end

    test "security regression (M8): omitting agent_id no longer defaults to first agent for capabilities",
         %{state: state} do
      Process.put(:arbor_authenticated_agent_id, "caller_m8_test")

      {:ok, result, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "capabilities"}, state)

      [%{type: "text", text: text}] = result.content
      assert text =~ "requires an explicit `agent_id`"
    end

    test "security regression (M8): omitting agent_id no longer defaults to first agent for goals",
         %{state: state} do
      Process.put(:arbor_authenticated_agent_id, "caller_m8_test")

      {:ok, result, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "goals"}, state)

      [%{type: "text", text: text}] = result.content
      assert text =~ "requires an explicit `agent_id`"
    end

    test "security regression (M8): no authenticated caller denies access", %{state: state} do
      # No Process.put — simulates a request that reached the handler without
      # the SignedRequestAuth pipeline running (or one whose auth was stripped).
      {:ok, result, _state} =
        Handler.handle_call_tool(
          "arbor_status",
          %{"component" => "memory", "agent_id" => "any_target"},
          state
        )

      [%{type: "text", text: text}] = result.content

      assert text =~ "no authenticated caller",
             "Expected the M8 unauthenticated-caller denial, got: #{inspect(text)}"

      refute text =~ ~r/^# Memory for/,
             "Memory detail returned despite missing caller — M8 regression"
    end

    test "security regression (M8): caller without capability is denied", %{state: state} do
      # Caller is authenticated but holds no arbor://status/memory/{target} cap.
      Process.put(:arbor_authenticated_agent_id, "caller_no_cap_m8")

      {:ok, result, _state} =
        Handler.handle_call_tool(
          "arbor_status",
          %{"component" => "memory", "agent_id" => "victim_m8"},
          state
        )

      [%{type: "text", text: text}] = result.content

      assert text =~ "not authorized" or text =~ "no_capability",
             "Expected the M8 unauthorized denial, got: #{inspect(text)}"

      refute text =~ ~r/^# Memory for/,
             "Memory detail returned without an authorizing capability — M8 regression"
    end

    test "security regression: agents detail (caps+goals) is gated per-target like other components",
         %{state: state} do
      # codex authz.mcp-agents-status-detail-bypass: component="agents" with an
      # agent_id returns the agent's Profile + capabilities + goals — the same
      # sensitive data the capabilities/goals components gate. Pre-fix it skipped
      # the per-target authorization, so an authenticated caller without an
      # arbor://status/agents/{target} cap could read any agent's caps + goals.
      Process.put(:arbor_authenticated_agent_id, "caller_no_cap_agents")

      {:ok, result, _state} =
        Handler.handle_call_tool(
          "arbor_status",
          %{"component" => "agents", "agent_id" => "victim_agents"},
          state
        )

      [%{type: "text", text: text}] = result.content

      assert text =~ "not authorized" or text =~ "no_capability",
             "Expected an authz denial for the agents detail, got: #{inspect(text)}"

      refute text =~ "## Profile",
             "Agent detail (profile/caps/goals) leaked without an authorizing capability"
    end

    test "security regression: agents detail with no authenticated caller is denied", %{
      state: state
    } do
      # No Process.put — unauthenticated request must not get agent detail.
      {:ok, result, _state} =
        Handler.handle_call_tool(
          "arbor_status",
          %{"component" => "agents", "agent_id" => "victim_agents"},
          state
        )

      [%{type: "text", text: text}] = result.content

      assert text =~ "no authenticated caller"
      refute text =~ "## Profile"
    end

    test "security regression (M8): overview component does not name any specific agent",
         %{state: state} do
      # M8: the "overview" component used to embed get_memory_summary, which
      # called find_first_agent_id and reported "Agent X: N notes". That
      # leaked the agent_id and a memory-content count to every caller.
      # Overview now reports only aggregate counts.
      Process.put(:arbor_authenticated_agent_id, "caller_overview_m8")

      {:ok, result, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "overview"}, state)

      [%{type: "text", text: text}] = result.content

      refute text =~ ~r/Agent agent_\w+: \d+ notes/,
             "Overview component leaks a specific agent_id and memory count — M8 regression"
    end
  end
end
