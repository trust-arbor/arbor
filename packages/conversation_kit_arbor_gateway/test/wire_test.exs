defmodule ConversationKit.Arbor.Gateway.WireTest do
  use ExUnit.Case, async: true
  alias ConversationKit.Arbor.Gateway.Wire
  alias ConversationKit.Arbor
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

  defp command(status, outcome \\ nil) do
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

  defp window do
    %{
      "agent_id" => "agent_test",
      "engagement_id" => @engagement,
      "entries" => [
        %{
          "id" => "host_9",
          "role" => "assistant",
          "content" => "authoritative",
          "timestamp" => "2026-10-02T00:00:00Z",
          "entry_ordinal" => 9
        }
      ],
      "head" => 12,
      "first" => 9,
      "last" => 9,
      "has_older" => true,
      "has_newer" => true
    }
  end

  defp window_client(page) do
    transport = fn context, _proof ->
      Wire.decode(encoded("conversation_window", page), context)
    end

    {:ok, client} =
      Arbor.new("human_test", "agent_test", fn _ -> {:ok, [session_token: "fixture"]} end,
        transport: transport
      )

    client
  end

  test "window normalization and target binding pass through the public adapter boundary" do
    assert {:ok, client, window} =
             Arbor.window(window_client(window()), through: 12, after: 8, limit: 1)

    assert window == %{head: 12, first: 9, last: 9, has_older: true, has_newer: true}

    assert [%{"id" => "host_9", "ordinal" => 9, "text" => "authoritative"}] =
             Arbor.projection(client)["messages"]

    assert Arbor.position(client) == %{history: 9, commands: 0}

    for page <- [
          Map.put(window(), "agent_id", "other_target"),
          Map.put(window(), "unexpected", "private"),
          Map.delete(window(), "has_newer"),
          put_in(window(), ["entries", Access.at(0), "unexpected"], "private")
        ] do
      assert {:error, :invalid_transport_response} =
               Arbor.window(window_client(page), through: 12, limit: 1)
    end
  end

  test "window status remains an assistant semantic string through wire and public projection" do
    for status <- ~w(complete interrupted cancelled failed streaming) do
      page = put_in(window(), ["entries", Access.at(0), "status"], status)

      assert {:ok, %{entries: [%{status: ^status, role: "assistant"}]}} =
               Wire.decode(encoded("conversation_window", page), context(:window))

      assert {:ok, next, _} = Arbor.window(window_client(page), through: 12, limit: 1)

      assert [%{"status" => ^status, "role" => "assistant", "text" => "authoritative"}] =
               Arbor.projection(next)["messages"]
    end
  end

  test "security regression wire rejects unknown status, non-assistant status, and extra metadata" do
    valid = put_in(window(), ["entries", Access.at(0), "status"], "cancelled")

    for page <- [
          put_in(valid, ["entries", Access.at(0), "status"], "unknown"),
          put_in(valid, ["entries", Access.at(0), "status"], nil),
          put_in(valid, ["entries", Access.at(0), "status"], 123),
          put_in(valid, ["entries", Access.at(0), "status"], %{"status" => "cancelled"}),
          put_in(valid, ["entries", Access.at(0), "role"], "user"),
          put_in(valid, ["entries", Access.at(0), "metadata"], %{"principal_id" => "private"}),
          put_in(valid, ["entries", Access.at(0), "reason"], "private")
        ] do
      assert {:error, :invalid_transport_response} =
               Wire.decode(encoded("conversation_window", page), context(:window))

      initial = window_client(page)
      assert {:error, :invalid_transport_response} = Arbor.window(initial, through: 12, limit: 1)
      assert Arbor.projection(initial)["messages"] == []
      assert Arbor.position(initial) == %{history: 0, commands: 0}
    end
  end

  test "legacy history wire keeps its exact five-field entry contract" do
    entry = hd(window()["entries"])
    page = history(%{"entries" => [entry], "cursor" => 9, "head" => 9})

    assert {:ok, %{entries: [legacy]}} =
             Wire.decode(encoded("conversation_history", page), context(:history))

    assert Enum.sort(Map.keys(legacy)) == [:content, :entry_ordinal, :id, :role, :timestamp]

    changed = put_in(page, ["entries", Access.at(0), "status"], "cancelled")

    assert {:error, :invalid_transport_response} =
             Wire.decode(encoded("conversation_history", changed), context(:history))
  end

  test "semantic window tampering fails through the public adapter without replacing state" do
    for {page, expected} <- [
          {Map.put(window(), "head", 13), :invalid_history_page},
          {Map.put(window(), "first", 8), :invalid_history_entry},
          {Map.put(window(), "has_older", "true"), :invalid_history_page},
          {put_in(window(), ["entries", Access.at(0), "entry_ordinal"], 13),
           :invalid_history_entry},
          {put_in(window(), ["entries", Access.at(0), "role"], "unexpected"),
           :invalid_history_entry}
        ] do
      client = window_client(page)
      assert {:error, ^expected} = Arbor.window(client, through: 12, limit: 1)
      assert Arbor.projection(client)["messages"] == []
      assert Arbor.position(client) == %{history: 0, commands: 0}
    end
  end

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

  test "stopped-agent rejection is a closed error correlated to the submitted ID" do
    rejection = encoded("conversation_rejected", %{id: "id1", reason: "agent_not_running"})

    assert {:error, :agent_not_running} =
             Wire.decode(rejection, context(:submit, %{id: "id1", text: "hello"}))

    assert {:error, :agent_not_running} =
             Wire.decode(
               Jason.encode!(%{type: "error", reason: "agent_not_running"}),
               context(:submit, %{id: "id1", text: "hello"})
             )

    assert {:error, :invalid_transport_response} =
             Wire.decode(rejection, context(:command, "id1"))

    assert {:error, :invalid_transport_response} =
             Wire.decode(
               encoded("conversation_rejected", %{
                 id: "id1",
                 reason: "agent_not_running",
                 detail: "unqualified host detail"
               }),
               context(:submit, %{id: "id1", text: "hello"})
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
