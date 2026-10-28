defmodule Arbor.Persistence.SessionStoreTest do
  @moduledoc """
  VP-04A: `Arbor.Persistence.SessionStore.ensure_session/3` (race-safe
  get-or-create with fail-closed agent_id ownership) and the `:engagement_id`
  filter on `load_recent_for_display/2` (applied before `:limit`).
  """
  use Arbor.Persistence.DatabaseCase, async: false

  import Ecto.Query

  @moduletag :database

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Persistence.SessionStore

  describe "ensure_session/3" do
    test "creates a session on first call, returns the same row on a second call" do
      session_id = "sess-#{System.unique_integer([:positive])}"

      assert {:ok, created} = SessionStore.ensure_session(session_id, "agent_a")
      assert created.session_id == session_id
      assert created.agent_id == "agent_a"

      assert {:ok, fetched} = SessionStore.ensure_session(session_id, "agent_a")
      assert fetched.id == created.id
    end

    test "fails closed when session_id already belongs to a different agent_id" do
      session_id = "sess-#{System.unique_integer([:positive])}"
      assert {:ok, _} = SessionStore.create_session("agent_a", session_id: session_id)

      assert {:error, {:agent_id_mismatch, "agent_a", "agent_b"}} =
               SessionStore.ensure_session(session_id, "agent_b")
    end

    test "converges concurrent first callers on one session" do
      session_id = "sess-#{System.unique_integer([:positive])}"

      results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn -> SessionStore.ensure_session(session_id, "agent_c") end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      assert Enum.all?(results, &match?({:ok, _}, &1))

      ids =
        results
        |> Enum.map(fn {:ok, session} -> session.id end)
        |> Enum.uniq()

      assert length(ids) == 1

      count =
        Arbor.Persistence.Repo.one(
          from(s in Arbor.Persistence.Schemas.Session,
            where: s.session_id == ^session_id,
            select: count()
          )
        )

      assert count == 1
    end
  end

  describe "load_recent_for_display/2 with :engagement_id" do
    setup do
      session_id = "sess-#{System.unique_integer([:positive])}"
      {:ok, session} = SessionStore.create_session("agent_d", session_id: session_id)

      for i <- 1..3 do
        SessionStore.append_entry(session.id, %{
          entry_type: "user",
          role: "user",
          content: [%{"type" => "text", "text" => "a#{i}"}],
          timestamp: DateTime.utc_now(),
          metadata: %{"engagement_id" => "eng_a"}
        })
      end

      for i <- 1..2 do
        SessionStore.append_entry(session.id, %{
          entry_type: "user",
          role: "user",
          content: [%{"type" => "text", "text" => "b#{i}"}],
          timestamp: DateTime.utc_now(),
          metadata: %{"engagement_id" => "eng_b"}
        })
      end

      %{session_id: session_id}
    end

    test "filters before :limit — a smaller limit still returns only the matching engagement", %{
      session_id: session_id
    } do
      results = SessionStore.load_recent_for_display(session_id, limit: 2, engagement_id: "eng_a")

      assert length(results) == 2
      assert Enum.all?(results, fn m -> m.content in ["a1", "a2", "a3"] end)
    end

    test "without :engagement_id returns entries from every engagement", %{session_id: session_id} do
      results = SessionStore.load_recent_for_display(session_id, limit: 10)

      assert length(results) == 5
    end

    # The engagement filter's SQL fragment branches on
    # Arbor.Persistence.Repo.__adapter__/0 (json_extract on SQLite3, ->>' on
    # Postgres) — a real correctness concern, not just syntax. This suite runs
    # against whichever adapter apps/arbor_persistence's config actually
    # compiled Repo with (SQLite3 by default per config/test.exs, Postgres when
    # ARBOR_DB=postgres), so the two tests above already execute the real query
    # for the ACTIVE adapter end-to-end. This assertion documents which
    # dialect that run proved, without mutating Application env to fake the
    # other one — Repo.__adapter__/0 reflects what was actually compiled, so
    # there is nothing to swap at runtime.
    test "the filter above ran against the actually-compiled adapter", %{session_id: session_id} do
      adapter = Arbor.Persistence.Repo.__adapter__()
      assert adapter in [Ecto.Adapters.SQLite3, Ecto.Adapters.Postgres]

      assert [%{content: content}] =
               SessionStore.load_recent_for_display(session_id, limit: 1, engagement_id: "eng_a")

      assert content in ["a1", "a2", "a3"]
    end
  end

  describe "session entry ordinals" do
    setup do
      session_id = "ordinal-#{System.unique_integer([:positive])}"
      {:ok, session} = SessionStore.create_session("agent-ordinal", session_id: session_id)
      %{session: session, session_id: session_id}
    end

    test "allocates contiguous ordinals in bulk input order and ignores forged ordinals", %{
      session: session
    } do
      assert {:ok, 3} =
               SessionStore.append_entries(session.id, [
                 entry_attrs("first", entry_ordinal: 99),
                 entry_attrs("second", entry_ordinal: -7),
                 entry_attrs("third", entry_ordinal: 1)
               ])

      assert [
               %{content: [%{"text" => "first"}], entry_ordinal: 1},
               %{content: [%{"text" => "second"}], entry_ordinal: 2},
               %{content: [%{"text" => "third"}], entry_ordinal: 3}
             ] =
               SessionStore.load_entries(session.id)
    end

    test "single append returns the inserted entry with its allocated ordinal", %{
      session: session
    } do
      assert {:ok, entry} = SessionStore.append_entry(session.id, entry_attrs("single"))
      assert %Arbor.Persistence.Schemas.SessionEntry{entry_ordinal: 1} = entry
    end

    test "reads use ordinal order even when timestamps disagree", %{session: session} do
      now = DateTime.utc_now()

      assert {:ok, 2} =
               SessionStore.append_entries(session.id, [
                 Map.put(entry_attrs("first"), :timestamp, DateTime.add(now, 60, :second)),
                 Map.put(entry_attrs("second"), :timestamp, DateTime.add(now, -60, :second))
               ])

      assert [
               %{content: "first", entry_ordinal: 1},
               %{content: "second", entry_ordinal: 2}
             ] = SessionStore.load_recent_for_display(session.session_id)
    end

    test "concurrent same-session appends produce unique gap-free ordinals", %{session: session} do
      tasks =
        for index <- 1..12 do
          Task.async(fn -> SessionStore.append_entry(session.id, entry_attrs("#{index}")) end)
        end

      assert Enum.all?(Enum.map(tasks, &Task.await(&1, 10_000)), &match?({:ok, _}, &1))

      ordinals =
        session.id
        |> SessionStore.load_entries()
        |> Enum.map(& &1.entry_ordinal)

      assert ordinals == Enum.to_list(1..12)
    end

    test "a malformed batch inserts no rows", %{session: session} do
      assert {:error, {:invalid_entry, 1, _reason}} =
               SessionStore.append_entries(session.id, [
                 entry_attrs("valid"),
                 %{entry_type: "not-a-valid-entry"}
               ])

      assert SessionStore.entry_count(session.id) == 0
    end
  end

  describe "durable entry provenance" do
    setup do
      session_id = "provenance-#{System.unique_integer([:positive])}"
      {:ok, session} = SessionStore.create_session("agent-provenance", session_id: session_id)
      %{session: session, session_id: session_id}
    end

    test "valid envelope is verified on public display read", %{
      session: session,
      session_id: session_id
    } do
      content = [%{"type" => "text", "text" => "labeled"}]
      assert {:ok, envelope} = TaintEnvelope.new(content, %Taint{level: :derived, source: "test"})
      assert {:ok, persisted} = TaintEnvelope.to_map(envelope)

      assert {:ok, _entry} =
               SessionStore.append_entry(
                 session.id,
                 entry_attrs("labeled", metadata: %{"taint" => persisted})
               )

      assert [%{taint_status: :verified, entry_ordinal: 1, metadata: %{"taint" => ^persisted}}] =
               SessionStore.load_recent_for_display(session_id)
    end

    test "missing envelope remains a legacy-unlabeled entry", %{
      session: session,
      session_id: session_id
    } do
      assert {:ok, _entry} = SessionStore.append_entry(session.id, entry_attrs("legacy"))

      assert [%{taint_status: :legacy_unlabeled, taint: taint}] =
               SessionStore.load_recent_for_display(session_id)

      assert taint.level == :untrusted
    end

    test "malformed, unknown-version, and mismatched envelopes are rejected", %{session: session} do
      content = [%{"type" => "text", "text" => "original"}]
      assert {:ok, envelope} = TaintEnvelope.new(content, %Taint{level: :derived, source: "test"})
      assert {:ok, valid} = TaintEnvelope.to_map(envelope)

      cases = [
        %{"taint" => %{"version" => 99}},
        %{"taint" => Map.put(valid, "version", 99)}
      ]

      for metadata <- cases do
        assert {:error, {:invalid_entry, 0, {:invalid_durable_provenance, _}}} =
                 SessionStore.append_entry(
                   session.id,
                   entry_attrs("original", metadata: metadata)
                 )
      end

      assert {:error, {:invalid_entry, 0, {:invalid_durable_provenance, :payload_mismatch}}} =
               SessionStore.append_entry(
                 session.id,
                 entry_attrs("changed", metadata: %{"taint" => valid})
               )

      assert {:error, {:invalid_entry, 0, :invalid_entry}} =
               SessionStore.append_entry(
                 session.id,
                 entry_attrs("secret-transcript", content: :malformed)
               )

      refute String.contains?(
               inspect(SessionStore.append_entry(session.id, %{entry_type: "secret-transcript"})),
               "secret-transcript"
             )

      assert SessionStore.entry_count(session.id) == 0
    end

    test "security regression: public display treats persisted provenance failures as hostile", %{
      session: session,
      session_id: session_id
    } do
      valid_content = [%{"type" => "text", "text" => "bound-to-another-row"}]

      assert {:ok, envelope} =
               TaintEnvelope.new(valid_content, %Taint{level: :derived, source: "test"})

      assert {:ok, valid} = TaintEnvelope.to_map(envelope)

      cases = [
        {"malformed", %{"taint" => %{"version" => 1}}},
        {"unknown-version", %{"taint" => Map.put(valid, "version", 99)}},
        {"payload-mismatch", %{"taint" => valid}},
        # JSON-backed metadata normalizes atom keys to strings before the read
        # boundary. This is the persisted equivalent of an atom/string taint
        # ambiguity; the writer rejects the atom form before serialization.
        {"atom-key-normalized", %{taint: %{version: 99}}},
        {"non-map-metadata", nil}
      ]

      for {label, metadata} <- cases do
        assert {:ok, entry} = SessionStore.append_entry(session.id, entry_attrs(label))

        {1, _} =
          Arbor.Persistence.Repo.update_all(
            from(e in Arbor.Persistence.Schemas.SessionEntry, where: e.id == ^entry.id),
            set: [metadata: metadata]
          )

        assert [%{taint_status: :invalid_durable_provenance, taint: taint}] =
                 SessionStore.load_recent_for_display(session_id, limit: 1)

        assert taint.level == :hostile
        assert taint.sensitivity == :restricted
      end
    end

    test "atom taint metadata is rejected instead of becoming an unlabeled entry", %{
      session: session
    } do
      assert {:error, {:invalid_entry, 0, :ambiguous_taint_metadata_key}} =
               SessionStore.append_entry(
                 session.id,
                 entry_attrs("ambiguous", metadata: %{taint: %{}})
               )

      assert SessionStore.entry_count(session.id) == 0
    end
  end

  defp entry_attrs(text, opts \\ []) do
    %{
      entry_type: "user",
      role: "user",
      content: Keyword.get(opts, :content, [%{"type" => "text", "text" => text}]),
      timestamp: DateTime.utc_now(),
      metadata: Keyword.get(opts, :metadata, %{})
    }
    |> Map.merge(Keyword.get(opts, :extra, %{}))
    |> then(fn attrs ->
      case Keyword.fetch(opts, :entry_ordinal) do
        {:ok, ordinal} -> Map.put(attrs, :entry_ordinal, ordinal)
        :error -> attrs
      end
    end)
  end
end
