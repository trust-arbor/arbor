defmodule ConversationKit.Arbor.Gateway.NoticeWireTest do
  use ExUnit.Case, async: true
  alias ConversationKit.Arbor.Gateway.Wire
  @moduletag :fast
  @page Jason.decode!(File.read!(Path.join(__DIR__, "support/notice_page.json")))
  @vectors Jason.decode!(File.read!(Path.join(__DIR__, "support/notice_vectors.json")))

  defp context(operation \\ :notices),
    do: %{
      operation: operation,
      caller: "human_linked_alias",
      target: @page["target_agent_id"],
      input: nil,
      options: [expected_engagement_id: @page["engagement_id"], limit: 8]
    }

  defp frame(page), do: Jason.encode!(%{type: "conversation_notices", data: page})

  test "remote public codec accepts real producer page and preserves original readonly recipient for local verification" do
    assert {:ok, page} = Wire.decode(frame(@page), context())
    assert page == @page
    assert hd(page["notices"])["recipient_subject_id"] == "human_fixture_original_recipient"
    assert payload = Wire.payload(context())

    assert Jason.decode!(payload) == [
             "arbor.conversation.notices.v1",
             "human_linked_alias",
             @page["target_agent_id"],
             [nil, nil, 8],
             @page["engagement_id"]
           ]

    refute payload =~ "recipient_subject_id"
  end

  test "security regression: valid foreign scope invalidates binding while malformed notice data remains a notice-only failure" do
    assert {:error, :conversation_scope_changed} =
             Wire.decode(frame(@page), %{context() | target: "agent_other"})

    assert {:error, :conversation_scope_changed} =
             Wire.decode(frame(@page), %{
               context()
               | options: [expected_engagement_id: "eng_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
             })

    for page <- [
          Map.put(@page, "callback", "forged"),
          put_in(@page, ["notices", Access.at(0), "text"], "tampered"),
          Map.put(@page, "complete", false)
        ] do
      assert {:error, :invalid_notice_response} = Wire.decode(frame(page), context())
    end

    refute inspect(Wire.decode(frame(@page), context())) =~ "credential-sentinel"
  end

  test "notice_subject_required is only accepted in the freshly authenticated notices operation context" do
    error = Jason.encode!(%{type: "error", reason: "notice_subject_required"})
    assert {:error, :notice_subject_required} = Wire.decode(error, context())
    assert {:error, :invalid_transport_response} = Wire.decode(error, context(:window))
    assert {:error, :invalid_transport_response} = Wire.decode(frame(@page), context(:window))
  end

  test "duplicate JSON selectors oversized frame and wrong response phase cannot silently retain stale notice data" do
    duplicate =
      String.replace(frame(@page), "\"complete\":true", "\"complete\":true,\"complete\":true")

    assert {:error, :invalid_notice_response} = Wire.decode(duplicate, context())

    assert {:error, :invalid_notice_response} =
             Wire.decode(String.duplicate(" ", 131_073), context())

    assert {:error, :invalid_notice_response} =
             Wire.decode(Jason.encode!(%{type: "conversation_window", data: %{}}), context())
  end

  test "remote page obeys the exact requested exclusive before, fixed through and row limit" do
    for opts <- [
          [before: 1, limit: 8, expected_engagement_id: @page["engagement_id"]],
          [through: 2, limit: 8, expected_engagement_id: @page["engagement_id"]]
        ] do
      assert {:error, :invalid_notice_response} =
               Wire.decode(frame(@page), %{context() | options: opts})
    end

    assert {:ok, @page} =
             Wire.decode(frame(@page), %{
               context()
               | options: [
                   before: 2,
                   through: 1,
                   limit: 1,
                   expected_engagement_id: @page["engagement_id"]
                 ]
             })

    old_cutoff = %{@page | "head" => 2}
    assert {:error, :invalid_notice_response} = Wire.decode(frame(old_cutoff), context())

    assert {:ok, ^old_cutoff} =
             Wire.decode(frame(old_cutoff), %{
               context()
               | options: [through: 1, limit: 8, expected_engagement_id: @page["engagement_id"]]
             })
  end

  test "released Jason fixed-array bytes match the local codec's stored Unicode and escape vectors" do
    for vector <- @vectors do
      record = hd(@page["notices"])

      payload = [
        "arbor.notice.provenance.v1",
        @page["owner_id"],
        @page["target_agent_id"],
        @page["engagement_id"],
        record["recipient_subject_id"],
        record["notice_id"],
        record["kind"],
        vector["text"]
      ]

      assert Base.encode16(Jason.encode!(payload), case: :lower) == vector["canonical_hex"]

      record =
        record
        |> Map.put("text", vector["text"])
        |> put_in(["provenance", "taint", "payload_sha256"], vector["payload_sha256"])

      assert {:ok, page} = Wire.decode(frame(Map.put(@page, "notices", [record])), context())
      assert hd(page["notices"])["text"] == vector["text"]
    end
  end
end
