defmodule Arbor.Persistence.SessionTranscriptTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias Arbor.Persistence
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.{Session, SessionEntry}
  @moduletag :database
  # Not :fast. `mix test --only fast` includes a :fast test even when
  # :isolated_repo is excluded, and this file has to start Repo itself.
  @moduletag :isolated_repo
  @engagement "eng_0123456789abcdef0123456789abcdef"
  @foreign "eng_abcdef0123456789abcdef0123456789"

  setup_all do
    assert Process.whereis(Repo) == nil, "run standalone with a private SQLite Repo"

    database =
      Path.join(System.tmp_dir!(), "transcript_#{System.unique_integer([:positive])}.sqlite3")

    start_supervised!(
      {Repo,
       database: database,
       pool: DBConnection.ConnectionPool,
       pool_size: 4,
       busy_timeout: 5_000,
       journal_mode: :wal}
    )

    Ecto.Migrator.run(Repo, Path.expand("../../../priv/repo/migrations", __DIR__), :up,
      all: true,
      log: false
    )

    on_exit(fn ->
      File.rm(database)
      File.rm(database <> "-wal")
      File.rm(database <> "-shm")
    end)

    :ok
  end

  setup do
    agent = "transcript_#{System.unique_integer([:positive])}"
    {:ok, session} = Persistence.ensure_session("agent-session-#{agent}", agent)
    %{agent: agent, session: session}
  end

  test "cognitive read retains blocks metadata and conservative provenance with stable preappend IDs",
       ctx do
    attrs = entry(@engagement, "same")

    attrs = %{
      attrs
      | content:
          attrs.content ++
            [%{"type" => "tool_use", "id" => "t", "name" => "read", "input" => %{}}]
    }

    assert {:ok, [identified]} = Persistence.identify_session_entries([attrs])
    assert {:ok, 1} = Persistence.append_session_entries(ctx.session.id, [identified])
    assert {:ok, %{entries: [row], head: 1, cursor: 1}} = read(ctx)
    assert row.id == identified.id
    assert row.content == attrs.content
    assert row.metadata == attrs.metadata
    assert row.taint_status == :legacy_unlabeled
    assert row.taint == Arbor.Contracts.Security.TaintEnvelope.missing_fallback()
  end

  test "bootstrap is recent and bounded while deltas are ordered and pinned before foreign filtering",
       ctx do
    append(ctx, [entry(@engagement, "one"), entry(@foreign, "foreign"), entry(@engagement, "two")])

    assert {:ok, %{entries: [two], head: 3, truncated: true, has_more: false}} =
             read(ctx, limit: 1)

    assert two.content == entry(@engagement, "two").content
    append(ctx, [entry(@engagement, "three")])

    assert {:ok, %{entries: [one], head: 3, cursor: 1, has_more: true}} =
             read(ctx, after: 0, through: 3, limit: 1)

    assert one.entry_ordinal == 1

    assert {:ok, %{entries: [two], head: 3, cursor: 3, has_more: false}} =
             read(ctx, after: 1, through: 3)

    assert two.entry_ordinal == 3
    assert {:ok, %{entries: [three], head: 4}} = read(ctx, after: 3)
    assert three.entry_ordinal == 4
  end

  test "security regression corrupted provenance and wrong owner fail closed", ctx do
    append(ctx, [entry(@engagement, "private")])

    Repo.update_all(from(e in SessionEntry, where: e.session_id == ^ctx.session.id),
      set: [metadata: %{"engagement_id" => @engagement, "taint" => %{"forged" => true}}]
    )

    assert {:error, :invalid_transcript} = read(ctx)

    Repo.update_all(from(s in Session, where: s.id == ^ctx.session.id),
      set: [agent_id: "foreign"]
    )

    assert {:error, :transcript_owner_mismatch} = read(ctx)
  end

  test "observed absence differs from unavailable source and backward cursor", ctx do
    assert {:ok, %{entries: [], head: 0}} = read(ctx)
    assert {:error, :transcript_cursor_invalid} = read(ctx, after: 1)
    previous = Repo.put_dynamic_repo(:unavailable_transcript_repo)

    try do
      assert {:error, :transcript_unavailable} = read(ctx)
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  test "closed read options reject duplicate and unknown keys", ctx do
    for opts <- [
          [after: 0, after: 1],
          [limit: 1_001],
          [limit: 0],
          [owner: "foreign"],
          [after: -1]
        ] do
      assert {:error, :invalid_transcript_options} = read(ctx, opts)
    end
  end

  test "consultation pairs stay durable but canonical readers exclude them before limits and heads",
       ctx do
    append(ctx, pair("user", "question", "answer"))
    append(ctx, pair("consultation", "question", "internal answer"))
    append(ctx, pair("user", "question", "final answer"))
    append(ctx, pair("consultation", "question", "later internal answer"))

    assert Repo.aggregate(from(e in SessionEntry, where: e.session_id == ^ctx.session.id), :count) ==
             8

    assert {:ok, first} = Persistence.read_conversation_page(ctx.agent, @engagement, limit: 2)
    assert Enum.map(first.entries, & &1.entry_ordinal) == [1, 2]
    assert %{head: 6, cursor: 2, has_more: true} = first

    assert {:ok, last} =
             Persistence.read_conversation_page(ctx.agent, @engagement,
               after: first.cursor,
               through: first.head,
               limit: 2
             )

    assert Enum.map(last.entries, & &1.entry_ordinal) == [5, 6]
    assert %{head: 6, cursor: 6, has_more: false} = last

    display =
      Persistence.load_recent_session_messages(ctx.session.session_id,
        engagement_id: @engagement,
        limit: 2
      )

    assert Enum.map(display, & &1.entry_ordinal) == [5, 6]
    assert Enum.map(display, & &1.content) == ["question", "final answer"]
    assert {:ok, %{entries: recent, head: 6, cursor: 6, truncated: true}} = read(ctx, limit: 2)
    assert Enum.map(recent, & &1.entry_ordinal) == [5, 6]
    assert {:ok, %{entries: [], head: 6, cursor: 6, has_more: false}} = read(ctx, after: 6)
  end

  test "private-memory recovery includes consultation roles and preserves source proof metadata",
       ctx do
    proof = %{"descriptor" => %{"source_id" => "owned-source"}, "stamp" => %{"opaque" => true}}

    consultation =
      pair("consultation", "private question", "private answer")
      |> Enum.map(&put_in(&1, [:metadata, "private_memory_source"], proof))

    append(ctx, pair("user", "visible question", "visible answer"))
    append(ctx, consultation)
    rows = Persistence.load_private_memory_source_messages(ctx.session.session_id, ctx.agent)
    assert Enum.map(rows, & &1.entry_ordinal) == [1, 2, 3, 4]
    assert Enum.map(rows, & &1.role) == [:user, :assistant, :user, :assistant]

    recent =
      Persistence.load_private_memory_source_messages(ctx.session.session_id, ctx.agent, limit: 2)

    assert Enum.map(recent, & &1.entry_ordinal) == [3, 4]
    assert Enum.map(recent, & &1.content) == ["private question", "private answer"]
    assert Enum.all?(recent, &(&1.metadata["private_memory_source"] == proof))

    assert Enum.all?(
             recent,
             &(&1.metadata["voice_parent_id"] == "voice_" <> String.duplicate("a", 32))
           )
  end

  test "security regression: private-memory recovery checks the exact session owner", ctx do
    append(ctx, pair("consultation", "private question", "private answer"))

    assert {:error, :private_memory_source_owner_mismatch} =
             Persistence.load_private_memory_source_messages(ctx.session.session_id, "foreign")

    Repo.update_all(from(s in Session, where: s.id == ^ctx.session.id),
      set: [agent_id: "foreign"]
    )

    assert {:error, :private_memory_source_owner_mismatch} =
             Persistence.load_private_memory_source_messages(ctx.session.session_id, ctx.agent)

    assert [] = Persistence.load_private_memory_source_messages("absent-owned-session", ctx.agent)
  end

  test "private-memory recovery rejects open options and distinguishes unavailable storage",
       ctx do
    for opts <- [
          [limit: 0],
          [limit: 1001],
          [limit: nil],
          [limit: 1.0],
          [limit: 1, limit: 2],
          [entry_types: ["consultation"]],
          [after: 0],
          %{},
          [{"limit", 1}]
        ] do
      assert {:error, :invalid_private_memory_source_options} =
               Persistence.load_private_memory_source_messages(
                 ctx.session.session_id,
                 ctx.agent,
                 opts
               )
    end

    for {session_id, agent_id} <- [
          {nil, ctx.agent},
          {"", ctx.agent},
          {ctx.session.session_id, " "}
        ] do
      assert {:error, :invalid_private_memory_source_scope} =
               Persistence.load_private_memory_source_messages(session_id, agent_id)
    end

    previous = Repo.put_dynamic_repo(:unavailable_private_memory_source_repo)

    try do
      assert {:error, :private_memory_source_unavailable} =
               Persistence.load_private_memory_source_messages(ctx.session.session_id, ctx.agent)
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  test "client metadata cannot hide ordinary pairs and internal-only history has an empty cursor",
       ctx do
    append(ctx, pair("consultation", "internal", "internal"))
    assert {:ok, %{entries: [], head: 0, cursor: 0}} = read(ctx)

    assert {:ok, %{entries: [], head: 0, cursor: 0}} =
             Persistence.read_conversation_page(ctx.agent, @engagement)

    ordinary =
      pair("user", "same", "same")
      |> Enum.map(fn row ->
        update_in(row, [:metadata], fn metadata ->
          Map.merge(metadata, %{"internal" => true, "entry_type" => "consultation"})
        end)
      end)

    append(ctx, ordinary)
    assert {:ok, %{entries: entries, head: 4, cursor: 4}} = read(ctx)
    assert Enum.map(entries, & &1.entry_ordinal) == [3, 4]

    assert Enum.map(entries, & &1.content) == [
             entry(@engagement, "same").content,
             entry(@engagement, "same").content
           ]
  end

  defp pair(type, user, assistant) do
    for {role, content} <- [{"user", user}, {"assistant", assistant}] do
      entry(@engagement, content)
      |> Map.put(:role, role)
      |> Map.put(:entry_type, if(type == "consultation", do: type, else: role))
      |> put_in([:metadata, "voice_parent_id"], "voice_" <> String.duplicate("a", 32))
    end
  end

  defp read(ctx, opts \\ []),
    do: Persistence.read_session_transcript(ctx.session.session_id, ctx.agent, @engagement, opts)

  defp append(ctx, entries),
    do: assert({:ok, _} = Persistence.append_session_entries(ctx.session.id, entries))

  defp entry(engagement, text) do
    %{
      entry_type: "user",
      role: "user",
      content: [%{"type" => "text", "text" => text}],
      metadata: %{"engagement_id" => engagement, "transport" => "voice"},
      timestamp: DateTime.utc_now()
    }
  end
end
