defmodule ConversationKit.Arbor.Gateway.WireTest do
  use ExUnit.Case, async: true
  alias ConversationKit.Arbor.Gateway.Wire
  @engagement "eng_11111111111111111111111111111111"

  defp context(op, input \\ nil),
    do: %{caller: "human_test", target: "agent_test", operation: op, input: input, options: []}

  defp history(extra \\ %{}) do
    Map.merge(
      %{
        "agent_id" => "agent_test",
        "engagement_id" => @engagement,
        "entries" => [],
        "cursor" => 0,
        "head" => 0,
        "has_more" => false
      },
      extra
    )
  end

  defp command(status \\ "admitted", outcome \\ nil) do
    %{
      "id" => "id1",
      "name" => "chat.send",
      "text" => "hello",
      "principal_id" => "human_owner",
      "agent_id" => "agent_test",
      "engagement_id" => @engagement,
      "status" => status,
      "outcome" => outcome,
      "admitted_cursor" => 1,
      "updated_cursor" => 1
    }
  end

  defp encoded(type, data), do: Jason.encode!(%{type: type, data: data})

  test "history verifies transport target before stripping its extra field" do
    assert {:ok, %{engagement_id: @engagement, entries: []} = result} =
             Wire.decode(encoded("conversation_history", history()), context(:history))

    refute Map.has_key?(result, :agent_id)

    for changed <- [%{"agent_id" => "agent_other"}, %{"extra" => true}] do
      assert {:error, :invalid_transport_response} =
               Wire.decode(encoded("conversation_history", history(changed)), context(:history))
    end
  end

  test "only enumerated command statuses and outcomes become atoms" do
    for {status, outcome, expected} <- [
          {"admitted", nil, :admitted},
          {"dispatch_started", nil, :dispatch_started},
          {"completed", %{"status" => "completed", "text" => "answer"}, :completed},
          {"uncertain", %{"status" => "uncertain", "reason" => "delivery_unknown"}, :uncertain}
        ] do
      assert {:ok, result} =
               Wire.decode(
                 encoded("conversation_command", command(status, outcome)),
                 context(:command, "id1")
               )

      assert result.status == expected
    end

    assert {:error, :invalid_transport_response} =
             Wire.decode(
               encoded("conversation_command", command("future")),
               context(:command, "id1")
             )
  end

  test "security regression: wrong response operation, rejection ID and unknown errors fail closed" do
    assert {:error, :invalid_transport_response} =
             Wire.decode(encoded("conversation_history", history()), context(:command, "id1"))

    assert {:error, :invalid_transport_response} =
             Wire.decode(
               encoded("conversation_rejected", %{id: "other", reason: "invalid_command"}),
               context(:submit, %{id: "id1", text: "hello"})
             )

    assert {:error, :invalid_transport_response} =
             Wire.decode(
               Jason.encode!(%{type: "error", reason: "unknown-secret-detail"}),
               context(:history)
             )

    assert {:error, :unauthorized} =
             Wire.decode(
               Jason.encode!(%{type: "error", reason: "unauthorized"}),
               context(:history)
             )
  end

  test "wire rejects oversized payload and malformed nested arrays before Kit" do
    assert {:error, :invalid_transport_response} =
             Wire.decode(String.duplicate("x", 8_388_609), context(:history))

    assert {:error, :invalid_transport_response} =
             Wire.decode(
               encoded("conversation_history", history(%{"entries" => [%{"unknown" => 1}]})),
               context(:history)
             )
  end
end
