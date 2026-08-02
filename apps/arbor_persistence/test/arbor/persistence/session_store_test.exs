defmodule Arbor.Persistence.SessionStoreTest do
  @moduledoc """
  VP-04A: `Arbor.Persistence.SessionStore.ensure_session/3` (race-safe
  get-or-create with fail-closed agent_id ownership) and the `:engagement_id`
  filter on `load_recent_for_display/2` (applied before `:limit`).
  """
  use Arbor.Persistence.DatabaseCase, async: false

  import Ecto.Query

  @moduletag :database

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
end
