defmodule Arbor.Client.NoticePageTest do
  use ExUnit.Case, async: true
  alias Arbor.Client

  @owner "human_notice_owner"
  @target "agent_notice_publisher"
  @engagement "eng_11111111111111111111111111111111"

  test "notice reads use their own domain and preserve cursor/fence bytes" do
    options = [before: 9, through: 12, limit: 4, expected_engagement_id: @engagement]

    expected = [
      "arbor.conversation.notices.v1",
      @owner,
      @target,
      [9, 12, 4],
      @engagement
    ]

    payload = Client.conversation_notices_payload(@owner, @target, options)
    assert Jason.decode!(payload) == expected
    assert payload == Client.conversation_payload(:notices, @owner, @target, nil, options)

    assert Jason.decode!(
             Client.conversation_notices_payload(@owner, @target,
               expected_engagement_id: @engagement
             )
           ) ==
             ["arbor.conversation.notices.v1", @owner, @target, [nil, nil, nil], @engagement]

    session = Jason.decode!(Client.session_operation(@owner, @target, :notices, nil, options))
    assert session == %{"payload" => payload, "authentication" => "conversation_session"}
  end

  test "security regression: malformed notice options cannot fall back to another domain" do
    for options <- [
          [before: nil],
          [through: nil],
          [before: 0],
          [through: -1],
          [limit: 0],
          [limit: 51],
          [limit: 1, limit: 2],
          [after: 1],
          [limit: nil],
          [{"limit", 2}],
          %{limit: 2},
          [expected_engagement_id: "eng_wrong"]
        ] do
      assert {:error, :invalid_notice_request} =
               Client.conversation_payload(:notices, @owner, @target, nil, options)
    end

    assert {:error, :invalid_notice_request} =
             Client.conversation_payload(:notices, @owner, @target, "body", [])

    assert {:error, :invalid_notice_request} =
             Client.session_operation(@owner, @target, :notices, %{}, [])
  end

  test "security regression: a notice read cannot be encoded or signed without a conversation fence" do
    assert {:error, :invalid_notice_request} =
             Client.conversation_notices_payload(@owner, @target, [])

    assert {:error, :invalid_notice_request} =
             Client.session_operation(@owner, @target, :notices, nil, limit: 4)

    {_, private} = :crypto.generate_key(:eddsa, :ed25519)
    identity = %{agent_id: @owner, private_key: private}

    assert {:error, :invalid_notice_request} =
             Client.signed_operation(identity, @target, :notices, nil, limit: 4)
  end

  test "each signed notice read gets fresh authentication over the same exact payload" do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    identity = %{agent_id: @owner, private_key: private}
    options = [limit: 4, expected_engagement_id: @engagement]
    first = Client.signed_operation(identity, @target, :notices, nil, options) |> Jason.decode!()
    second = Client.signed_operation(identity, @target, :notices, nil, options) |> Jason.decode!()
    assert first["payload"] == second["payload"]

    envelopes =
      for operation <- [first, second] do
        "Signature " <> encoded = operation["authorization"]
        envelope = encoded |> Base.decode64!(padding: false) |> Jason.decode!()
        nonce = Base.decode64!(envelope["nonce"])

        message =
          prefix(operation["payload"]) <>
            prefix(@owner) <>
            prefix(envelope["timestamp"]) <> nonce

        assert :crypto.verify(:eddsa, :sha512, message, Base.decode64!(envelope["signature"]), [
                 public,
                 :ed25519
               ])

        envelope
      end

    assert hd(envelopes)["nonce"] != List.last(envelopes)["nonce"]
  end

  test "producer-owned SQL page retains original recipient and verifies Unicode provenance" do
    page = page()
    assert page["owner_id"] != hd(page["notices"])["recipient_subject_id"]
    assert hd(page["notices"])["text"] =~ "進捗: café 🌳"
    assert {:ok, ^page} = Client.decode_notice_page(page, scope(page))
    assert {:ok, {:conversation_notices, ^page}} = Client.decode(frame(page))
  end

  test "security regression: content, recipient and established scope tampering is rejected" do
    page = page()

    for field <- ~w(text recipient_subject_id notice_id kind) do
      changed = update_in(page, ["notices", Access.at(0), field], &(&1 <> "changed"))
      assert {:error, :invalid_notice_response} = Client.decode_notice_page(changed)
    end

    for field <- ~w(owner_id target_agent_id engagement_id) do
      changed = Map.put(page, field, page[field] <> "changed")
      assert {:error, :invalid_notice_response} = Client.decode_notice_page(changed)
      expected = Map.put(scope(page), String.to_existing_atom(field), "mismatched")
      assert {:error, :invalid_notice_response} = Client.decode_notice_page(page, expected)
    end
  end

  test "security regression: duplicate JSON keys, unknown fields and weakened taint are rejected" do
    page = page()
    binary = frame(page)

    duplicate =
      String.replace(binary, "\"text\":", "\"text\":\"hidden\",\"text\":", global: false)

    assert {:error, :invalid_notice_response} = Client.decode(duplicate)

    assert {:error, :invalid_notice_response} =
             Client.decode(
               Jason.encode!(%{type: "conversation_notices", data: page, proof: "extra"})
             )

    for {key, value} <- [
          {"level", "trusted"},
          {"sensitivity", "public"},
          {"sanitizations", 1},
          {"confidence", "verified"},
          {"chain", ["source"]},
          {"source", "provider"}
        ] do
      changed =
        put_in(page, ["notices", Access.at(0), "provenance", "taint", "taint", key], value)

      assert {:error, :invalid_notice_response} = Client.decode_notice_page(changed)
    end

    assert {:error, :invalid_notice_response} =
             Client.decode_notice_page(Map.put(page, "proof", "extra"))
  end

  test "ordinal ordering and whole-record paging cursors cannot skip records" do
    page = page()
    [notice | _] = page["notices"]

    paged =
      page
      |> Map.put("has_older", true)
      |> Map.put("next_before", notice["ordinal"])
      |> Map.put("notices", [notice])

    assert {:ok, ^paged} = Client.decode_notice_page(paged)

    assert {:error, :invalid_notice_response} =
             Client.decode_notice_page(Map.put(paged, "next_before", notice["ordinal"] - 1))

    assert {:error, :invalid_notice_response} =
             Client.decode_notice_page(Map.put(page, "notices", [notice, notice]))

    assert {:error, :invalid_notice_response} =
             Client.decode_notice_page(Map.put(page, "through", notice["ordinal"] - 1))

    assert {:error, :invalid_notice_response} =
             Client.decode_notice_page(Map.put(page, "complete", false))

    empty =
      page
      |> Map.put("notices", [])
      |> Map.put("has_older", false)
      |> Map.put("next_before", nil)
      |> Map.put("head", 0)
      |> Map.put("through", 0)

    assert {:ok, ^empty} = Client.decode_notice_page(empty)

    assert {:error, :invalid_notice_response} =
             Client.decode_notice_page(Map.put(empty, "has_older", true))
  end

  test "oversized frames and pages are rejected before being exposed as notice events" do
    assert {:error, :invalid_notice_response} =
             Client.decode(frame(page()) <> String.duplicate(" ", 131_072))

    assert {:error, :invalid_notice_response} =
             Client.decode_notice_page(
               put_in(page(), ["notices", Access.at(0), "text"], String.duplicate("x", 32_769))
             )
  end

  defp page do
    Path.join(__DIR__, "../../support/notice_page.json") |> File.read!() |> Jason.decode!()
  end

  defp scope(page),
    do: %{
      owner_id: page["owner_id"],
      target_agent_id: page["target_agent_id"],
      engagement_id: page["engagement_id"]
    }

  defp frame(page), do: Jason.encode!(%{type: "conversation_notices", data: page})
  defp prefix(value), do: <<byte_size(value)::32, value::binary>>
end
