defmodule ConversationKit.SnapshotTest do
  use ExUnit.Case, async: true
  alias ConversationKit.Snapshot

  test "projection is pure and excludes non-display keys without correlating logs" do
    messages = [
      %{
        "id" => "entry",
        "role" => "assistant",
        "text" => "Transcript",
        "timestamp" => "time",
        "ordinal" => 8,
        "metadata" => "secret"
      }
    ]

    deliveries = [
      %{
        "id" => "delivery",
        "status" => "completed",
        "input_text" => "Input",
        "result_text" => "Response",
        "reason" => nil,
        "admitted_cursor" => 1,
        "updated_cursor" => 3,
        "proof" => "secret"
      }
    ]

    projected = Snapshot.project(messages, deliveries)
    assert projected == Snapshot.project(messages, deliveries)
    assert length(projected["messages"]) == 1
    assert length(projected["blocks"]) == 2
    assert projected["speech"] == []
    refute inspect(projected) =~ "secret"
    assert List.last(projected["blocks"])["type"] == "delivery"
  end

  test "unknown delivery outcomes are factual display blocks, never speech effects" do
    deliveries =
      for {status, ordinal} <- Enum.with_index(~w(admitted dispatch_started uncertain), 1) do
        %{
          "id" => "command_#{ordinal}",
          "status" => status,
          "input_text" => "Input",
          "result_text" => nil,
          "reason" => nil,
          "admitted_cursor" => ordinal,
          "updated_cursor" => ordinal
        }
      end

    projected = Snapshot.project([], Enum.reverse(deliveries))

    assert Enum.map(projected["deliveries"], & &1["status"]) ==
             ~w(admitted dispatch_started uncertain)

    assert projected["speech"] == []
    assert projected["messages"] == []
  end
end
