defmodule Arbor.PersistenceSessionFacadeTest do
  @moduledoc """
  VP-04A: `Arbor.Persistence.ensure_session/3`, `append_session_entries/2`, and
  `load_recent_session_messages/2` — thin delegation to
  `Arbor.Persistence.SessionStore`, plus the closed-allowlist opts validation
  each one performs before delegating.
  """
  use Arbor.Persistence.DatabaseCase, async: false

  @moduletag :database

  describe "ensure_session/3" do
    test "delegates to SessionStore and returns the same shape" do
      session_id = "sess-#{System.unique_integer([:positive])}"

      assert {:ok, session} = Arbor.Persistence.ensure_session(session_id, "agent_a")
      assert session.session_id == session_id
      assert session.agent_id == "agent_a"

      assert {:ok, ^session} = Arbor.Persistence.ensure_session(session_id, "agent_a")
    end

    test "rejects an unknown opts key without touching SessionStore" do
      session_id = "sess-#{System.unique_integer([:positive])}"

      assert {:error, {:invalid_opts, {:unknown_keys, [:bogus]}}} =
               Arbor.Persistence.ensure_session(session_id, "agent_a", bogus: true)

      assert {:error, :not_found} = Arbor.Persistence.SessionStore.get_session(session_id)
    end

    test "rejects a duplicate opts key" do
      session_id = "sess-#{System.unique_integer([:positive])}"

      assert {:error, {:invalid_opts, :duplicate_keys}} =
               Arbor.Persistence.ensure_session(session_id, "agent_a", [
                 {:model, "a"},
                 {:model, "b"}
               ])
    end

    test "rejects a non-keyword opts value" do
      session_id = "sess-#{System.unique_integer([:positive])}"

      assert {:error, {:invalid_opts, :not_a_keyword_list}} =
               Arbor.Persistence.ensure_session(session_id, "agent_a", %{model: "a"})
    end
  end

  describe "append_session_entries/2" do
    test "delegates to SessionStore.append_entries/2 (atomic bulk insert)" do
      session_id = "sess-#{System.unique_integer([:positive])}"
      {:ok, session} = Arbor.Persistence.ensure_session(session_id, "agent_a")

      entries = [
        %{
          entry_type: "user",
          role: "user",
          content: [],
          timestamp: DateTime.utc_now(),
          metadata: %{}
        },
        %{
          entry_type: "assistant",
          role: "assistant",
          content: [],
          timestamp: DateTime.utc_now(),
          metadata: %{}
        }
      ]

      assert {:ok, 2} = Arbor.Persistence.append_session_entries(session.id, entries)
    end
  end

  describe "load_recent_session_messages/2" do
    test "delegates to SessionStore.load_recent_for_display/2, honoring :engagement_id" do
      session_id = "sess-#{System.unique_integer([:positive])}"
      {:ok, session} = Arbor.Persistence.ensure_session(session_id, "agent_a")

      Arbor.Persistence.SessionStore.append_entry(session.id, %{
        entry_type: "user",
        role: "user",
        content: [%{"type" => "text", "text" => "hi"}],
        timestamp: DateTime.utc_now(),
        metadata: %{"engagement_id" => "eng_1"}
      })

      assert [%{content: "hi"}] =
               Arbor.Persistence.load_recent_session_messages(session_id, engagement_id: "eng_1")

      assert [] =
               Arbor.Persistence.load_recent_session_messages(session_id,
                 engagement_id: "eng_other"
               )
    end

    test "rejects an unknown opts key without touching SessionStore" do
      session_id = "sess-#{System.unique_integer([:positive])}"

      assert {:error, {:invalid_opts, {:unknown_keys, [:persistence]}}} =
               Arbor.Persistence.load_recent_session_messages(session_id, persistence: :fake)
    end

    test "rejects a duplicate opts key" do
      session_id = "sess-#{System.unique_integer([:positive])}"

      assert {:error, {:invalid_opts, :duplicate_keys}} =
               Arbor.Persistence.load_recent_session_messages(session_id, [
                 {:limit, 1},
                 {:limit, 2}
               ])
    end

    test "rejects a non-keyword opts value" do
      session_id = "sess-#{System.unique_integer([:positive])}"

      assert {:error, {:invalid_opts, :not_a_keyword_list}} =
               Arbor.Persistence.load_recent_session_messages(session_id, %{limit: 1})
    end

    test "rejects a non-positive, non-integer, or over-cap :limit value" do
      session_id = "sess-#{System.unique_integer([:positive])}"

      for bad_limit <- [0, -1, 1.5, "10", 1001] do
        assert {:error, {:invalid_opt_value, :limit, ^bad_limit}} =
                 Arbor.Persistence.load_recent_session_messages(session_id, limit: bad_limit)
      end

      assert {:ok, _session} = Arbor.Persistence.ensure_session(session_id, "agent_a")
      assert [] = Arbor.Persistence.load_recent_session_messages(session_id, limit: 1000)
    end

    test "rejects a :before_timestamp that isn't a DateTime or nil" do
      session_id = "sess-#{System.unique_integer([:positive])}"

      assert {:error, {:invalid_opt_value, :before_timestamp, "not-a-datetime"}} =
               Arbor.Persistence.load_recent_session_messages(session_id,
                 before_timestamp: "not-a-datetime"
               )
    end

    test "rejects a blank, non-UTF8, or oversized :engagement_id value" do
      session_id = "sess-#{System.unique_integer([:positive])}"

      assert {:error, {:invalid_opt_value, :engagement_id, :blank}} =
               Arbor.Persistence.load_recent_session_messages(session_id, engagement_id: "   ")

      assert {:error, {:invalid_opt_value, :engagement_id, :not_utf8}} =
               Arbor.Persistence.load_recent_session_messages(session_id,
                 engagement_id: <<0xFF, 0xFE>>
               )

      assert {:error, {:invalid_opt_value, :engagement_id, :too_large}} =
               Arbor.Persistence.load_recent_session_messages(session_id,
                 engagement_id: String.duplicate("a", 257)
               )

      assert {:error, {:invalid_opt_value, :engagement_id, 123}} =
               Arbor.Persistence.load_recent_session_messages(session_id, engagement_id: 123)
    end
  end
end
