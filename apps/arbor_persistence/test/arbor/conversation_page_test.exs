defmodule Arbor.Persistence.ConversationPageTest do
  use Arbor.Persistence.DatabaseCase, async: false

  import Ecto.Query

  alias Arbor.Persistence
  alias Arbor.Persistence.Schemas.{Session, SessionEntry}

  @moduletag :database
  @moduletag :fast
  @engagement "eng_0123456789abcdef0123456789abcdef"
  @other "eng_abcdef0123456789abcdef0123456789"

  setup do
    agent = "page_#{System.unique_integer([:positive])}"
    {:ok, session} = Persistence.ensure_session("agent-session-#{agent}", agent)
    %{agent: agent, session: session}
  end

  test "security regression filters the engagement before limiting and excludes metadata", ctx do
    assert {:ok, 5} =
             Persistence.append_session_entries(ctx.session.id, [
               entry(@other, "other first"),
               entry(@engagement, "ours first"),
               entry(@other, "other middle"),
               entry(@engagement, "not a message", "heartbeat"),
               entry(@engagement, "ours second", "assistant")
             ])

    assert {:ok, first} = Persistence.read_conversation_page(ctx.agent, @engagement, limit: 1)
    assert %{head: 5, cursor: 2, has_more: true, entries: [one]} = first
    assert one.content == "ours first"
    assert Enum.sort(Map.keys(one)) == [:content, :entry_ordinal, :id, :role, :timestamp]
    assert is_binary(one.id)
    assert {:ok, _, 0} = DateTime.from_iso8601(one.timestamp)

    assert {:ok, %{cursor: 5, head: 5, has_more: false, entries: [two]}} =
             Persistence.read_conversation_page(ctx.agent, @engagement,
               after: first.cursor,
               through: first.head,
               limit: 1
             )

    assert two.content == "ours second"
    assert two.role == "assistant"
  end

  test "pinned head excludes concurrent later appends while ordinal gaps remain legal", ctx do
    append(ctx, [entry(@engagement, "one"), entry(@other, "gap"), entry(@engagement, "three")])
    {:ok, first} = Persistence.read_conversation_page(ctx.agent, @engagement, limit: 1)
    append(ctx, [entry(@engagement, "four")])

    assert {:ok, %{head: 3, cursor: 3, has_more: false, entries: [%{content: "three"}]}} =
             Persistence.read_conversation_page(ctx.agent, @engagement,
               after: first.cursor,
               through: first.head
             )

    assert {:ok, %{head: 4, entries: [%{content: "three"}, %{content: "four"}]}} =
             Persistence.read_conversation_page(ctx.agent, @engagement, after: first.cursor)

    assert {:ok, %{head: 2, cursor: 2, entries: []}} =
             Persistence.read_conversation_page(ctx.agent, @engagement, after: 1, through: 2)
  end

  test "security regression rejects a canonical session row owned by another agent", ctx do
    append(ctx, [entry(@engagement, "private")])

    Repo.update_all(from(s in Session, where: s.id == ^ctx.session.id),
      set: [agent_id: "foreign"]
    )

    assert {:error, :conversation_unavailable} =
             Persistence.read_conversation_page(ctx.agent, @engagement)
  end

  test "empty observed history is distinct from unavailable storage", ctx do
    assert {:ok, %{entries: [], head: 0, cursor: 0, has_more: false}} =
             Persistence.read_conversation_page(ctx.agent <> "_absent", @engagement)

    assert {:error, :invalid_cursor} =
             Persistence.read_conversation_page(ctx.agent <> "_absent", @engagement, after: 1)

    previous = Repo.put_dynamic_repo(:conversation_page_unavailable_repo)

    try do
      assert {:error, :conversation_unavailable} =
               Persistence.read_conversation_page(ctx.agent, @engagement)
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  test "rejects ahead-of-head cursors instead of inventing continuity", ctx do
    append(ctx, [entry(@engagement, "one")])

    assert {:error, :invalid_cursor} =
             Persistence.read_conversation_page(ctx.agent, @engagement, after: 2)

    assert {:error, :invalid_cursor} =
             Persistence.read_conversation_page(ctx.agent, @engagement, through: 2)
  end

  test "security regression rejects malformed and authority-bearing options before storage",
       ctx do
    previous = Repo.put_dynamic_repo(:conversation_page_unavailable_repo)

    try do
      for opts <- [
            nil,
            %{},
            ["limit"],
            [{"limit", 1}],
            [{:limit, 1} | :bad],
            [limit: 1, limit: 2],
            [limit: 0],
            [limit: 101],
            [limit: "1"],
            [after: -1],
            [after: 9_223_372_036_854_775_808],
            [through: nil],
            [after: 2, through: 1],
            [engagement_id: @other],
            [principal_id: "foreign"],
            [session_id: "foreign"],
            [persistence: Repo]
          ] do
        assert {:error, :invalid_options} =
                 Persistence.read_conversation_page(ctx.agent, @engagement, opts)
      end
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  test "rejects invalid identifiers without a database query", ctx do
    for agent <- [nil, "", " ", <<255>>, String.duplicate("x", 257)] do
      assert {:error, :invalid_identifier} =
               Persistence.read_conversation_page(agent, @engagement)
    end

    for engagement <- [nil, "eng_foreign", @engagement <> "x", <<255>>] do
      assert {:error, :invalid_identifier} =
               Persistence.read_conversation_page(ctx.agent, engagement)
    end
  end

  test "security regression rejects malformed text blocks and role confusion", ctx do
    append(ctx, [entry(@engagement, "one")])
    query = from(e in SessionEntry, where: e.session_id == ^ctx.session.id)
    Repo.update_all(query, set: [content: [%{"type" => "text", "text" => 123}]])

    assert {:error, :invalid_transcript} =
             Persistence.read_conversation_page(ctx.agent, @engagement)

    Repo.update_all(query, set: [content: [%{"type" => "text", "text" => "ok"}], role: "system"])

    assert {:error, :invalid_transcript} =
             Persistence.read_conversation_page(ctx.agent, @engagement)
  end

  test "security regression rejects a corrupt zero ordinal instead of reporting empty", ctx do
    append(ctx, [entry(@engagement, "one")])

    Repo.update_all(from(e in SessionEntry, where: e.session_id == ^ctx.session.id),
      set: [entry_ordinal: 0]
    )

    assert {:error, :invalid_transcript} =
             Persistence.read_conversation_page(ctx.agent, @engagement)
  end

  test "text-only projection omits non-text blocks and preserves empty text messages", ctx do
    row = entry(@engagement, "one")

    row = %{
      row
      | content: [
          %{"type" => "text", "text" => "one"},
          %{"type" => "thinking", "thinking" => "private"},
          %{"type" => "text", "text" => "two"}
        ]
    }

    append(ctx, [row, %{entry(@engagement, "") | content: []}])

    assert {:ok, %{entries: [%{content: "one\ntwo"}, %{content: ""}]}} =
             Persistence.read_conversation_page(ctx.agent, @engagement)
  end

  test "bounds entry and encoded page size with explicit errors, never truncation", ctx do
    append(ctx, [entry(@engagement, String.duplicate("x", 262_145))])
    assert {:error, :page_too_large} = Persistence.read_conversation_page(ctx.agent, @engagement)

    Repo.delete_all(from(e in SessionEntry, where: e.session_id == ^ctx.session.id))
    rows = for _ <- 1..5, do: entry(@engagement, String.duplicate("x", 230_000))
    append(ctx, rows)
    assert {:error, :page_too_large} = Persistence.read_conversation_page(ctx.agent, @engagement)

    assert {:ok, %{has_more: true, entries: [_, _, _, _]}} =
             Persistence.read_conversation_page(ctx.agent, @engagement, limit: 4)
  end

  test "new_event public wrapper preserves explicit event identity and payload" do
    timestamp = ~U[2026-09-26 00:00:00Z]

    event =
      Persistence.new_event("stream", "admitted", %{"text" => "hello"},
        id: "event-1",
        timestamp: timestamp
      )

    assert event.id == "event-1"
    assert event.stream_id == "stream"
    assert event.type == "admitted"
    assert event.data == %{"text" => "hello"}
    assert event.timestamp == timestamp
  end

  defp append(ctx, rows) do
    assert {:ok, count} = Persistence.append_session_entries(ctx.session.id, rows)
    assert count == length(rows)
  end

  defp entry(engagement, text, role \\ "user") do
    %{
      entry_type: role,
      role: if(role == "heartbeat", do: nil, else: role),
      content: [%{"type" => "text", "text" => text}],
      timestamp: ~U[2026-09-26 00:00:00.000000Z],
      metadata: %{"engagement_id" => engagement, "private" => "not for the UI"}
    }
  end
end
