defmodule Arbor.Persistence.ConversationWindowTest do
  use Arbor.Persistence.DatabaseCase, async: false
  import Ecto.Query
  alias Arbor.Persistence
  alias Arbor.Persistence.Schemas.{Session, SessionEntry}
  @moduletag :database
  @moduletag :fast
  @own "eng_0123456789abcdef0123456789abcdef"
  @other "eng_abcdef0123456789abcdef0123456789"

  setup do
    agent = "window_#{System.unique_integer([:positive])}"
    {:ok, session} = Persistence.ensure_session("agent-session-#{agent}", agent)
    %{agent: agent, session: session}
  end

  test "security regression latest window filters before limiting and excludes private fields",
       c do
    append(c, [
      entry(@own, "one"),
      entry(@other, "foreign"),
      entry(@own, "three"),
      entry(@own, "four")
    ])

    assert {:ok, %{head: 4, first: 3, last: 4, has_older: true, has_newer: false, entries: rows}} =
             Persistence.read_conversation_window(c.agent, @own, limit: 2)

    assert Enum.map(rows, & &1.content) == ["three", "four"]

    for row <- rows do
      assert Enum.sort(Map.keys(row)) == [:content, :entry_ordinal, :id, :role, :timestamp]
    end
  end

  test "security regression window preserves assistant status without changing legacy page shape",
       c do
    statuses = ~w(complete interrupted cancelled failed streaming)

    assistants =
      for status <- statuses do
        row = assistant_entry(status)

        %{row | metadata: Map.merge(row.metadata, %{"status" => status, "reason" => "private"})}
      end

    user_text = "user metadata is not an assistant status"
    user = entry(@own, user_text)
    user = %{user | metadata: Map.put(user.metadata, "status", "cancelled")}
    append(c, assistants ++ [assistant_entry("legacy"), user])

    assert {:ok, %{entries: window}} = Persistence.read_conversation_window(c.agent, @own)
    assert Enum.map(Enum.take(window, 5), & &1.status) == statuses
    assert Enum.map(window, & &1.content) == statuses ++ ["legacy", user_text]

    for row <- Enum.take(window, 5) do
      assert Enum.sort(Map.keys(row)) ==
               [:content, :entry_ordinal, :id, :role, :status, :timestamp]

      refute Map.has_key?(row, :metadata)
      refute Map.has_key?(row, :reason)
    end

    for row <- Enum.drop(window, 5) do
      refute Map.has_key?(row, :status)
    end

    assert {:ok, %{entries: legacy}} = Persistence.read_conversation_page(c.agent, @own)
    assert legacy == Enum.map(window, &Map.delete(&1, :status))
  end

  test "security regression unknown explicit assistant status rejects the entire window", c do
    append(c, [assistant_entry("partial")])
    query = from(e in SessionEntry, where: e.session_id == ^c.session.id)

    for status <- ["future", "", nil, 123, %{"status" => "cancelled"}] do
      Repo.update_all(query, set: [metadata: %{"engagement_id" => @own, "status" => status}])

      assert {:error, :invalid_transcript} =
               Persistence.read_conversation_window(c.agent, @own)

      assert {:ok, %{entries: [legacy]}} = Persistence.read_conversation_page(c.agent, @own)
      assert legacy.content == "partial"
      refute Map.has_key?(legacy, :status)
    end
  end

  test "exclusive older and newer selectors preserve ascending order and ordinal gaps", c do
    append(c, [
      entry(@own, "one"),
      entry(@other, "gap"),
      entry(@own, "three"),
      entry(@own, "four"),
      entry(@own, "five")
    ])

    assert {:ok, %{first: 1, last: 3, has_older: false, has_newer: true, entries: older}} =
             Persistence.read_conversation_window(c.agent, @own, before: 4, limit: 2)

    assert Enum.map(older, & &1.entry_ordinal) == [1, 3]

    assert {:ok, %{first: 4, last: 5, has_older: true, has_newer: false, entries: newer}} =
             Persistence.read_conversation_window(c.agent, @own, after: 3, limit: 2)

    assert Enum.map(newer, & &1.entry_ordinal) == [4, 5]
  end

  test "pinned window head excludes concurrent appends and does not assume contiguous ordinals",
       c do
    append(c, [entry(@own, "one"), entry(@other, "gap"), entry(@own, "three")])
    assert {:ok, initial} = Persistence.read_conversation_window(c.agent, @own, limit: 1)
    append(c, [entry(@own, "four")])

    assert {:ok, %{head: 3, entries: [%{content: "three"}], has_newer: false}} =
             Persistence.read_conversation_window(c.agent, @own, through: initial.head, limit: 1)

    assert {:ok, %{head: 4, entries: [%{content: "four"}]}} =
             Persistence.read_conversation_window(c.agent, @own, after: initial.last, limit: 1)

    assert {:ok, %{head: 2, entries: [%{content: "one"}]}} =
             Persistence.read_conversation_window(c.agent, @own, through: 2)
  end

  test "empty directional windows report navigation relative to their exclusive anchor", c do
    append(c, [entry(@own, "one"), entry(@own, "two")])

    assert {:ok, %{entries: [], first: 0, last: 0, has_older: false, has_newer: true}} =
             Persistence.read_conversation_window(c.agent, @own, before: 1)

    assert {:ok, %{entries: [], first: 0, last: 0, has_older: true, has_newer: false}} =
             Persistence.read_conversation_window(c.agent, @own, after: 2)

    assert {:ok, %{entries: [], head: 0, has_older: false, has_newer: false}} =
             Persistence.read_conversation_window(c.agent <> "_absent", @own)
  end

  test "security regression rejects malformed bounds and routing overrides before storage", c do
    previous = Repo.put_dynamic_repo(:unavailable_window_repo)

    try do
      for opts <- [
            nil,
            %{},
            [limit: 0],
            [limit: 101],
            [limit: 1, limit: 2],
            [before: 0],
            [after: -1],
            [before: 1, after: 0],
            [before: nil],
            [after: nil],
            [through: nil],
            [before: 3, through: 2],
            [after: 3, through: 2],
            [engagement_id: @other],
            [principal_id: "foreign"],
            [persistence: Repo],
            [after: 9_223_372_036_854_775_808]
          ] do
        assert {:error, :invalid_options} =
                 Persistence.read_conversation_window(c.agent, @own, opts)
      end

      assert {:error, :conversation_unavailable} =
               Persistence.read_conversation_window(c.agent, @own)
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  test "security regression rejects foreign session ownership and corrupt ordinals", c do
    append(c, [entry(@own, "private")])
    query = from(e in SessionEntry, where: e.session_id == ^c.session.id)
    Repo.update_all(query, set: [entry_ordinal: 0])
    assert {:error, :invalid_transcript} = Persistence.read_conversation_window(c.agent, @own)
    Repo.update_all(query, set: [entry_ordinal: 1])
    Repo.update_all(from(s in Session, where: s.id == ^c.session.id), set: [agent_id: "foreign"])

    assert {:error, :conversation_unavailable} =
             Persistence.read_conversation_window(c.agent, @own)
  end

  test "window rejects ahead-of-head cursors and does not truncate oversized text", c do
    append(c, [entry(@own, String.duplicate("x", 262_145))])
    assert {:error, :page_too_large} = Persistence.read_conversation_window(c.agent, @own)

    for opts <- [[before: 2], [after: 2], [through: 2]] do
      assert {:error, :invalid_cursor} = Persistence.read_conversation_window(c.agent, @own, opts)
    end
  end

  defp append(c, rows),
    do: assert({:ok, length(rows)} == Persistence.append_session_entries(c.session.id, rows))

  defp assistant_entry(text),
    do: %{entry(@own, text) | entry_type: "assistant", role: "assistant"}

  defp entry(engagement, text),
    do: %{
      entry_type: "user",
      role: "user",
      content: [%{"type" => "text", "text" => text}],
      timestamp: ~U[2026-10-02 00:00:00Z],
      metadata: %{"engagement_id" => engagement, "private" => "hidden"}
    }
end
