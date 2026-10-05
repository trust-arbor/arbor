defmodule ConversationKit.Arbor.Gateway.ControlWireTest do
  use ExUnit.Case, async: true
  alias ConversationKit.Arbor
  alias ConversationKit.Arbor.Gateway.Wire
  @eng "eng_0123456789abcdef0123456789abcdef"
  @moduletag :fast
  defp context(op, input \\ nil),
    do: %{
      caller: "human_test",
      target: "agent_test",
      operation: op,
      input: input,
      options: [expected_engagement_id: @eng]
    }

  defp frame(type, data), do: Jason.encode!(%{type: type, data: data})

  defp activity,
    do: %{
      command_id: "cmd",
      task_id: "private_task",
      delivery_status: "uncertain",
      admitted_cursor: 1,
      cancellation: %{status: "none"},
      execution: "not_observed",
      preview: "literal",
      preview_truncated: false,
      progress: nil
    }

  defp page,
    do: %{
      agent_id: "agent_test",
      engagement_id: @eng,
      commands: [activity()],
      source_watermark: 4,
      index_watermark: 3,
      incomplete: true,
      has_more: false,
      next_cursor: nil,
      truncated: false
    }

  defp input,
    do: %{
      command_id: "cmd",
      request_id: "request",
      operation_id: "op",
      revision: 1,
      choice_id: "choice"
    }

  defp answer,
    do:
      Map.take(input(), [:command_id, :request_id, :operation_id, :revision])
      |> Map.merge(%{agent_id: "agent_test", engagement_id: @eng, status: "responded"})

  test "closed activity wire normalizes enums and strips target only after exact authenticated correlation" do
    assert {:ok, %{commands: [%{delivery_status: :uncertain, execution: :not_observed}]}} =
             Wire.decode(frame("conversation_activity", page()), context(:activity))

    for changed <- [
          %{agent_id: "other"},
          %{engagement_id: "eng_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
          %{callback: "forged"},
          %{incomplete: false}
        ] do
      assert {:error, :invalid_transport_response} =
               Wire.decode(
                 frame("conversation_activity", Map.merge(page(), changed)),
                 context(:activity)
               )
    end

    assert {:error, :invalid_transport_response} =
             Wire.decode(
               frame("conversation_activity", %{
                 page()
                 | commands: [Map.put(activity(), :source, "forged")]
               }),
               context(:activity)
             )
  end

  test "empty interactions and answered operations correlate command request operation revision and agent" do
    empty = %{agent_id: "agent_test", engagement_id: @eng, command_id: "cmd", interactions: []}

    assert {:ok, %{command_id: "cmd", interactions: []}} =
             Wire.decode(frame("conversation_interactions", empty), context(:interactions, "cmd"))

    assert {:error, :invalid_transport_response} =
             Wire.decode(
               frame("conversation_interactions", %{empty | command_id: "other"}),
               context(:interactions, "cmd")
             )

    assert {:ok, %{status: :responded}} =
             Wire.decode(
               frame("conversation_interaction_answer", answer()),
               context(:interaction_choice, input())
             )

    for changed <- [
          %{request_id: "other"},
          %{operation_id: "other"},
          %{command_id: "other"},
          %{revision: 1.0},
          %{agent_id: "other"}
        ] do
      assert {:error, :invalid_transport_response} =
               Wire.decode(
                 frame("conversation_interaction_answer", Map.merge(answer(), changed)),
                 context(:interaction_choice, input())
               )
    end
  end

  test "cancellation response remains a single command with uncertain delivery and independent confirmation" do
    raw = %{
      agent_id: "agent_test",
      engagement_id: @eng,
      command_id: "cmd",
      task_id: "private_task",
      delivery_status: "uncertain",
      cancellation: %{status: "confirmed", termination: "engine_terminated"},
      termination_observation: "confirmed"
    }

    assert {:ok,
            %{
              delivery_status: :uncertain,
              cancellation: %{status: :confirmed, termination: :engine_terminated}
            }} = Wire.decode(frame("conversation_cancellation", raw), context(:cancel, "cmd"))

    assert {:error, :invalid_transport_response} =
             Wire.decode(
               frame("conversation_cancellation", %{raw | termination_observation: "unconfirmed"}),
               context(:cancel, "cmd")
             )
  end

  test "security regression duplicate authenticated target and nested command keys refuse either JSON order" do
    data = %{
      "agent_id" => "agent_test",
      "engagement_id" => @eng,
      "entries" => [],
      "cursor" => 0,
      "head" => 0,
      "has_more" => false
    }

    encoded = frame("conversation_history", data)
    assert {:ok, _} = Wire.decode(encoded, context(:history))

    for replacement <- [
          "\"agent_id\":\"other\",\"agent_id\":\"agent_test\"",
          "\"agent_id\":\"agent_test\",\"agent_id\":\"other\""
        ] do
      duplicate = String.replace(encoded, "\"agent_id\":\"agent_test\"", replacement)
      assert {:error, :invalid_transport_response} = Wire.decode(duplicate, context(:history))
    end

    duplicate =
      String.replace(
        frame("conversation_interaction_answer", answer()),
        "\"revision\":1",
        "\"revision\":2,\"revision\":1"
      )

    assert {:error, :invalid_transport_response} =
             Wire.decode(duplicate, context(:interaction_choice, input()))
  end

  test "control reply bound and generic errors refuse private unknown strings" do
    assert {:error, :invalid_transport_response} =
             Wire.decode(
               frame("conversation_activity", %{
                 page()
                 | commands: [%{activity() | preview: String.duplicate("x", 131_584)}]
               }),
               context(:activity)
             )

    assert {:error, :approval_answer_required} =
             Wire.decode(
               frame("unused", %{})
               |> then(fn _ ->
                 Jason.encode!(%{type: "error", reason: "approval_answer_required"})
               end),
               context(:interaction_approval, input())
             )

    assert {:error, :invalid_transport_response} =
             Wire.decode(
               Jason.encode!(%{type: "error", reason: "private exception payload"}),
               context(:cancel, "cmd")
             )
  end

  test "v2 command wire accepts cancellation while public reader preserves original delivery outcome" do
    command = %{
      id: "cmd",
      name: "chat.send",
      text: "Hello",
      principal_id: "human_test",
      agent_id: "agent_test",
      engagement_id: @eng,
      status: "uncertain",
      outcome: %{status: "uncertain", reason: "delivery_unknown"},
      admitted_cursor: 1,
      updated_cursor: 5,
      cancellation: %{status: "confirmed", termination: "engine_terminated"}
    }

    {:ok, client} =
      Arbor.new("human_test", "agent_test", fn _ -> {:ok, [session_token: "private"]} end,
        expected_engagement_id: @eng,
        transport: fn ctx, _ -> Wire.decode(frame("conversation_command", command), ctx) end
      )

    assert {:ok, _, %{"status" => "uncertain", "cancellation" => %{"status" => "confirmed"}}} =
             Arbor.command(client, "cmd")
  end
end
