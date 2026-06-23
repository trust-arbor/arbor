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
  end
end
