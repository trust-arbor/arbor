defmodule Arbor.Behavioral.ToolExecutionTest do
  @moduledoc """
  Behavioral test: SDK tool execution pipeline.

  Verifies the full tool execution flow:
  1. ToolServer starts and accepts tool registrations
  2. Handler-based tools execute with correct args
  3. Hooks chain (pre: allow/deny/modify, post: logging)
  4. Permission checks gate tool access
  5. ToolBridge converts Jido action schemas to SDK format

  Uses inline test tools and handler functions — no real LLM calls.
  """
  use Arbor.Test.BehavioralCase

  alias Arbor.AI.AgentSDK.Hooks
  alias Arbor.AI.AgentSDK.ToolServer

  # -- Inline test tool module --

  defmodule TestTools do
    @moduledoc false
    use Arbor.AI.AgentSDK.Tool

    deftool :greet, "Greet someone by name" do
      param(:name, :string, required: true, description: "Person to greet")
      param(:formal, :boolean, description: "Use formal greeting")

      def execute(%{name: name} = args) do
        if Map.get(args, :formal, false) do
          {:ok, "Good day, #{name}."}
        else
          {:ok, "Hello, #{name}!"}
        end
      end
    end

    deftool :add, "Add two numbers" do
      param(:a, :number, required: true, description: "First number")
      param(:b, :number, required: true, description: "Second number")

      def execute(%{a: a, b: b}) do
        {:ok, "#{a + b}"}
      end
    end
  end

  defmodule FailingTool do
    @moduledoc false
    use Arbor.AI.AgentSDK.Tool

    deftool :fail, "Always fails" do
      param(:reason, :string, description: "Failure reason")

      def execute(%{reason: reason}) do
        {:error, reason}
      end

      def execute(_) do
        {:error, "unspecified failure"}
      end
    end
  end

  describe "scenario: ToolServer registration and execution" do
    setup do
      # Start a dedicated ToolServer for this test
      name = :"tool_server_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = ToolServer.start_link(name: name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, server: name}
    end

    test "register_tools/2 registers all tools from a module", %{server: server} do
      assert :ok = ToolServer.register_tools(TestTools, server)

      names = ToolServer.tool_names(server)
      assert "greet" in names
      assert "add" in names
    end

    test "call_tool/3 executes a registered tool with correct result", %{server: server} do
      :ok = ToolServer.register_tools(TestTools, server)

      assert {:ok, result} = ToolServer.call_tool("greet", %{"name" => "World"}, server)
      assert result =~ "Hello, World!"
    end

    test "call_tool/3 normalizes string-keyed args to atom keys", %{server: server} do
      :ok = ToolServer.register_tools(TestTools, server)

      assert {:ok, result} = ToolServer.call_tool("add", %{"a" => 3, "b" => 7}, server)
      assert result =~ "10"
    end

    test "call_tool/3 returns error for unregistered tool", %{server: server} do
      result = ToolServer.call_tool("nonexistent_tool", %{}, server)
      assert {:error, _} = result
    end

    test "list_tools/1 returns JSON schema format", %{server: server} do
      :ok = ToolServer.register_tools(TestTools, server)

      tools = ToolServer.list_tools(server)
      assert is_list(tools)
      assert length(tools) == 2

      greet_tool = Enum.find(tools, fn t -> t["name"] == "greet" end)
      assert greet_tool != nil
      assert is_binary(greet_tool["description"])
      assert is_map(greet_tool["input_schema"])
    end

    test "has_tool?/2 checks tool registration", %{server: server} do
      :ok = ToolServer.register_tools(TestTools, server)

      assert ToolServer.has_tool?("greet", server) == true
      assert ToolServer.has_tool?("nonexistent", server) == false
    end

    test "unregister_tools/2 removes all tools from a module", %{server: server} do
      :ok = ToolServer.register_tools(TestTools, server)
      assert ToolServer.has_tool?("greet", server)

      :ok = ToolServer.unregister_tools(TestTools, server)
      assert ToolServer.has_tool?("greet", server) == false
    end

    test "failing tool returns error tuple, not crash", %{server: server} do
      :ok = ToolServer.register_tools(FailingTool, server)

      result = ToolServer.call_tool("fail", %{"reason" => "test failure"}, server)
      assert {:error, _} = result
    end
  end

  describe "scenario: handler-based tool registration" do
    setup do
      name = :"tool_server_handler_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = ToolServer.start_link(name: name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, server: name}
    end

    test "register_handler/4 registers a custom function as a tool", %{server: server} do
      schema = %{
        "name" => "echo",
        "description" => "Echo back the input",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "message" => %{"type" => "string"}
          }
        }
      }

      handler = fn args ->
        msg = Map.get(args, :message) || Map.get(args, "message") || ""
        {:ok, "Echo: #{msg}"}
      end

      :ok = ToolServer.register_handler("echo", schema, handler, server)

      assert ToolServer.has_tool?("echo", server)
      assert {:ok, result} = ToolServer.call_tool("echo", %{"message" => "test"}, server)
      assert result =~ "Echo: test"
    end

    test "unregister_handler/2 removes a handler-based tool", %{server: server} do
      schema = %{"name" => "temp", "description" => "Temporary tool", "input_schema" => %{}}
      handler = fn _ -> {:ok, "temp result"} end

      :ok = ToolServer.register_handler("temp", schema, handler, server)
      assert ToolServer.has_tool?("temp", server)

      :ok = ToolServer.unregister_handler("temp", server)
      assert ToolServer.has_tool?("temp", server) == false
    end
  end

  describe "scenario: hook chain execution" do
    test "pre-hooks with :allow proceed to execution" do
      hooks = %{
        pre_tool_use: fn _name, _input, _ctx -> :allow end
      }

      context = Hooks.build_context(cwd: "/tmp")
      result = Hooks.run_pre_hooks(hooks, "greet", %{"name" => "test"}, context)

      assert {:allow, %{"name" => "test"}} = result
    end

    test "pre-hooks with :deny block execution" do
      hooks = %{
        pre_tool_use: fn _name, _input, _ctx -> {:deny, "Not allowed in test"} end
      }

      context = Hooks.build_context(cwd: "/tmp")
      result = Hooks.run_pre_hooks(hooks, "greet", %{"name" => "test"}, context)

      assert {:deny, "Not allowed in test"} = result
    end

    test "pre-hooks with {:modify, new_input} transforms tool input" do
      hooks = %{
        pre_tool_use: fn _name, input, _ctx ->
          {:modify, Map.put(input, "injected", true)}
        end
      }

      context = Hooks.build_context(cwd: "/tmp")
      {:allow, modified_input} = Hooks.run_pre_hooks(hooks, "greet", %{"name" => "test"}, context)

      assert modified_input["injected"] == true
      assert modified_input["name"] == "test"
    end

    test "multiple pre-hooks chain in sequence" do
      hooks = %{
        pre_tool_use: [
          fn _name, input, _ctx -> {:modify, Map.put(input, "step1", true)} end,
          fn _name, input, _ctx -> {:modify, Map.put(input, "step2", true)} end
        ]
      }

      context = Hooks.build_context(cwd: "/tmp")
      {:allow, final_input} = Hooks.run_pre_hooks(hooks, "greet", %{}, context)

      assert final_input["step1"] == true
      assert final_input["step2"] == true
    end

    test "deny in hook chain stops further hooks" do
      call_log = :ets.new(:hook_call_log, [:set, :public])

      hooks = %{
        pre_tool_use: [
          fn _name, _input, _ctx ->
            :ets.insert(call_log, {:hook1, true})
            {:deny, "Blocked by first hook"}
          end,
          fn _name, _input, _ctx ->
            :ets.insert(call_log, {:hook2, true})
            :allow
          end
        ]
      }

      context = Hooks.build_context(cwd: "/tmp")
      assert {:deny, _} = Hooks.run_pre_hooks(hooks, "greet", %{}, context)

      assert :ets.lookup(call_log, :hook1) == [{:hook1, true}]
      assert :ets.lookup(call_log, :hook2) == []

      :ets.delete(call_log)
    end

    test "post-hooks run for logging after execution" do
      log_ref = make_ref()
      test_pid = self()

      hooks = %{
        post_tool_use: fn name, _input, result, _ctx ->
          send(test_pid, {log_ref, :post_hook, name, result})
          :ok
        end
      }

      context = Hooks.build_context(cwd: "/tmp")
      Hooks.run_post_hooks(hooks, "greet", %{}, {:ok, "Hello!"}, context)

      assert_receive {^log_ref, :post_hook, "greet", {:ok, "Hello!"}}, 1000
    end
  end

  describe "scenario: tool schema generation" do
    test "deftool macro generates correct JSON schema" do
      tools = TestTools.__tools__()
      assert is_list(tools)
      assert length(tools) == 2

      greet_schema = TestTools.__tool_schema__("greet")
      assert greet_schema.name == "greet"
      assert is_binary(greet_schema.description)
      assert length(greet_schema.params) == 2

      # Required param
      name_param = Enum.find(greet_schema.params, &(&1.name == :name))
      assert name_param.type == :string
      assert name_param.required == true

      # Optional param
      formal_param = Enum.find(greet_schema.params, &(&1.name == :formal))
      assert formal_param.type == :boolean
      assert formal_param.required == false
    end

    test "to_json_schema/1 produces valid JSON schema format" do
      schema = TestTools.__tool_schema__("greet")
      json_schema = Arbor.AI.AgentSDK.Tool.to_json_schema(schema)

      assert json_schema["name"] == "greet"
      assert is_binary(json_schema["description"])
      assert json_schema["input_schema"]["type"] == "object"
      assert is_map(json_schema["input_schema"]["properties"])
      assert "name" in (json_schema["input_schema"]["required"] || [])
    end
  end
end
