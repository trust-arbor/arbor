defmodule Arbor.LLM.ClientTest do
  use ExUnit.Case, async: true

  alias Arbor.LLM.Client
  alias Arbor.LLM.StreamEvent

  @moduletag :fast

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

      assert {:error, {:stream_limit_exceeded, :retained_bytes, 16_777_216}} =
               Client.collect_stream(events)

      assert_receive :arbitrary_stream_closed

      node_heavy = %StreamEvent{
        type: :tool_call,
        data: %{id: "call", name: "nodes", arguments: %{"items" => List.duplicate(0, 9_000)}}
      }

      assert {:error, {:stream_limit_exceeded, :retained_nodes, 100_000}} =
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
  end
end
