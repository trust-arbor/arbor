defmodule Arbor.AI.AcpTranscriptTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.AcpTranscript

  @moduletag :fast
  @captured_at "2026-07-16T12:34:56Z"

  test "empty stream tail is closed and JSON-clean" do
    assert %{
             "events" => [],
             "events_retained" => 0,
             "events_seen" => 0,
             "events_omitted" => 0,
             "events_truncated" => false
           } = tail = AcpTranscript.empty_stream_tail()

    assert {:ok, _json} = Jason.encode(tail)
  end

  test "stream tail retains latest N with monotonic source sequence" do
    maximum = AcpTranscript.bounds().max_stream_events

    tail =
      Enum.reduce(1..(maximum + 6), AcpTranscript.empty_stream_tail(), fn index, acc ->
        AcpTranscript.append_stream_event(acc, %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"text" => "event-#{index}"}
        })
      end)

    assert tail["events_seen"] == maximum + 6
    assert tail["events_retained"] == maximum
    assert tail["events_omitted"] == 6
    assert tail["events_truncated"]
    assert hd(tail["events"])["source_seq"] == 6
    assert hd(tail["events"])["content"]["text"] == "event-7"
    assert List.last(tail["events"])["source_seq"] == maximum + 5
  end

  test "event projection bounds bytes and drops hostile nested terms" do
    maximum = AcpTranscript.bounds().max_event_bytes
    huge = String.duplicate("x", maximum + 100)

    event =
      AcpTranscript.normalize_stream_event(
        %{
          "kind" => "text",
          "content" => huge,
          "pid" => self(),
          "callback" => fn -> :ok end,
          "nested" => %{ref: make_ref()}
        },
        12
      )

    assert Map.keys(event) |> Enum.sort() ==
             ~w(content kind source_seq tool_call_id tool_name)

    assert event["source_seq"] == 12
    assert event["content"]["original_bytes"] == byte_size(huge)
    assert event["content"]["truncated"]
    assert byte_size(event["content"]["text"]) <= maximum
    assert event["content"]["sha256"] == sha(huge)
    assert {:ok, _json} = Jason.encode(event)
  end

  test "invalid UTF-8 becomes valid while preserving original bytes and digest" do
    invalid = <<0xFF, 0xFE, "ok">>
    field = AcpTranscript.bound_text_field(invalid, 1_000)

    assert field["original_bytes"] == byte_size(invalid)
    assert field["truncated"]
    assert String.valid?(field["text"])
    assert field["sha256"] == sha(invalid)
  end

  test "invalid UTF-8 stream facts survive append to turn normalization" do
    invalid = <<0xFF>>

    tail =
      AcpTranscript.append_stream_event(
        AcpTranscript.empty_stream_tail(),
        %{"kind" => "text", "content" => invalid}
      )

    appended = get_in(tail, ["events", Access.at(0), "content"])
    assert appended["original_bytes"] == 1
    assert appended["sha256"] == sha(invalid)
    assert appended["truncated"]

    assert {:ok, turn} =
             AcpTranscript.build_turn(%{
               execution_id: "exec_invalid_utf8_stream",
               capture_index: 0,
               prompt_kind: "initial",
               terminal_status: "success",
               stream_tail: tail,
               captured_at: @captured_at
             })

    retained = get_in(turn, ["stream_tail", "events", Access.at(0), "content"])
    assert retained["original_bytes"] == 1
    assert retained["sha256"] == sha(invalid)
    assert retained["truncated"]
    assert String.valid?(retained["text"])
  end

  test "UTF-8 byte truncation never keeps an incomplete codepoint" do
    field = AcpTranscript.bound_text_field("abc" <> <<0xF0, 0x9F, 0x98, 0x80>>, 5)

    assert field["text"] == "abc"
    assert field["original_bytes"] == 7
    assert field["truncated"]
    assert String.valid?(field["text"])
  end

  test "success turn uses the injected timestamp and closed prompt metadata" do
    tail =
      AcpTranscript.append_stream_event(AcpTranscript.empty_stream_tail(), %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"text" => "streamed"}
      })

    assert {:ok, turn} =
             AcpTranscript.build_turn(%{
               execution_id: "exec_run_node_input",
               capture_index: 0,
               prompt_kind: "initial",
               terminal_status: "success",
               prompt: "implement feature",
               response_text: "done",
               stop_reason: "end_turn",
               provider: :grok,
               provider_session_id: "provider-session-1",
               stream_tail: tail,
               captured_at: @captured_at
             })

    assert turn["turn_id"] == AcpTranscript.turn_id("exec_run_node_input", 0)
    assert turn["execution"]["capture_index"] == 0
    assert turn["prompt"]["kind"] == "initial"
    assert turn["prompt"]["control_id"]["text"] == ""
    assert turn["prompt"]["content"]["text"] == "implement feature"
    assert turn["terminal"]["status"] == "success"
    assert turn["terminal"]["response"]["text"] == "done"
    assert turn["terminal"]["error"]["text"] == ""
    assert turn["continuity"]["provider"]["text"] == "grok"
    assert turn["captured_at"]["text"] == @captured_at
    assert turn["stream_tail"]["events_retained"] == 1
    assert {:ok, _json} = Jason.encode(turn)
  end

  test "error turn preserves task-control association and bounded error facts" do
    error = String.duplicate("provider failed ", 1_000)

    assert {:ok, turn} =
             AcpTranscript.build_turn(%{
               execution_id: "exec_error",
               capture_index: 3,
               prompt_kind: "task_control",
               control_id: "control-7",
               terminal_status: "provider_error",
               prompt: "continue safely",
               error: error,
               provider: "codex",
               session_id: "session-1",
               captured_at: @captured_at
             })

    assert turn["prompt"]["control_id"]["text"] == "control-7"
    assert turn["terminal"]["status"] == "provider_error"
    assert turn["terminal"]["error"]["original_bytes"] == byte_size(error)
    assert turn["terminal"]["error"]["truncated"]
    assert turn["terminal"]["error"]["sha256"] == sha(error)
    assert turn["stream_tail"] == AcpTranscript.empty_stream_tail()
  end

  test "all prompt response error and continuity scalars are byte-bounded" do
    huge = String.duplicate("z", 100_000)

    assert {:ok, turn} =
             AcpTranscript.build_turn(%{
               execution_id: String.duplicate("e", 512),
               capture_index: 0,
               prompt_kind: "initial",
               terminal_status: "success",
               prompt: huge,
               response_text: huge,
               error: huge,
               stop_reason: huge,
               provider: huge,
               provider_session_id: huge,
               captured_at: @captured_at
             })

    for field <- [
          turn["prompt"]["content"],
          turn["terminal"]["response"],
          turn["terminal"]["error"],
          turn["terminal"]["stop_reason"],
          turn["continuity"]["provider"],
          turn["continuity"]["provider_session_id"]
        ] do
      assert field["original_bytes"] == byte_size(huge)
      assert field["truncated"]
      assert String.valid?(field["text"])
      assert field["sha256"] == sha(huge)
    end

    assert {:ok, _json} = Jason.encode(turn)
  end

  test "hostile turn terms never survive scalar projection" do
    assert {:ok, turn} =
             AcpTranscript.build_turn(%{
               execution_id: "exec_hostile",
               capture_index: 0,
               prompt_kind: "initial",
               terminal_status: "provider_error",
               prompt: %{pid: self()},
               response_text: fn -> :bad end,
               error: {:provider, self(), make_ref()},
               provider: self(),
               provider_session_id: make_ref(),
               captured_at: @captured_at,
               stream_tail: %{"events" => [self(), fn -> :bad end]}
             })

    assert turn["prompt"]["content"]["text"] == ""
    assert turn["terminal"]["response"]["text"] == ""
    assert turn["terminal"]["error"]["text"] == ""
    assert turn["continuity"]["provider"]["text"] == ""
    assert {:ok, _json} = Jason.encode(turn)
  end

  test "hostile pre-shaped integer metadata is normalized to bounded values" do
    huge_integer = Integer.pow(10, 100)

    tail =
      AcpTranscript.append_stream_event(
        %{
          "events" => [
            %{
              "source_seq" => huge_integer,
              "kind" => "text",
              "content" => %{
                "text" => "kept",
                "original_bytes" => huge_integer,
                "truncated" => true,
                "sha256" => sha("kept")
              }
            }
          ],
          "events_seen" => huge_integer
        },
        %{"kind" => "text", "content" => "next"}
      )

    bounds = AcpTranscript.bounds()
    assert tail["events_seen"] <= bounds.max_stream_events_seen

    for event <- tail["events"] do
      assert event["source_seq"] < bounds.max_stream_events_seen
      assert event["content"]["original_bytes"] <= bounds.max_original_bytes
    end

    first_content = get_in(tail, ["events", Access.at(0), "content"])
    assert first_content["original_bytes"] == byte_size("kept")
    assert first_content["sha256"] == sha("kept")
    refute first_content["truncated"]

    last_content = get_in(tail, ["events", Access.at(-1), "content"])
    assert last_content["original_bytes"] == byte_size("next")
    assert last_content["sha256"] == sha("next")
    refute last_content["truncated"]

    assert {:error, {:invalid_turn_field, :capture_index}} =
             AcpTranscript.build_turn(%{
               execution_id: "exec_oversized_index",
               capture_index: bounds.max_capture_index + 1,
               prompt_kind: "initial",
               terminal_status: "success",
               captured_at: @captured_at
             })
  end

  test "inconsistent untruncated field facts are reconstructed as one tuple" do
    tail = %{
      "events" => [
        %{
          "source_seq" => 0,
          "kind" => "text",
          "content" => %{
            "text" => "kept",
            "original_bytes" => 1,
            "truncated" => false,
            "sha256" => String.duplicate("a", 64)
          },
          "tool_name" => AcpTranscript.bound_text_field("", 128),
          "tool_call_id" => AcpTranscript.bound_text_field("", 128)
        }
      ],
      "events_seen" => 1
    }

    assert {:ok, turn} =
             AcpTranscript.build_turn(%{
               execution_id: "exec_inconsistent_field",
               capture_index: 0,
               prompt_kind: "initial",
               terminal_status: "success",
               stream_tail: tail,
               captured_at: @captured_at
             })

    content = get_in(turn, ["stream_tail", "events", Access.at(0), "content"])
    assert content["original_bytes"] == byte_size("kept")
    assert content["sha256"] == sha("kept")
    refute content["truncated"]
  end

  test "captured_at is required instead of consulting a clock" do
    attrs = %{
      execution_id: "exec_no_clock",
      capture_index: 0,
      prompt_kind: "initial",
      terminal_status: "success",
      prompt: "hello"
    }

    assert {:error, {:invalid_turn_field, :captured_at}} = AcpTranscript.build_turn(attrs)
  end

  defp sha(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
end
