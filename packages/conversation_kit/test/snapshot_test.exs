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

  test "retained assistant partials expose their status without becoming completed speech" do
    labels = %{
      "cancelled" => "Cancelled · partial response",
      "interrupted" => "Interrupted · partial response",
      "failed" => "Response failed",
      "streaming" => "Response in progress"
    }

    messages =
      for {status, _label} <- labels do
        %{
          "id" => status,
          "role" => "assistant",
          "text" => "retained café 東京",
          "status" => status,
          "status_text" => "untrusted label",
          "metadata" => "private evidence",
          "interrupted_reason" => "private reason"
        }
      end

    projection = Snapshot.project(messages, [])

    for message <- projection["messages"] do
      assert message["status"] == message["id"]
      assert message["text"] == "retained café 東京"
      assert message["status_text"] == labels[message["status"]]
    end

    assert projection["speech"] == []
    refute inspect(projection) =~ "private"
    refute inspect(projection) =~ "untrusted label"
    assert Enum.all?(projection["blocks"], &(&1["type"] == "message"))
  end

  test "legacy and complete messages do not acquire a partial label" do
    legacy = %{"id" => "legacy", "role" => "assistant", "text" => "Legacy reply"}

    complete =
      Map.put(
        %{"id" => "complete", "role" => "assistant", "text" => "Done"},
        "status",
        "complete"
      )

    user = %{"id" => "user", "role" => "user", "text" => "Input", "status" => "cancelled"}
    projection = Snapshot.project([legacy, complete, user], [])

    assert hd(projection["messages"]) == legacy
    assert Enum.at(projection["messages"], 1)["status"] == "complete"
    assert Enum.all?(projection["messages"], &(not Map.has_key?(&1, "status_text")))
    refute Map.has_key?(List.last(projection["messages"]), "status")
    assert projection["speech"] == []
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

  test "notice replay is separate from transcript and speech and discards host authority" do
    notice = %{
      "id" => "notice-1",
      "kind" => "progress",
      "text" => "Task finished",
      "timestamp" => "time",
      "ordinal" => 4,
      "role" => "assistant",
      "owner_id" => "private-owner",
      "target_agent_id" => "private-agent",
      "recipient_subject_id" => "private-recipient",
      "provenance" => "private-proof",
      "command" => "private-command"
    }

    projected = Snapshot.project([], [], [notice])
    assert projected == Snapshot.project([], [], [notice])
    assert projected["messages"] == []
    assert projected["deliveries"] == []
    assert projected["speech"] == []

    assert [%{"type" => "notice", "text" => "Task finished", "ordinal" => 4}] =
             projected["blocks"]

    assert projected["notices"] == [Map.take(notice, ~w(id kind text timestamp ordinal))]
    refute inspect(projected) =~ "private-"
    refute Map.has_key?(hd(projected["blocks"]), "role")
  end
end
