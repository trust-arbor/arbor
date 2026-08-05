defmodule Arbor.Orchestrator.Session.PersistenceFreshSessionTest do
  @moduledoc """
  **Security/data-loss regression guard.**

  Asserts that `Persistence.build_persist_fn_from_store/1` creates a
  SessionStore session row when none exists for the given session_id,
  rather than returning `nil` and silently dropping every entry.

  This was the failure mode of commit 6087feaf
  ("fix(session): remove duplicate turn persistence path"): the legacy
  `maybe_persist_turn` had a `create_session` fallback for fresh agents,
  and removing it left only the modern `persist_turn_entries` path —
  which only LOOKED UP existing sessions, never created them. Result:
  every fresh agent dropped its first turn (and every subsequent turn,
  because the session row was never created), and restored chat history
  was empty after server restart.

  Fixed by adding `ensure_session_uuid/2` to `build_persist_fn_from_store`.
  Do NOT delete this test as "redundant" — it is the canary that catches
  the next refactor silently re-removing the create-if-not-exists step.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Session.AssistantMessage
  alias Arbor.Orchestrator.Session.Persistence

  defmodule FakePersistence do
    @moduledoc """
    In-memory stand-in for the public `Arbor.Persistence` session API. Tracks calls
    in an Agent so the test can assert exactly which functions were
    invoked and with what arguments. The interface mirrors the subset of
    facade that `Persistence` actually uses.
    """

    use Agent

    def start_link(opts \\ []) do
      existing = Keyword.get(opts, :existing_sessions, %{})

      initial = %{
        sessions_by_session_id: existing,
        appended_entries: [],
        calls: []
      }

      Agent.start_link(fn -> initial end, name: __MODULE__)
    end

    def stop do
      if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
    catch
      :exit, _ -> :ok
    end

    # ---- Public facade-shaped API ------------------------------------------

    def ensure_session(session_id, agent_id, []) do
      record_call({:ensure_session, session_id, agent_id})

      Agent.get_and_update(__MODULE__, fn state ->
        case Map.get(state.sessions_by_session_id, session_id) do
          nil ->
            session = %{
              id: "uuid_for_#{session_id}",
              agent_id: agent_id,
              session_id: session_id
            }

            {{:ok, session},
             %{
               state
               | sessions_by_session_id:
                   Map.put(state.sessions_by_session_id, session_id, session)
             }}

          %{agent_id: ^agent_id} = session ->
            {{:ok, session}, state}

          _other_owner ->
            {{:error, :session_owner_mismatch}, state}
        end
      end)
    end

    def append_session_entries(uuid, entries) do
      record_call({:append_session_entries, uuid, Enum.map(entries, & &1.entry_type)})

      Agent.update(__MODULE__, fn state ->
        appended = Enum.map(entries, &{uuid, &1})
        %{state | appended_entries: Enum.reverse(appended) ++ state.appended_entries}
      end)

      {:ok, length(entries)}
    end

    # ---- Test introspection ------------------------------------------------

    def calls, do: Agent.get(__MODULE__, & &1.calls) |> Enum.reverse()
    def appended_entries, do: Agent.get(__MODULE__, & &1.appended_entries) |> Enum.reverse()
    def sessions_by_session_id, do: Agent.get(__MODULE__, & &1.sessions_by_session_id)

    defp record_call(call) do
      Agent.update(__MODULE__, fn s -> %{s | calls: [call | s.calls]} end)
    end
  end

  defp build_state(session_id, agent_id) do
    %{
      session_id: session_id,
      agent_id: agent_id,
      adapters: %{
        ensure_session: &FakePersistence.ensure_session/3,
        append_session_entries: &FakePersistence.append_session_entries/2
      },
      # ContextBuilder.get_turn_count/1 reads this; persist_turn_entries
      # references it for the assistant entry's metadata.turn_count.
      turn_count: 0,
      messages: []
    }
  end

  describe "build_persist_fn_from_store/1 (regression guard for 6087feaf)" do
    test "creates a SessionStore session row on first call when none exists" do
      {:ok, _} = FakePersistence.start_link()
      on_exit(&FakePersistence.stop/0)

      state = build_state("agent-session-fresh_agent_42", "fresh_agent_42")

      assert is_function(Persistence.build_persist_fn_from_store(state), 1),
             "build_persist_fn_from_store/1 must return a callable persist fn for a fresh agent " <>
               "(it returned nil — get_session_uuid never created the row, dropping every entry)"

      # The session row must now exist
      assert Map.has_key?(
               FakePersistence.sessions_by_session_id(),
               "agent-session-fresh_agent_42"
             )

      assert {:ensure_session, "agent-session-fresh_agent_42", "fresh_agent_42"} in FakePersistence.calls()
    end

    test "the persist function from a fresh-session call actually appends entries" do
      {:ok, _} = FakePersistence.start_link()
      on_exit(&FakePersistence.stop/0)

      state = build_state("agent-session-fresh_writer_7", "fresh_writer_7")
      persist_fn = Persistence.build_persist_fn_from_store(state)
      assert is_function(persist_fn, 1)

      assert {:ok, 1} =
               persist_fn.(%{entry_type: "user", role: "user", content: [%{"text" => "hi"}]})

      assert {:ok, 1} =
               persist_fn.(%{
                 entry_type: "assistant",
                 role: "assistant",
                 content: [%{"text" => "hello"}]
               })

      entries = FakePersistence.appended_entries()
      assert length(entries) == 2

      assert Enum.any?(entries, fn {_uuid, attrs} -> attrs[:entry_type] == "user" end)
      assert Enum.any?(entries, fn {_uuid, attrs} -> attrs[:entry_type] == "assistant" end)
    end

    test "reuses the existing session row when it already exists" do
      {:ok, _} =
        FakePersistence.start_link(
          existing_sessions: %{
            "agent-session-existing_8" => %{
              id: "uuid_pre_existing",
              agent_id: "existing_8",
              session_id: "agent-session-existing_8"
            }
          }
        )

      on_exit(&FakePersistence.stop/0)

      state = build_state("agent-session-existing_8", "existing_8")
      persist_fn = Persistence.build_persist_fn_from_store(state)
      assert is_function(persist_fn, 1)

      # The persist fn writes against the pre-existing uuid
      assert {:ok, 1} = persist_fn.(%{entry_type: "user", role: "user", content: []})

      [{uuid, _attrs}] = FakePersistence.appended_entries()
      assert uuid == "uuid_pre_existing"
    end
  end

  describe "persist_turn_entries/5 — user/assistant timestamp ordering (regression for 24246be2)" do
    # The 2026-04-07 chat-history ordering bug: SessionEntry has only a
    # `timestamp` field (no inserted_at, no sequence number) and a UUID `id`,
    # so the SessionStore query has no deterministic tiebreaker on equal
    # timestamps. The original fix bumped the assistant timestamp +1µs as a
    # workaround. After the typed UserMessage envelope shipped, that
    # workaround was removed in favor of real divergence (`user_sent_at`
    # captured at the transport boundary, `assistant_completed_at` captured
    # at turn completion).
    #
    # These tests guard against TWO failure modes:
    #   1. Someone removes the explicit timestamp opts (regression to single
    #      shared `now` for both entries)
    #   2. Someone re-introduces the +1µs workaround AND drops the explicit
    #      opts (a confusing partial revert)
    #
    # If either happens, these tests fail loudly.

    test "user_sent_at is used for the user entry timestamp" do
      {:ok, _} =
        FakePersistence.start_link(
          existing_sessions: %{
            "agent-session-ordering_a" => %{
              id: "uuid_a",
              agent_id: "ordering_a",
              session_id: "agent-session-ordering_a"
            }
          }
        )

      on_exit(&FakePersistence.stop/0)

      state = build_state("agent-session-ordering_a", "ordering_a")
      sent_at = ~U[2026-04-08 15:00:00.000000Z]
      completed_at = ~U[2026-04-08 15:00:42.500000Z]

      Persistence.persist_turn_entries(
        state,
        %{"role" => "user", "content" => "hello"},
        %AssistantMessage{content: "hi there", started_at: sent_at, completed_at: completed_at},
        %{},
        user_sent_at: sent_at,
        assistant_completed_at: completed_at
      )

      # persist_turn_entries spawns a Task — give it a moment to land
      :timer.sleep(50)

      entries = FakePersistence.appended_entries()
      assert length(entries) == 2

      user_entry =
        Enum.find_value(entries, fn {_uuid, attrs} ->
          if attrs[:entry_type] == "user", do: attrs
        end)

      assistant_entry =
        Enum.find_value(entries, fn {_uuid, attrs} ->
          if attrs[:entry_type] == "assistant", do: attrs
        end)

      assert user_entry, "expected a user entry to be persisted"
      assert assistant_entry, "expected an assistant entry to be persisted"

      assert user_entry[:timestamp] == sent_at,
             "user entry must use user_sent_at, not turn-end time " <>
               "(got: #{inspect(user_entry[:timestamp])})"

      assert assistant_entry[:timestamp] == completed_at,
             "assistant entry must use assistant_completed_at " <>
               "(got: #{inspect(assistant_entry[:timestamp])})"
    end

    test "user timestamp is strictly less than assistant timestamp (real divergence, not +1µs)" do
      {:ok, _} =
        FakePersistence.start_link(
          existing_sessions: %{
            "agent-session-ordering_b" => %{
              id: "uuid_b",
              agent_id: "ordering_b",
              session_id: "agent-session-ordering_b"
            }
          }
        )

      on_exit(&FakePersistence.stop/0)

      state = build_state("agent-session-ordering_b", "ordering_b")
      sent_at = ~U[2026-04-08 15:00:00.000000Z]
      completed_at = ~U[2026-04-08 15:00:42.500000Z]

      Persistence.persist_turn_entries(
        state,
        %{"role" => "user", "content" => "test"},
        %AssistantMessage{content: "response", started_at: sent_at, completed_at: completed_at},
        %{},
        user_sent_at: sent_at,
        assistant_completed_at: completed_at
      )

      :timer.sleep(50)

      entries = FakePersistence.appended_entries()

      user_ts =
        Enum.find_value(entries, fn {_uuid, attrs} ->
          if attrs[:entry_type] == "user", do: attrs[:timestamp]
        end)

      asst_ts =
        Enum.find_value(entries, fn {_uuid, attrs} ->
          if attrs[:entry_type] == "assistant", do: attrs[:timestamp]
        end)

      assert DateTime.compare(user_ts, asst_ts) == :lt,
             "user.timestamp must be strictly less than assistant.timestamp " <>
               "(real LLM-call latency divergence, NOT a +1µs synthetic offset). " <>
               "user=#{inspect(user_ts)} assistant=#{inspect(asst_ts)}"

      # The divergence should also be MORE than 1µs (the old workaround) — if
      # it's exactly 1µs we may have regressed to the synthetic offset.
      diff_us = DateTime.diff(asst_ts, user_ts, :microsecond)

      assert diff_us > 1,
             "timestamps diverge by exactly #{diff_us}µs — this looks like the " <>
               "+1µs workaround crept back. Real LLM-call latency should be much larger."
    end

    test "missing opts fall back to DateTime.utc_now/0 for backwards compat" do
      {:ok, _} =
        FakePersistence.start_link(
          existing_sessions: %{
            "agent-session-ordering_c" => %{
              id: "uuid_c",
              agent_id: "ordering_c",
              session_id: "agent-session-ordering_c"
            }
          }
        )

      on_exit(&FakePersistence.stop/0)

      state = build_state("agent-session-ordering_c", "ordering_c")
      before = DateTime.utc_now()

      Persistence.persist_turn_entries(
        state,
        %{"role" => "user", "content" => "test"},
        %AssistantMessage{content: "reply", started_at: before},
        %{}
      )

      :timer.sleep(50)
      after_time = DateTime.utc_now()

      entries = FakePersistence.appended_entries()
      assert length(entries) == 2

      Enum.each(entries, fn {_uuid, attrs} ->
        ts = attrs[:timestamp]
        assert %DateTime{} = ts, "entry must have a DateTime timestamp"

        assert DateTime.compare(ts, before) in [:gt, :eq],
               "entry timestamp #{inspect(ts)} should be >= before=#{inspect(before)}"

        assert DateTime.compare(ts, after_time) in [:lt, :eq],
               "entry timestamp #{inspect(ts)} should be <= after=#{inspect(after_time)}"
      end)
    end
  end
end
