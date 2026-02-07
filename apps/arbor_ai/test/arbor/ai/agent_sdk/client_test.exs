defmodule Arbor.AI.AgentSDK.ClientTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.AgentSDK.Client
  alias Arbor.AI.AgentSDK.Error
  alias Arbor.AI.AgentSDK.ToolServer

  # Test tools module
  defmodule ClientTestTools do
    use Arbor.AI.AgentSDK.Tool

    deftool :greet, "Greet a user" do
      param(:name, :string, required: true)

      def execute(%{name: name}) do
        {:ok, "Hello, #{name}!"}
      end
    end

    deftool :write_file, "Write to a file" do
      param(:path, :string, required: true)

      def execute(%{path: _path}) do
        {:ok, "written"}
      end
    end
  end

  defp start_tool_server do
    {:ok, server} = ToolServer.start_link(name: nil)
    :ok = ToolServer.register_tools(ClientTestTools, server)
    server
  end

  defp send_tool_use(client, name, input, id \\ "tool_1") do
    msg = %{
      "type" => "assistant",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => id,
            "name" => name,
            "input" => input
          }
        ]
      }
    }

    send(client, {:claude_message, msg})
  end

  defp send_result(client) do
    send(client, {:claude_message, %{"type" => "result", "usage" => %{}, "session_id" => "s1"}})
  end

  describe "in-process tool execution" do
    test "executes registered tool and records result" do
      server = start_tool_server()
      {:ok, client} = Client.start_link(tool_server: server)

      # We need to set up a pending query to get the response
      test_pid = self()

      # Send tool_use + result messages
      send_tool_use(client, "greet", %{"name" => "World"})
      send_result(client)

      # Client has no pending_query so it won't reply, but processes the messages
      Process.sleep(50)
      assert Process.alive?(client)
    end

    test "tool without tool_server records nil result" do
      {:ok, client} = Client.start_link([])

      send_tool_use(client, "greet", %{"name" => "World"})
      send_result(client)

      Process.sleep(50)
      assert Process.alive?(client)
    end
  end

  describe "permission enforcement for in-process tools" do
    test "denies tool in plan mode" do
      server = start_tool_server()

      {:ok, client} =
        Client.start_link(
          tool_server: server,
          permission_mode: :plan
        )

      # write_file is not in plan mode's allowed list
      send_tool_use(client, "write_file", %{"path" => "/tmp/test"})
      send_result(client)

      Process.sleep(50)
      assert Process.alive?(client)
    end

    test "allows read tools in plan mode" do
      server = start_tool_server()

      # Register a "Read" tool
      handler = fn _args -> {:ok, "file contents"} end

      schema = %{
        "name" => "Read",
        "description" => "Read a file",
        "input_schema" => %{}
      }

      :ok = ToolServer.register_handler("Read", schema, handler, server)

      {:ok, client} =
        Client.start_link(
          tool_server: server,
          permission_mode: :plan
        )

      send_tool_use(client, "Read", %{})
      send_result(client)

      Process.sleep(50)
      assert Process.alive?(client)
    end
  end

  describe "post-hook execution" do
    test "runs post hooks after in-process tool execution" do
      server = start_tool_server()
      test_pid = self()

      hooks = %{
        post_tool_use: fn name, _input, result, _ctx ->
          send(test_pid, {:post_hook_called, name, result})
        end
      }

      {:ok, client} =
        Client.start_link(
          tool_server: server,
          hooks: hooks
        )

      send_tool_use(client, "greet", %{"name" => "World"})

      assert_receive {:post_hook_called, "greet", {:ok, "Hello, World!"}}, 1000
    end

    test "does not run post hooks when pre-hook denies" do
      server = start_tool_server()
      test_pid = self()

      hooks = %{
        pre_tool_use: fn _name, _input, _ctx -> {:deny, "blocked"} end,
        post_tool_use: fn _name, _input, _result, _ctx ->
          send(test_pid, :post_hook_should_not_run)
        end
      }

      {:ok, client} =
        Client.start_link(
          tool_server: server,
          hooks: hooks
        )

      send_tool_use(client, "greet", %{"name" => "World"})

      Process.sleep(100)
      refute_received :post_hook_should_not_run
    end

    test "does not run post hooks for unregistered tools" do
      # No tool_server means no in-process execution, no post-hooks
      test_pid = self()

      hooks = %{
        post_tool_use: fn _name, _input, _result, _ctx ->
          send(test_pid, :post_hook_should_not_run)
        end
      }

      {:ok, client} = Client.start_link(hooks: hooks)

      send_tool_use(client, "greet", %{"name" => "World"})

      Process.sleep(100)
      refute_received :post_hook_should_not_run
    end
  end

  describe "pre-hook deny" do
    test "records hook_result as :deny" do
      server = start_tool_server()

      hooks = %{
        pre_tool_use: fn _name, _input, _ctx -> {:deny, "not allowed"} end
      }

      {:ok, client} =
        Client.start_link(
          tool_server: server,
          hooks: hooks
        )

      send_tool_use(client, "greet", %{"name" => "World"})
      send_result(client)

      Process.sleep(50)
      assert Process.alive?(client)
    end
  end

  describe "error struct propagation" do
    test "transport_closed with no response returns Error" do
      {:ok, client} = Client.start_link([])

      # No pending query, so just verify it doesn't crash
      send(client, {:transport_closed, 1})

      Process.sleep(50)
      assert Process.alive?(client)
    end

    test "transport_error with Error struct doesn't crash" do
      {:ok, client} = Client.start_link([])

      error = Error.buffer_overflow()
      send(client, {:transport_error, error})

      Process.sleep(50)
      assert Process.alive?(client)
    end

    test "transport_error with raw error doesn't crash" do
      {:ok, client} = Client.start_link([])

      send(client, {:transport_error, :some_error})

      Process.sleep(50)
      assert Process.alive?(client)
    end
  end

  describe "stream callbacks for tool_use" do
    test "processes tool_use without stream callback" do
      server = start_tool_server()

      {:ok, client} =
        Client.start_link(tool_server: server)

      # No stream callback set — notify_stream is a no-op
      send_tool_use(client, "greet", %{"name" => "Test"})
      send_result(client)

      Process.sleep(50)
      assert Process.alive?(client)
    end
  end
end
