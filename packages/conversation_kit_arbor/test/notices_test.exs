defmodule ConversationKit.Arbor.NoticesTest do
  use ExUnit.Case, async: true
  alias ConversationKit.Arbor
  @moduletag :fast
  @page JSON.decode!(File.read!(Path.join(__DIR__, "support/notice_page.json")))
  @vectors JSON.decode!(File.read!(Path.join(__DIR__, "support/notice_vectors.json")))

  defp client(host, caller \\ "human_linked_alias") do
    observer = self()

    proof = fn context ->
      token = make_ref()
      send(observer, {:proof, context, token})
      {:ok, [session_token: token]}
    end

    {:ok, client} =
      Arbor.new(caller, @page["target_agent_id"], proof,
        transport: fn context, proof ->
          send(observer, {:request, context, proof})

          if context.operation == :window,
            do:
              {:ok,
               %{
                 engagement_id: @page["engagement_id"],
                 entries: [],
                 head: 0,
                 first: 0,
                 last: 0,
                 has_older: false,
                 has_newer: false
               }},
            else: host.(context)
        end
      )

    {:ok, client, _} = Arbor.window(client)
    client
  end

  test "producer-owned Unicode page is scoped, fresh-proof read only and strips original-recipient provenance from display" do
    initial = client(fn _ -> {:ok, @page} end)
    assert {:ok, read, %{head: 1, through: 1, has_older: false}} = Arbor.notices(initial)
    assert read.owner == @page["owner_id"]
    projection = Arbor.projection(read)
    assert [%{"text" => text, "kind" => "progress"} = notice] = projection["notices"]
    assert text == hd(@page["notices"])["text"]
    assert Map.keys(notice) |> Enum.sort() == ~w(id kind ordinal text timestamp)
    assert projection["messages"] == []
    assert projection["deliveries"] == []
    assert [%{"type" => "notice"}] = projection["blocks"]
    assert projection["speech"] == []
    refute inspect(projection) =~ "human_"
    refute inspect(projection) =~ "payload_sha256"
    assert_receive {:proof, %{operation: :window}, first}
    assert_receive {:proof, %{operation: :notices, input: nil, options: opts}, second}
    assert first != second
    assert opts == [expected_engagement_id: @page["engagement_id"], limit: 8]
    assert {:ok, cleared, _} = Arbor.notices(read)
    assert Arbor.clear_notices(cleared).owner == @page["owner_id"]
    assert Arbor.projection(Arbor.clear_notices(cleared))["notices"] == []
  end

  test "fixed-array digest matches producer canonical JSON for quotes controls separators and Unicode" do
    for vector <- @vectors do
      notice = hd(@page["notices"])

      payload = [
        "arbor.notice.provenance.v1",
        @page["owner_id"],
        @page["target_agent_id"],
        @page["engagement_id"],
        notice["recipient_subject_id"],
        notice["notice_id"],
        notice["kind"],
        vector["text"]
      ]

      assert Base.encode16(JSON.encode!(payload), case: :lower) == vector["canonical_hex"]

      notice =
        notice
        |> Map.put("text", vector["text"])
        |> put_in(["provenance", "taint", "payload_sha256"], vector["payload_sha256"])

      page = Map.put(@page, "notices", [notice])
      assert {:ok, read, _} = Arbor.notices(client(fn _ -> {:ok, page} end))
      assert hd(Arbor.projection(read)["notices"])["text"] == vector["text"]
    end
  end

  test "security regression: canonical scope and readonly original recipient cannot be replaced by caller alias" do
    initial = client(fn _ -> {:ok, @page} end)
    assert {:ok, pinned, _} = Arbor.notices(initial)

    for page <- [
          put_in(@page, ["notices", Access.at(0), "recipient_subject_id"], "human_linked_alias"),
          put_in(
            @page,
            ["notices", Access.at(0), "provenance", "taint", "taint", "level"],
            "trusted"
          ),
          Map.put(@page, "callback", "forged")
        ] do
      assert {:error, :invalid_notice_response} =
               Arbor.notices(%{pinned | transport: fn _, _ -> {:ok, page} end})
    end

    other = %{@page | "owner_id" => "human_other", "notices" => [], "head" => 1, "through" => 1}

    assert {:error, :conversation_scope_changed} =
             Arbor.notices(%{pinned | transport: fn _, _ -> {:ok, other} end})
  end

  test "malformed bounds are refused before proof acquisition and response cursor cannot skip omitted records" do
    initial = client(fn _ -> flunk("invalid request reached transport") end)

    for opts <- [
          [before: nil],
          [through: 0],
          [limit: 51],
          [before: 2, before: 3],
          [after: 2],
          %{},
          [limit: 1.0]
        ] do
      assert {:error, :invalid_notice_request} = Arbor.notices(initial, opts)
    end

    refute_receive {:proof, %{operation: :notices}, _}
    page = @page |> Map.put("has_older", true) |> Map.put("next_before", 2)
    assert {:error, :invalid_notice_response} = Arbor.notices(client(fn _ -> {:ok, page} end))
    page = @page |> Map.put("has_older", true) |> Map.put("next_before", 1)
    assert {:ok, _, %{next_before: 1}} = Arbor.notices(client(fn _ -> {:ok, page} end))
  end

  test "closed page rejects duplicate IDs, oversized bytes, non UTC6 timestamp and rollback head" do
    notice = hd(@page["notices"])

    pages = [
      Map.put(@page, "notices", [notice, notice]),
      put_in(@page, ["notices", Access.at(0), "created_at"], "2026-10-03T18:23:19Z"),
      put_in(@page, ["notices", Access.at(0), "text"], String.duplicate("x", 32_769)),
      Map.put(@page, "complete", false)
    ]

    for page <- pages,
        do:
          assert(
            {:error, :invalid_notice_response} = Arbor.notices(client(fn _ -> {:ok, page} end))
          )

    assert {:ok, pinned, _} = Arbor.notices(client(fn _ -> {:ok, @page} end))
    empty = %{@page | "notices" => [], "head" => 0, "through" => 0}

    assert {:error, :invalid_notice_response} =
             Arbor.notices(%{pinned | transport: fn _, _ -> {:ok, empty} end})
  end

  test "notice commands are finite local intents and preserve ordinary Unicode message bytes" do
    for {text, action} <- [
          {" /notices", :notices},
          {"/older-notices", :older_notices},
          {"/latest-notices\n", :latest_notices}
        ] do
      assert {:local, ^action} = Arbor.classify_composer_input(text)
    end

    assert {:unavailable, :runtime_command} = Arbor.classify_composer_input("/notices send user")
    assert {:unavailable, :runtime_command} = Arbor.classify_composer_input("/notice publish")
    message = "  通知 café 🌳\nwith a second line  "
    assert {:message, ^message} = Arbor.classify_composer_input(message)
  end

  test "a full byte-budget page is rejected rather than silently dropping its last record or cursor" do
    text = String.duplicate("a", 32_768)

    records =
      for ordinal <- 4..1//-1 do
        record =
          hd(@page["notices"])
          |> Map.put("text", text)
          |> Map.put("ordinal", ordinal)
          |> Map.put(
            "notice_id",
            "notice_" <> (ordinal |> Integer.to_string(16) |> String.pad_leading(32, "0"))
          )

        payload = [
          "arbor.notice.provenance.v1",
          @page["owner_id"],
          @page["target_agent_id"],
          @page["engagement_id"],
          record["recipient_subject_id"],
          record["notice_id"],
          record["kind"],
          text
        ]

        digest = :crypto.hash(:sha256, JSON.encode!(payload)) |> Base.encode16(case: :lower)
        put_in(record, ["provenance", "taint", "payload_sha256"], digest)
      end

    page = %{@page | "head" => 4, "through" => 4, "notices" => records}
    assert byte_size(JSON.encode!(page)) > 129_024
    assert {:error, :invalid_notice_response} = Arbor.notices(client(fn _ -> {:ok, page} end))

    bounded = %{
      page
      | "notices" => Enum.take(records, 3),
        "has_older" => true,
        "next_before" => 2
    }

    assert byte_size(JSON.encode!(bounded)) < 129_024

    assert {:ok, read, %{has_older: true, next_before: 2}} =
             Arbor.notices(client(fn _ -> {:ok, bounded} end))

    assert Enum.map(Arbor.projection(read)["notices"], & &1["ordinal"]) == [4, 3, 2]

    assert {:error, :invalid_notice_response} =
             Arbor.notices(client(fn _ -> {:ok, bounded} end), limit: 2)
  end
end
