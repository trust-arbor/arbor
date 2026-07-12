defmodule Arbor.LLM.ClientTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM.{Client, Message, Request, RequestTimeoutError, Response, StreamEvent}

  @moduletag :fast

  defmodule BoundaryAdapter do
    def provider, do: "boundary"

    def complete(%Request{model: "huge"}, _opts) do
      {:ok, %Response{text: String.duplicate("x", 16_777_217)}}
    end

    def complete(%Request{model: "huge-usage"}, _opts) do
      {:ok, %Response{text: "ok", usage: %{total_tokens: 1.0e308}}}
    end

    def complete(%Request{model: "late"}, opts) do
      send(Keyword.fetch!(opts, :observer), {:late_adapter_started, self()})
      Process.sleep(40)
      {:ok, %Response{text: "late"}}
    end

    def complete(_request, _opts), do: {:ok, %Response{text: "ok"}}

    def stream(%Request{model: "cumulative-stream"}, _opts) do
      for _ <- 1..3 do
        %StreamEvent{type: :delta, data: %{text: String.duplicate("s", 64)}}
      end
    end

    def complete_streaming(%Request{model: "cumulative-callback"}, callback, _opts) do
      for _ <- 1..3 do
        callback.(%StreamEvent{type: :delta, data: %{text: String.duplicate("c", 64)}})
      end

      {:ok, %Response{text: "ok"}}
    end
  end

  describe "public adapter boundary" do
    test "security regression: injected adapters and middleware cannot bypass response ceilings" do
      client =
        Client.new(adapters: %{"boundary" => BoundaryAdapter}, default_provider: "boundary")

      request = %Request{provider: "boundary", model: "huge", messages: []}

      assert {:error, {:invalid_completion_response, _reason}} = Client.complete(client, request)

      assert {:error, {:invalid_completion_response, _reason}} =
               Arbor.LLM.generate(
                 client: client,
                 provider: "boundary",
                 model: "huge",
                 prompt: "hello"
               )

      middleware = fn _request, _next ->
        {:ok, %Response{text: String.duplicate("m", 16_777_217)}}
      end

      middleware_client = %{client | middleware: [middleware]}

      assert {:error, {:invalid_completion_response, _reason}} =
               Client.complete(middleware_client, %{request | model: "valid"})

      assert {:error, {:invalid_completion_response, :bounded_usage_number_required}} =
               Client.complete(client, %{request | model: "huge-usage"})
    end

    test "security regression: queued late success is rejected by its completion timestamp" do
      client =
        Client.new(adapters: %{"boundary" => BoundaryAdapter}, default_provider: "boundary")

      request = %Request{provider: "boundary", model: "late", messages: [Message.new(:user, "x")]}
      observer = self()

      for _iteration <- 1..10 do
        task =
          Task.async(fn ->
            Client.complete(client, request, receive_timeout: 30, observer: observer)
          end)

        assert_receive {:late_adapter_started, _worker}
        :erlang.suspend_process(task.pid)
        Process.sleep(70)
        :erlang.resume_process(task.pid)

        assert {:error, %RequestTimeoutError{timeout_ms: 30}} = Task.await(task, 1_000)
      end
    end

    test "security regression: stream events and callbacks consume cumulative response budgets" do
      client =
        Client.new(adapters: %{"boundary" => BoundaryAdapter}, default_provider: "boundary")

      stream_request = %Request{provider: "boundary", model: "cumulative-stream", messages: []}

      assert {:ok, stream} =
               Client.stream(client, stream_request,
                 max_response_bytes: 180,
                 max_stream_event_bytes: 180
               )

      stream_error = assert_raise Arbor.LLM.StreamError, fn -> Enum.to_list(stream) end

      assert stream_error.reason ==
               {:response_budget_exceeded, :stream_events, :bytes, 180}

      callback_request = %{
        stream_request
        | model: "cumulative-callback"
      }

      assert {:error, {:response_budget_exceeded, :stream_events, :bytes, 180}} =
               Client.complete_streaming(client, callback_request, fn _event -> :ok end,
                 max_response_bytes: 180,
                 max_stream_event_bytes: 180
               )
    end
  end

  describe "collect_stream/1 — streamed tool calls (regression)" do
    test "preserves the tool-call name/id from atom-keyed stream events" do
      # `translate_stream_chunk` emits tool-call events with ATOM keys
      # (%{name:, arguments:, id:}); collect_stream used to read only the
      # string keys ("name"/"id") → empty-named tool calls → "Unknown action:"
      # → the tool-loop spiral. This is exactly the streaming path the chat turn
      # uses (a stream_callback routes ToolLoop through Client.stream).
      events = [
        %StreamEvent{
          type: :tool_call,
          data: %{name: "get_weather", arguments: %{"city" => "Paris"}, id: "call_1"}
        },
        %StreamEvent{type: :finish, data: %{reason: :tool_calls}}
      ]

      {:ok, response} = Client.collect_stream(events)

      tool_call = Enum.find(response.content_parts, &(&1.kind == :tool_call))
      assert tool_call, "expected a tool_call content part"
      assert tool_call.name == "get_weather"
      assert tool_call.id == "call_1"
    end

    test "still reads string-keyed tool-call events" do
      events = [
        %StreamEvent{
          type: :tool_call,
          data: %{"name" => "search", "arguments" => "{}", "id" => "c2"}
        },
        %StreamEvent{type: :finish, data: %{reason: :tool_calls}}
      ]

      {:ok, response} = Client.collect_stream(events)
      tool_call = Enum.find(response.content_parts, &(&1.kind == :tool_call))
      assert tool_call.name == "search"
      assert tool_call.id == "c2"
    end

    test "security regression: arbitrary enumerables have aggregate tool-call byte and node budgets" do
      parent = self()

      event = %StreamEvent{
        type: :tool_call,
        data: %{
          id: "call",
          name: "large",
          arguments: %{"blob" => String.duplicate("x", 900_000)}
        }
      }

      events =
        Stream.resource(
          fn -> 0 end,
          fn
            count when count < 100 -> {[event], count + 1}
            count -> {:halt, count}
          end,
          fn _count -> send(parent, :arbitrary_stream_closed) end
        )

      assert {:error, {:response_budget_exceeded, :stream_events, :bytes, 16_777_216}} =
               Client.collect_stream(events)

      assert_receive :arbitrary_stream_closed

      node_heavy = %StreamEvent{
        type: :tool_call,
        data: %{id: "call", name: "nodes", arguments: %{"items" => List.duplicate(0, 9_000)}}
      }

      assert {:error, {:response_budget_exceeded, :stream_events, :nodes, 100_000}} =
               Stream.repeatedly(fn -> node_heavy end)
               |> Stream.take(100)
               |> Client.collect_stream()
    end

    test "security regression: decoded argument lists are charged before aggregate retention" do
      arguments = Jason.encode!(%{"items" => List.duplicate(0, 4_500)})

      events =
        for index <- 1..30 do
          %StreamEvent{
            type: :tool_call,
            data: %{id: "call-#{index}", name: "bounded", arguments: arguments}
          }
        end

      assert {:error, {:stream_limit_exceeded, boundary, 100_000}} =
               Client.collect_stream(events)

      assert boundary in [:retained_nodes, :retained_list_items]
    end

    test "security regression: tool fields and finish usage are bounded before retention" do
      huge_id = String.duplicate("i", 513)

      assert {:error, {:invalid_tool_call_field, :id, {:bounded_string_required, 512}}} =
               Client.collect_stream([
                 %StreamEvent{
                   type: :tool_call,
                   data: %{id: huge_id, name: "tool", arguments: %{}}
                 }
               ])

      huge_usage = %{provider_blob: String.duplicate("u", 1_048_576)}

      assert {:error, {:invalid_stream_event, {:decoded_term_limit_exceeded, :bytes, 1_048_576}}} =
               Client.collect_stream([
                 %StreamEvent{type: :finish, data: %{reason: :stop, usage: huge_usage}}
               ])
    end

    test "security regression: collect_stream validates final aggregate usage" do
      assert {:error, {:invalid_completion_response, :bounded_usage_number_required}} =
               Client.collect_stream([
                 %StreamEvent{
                   type: :finish,
                   data: %{reason: :stop, usage: %{total_tokens: 1.0e308}}
                 }
               ])
    end
  end
end
