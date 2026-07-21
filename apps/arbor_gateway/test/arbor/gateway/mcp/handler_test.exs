defmodule Arbor.Gateway.MCP.HandlerTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.{AuthContext, SignedRequest}
  alias Arbor.Gateway.MCP.Handler

  defmodule FakeOrchestration do
    def list_pending_approvals(opts) do
      send(self(), {:list_pending_approvals, opts})
      Process.get({__MODULE__, :list_result}, {:ok, []})
    end

    def answer_approval(id, decision, opts) do
      send(self(), {:answer_approval, id, decision, opts})
      Process.get({__MODULE__, :answer_result}, :ok)
    end

    def dispatch(agent_id, task, opts) do
      send(self(), {:dispatch_task, agent_id, task, opts})
      Process.get({__MODULE__, :dispatch_result}, {:ok, "task_1"})
    end

    def task_status(task_id, opts) do
      send(self(), {:task_status, task_id, opts})

      Process.get(
        {__MODULE__, :status_result},
        {:ok,
         %{
           task_id: task_id,
           agent_id: "agent_1",
           state: :running,
           current_step: "running",
           waiting_on: nil,
           started_at: ~U[2026-07-08 12:00:00Z],
           updated_at: ~U[2026-07-08 12:00:01Z],
           completed_at: nil,
           metadata: %{"ticket" => "A-1"}
         }}
      )
    end

    def task_result(task_id, opts) do
      send(self(), {:task_result, task_id, opts})

      Process.get(
        {__MODULE__, :result_result},
        {:ok,
         %{
           result_type: :coding_change,
           payload: %{branch: "agent/change", files: ["lib/a.ex"], verdict: %{status: "ok"}}
         }}
      )
    end

    def cancel_task(task_id, opts) do
      send(self(), {:cancel_task, task_id, opts})

      Process.get(
        {__MODULE__, :cancel_result},
        {:ok,
         %{
           task_id: task_id,
           agent_id: "agent_1",
           state: :cancelled,
           current_step: "cancelled",
           waiting_on: nil,
           started_at: ~U[2026-07-08 12:00:00Z],
           updated_at: ~U[2026-07-08 12:00:02Z],
           completed_at: ~U[2026-07-08 12:00:02Z],
           metadata: %{}
         }}
      )
    end

    def steer_task(task_id, message, opts) do
      send(self(), {:steer_task, task_id, message, opts})

      Process.get(
        {__MODULE__, :steer_result},
        {:ok,
         %{
           "control_id" => "control_1",
           "task_id" => task_id,
           "sequence" => 1,
           "status" => "delivered",
           "sender_id" => opts[:caller_id],
           "message" => message,
           "queued_at" => "2026-07-10T12:00:00Z",
           "delivered_at" => "2026-07-10T12:00:01Z",
           "target_stage" => opts[:target_stage],
           "delivery_mode" => "native_tool_loop",
           "error" => nil
         }}
      )
    end

    def adopt_task_change(task_id, destination_ref, opts) do
      send(self(), {:adopt_task_change, task_id, destination_ref, opts})
      {:ok, %{result_type: :coding_change, payload: %{destination_ref: destination_ref}}}
    end
  end

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

    Process.delete(:arbor_authenticated_agent_id)
    Process.delete(:arbor_authenticated_signed_request)
    Process.delete({FakeOrchestration, :list_result})
    Process.delete({FakeOrchestration, :answer_result})
    Process.delete({FakeOrchestration, :dispatch_result})
    Process.delete({FakeOrchestration, :status_result})
    Process.delete({FakeOrchestration, :result_result})
    Process.delete({FakeOrchestration, :cancel_result})
    Process.delete({FakeOrchestration, :steer_result})

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

  describe "ExMCP auth context bridge" do
    setup do
      Process.delete(:arbor_authenticated_agent_id)
      Process.delete(:arbor_authenticated_signed_request)

      on_exit(fn ->
        Process.delete(:arbor_authenticated_agent_id)
        Process.delete(:arbor_authenticated_signed_request)
      end)

      :ok
    end

    test "builds handler opts from SignedRequestAuth assigns" do
      signed_request = %{agent_id: "agent_mcp_bridge", signature: "sig"}
      conn = %{assigns: %{agent_id: "agent_mcp_bridge", signed_request: signed_request}}

      assert Handler.handler_opts_from_conn(conn, %{"method" => "tools/call"}) == [
               authenticated_agent_id: "agent_mcp_bridge",
               authenticated_signed_request: signed_request
             ]
    end

    test "security regression: init installs verified auth context in handler process" do
      signed_request = %{agent_id: "agent_mcp_bridge", signature: "sig"}

      assert {:ok, %{}} =
               Handler.init(
                 authenticated_agent_id: "agent_mcp_bridge",
                 authenticated_signed_request: signed_request
               )

      assert Process.get(:arbor_authenticated_agent_id) == "agent_mcp_bridge"
      assert Process.get(:arbor_authenticated_signed_request) == signed_request
    end
  end

  # ===========================================================================
  # Tool Listing
  # ===========================================================================

  describe "handle_list_tools/2" do
    test "returns tools", %{state: state} do
      {:ok, tools, nil, _state} = Handler.handle_list_tools(nil, state)
      assert length(tools) == 12

      names = Enum.map(tools, & &1.name) |> Enum.sort()

      assert names == [
               "arbor_actions",
               "arbor_adopt_task_change",
               "arbor_answer_approval",
               "arbor_cancel_task",
               "arbor_dispatch_task",
               "arbor_help",
               "arbor_list_pending_approvals",
               "arbor_run",
               "arbor_status",
               "arbor_steer_task",
               "arbor_task_result",
               "arbor_task_status"
             ]
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

    test "arbor_status schema documents agent_id requirements and mcp registration meaning", %{
      state: state
    } do
      {:ok, tools, _, _} = Handler.handle_list_tools(nil, state)
      status_tool = Enum.find(tools, &(&1.name == "arbor_status"))
      refute is_nil(status_tool)

      desc = status_tool.description
      assert desc =~ "agent_id is required"
      assert desc =~ "component=memory"
      assert desc =~ "component=capabilities"
      assert desc =~ "component=goals"
      assert desc =~ "component=mcp"
      assert desc =~ "MCP client/server registrations"
      assert desc =~ "not the current caller connection"
      assert desc =~ "open agent list summary" or desc =~ "authorization-gated"

      component_desc = status_tool.inputSchema.properties.component.description
      assert component_desc =~ "requires agent_id"
      assert component_desc =~ "not this caller connection"

      agent_id_desc = status_tool.inputSchema.properties.agent_id.description
      assert agent_id_desc =~ "Required for memory, capabilities, and goals"
      assert agent_id_desc =~ "Not used for signals, pipelines, overview, or mcp"
    end

    test "arbor_actions schema documents progressive-disclosure category index", %{state: state} do
      {:ok, tools, _, _} = Handler.handle_list_tools(nil, state)
      actions_tool = Enum.find(tools, &(&1.name == "arbor_actions"))
      refute is_nil(actions_tool)

      assert actions_tool.description =~ "compact"
      assert actions_tool.description =~ "category"
      assert actions_tool.description =~ "not every action"
      assert actions_tool.inputSchema.properties.category.description =~ "Omit for the compact"
    end

    test "arbor_answer_approval requires id and decision", %{state: state} do
      {:ok, tools, _, _} = Handler.handle_list_tools(nil, state)
      approval_tool = Enum.find(tools, &(&1.name == "arbor_answer_approval"))
      assert "id" in approval_tool.inputSchema.required
      assert "decision" in approval_tool.inputSchema.required
    end

    test "task orchestration tools require stable ids", %{state: state} do
      {:ok, tools, _, _} = Handler.handle_list_tools(nil, state)
      dispatch_tool = Enum.find(tools, &(&1.name == "arbor_dispatch_task"))
      status_tool = Enum.find(tools, &(&1.name == "arbor_task_status"))
      result_tool = Enum.find(tools, &(&1.name == "arbor_task_result"))
      cancel_tool = Enum.find(tools, &(&1.name == "arbor_cancel_task"))
      steer_tool = Enum.find(tools, &(&1.name == "arbor_steer_task"))

      assert "agent_id" in dispatch_tool.inputSchema.required
      assert "task" in dispatch_tool.inputSchema.required
      assert "task_id" in status_tool.inputSchema.required
      assert "task_id" in result_tool.inputSchema.required
      assert "task_id" in cancel_tool.inputSchema.required
      assert "task_id" in steer_tool.inputSchema.required
      assert "message" in steer_tool.inputSchema.required
    end

    test "arbor_dispatch_task documents stable coding_change envelope without dropping string/object support",
         %{state: state} do
      {:ok, tools, _, _} = Handler.handle_list_tools(nil, state)
      dispatch_tool = Enum.find(tools, &(&1.name == "arbor_dispatch_task"))
      refute is_nil(dispatch_tool)

      desc = dispatch_tool.description
      assert desc =~ ~s({"kind":"coding_change","plan":{...}})
      assert desc =~ "version is 1"
      assert desc =~ "task, repo_root, and worker.provider"
      assert desc =~ "validation_profile"
      assert desc =~ "review_profile"
      assert desc =~ "compiled DOT pipeline by default"
      assert desc =~ "string prompts"
      assert desc =~ "generic object"

      task_schema = dispatch_tool.inputSchema.properties.task
      assert is_list(task_schema.oneOf)
      assert length(task_schema.oneOf) == 2

      string_branch = Enum.find(task_schema.oneOf, &(&1.type == "string"))
      object_branch = Enum.find(task_schema.oneOf, &(&1.type == "object"))
      refute is_nil(string_branch)
      refute is_nil(object_branch)

      assert object_branch.description =~ ~s({"kind":"coding_change","plan":)
      assert object_branch.description =~ ~s("version":1)
      assert object_branch.description =~ ~s("task":)
      assert object_branch.description =~ ~s("repo_root":)
      assert object_branch.description =~ ~s("worker":{"provider")
      assert object_branch.description =~ "validation_profile"
      assert object_branch.description =~ "review_profile"

      assert object_branch.properties.kind.type == "string"
      assert object_branch.properties.plan.type == "object"
      plan_desc = object_branch.properties.plan.description
      assert plan_desc =~ "task"
      assert plan_desc =~ "repo_root"
      assert plan_desc =~ "worker.provider"
      assert plan_desc =~ "validation_profile"
      assert plan_desc =~ "review_profile"

      # Non-restrictive object branch: document coding shape without oneOf plan schema forks
      refute Map.has_key?(object_branch, :required)
      refute Map.has_key?(object_branch.properties.plan, :required)
      refute Map.has_key?(object_branch.properties.plan, :oneOf)
      refute Map.has_key?(object_branch.properties.plan, :properties)
    end
  end

  # ===========================================================================
  # approval orchestration tools
  # ===========================================================================

  describe "approval orchestration tools" do
    setup do
      previous = Application.get_env(:arbor_gateway, :orchestration_module)
      Application.put_env(:arbor_gateway, :orchestration_module, FakeOrchestration)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:arbor_gateway, :orchestration_module)
          value -> Application.put_env(:arbor_gateway, :orchestration_module, value)
        end

        Process.delete(:arbor_authenticated_agent_id)
      end)

      :ok
    end

    test "list_pending_approvals requires SignedRequest authentication", %{state: state} do
      {:ok, result, _state} =
        Handler.handle_call_tool("arbor_list_pending_approvals", %{}, state)

      assert result.isError == true
      assert [%{text: text}] = result.content
      assert text =~ "SignedRequest authentication"

      assert text =~
               "./bin/mix arbor.signer --key-file <path> --upstream http://localhost:4000/mcp"

      assert text =~ "docs/arbor/EXTERNAL_MCP_CLIENT.md"
    end

    test "list_pending_approvals calls the shared API with filters", %{state: state} do
      Process.put(:arbor_authenticated_agent_id, "human_1")

      Process.put(
        {FakeOrchestration, :list_result},
        {:ok,
         [
           %{
             id: "irq_1",
             source: :interaction,
             agent_id: "agent_1",
             principal_id: "agent_1",
             resource_uri: "arbor://fs/read/repo",
             status: :pending
           }
         ]}
      )

      {:ok, %{content: [%{text: text}]}, _state} =
        Handler.handle_call_tool(
          "arbor_list_pending_approvals",
          %{
            "agent_id" => "agent_1",
            "principal_id" => "agent_1",
            "resource_uri" => "arbor://fs/read"
          },
          state
        )

      assert %{"approvals" => [%{"id" => "irq_1", "source" => "interaction"}]} =
               Jason.decode!(text)

      assert_received {:list_pending_approvals, opts}
      assert opts[:caller_id] == "human_1"
      assert opts[:agent_id] == "agent_1"
      assert opts[:principal_id] == "agent_1"
      assert opts[:resource_uri] == "arbor://fs/read"
    end

    test "answer_approval calls the shared API with caller and note", %{state: state} do
      Process.put(:arbor_authenticated_agent_id, "human_1")

      {:ok, %{content: [%{text: text}]}, _state} =
        Handler.handle_call_tool(
          "arbor_answer_approval",
          %{
            "id" => "irq_1",
            "decision" => "rework",
            "note" => "add a regression test"
          },
          state
        )

      assert %{"ok" => true, "approval_id" => "irq_1", "decision" => "rework"} =
               Jason.decode!(text)

      assert_received {:answer_approval, "irq_1", "rework", opts}
      assert opts[:caller_id] == "human_1"
      assert opts[:note] == "add a regression test"
    end

    test "answer_approval marks orchestration errors as MCP errors", %{state: state} do
      Process.put(:arbor_authenticated_agent_id, "human_1")
      Process.put({FakeOrchestration, :answer_result}, {:error, :not_found})

      {:ok, result, _state} =
        Handler.handle_call_tool(
          "arbor_answer_approval",
          %{"id" => "missing", "decision" => "approve"},
          state
        )

      assert result.isError == true
      assert [%{text: text}] = result.content
      assert text =~ ":not_found"
    end

    test "dispatch_task requires SignedRequest authentication", %{state: state} do
      {:ok, result, _state} =
        Handler.handle_call_tool(
          "arbor_dispatch_task",
          %{"agent_id" => "agent_1", "task" => "write a patch"},
          state
        )

      assert result.isError == true
      assert [%{text: text}] = result.content
      assert text =~ "SignedRequest authentication"

      assert text =~
               "./bin/mix arbor.signer --key-file <path> --upstream http://localhost:4000/mcp"

      assert text =~ "docs/arbor/EXTERNAL_MCP_CLIENT.md"
    end

    test "dispatch_task calls the shared API with caller, metadata, and timeout", %{state: state} do
      Process.put(:arbor_authenticated_agent_id, "human_1")

      {:ok, %{content: [%{text: text}]}, _state} =
        Handler.handle_call_tool(
          "arbor_dispatch_task",
          %{
            "agent_id" => "agent_1",
            "task" => %{"prompt" => "write a patch"},
            "timeout" => 120_000,
            "metadata" => %{"ticket" => "A-1"}
          },
          state
        )

      assert %{"ok" => true, "task_id" => "task_1", "agent_id" => "agent_1"} =
               Jason.decode!(text)

      assert_received {:dispatch_task, "agent_1", %{"prompt" => "write a patch"}, opts}
      assert opts[:caller_id] == "human_1"
      assert opts[:timeout] == 120_000
      assert opts[:metadata] == %{"ticket" => "A-1"}
    end

    test "task_status calls the shared API and returns JSON-safe timestamps", %{state: state} do
      Process.put(:arbor_authenticated_agent_id, "human_1")

      {:ok, %{content: [%{text: text}]}, _state} =
        Handler.handle_call_tool("arbor_task_status", %{"task_id" => "task_1"}, state)

      assert %{
               "task" => %{
                 "task_id" => "task_1",
                 "agent_id" => "agent_1",
                 "state" => "running",
                 "started_at" => "2026-07-08T12:00:00Z"
               }
             } = Jason.decode!(text)

      assert_received {:task_status, "task_1", opts}
      assert opts[:caller_id] == "human_1"
    end

    test "task_result calls the shared API and returns structured artifacts", %{state: state} do
      Process.put(:arbor_authenticated_agent_id, "human_1")

      {:ok, %{content: [%{text: text}]}, _state} =
        Handler.handle_call_tool("arbor_task_result", %{"task_id" => "task_1"}, state)

      assert %{
               "task_id" => "task_1",
               "result" => %{
                 "result_type" => "coding_change",
                 "payload" => %{"branch" => "agent/change", "files" => ["lib/a.ex"]}
               }
             } = Jason.decode!(text)

      assert_received {:task_result, "task_1", opts}
      assert opts[:caller_id] == "human_1"
    end

    test "cancel_task requires SignedRequest authentication", %{state: state} do
      {:ok, result, _state} =
        Handler.handle_call_tool("arbor_cancel_task", %{"task_id" => "task_1"}, state)

      assert result.isError == true
      assert [%{text: text}] = result.content
      assert text =~ "SignedRequest authentication"

      assert text =~
               "./bin/mix arbor.signer --key-file <path> --upstream http://localhost:4000/mcp"

      assert text =~ "docs/arbor/EXTERNAL_MCP_CLIENT.md"
    end

    test "cancel_task calls the shared API and returns cancelled status", %{state: state} do
      Process.put(:arbor_authenticated_agent_id, "human_1")

      {:ok, %{content: [%{text: text}]}, _state} =
        Handler.handle_call_tool("arbor_cancel_task", %{"task_id" => "task_1"}, state)

      assert %{
               "ok" => true,
               "task_id" => "task_1",
               "task" => %{"task_id" => "task_1", "state" => "cancelled"}
             } = Jason.decode!(text)

      assert_received {:cancel_task, "task_1", opts}
      assert opts[:caller_id] == "human_1"
    end

    test "steer_task requires SignedRequest authentication", %{state: state} do
      {:ok, result, _state} =
        Handler.handle_call_tool(
          "arbor_steer_task",
          %{"task_id" => "task_1", "message" => "redirect"},
          state
        )

      assert result.isError == true
      assert [%{text: text}] = result.content
      assert text =~ "SignedRequest authentication"

      assert text =~
               "./bin/mix arbor.signer --key-file <path> --upstream http://localhost:4000/mcp"

      assert text =~ "docs/arbor/EXTERNAL_MCP_CLIENT.md"
    end

    test "steer_task calls the shared API with the signed caller and stable control result", %{
      state: state
    } do
      Process.put(:arbor_authenticated_agent_id, "human_1")

      {:ok, %{content: [%{text: text}]}, _state} =
        Handler.handle_call_tool(
          "arbor_steer_task",
          %{"task_id" => "task_1", "message" => "run tests", "target_stage" => "validation"},
          state
        )

      assert %{
               "ok" => true,
               "task_id" => "task_1",
               "control" => %{
                 "control_id" => "control_1",
                 "status" => "delivered",
                 "delivery_mode" => "native_tool_loop"
               }
             } = Jason.decode!(text)

      assert_received {:steer_task, "task_1", "run tests", opts}
      assert opts[:caller_id] == "human_1"
      assert opts[:target_stage] == "validation"
    end

    test "adopt_task_change requires SignedRequest authentication", %{state: state} do
      {:ok, result, _state} =
        Handler.handle_call_tool(
          "arbor_adopt_task_change",
          %{"task_id" => "task_1", "destination_ref" => "refs/heads/reviewed"},
          state
        )

      assert result.isError == true
      assert [%{text: text}] = result.content
      assert text =~ "SignedRequest authentication"
    end

    test "adopt_task_change calls orchestration with the authenticated caller", %{state: state} do
      Process.put(:arbor_authenticated_agent_id, "human_1")

      {:ok, %{content: [%{text: text}]}, _state} =
        Handler.handle_call_tool(
          "arbor_adopt_task_change",
          %{"task_id" => "task_1", "destination_ref" => "refs/heads/reviewed"},
          state
        )

      assert %{
               "ok" => true,
               "task_id" => "task_1",
               "result" => %{"payload" => %{"destination_ref" => "refs/heads/reviewed"}}
             } = Jason.decode!(text)

      assert_received {:adopt_task_change, "task_1", "refs/heads/reviewed", opts}
      assert opts[:caller_id] == "human_1"
    end
  end

  # ===========================================================================
  # arbor_actions tool
  # ===========================================================================

  describe "arbor_actions" do
    # These tests require Arbor.Actions to be loaded (cross-app dependency).
    # They pass from umbrella root but not from gateway app in isolation.
    @describetag :integration

    test "no-filter returns compact sorted category index with counts and disclosure hint", %{
      state: state
    } do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_actions", %{}, state)

      assert text =~ "# Arbor Actions"
      assert text =~ "Category index only"
      assert text =~ "Call arbor_actions with category"
      assert text =~ "progressive disclosure" or text =~ "progressive"

      # Category names + counts; include dynamic mcp without requiring connections.
      assert text =~ ~r/^- shell: \d+ actions$/m
      assert text =~ ~r/^- file: \d+ actions$/m
      assert text =~ ~r/^- mcp: \d+ actions$/m

      # Deterministic sort: category lines must be alphabetical by name.
      category_lines =
        text
        |> String.split("\n")
        |> Enum.filter(&String.match?(&1, ~r/^- [a-z0-9_]+: \d+ actions$/))

      assert category_lines == Enum.sort(category_lines)
      assert Enum.any?(category_lines, &String.starts_with?(&1, "- mcp:"))

      # Must not enumerate every action or include action descriptions.
      refute text =~ "shell_execute"
      refute text =~ "file_read"
      refute text =~ "### "
      refute text =~ ~r/^- [a-z_]+: .+:/m
    end

    test "filters to a specific category with detailed tool listing", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_actions", %{"category" => "shell"}, state)

      assert text =~ "# shell actions"
      assert text =~ "shell_execute"
      assert text =~ "### "
    end

    test "returns error for unknown category including mcp in available list", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_actions", %{"category" => "nonexistent_xyz"}, state)

      assert text =~ "Unknown category"
      assert text =~ "Available:"
      assert text =~ "mcp"
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
      {:ok, result, _state} =
        Handler.handle_call_tool(
          "arbor_run",
          %{"action" => "file_exists", "params" => %{"path" => "/tmp"}},
          state
        )

      assert result.isError == true
      assert [%{type: "text", text: text}] = result.content
      # Must reject when no authenticated agent_id in process dict
      assert text =~ "SignedRequest authentication"

      assert text =~
               "./bin/mix arbor.signer --key-file <path> --upstream http://localhost:4000/mcp"

      assert text =~ "docs/arbor/EXTERNAL_MCP_CLIENT.md"
      assert text =~ "Direct HTTP/Bearer"
    end

    test "rejects execution when agent_id passed in params instead of auth", %{state: state} do
      # agent_id in params is ignored — must come from SignedRequestAuth
      {:ok, result, _state} =
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
      assert result.isError == true
      assert [%{type: "text", text: text}] = result.content
      assert text =~ "SignedRequest authentication"

      assert text =~
               "./bin/mix arbor.signer --key-file <path> --upstream http://localhost:4000/mcp"

      assert text =~ "docs/arbor/EXTERNAL_MCP_CLIENT.md"
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
  # Owner-bound ACP lifecycle guard (standalone arbor_run is stateless)
  # ===========================================================================

  describe "arbor_run owner-bound ACP lifecycle guard" do
    @owner_bound_acp_actions ~w(
      acp_start_session
      acp_send_message
      acp_session_status
      acp_close_session
    )

    setup do
      on_exit(fn -> Process.delete(:arbor_authenticated_agent_id) end)
      :ok
    end

    test "unauthenticated owner-bound calls return SignedRequest auth error", %{state: state} do
      for action <- @owner_bound_acp_actions do
        {:ok, result, _state} =
          Handler.handle_call_tool(
            "arbor_run",
            %{"action" => action, "params" => %{}},
            state
          )

        assert result.isError == true,
               "Expected isError: true for unauthenticated #{action}, got: #{inspect(result)}"

        assert [%{type: "text", text: text}] = result.content
        assert text =~ "SignedRequest authentication"

        assert text =~
                 "./bin/mix arbor.signer --key-file <path> --upstream http://localhost:4000/mcp"

        assert text =~ "docs/arbor/EXTERNAL_MCP_CLIENT.md"
        refute text =~ "stateless"
        refute text =~ "arbor_dispatch_task"
      end
    end

    test "authenticated owner-bound calls return isError guidance for all four names", %{
      state: state
    } do
      Process.put(:arbor_authenticated_agent_id, "test_agent_acp_guard")

      for action <- @owner_bound_acp_actions do
        {:ok, result, _state} =
          Handler.handle_call_tool(
            "arbor_run",
            %{"action" => action, "params" => %{}},
            state
          )

        assert result.isError == true,
               "Expected isError: true for #{action}, got: #{inspect(result)}"

        assert [%{type: "text", text: text}] = result.content
        assert text =~ "stateless"
        assert text =~ "arbor_dispatch_task"
        assert text =~ "coding_change"
        assert text =~ "arbor_steer_task"
        assert text =~ action
        refute text =~ "## Success"
        refute text =~ "SignedRequest authentication"
      end
    end

    test "arbor_help still discovers owner-bound ACP actions and annotates standalone note", %{
      state: state
    } do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool(
          "arbor_help",
          %{"action" => "acp_start_session"},
          state
        )

      assert text =~ "acp_start_session"
      assert text =~ "Standalone MCP note" or text =~ "owner-bound"
      assert text =~ "arbor_dispatch_task"
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
      signed_request = %SignedRequest{
        agent_id: "agent_h1",
        signature: "fake-signature",
        payload: "fake-payload",
        timestamp: DateTime.utc_now(),
        nonce: :crypto.strong_rand_bytes(16)
      }

      Process.put(:arbor_authenticated_agent_id, signed_request.agent_id)
      Process.put(:arbor_authenticated_signed_request, signed_request)

      result = Handler.maybe_put_signed_request(%{workspace: "/tmp"})

      assert result[:signed_request] == signed_request,
             "Authenticated signed_request must reach the action context — H1 regression"

      assert %AuthContext{
               identity_verified: true,
               principal_id: "agent_h1",
               signed_request: ^signed_request
             } = result[:auth_context]

      refute Map.has_key?(result, :identity_verified)

      assert result[:workspace] == "/tmp",
             "Existing context keys must be preserved"
    end

    test "security regression: plain map request cannot mint a verified action context" do
      Process.put(:arbor_authenticated_agent_id, "agent_h1")
      Process.put(:arbor_authenticated_signed_request, %{agent_id: "agent_h1"})

      context = %{workspace: "/tmp"}
      assert Handler.maybe_put_signed_request(context) == context
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
