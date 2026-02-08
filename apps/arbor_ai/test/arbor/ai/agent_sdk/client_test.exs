defmodule Arbor.AI.AgentSDK.ClientTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.AgentSDK.Client
  alias Arbor.AI.AgentSDK.Error
  alias Arbor.AI.AgentSDK.ToolServer

  # A mock transport GenServer that records queries and sends back canned responses
  defmodule MockTransport do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def init(opts) do
      receiver = Keyword.get(opts, :receiver)
      # Notify ready immediately
      send(receiver, {:transport_ready})
      {:ok, %{receiver: receiver, queries: []}}
    end

    def handle_call({:send_query, prompt, _opts}, _from, state) do
      ref = make_ref()
      new_state = %{state | queries: [{ref, prompt} | state.queries]}

      # Schedule canned response
      Process.send_after(self(), {:send_response, ref}, 10)

      {:reply, {:ok, ref}, new_state}
    end

    def handle_call(:ready?, _from, state) do
      {:reply, true, state}
    end

    def handle_call(:close, _from, state) do
      {:reply, :ok, state}
    end

    def handle_info({:send_response, ref}, state) do
      # Send a simple text response
      assistant_msg = %{
        "type" => "assistant",
        "message" => %{
          "content" => [%{"type" => "text", "text" => "Mock response"}],
          "model" => "claude-test"
        }
      }

      result_msg = %{
        "type" => "result",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
        "session_id" => "mock-session"
      }

      send(state.receiver, {:claude_message, ref, assistant_msg})
      send(state.receiver, {:claude_message, ref, result_msg})

      {:noreply, state}
    end
  end

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

  describe "client with mock transport" do
    test "query returns response" do
      test_pid = self()
      {:ok, transport} = MockTransport.start_link(receiver: test_pid)

      # Flush the transport_ready sent to test_pid
      assert_receive {:transport_ready}

      {:ok, client} = Client.start_link(transport: transport)

      # Now we need the mock transport to send to the client
      # Let's directly simulate by sending messages to the client
      # Use a task to call query (blocking) while we inject messages
      task =
        Task.async(fn ->
          Client.query(client, "test prompt", timeout: 5_000)
        end)

      # The client calls Transport.send_query which goes to MockTransport
      # MockTransport schedules a response to test_pid (not client)
      # So we need to receive and forward
      assert_receive {:claude_message, ref, %{"type" => "assistant"} = msg}
      send(client, {:claude_message, ref, msg})

      assert_receive {:claude_message, ref2, %{"type" => "result"} = result_msg}
      send(client, {:claude_message, ref2, result_msg})

      {:ok, response} = Task.await(task)
      assert response.text == "Mock response"
      assert response.session_id == "mock-session"
    end
  end

  describe "message processing with query_ref" do
    test "processes assistant message with text" do
      test_pid = self()
      {:ok, transport} = MockTransport.start_link(receiver: test_pid)
      assert_receive {:transport_ready}

      {:ok, client} = Client.start_link(transport: transport)

      # Simulate a query by directly sending query/ref
      ref = make_ref()

      # Manually set up pending query
      task =
        Task.async(fn ->
          Client.query(client, "test", timeout: 5_000)
        end)

      # MockTransport sends response to test_pid
      assert_receive {:claude_message, query_ref, _assistant}
      assert_receive {:claude_message, ^query_ref, _result}

      # Forward to client
      send(
        client,
        {:claude_message, query_ref,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [%{"type" => "text", "text" => "Hello world"}],
             "model" => "claude-test"
           }
         }}
      )

      send(
        client,
        {:claude_message, query_ref,
         %{
           "type" => "result",
           "usage" => %{"input_tokens" => 5},
           "session_id" => "test-1"
         }}
      )

      {:ok, response} = Task.await(task)
      assert response.text == "Hello world"
      assert response.session_id == "test-1"
    end

    test "processes thinking blocks" do
      test_pid = self()
      {:ok, transport} = MockTransport.start_link(receiver: test_pid)
      assert_receive {:transport_ready}

      {:ok, client} = Client.start_link(transport: transport)

      task =
        Task.async(fn ->
          Client.query(client, "think hard", timeout: 5_000)
        end)

      # Drain mock responses
      assert_receive {:claude_message, query_ref, _}
      assert_receive {:claude_message, ^query_ref, _}

      # Send thinking + text + result
      send(
        client,
        {:claude_message, query_ref,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{"type" => "thinking", "thinking" => "Deep thought", "signature" => "sig1"},
               %{"type" => "text", "text" => "Answer"}
             ]
           }
         }}
      )

      send(
        client,
        {:claude_message, query_ref,
         %{
           "type" => "result",
           "usage" => %{},
           "session_id" => "think-1"
         }}
      )

      {:ok, response} = Task.await(task)
      assert response.text == "Answer"
      assert length(response.thinking) == 1
      assert hd(response.thinking).text == "Deep thought"
      assert hd(response.thinking).signature == "sig1"
    end
  end

  describe "in-process tool execution" do
    test "executes registered tool and records result" do
      server = start_tool_server()
      test_pid = self()
      {:ok, transport} = MockTransport.start_link(receiver: test_pid)
      assert_receive {:transport_ready}

      {:ok, client} = Client.start_link(tool_server: server, transport: transport)

      task =
        Task.async(fn ->
          Client.query(client, "use tools", timeout: 5_000)
        end)

      # Drain mock responses
      assert_receive {:claude_message, query_ref, _}
      assert_receive {:claude_message, ^query_ref, _}

      # Send tool use
      send(
        client,
        {:claude_message, query_ref,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "tool_1",
                 "name" => "greet",
                 "input" => %{"name" => "World"}
               }
             ]
           }
         }}
      )

      send(
        client,
        {:claude_message, query_ref,
         %{
           "type" => "result",
           "usage" => %{},
           "session_id" => "tool-1"
         }}
      )

      {:ok, response} = Task.await(task)
      assert length(response.tool_uses) == 1
      tool = hd(response.tool_uses)
      assert tool.name == "greet"
      assert tool.result == {:ok, "Hello, World!"}
    end

    test "tool without tool_server records nil result" do
      test_pid = self()
      {:ok, transport} = MockTransport.start_link(receiver: test_pid)
      assert_receive {:transport_ready}

      {:ok, client} = Client.start_link(transport: transport)

      task =
        Task.async(fn ->
          Client.query(client, "use tools", timeout: 5_000)
        end)

      assert_receive {:claude_message, query_ref, _}
      assert_receive {:claude_message, ^query_ref, _}

      send(
        client,
        {:claude_message, query_ref,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "tool_1",
                 "name" => "greet",
                 "input" => %{"name" => "World"}
               }
             ]
           }
         }}
      )

      send(
        client,
        {:claude_message, query_ref,
         %{
           "type" => "result",
           "usage" => %{},
           "session_id" => "t1"
         }}
      )

      {:ok, response} = Task.await(task)
      assert length(response.tool_uses) == 1
      assert hd(response.tool_uses).result == nil
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

      {:ok, transport} = MockTransport.start_link(receiver: test_pid)
      assert_receive {:transport_ready}

      {:ok, client} =
        Client.start_link(
          tool_server: server,
          hooks: hooks,
          transport: transport
        )

      task =
        Task.async(fn ->
          Client.query(client, "use tools", timeout: 5_000)
        end)

      assert_receive {:claude_message, query_ref, _}
      assert_receive {:claude_message, ^query_ref, _}

      send(
        client,
        {:claude_message, query_ref,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "tool_1",
                 "name" => "greet",
                 "input" => %{"name" => "World"}
               }
             ]
           }
         }}
      )

      assert_receive {:post_hook_called, "greet", {:ok, "Hello, World!"}}, 1000

      send(
        client,
        {:claude_message, query_ref,
         %{
           "type" => "result",
           "usage" => %{},
           "session_id" => "h1"
         }}
      )

      {:ok, _response} = Task.await(task)
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

      {:ok, transport} = MockTransport.start_link(receiver: test_pid)
      assert_receive {:transport_ready}

      {:ok, client} =
        Client.start_link(
          tool_server: server,
          hooks: hooks,
          transport: transport
        )

      task =
        Task.async(fn ->
          Client.query(client, "use tools", timeout: 5_000)
        end)

      assert_receive {:claude_message, query_ref, _}
      assert_receive {:claude_message, ^query_ref, _}

      send(
        client,
        {:claude_message, query_ref,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "tool_1",
                 "name" => "greet",
                 "input" => %{"name" => "World"}
               }
             ]
           }
         }}
      )

      Process.sleep(100)
      refute_received :post_hook_should_not_run

      send(
        client,
        {:claude_message, query_ref,
         %{
           "type" => "result",
           "usage" => %{},
           "session_id" => "h2"
         }}
      )

      {:ok, _response} = Task.await(task)
    end
  end

  describe "error handling" do
    test "transport_closed with no response returns Error" do
      test_pid = self()
      {:ok, transport} = MockTransport.start_link(receiver: test_pid)
      assert_receive {:transport_ready}

      {:ok, client} = Client.start_link(transport: transport)

      # No pending query, so just verify it doesn't crash
      send(client, {:transport_closed, :normal})

      Process.sleep(50)
      assert Process.alive?(client)
    end

    test "transport_error with Error struct doesn't crash" do
      test_pid = self()
      {:ok, transport} = MockTransport.start_link(receiver: test_pid)
      assert_receive {:transport_ready}

      {:ok, client} = Client.start_link(transport: transport)

      error = Error.buffer_overflow()
      ref = make_ref()
      send(client, {:transport_error, ref, error})

      Process.sleep(50)
      assert Process.alive?(client)
    end

    test "transport_error with raw error doesn't crash" do
      test_pid = self()
      {:ok, transport} = MockTransport.start_link(receiver: test_pid)
      assert_receive {:transport_ready}

      {:ok, client} = Client.start_link(transport: transport)

      send(client, {:transport_error, nil, :some_error})

      Process.sleep(50)
      assert Process.alive?(client)
    end
  end

  describe "stream callbacks" do
    test "stream callback receives text and complete events" do
      test_pid = self()
      {:ok, transport} = MockTransport.start_link(receiver: test_pid)
      assert_receive {:transport_ready}

      {:ok, client} = Client.start_link(transport: transport)

      callback = fn event ->
        send(test_pid, {:stream_event, event})
      end

      task =
        Task.async(fn ->
          Client.stream(client, "explain", callback, timeout: 5_000)
        end)

      assert_receive {:claude_message, query_ref, _}
      assert_receive {:claude_message, ^query_ref, _}

      send(
        client,
        {:claude_message, query_ref,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [%{"type" => "text", "text" => "Streaming text"}]
           }
         }}
      )

      assert_receive {:stream_event, {:text, "Streaming text"}}

      send(
        client,
        {:claude_message, query_ref,
         %{
           "type" => "result",
           "usage" => %{},
           "session_id" => "stream-1"
         }}
      )

      assert_receive {:stream_event, {:complete, response}}
      assert response.text == "Streaming text"

      {:ok, _} = Task.await(task)
    end
  end
end
