defmodule Arbor.Comms.EngagementTranscriptTest do
  @moduledoc """
  VP-04A: `Arbor.Comms.resolve_user_engagement/3`, `record_engagement_turn/5`,
  and `load_engagement_transcript/3` — the canonical public path a transport
  (dashboard, voice) uses to resolve a private user-scoped engagement and
  atomically append/load its transcript, without importing
  `Arbor.Comms.EngagementStore` or `Arbor.Persistence.SessionStore`.

  Fully hermetic: `opts[:engagement_store]` and `opts[:persistence]` inject
  Agent-backed fakes, so no database and no shared application state is
  touched.
  """
  use ExUnit.Case, async: true

  alias Arbor.Comms

  defmodule FakeEngagementStore do
    @moduledoc false
    def start_link, do: Agent.start_link(fn -> [] end)

    def calls(agent), do: Agent.get(agent, & &1)

    def resolve_or_create(agent, agent_id, resolution_key, opts) do
      Agent.update(agent, fn calls -> calls ++ [{agent_id, resolution_key, opts}] end)
      {:ok, %Arbor.Contracts.Comms.Engagement{agent_id: agent_id, id: "eng_fixed"}}
    end
  end

  defmodule FakePersistence do
    @moduledoc false
    def start_link(opts \\ []), do: Agent.start_link(fn -> %{opts: opts, appended: []} end)

    def calls(agent), do: Agent.get(agent, & &1)

    def ensure_session(agent, session_id, agent_id, opts) do
      Agent.update(agent, &Map.put(&1, :ensure_session, {session_id, agent_id, opts}))

      case Agent.get(agent, & &1[:opts][:ensure_session_result]) do
        nil -> {:ok, %{id: "session-uuid-1"}}
        result -> result
      end
    end

    def append_session_entries(agent, session_uuid, entries) do
      Agent.update(agent, fn state ->
        Map.update!(state, :appended, &(&1 ++ [{session_uuid, entries}]))
      end)

      case Agent.get(agent, & &1[:opts][:append_result]) do
        nil -> {:ok, length(entries)}
        result -> result
      end
    end

    def load_recent_session_messages(agent, session_id, opts) do
      Agent.update(agent, &Map.put(&1, :load, {session_id, opts}))
      Agent.get(agent, & &1[:opts][:load_result]) || []
    end
  end

  # Thin wrappers so the fakes can be passed as opts[:engagement_store] /
  # opts[:persistence] modules (Comms calls `store.resolve_or_create/3`,
  # `persistence.ensure_session/3`, etc. — arity matching the real facades).
  defmodule EngagementStoreAdapter do
    @moduledoc false
    def start(target), do: Process.put({__MODULE__, self()}, target)

    def resolve_or_create(agent_id, resolution_key, opts) do
      target = Process.get({__MODULE__, self()})
      FakeEngagementStore.resolve_or_create(target, agent_id, resolution_key, opts)
    end
  end

  defmodule PersistenceAdapter do
    @moduledoc false
    def start(target), do: Process.put({__MODULE__, self()}, target)

    def ensure_session(session_id, agent_id, opts) do
      target = Process.get({__MODULE__, self()})
      FakePersistence.ensure_session(target, session_id, agent_id, opts)
    end

    def append_session_entries(session_uuid, entries) do
      target = Process.get({__MODULE__, self()})
      FakePersistence.append_session_entries(target, session_uuid, entries)
    end

    def load_recent_session_messages(session_id, opts) do
      target = Process.get({__MODULE__, self()})
      FakePersistence.load_recent_session_messages(target, session_id, opts)
    end
  end

  setup do
    {:ok, store_agent} = FakeEngagementStore.start_link()
    EngagementStoreAdapter.start(store_agent)

    {:ok, persistence_agent} = FakePersistence.start_link()
    PersistenceAdapter.start(persistence_agent)

    %{store_agent: store_agent, persistence_agent: persistence_agent}
  end

  describe "resolve_user_engagement/3" do
    @tag spec: "VOICE-2"
    test "always forces scope: :user, visibility: :private, owner_tenant: user_id regardless of caller opts",
         %{store_agent: store_agent} do
      assert {:ok, engagement} =
               Comms.resolve_user_engagement("agent_1", "user_1",
                 engagement_store: EngagementStoreAdapter
               )

      assert engagement.id == "eng_fixed"

      assert [{"agent_1", "user_1", forced_opts}] = FakeEngagementStore.calls(store_agent)
      assert Keyword.get(forced_opts, :scope) == :user
      assert Keyword.get(forced_opts, :visibility) == :private
      assert Keyword.get(forced_opts, :owner_tenant) == "user_1"
    end

    test "rejects a blank agent_id/user_id without calling the store", %{store_agent: store_agent} do
      assert {:error, {:invalid_id, :agent_id, :blank}} =
               Comms.resolve_user_engagement("  ", "user_1",
                 engagement_store: EngagementStoreAdapter
               )

      assert {:error, {:invalid_id, :user_id, :blank}} =
               Comms.resolve_user_engagement("agent_1", "",
                 engagement_store: EngagementStoreAdapter
               )

      assert FakeEngagementStore.calls(store_agent) == []
    end

    test "rejects an id exceeding the byte bound without calling the store", %{
      store_agent: store_agent
    } do
      too_long = String.duplicate("a", 257)

      assert {:error, {:invalid_id, :agent_id, :too_large}} =
               Comms.resolve_user_engagement(too_long, "user_1",
                 engagement_store: EngagementStoreAdapter
               )

      assert FakeEngagementStore.calls(store_agent) == []
    end

    test "rejects an unknown opts key, a duplicate key, and a non-keyword-list opts value" do
      assert {:error, {:invalid_opts, {:unknown_keys, [:bogus]}}} =
               Comms.resolve_user_engagement("agent_1", "user_1", bogus: true)

      assert {:error, {:invalid_opts, :duplicate_keys}} =
               Comms.resolve_user_engagement("agent_1", "user_1", [
                 {:engagement_store, EngagementStoreAdapter},
                 {:engagement_store, EngagementStoreAdapter}
               ])

      assert {:error, {:invalid_opts, :not_a_keyword_list}} =
               Comms.resolve_user_engagement("agent_1", "user_1", %{
                 engagement_store: EngagementStoreAdapter
               })
    end
  end

  describe "record_engagement_turn/5" do
    setup do
      user_entry = %{content: "hello there", sent_at: ~U[2026-01-01 00:00:00.000000Z]}
      assistant_entry = %{content: "hi yourself", completed_at: ~U[2026-01-01 00:00:01.000000Z]}
      %{user_entry: user_entry, assistant_entry: assistant_entry}
    end

    @tag spec: "VOICE-3"
    test "appends exactly two ordered entries stamped with metadata[\"engagement_id\"] in the text-block shape",
         %{
           user_entry: user_entry,
           assistant_entry: assistant_entry,
           persistence_agent: persistence_agent
         } do
      assert {:ok, 2} =
               Comms.record_engagement_turn("agent_1", "eng_1", user_entry, assistant_entry,
                 persistence: PersistenceAdapter
               )

      %{appended: [{"session-uuid-1", [user_attrs, assistant_attrs]}]} =
        FakePersistence.calls(persistence_agent)

      assert user_attrs.entry_type == "user"
      assert user_attrs.role == "user"
      assert user_attrs.content == [%{"type" => "text", "text" => "hello there"}]
      assert user_attrs.metadata["engagement_id"] == "eng_1"

      assert assistant_attrs.entry_type == "assistant"
      assert assistant_attrs.role == "assistant"
      assert assistant_attrs.content == [%{"type" => "text", "text" => "hi yourself"}]
      assert assistant_attrs.metadata["engagement_id"] == "eng_1"
    end

    test "preserves the caller's sent_at/completed_at and derives utterance_end_at from sent_at",
         %{
           user_entry: user_entry,
           assistant_entry: assistant_entry,
           persistence_agent: persistence_agent
         } do
      assert {:ok, 2} =
               Comms.record_engagement_turn("agent_1", "eng_1", user_entry, assistant_entry,
                 persistence: PersistenceAdapter
               )

      %{appended: [{_uuid, [user_attrs, assistant_attrs]}]} =
        FakePersistence.calls(persistence_agent)

      assert user_attrs.timestamp == user_entry.sent_at
      assert assistant_attrs.timestamp == assistant_entry.completed_at
      assert user_attrs.metadata["utterance_end_at"] == DateTime.to_iso8601(user_entry.sent_at)
    end

    test "drops non-allowlisted metadata and cannot have engagement_id or utterance_end_at overridden",
         %{
           user_entry: user_entry,
           assistant_entry: assistant_entry,
           persistence_agent: persistence_agent
         } do
      poisoned_user =
        Map.put(user_entry, :metadata, %{
          engagement_id: "spoofed",
          utterance_end_at: "spoofed",
          transport: "voice",
          unexpected: "x"
        })

      assert {:ok, 2} =
               Comms.record_engagement_turn("agent_1", "eng_1", poisoned_user, assistant_entry,
                 persistence: PersistenceAdapter
               )

      %{appended: [{_uuid, [user_attrs, _assistant_attrs]}]} =
        FakePersistence.calls(persistence_agent)

      assert user_attrs.metadata == %{
               "engagement_id" => "eng_1",
               "transport" => "voice",
               "utterance_end_at" => DateTime.to_iso8601(user_entry.sent_at)
             }
    end

    @tag spec: "VOICE-10"
    test "assistant-only delegation keys persist; user-supplied delegation keys are dropped",
         %{
           user_entry: user_entry,
           assistant_entry: assistant_entry,
           persistence_agent: persistence_agent
         } do
      user_with_spoof =
        Map.put(user_entry, :metadata, %{
          "transport" => "voice",
          "delegation_provider" => "openai",
          "delegation_task" => "spoofed",
          "delegation_task_id" => "spoof_id",
          "delegation_outcome" => "dispatched"
        })

      assistant_with_receipt =
        Map.put(assistant_entry, :metadata, %{
          "transport" => "voice",
          "backend" => "xai_realtime",
          "mode" => "conversation",
          "delegation_provider" => "grok",
          "delegation_task" => "fix the bug",
          "delegation_task_id" => "task_abc_1",
          "delegation_outcome" => "dispatched"
        })

      assert {:ok, 2} =
               Comms.record_engagement_turn(
                 "agent_1",
                 "eng_1",
                 user_with_spoof,
                 assistant_with_receipt,
                 persistence: PersistenceAdapter
               )

      %{appended: [{_uuid, [user_attrs, assistant_attrs]}]} =
        FakePersistence.calls(persistence_agent)

      refute Map.has_key?(user_attrs.metadata, "delegation_provider")
      refute Map.has_key?(user_attrs.metadata, "delegation_task")
      refute Map.has_key?(user_attrs.metadata, "delegation_task_id")
      refute Map.has_key?(user_attrs.metadata, "delegation_outcome")
      assert user_attrs.metadata["engagement_id"] == "eng_1"
      assert user_attrs.metadata["transport"] == "voice"

      assert assistant_attrs.metadata["delegation_provider"] == "grok"
      assert assistant_attrs.metadata["delegation_task"] == "fix the bug"
      assert assistant_attrs.metadata["delegation_task_id"] == "task_abc_1"
      assert assistant_attrs.metadata["delegation_outcome"] == "dispatched"
      assert assistant_attrs.metadata["engagement_id"] == "eng_1"
    end

    @tag spec: "VOICE-10"
    test "maximal valid assistant receipt metadata passes; malformed delegation fields fail before persistence",
         %{
           user_entry: user_entry,
           assistant_entry: assistant_entry,
           persistence_agent: persistence_agent
         } do
      # Exact smallest measured whole-map ceiling for the maximal valid receipt
      # on the pinned OTP/Elixir runtime (matches Arbor.Comms constant).
      assistant_metadata_max_bytes = 4537

      max_meta = %{
        "transport" => "voice",
        "backend" => String.duplicate("b", 1024),
        "mode" => String.duplicate("m", 1024),
        "delegation_provider" => "grok",
        "delegation_task" => String.duplicate("t", 2048),
        "delegation_task_id" => String.duplicate("a", 256),
        "delegation_outcome" => "dispatched"
      }

      assert byte_size(:erlang.term_to_binary(max_meta)) == assistant_metadata_max_bytes

      assert {:ok, 2} =
               Comms.record_engagement_turn(
                 "agent_1",
                 "eng_1",
                 user_entry,
                 Map.put(assistant_entry, :metadata, max_meta),
                 persistence: PersistenceAdapter
               )

      for bad_meta <- [
            Map.put(max_meta, "delegation_provider", "openai"),
            Map.put(max_meta, "delegation_outcome", "completed"),
            Map.put(max_meta, "delegation_task", ""),
            Map.put(max_meta, "delegation_task", String.duplicate("x", 2049)),
            Map.put(max_meta, "delegation_task", "control\nbearing"),
            Map.put(max_meta, "delegation_task", "null\x00byte"),
            Map.put(max_meta, "delegation_task_id", ""),
            Map.put(max_meta, "delegation_task_id", String.duplicate("a", 257)),
            Map.put(max_meta, "delegation_task_id", "bad id with spaces"),
            Map.put(max_meta, "delegation_task_id", "bad/slash"),
            Map.put(max_meta, "delegation_task", %{nested: true}),
            Map.put(max_meta, "backend", String.duplicate("x", 1025))
          ] do
        assert {:error, {:invalid_assistant_entry, :invalid_metadata_value}} =
                 Comms.record_engagement_turn(
                   "agent_1",
                   "eng_1",
                   user_entry,
                   Map.put(assistant_entry, :metadata, bad_meta),
                   persistence: PersistenceAdapter
                 )
      end

      # Exact +1-byte over-bound: keep every other admitted field unchanged and
      # only grow transport from "voice" (5) to "voice!" (6). Encoded size must
      # be exactly 4538 and reject before persistence.
      oversize_meta = Map.put(max_meta, "transport", "voice!")
      assert byte_size(:erlang.term_to_binary(oversize_meta)) == assistant_metadata_max_bytes + 1
      assert byte_size(:erlang.term_to_binary(oversize_meta)) == 4538

      assert {:error, {:invalid_assistant_entry, :metadata_too_large}} =
               Comms.record_engagement_turn(
                 "agent_1",
                 "eng_1",
                 user_entry,
                 Map.put(assistant_entry, :metadata, oversize_meta),
                 persistence: PersistenceAdapter
               )

      # Only the successful maximal append (malformed/oversize never persisted).
      assert length(FakePersistence.calls(persistence_agent).appended) == 1
    end

    test "rejects an id/content exceeding the byte bound, blank/non-UTF8, out-of-order timestamps, bad metadata — no persistence call",
         %{
           user_entry: user_entry,
           assistant_entry: assistant_entry,
           persistence_agent: persistence_agent
         } do
      too_long_content = String.duplicate("a", 8193)

      assert {:error, {:invalid_id, :agent_id, :too_large}} =
               Comms.record_engagement_turn(
                 String.duplicate("a", 257),
                 "eng_1",
                 user_entry,
                 assistant_entry,
                 persistence: PersistenceAdapter
               )

      assert {:error, {:invalid_user_entry, {:invalid_content, :content, :too_large}}} =
               Comms.record_engagement_turn(
                 "agent_1",
                 "eng_1",
                 %{user_entry | content: too_long_content},
                 assistant_entry,
                 persistence: PersistenceAdapter
               )

      assert {:error, {:invalid_user_entry, {:invalid_content, :content, :blank}}} =
               Comms.record_engagement_turn(
                 "agent_1",
                 "eng_1",
                 %{user_entry | content: "   "},
                 assistant_entry,
                 persistence: PersistenceAdapter
               )

      out_of_order_assistant = %{assistant_entry | completed_at: ~U[2025-01-01 00:00:00.000000Z]}

      assert {:error, :timestamps_out_of_order} =
               Comms.record_engagement_turn(
                 "agent_1",
                 "eng_1",
                 user_entry,
                 out_of_order_assistant,
                 persistence: PersistenceAdapter
               )

      bad_metadata_user = Map.put(user_entry, :metadata, %{transport: %{nested: true}})

      assert {:error, {:invalid_user_entry, :invalid_metadata_value}} =
               Comms.record_engagement_turn(
                 "agent_1",
                 "eng_1",
                 bad_metadata_user,
                 assistant_entry,
                 persistence: PersistenceAdapter
               )

      oversized_value_user =
        Map.put(user_entry, :metadata, %{transport: String.duplicate("x", 4096)})

      assert {:error, {:invalid_user_entry, :invalid_metadata_value}} =
               Comms.record_engagement_turn(
                 "agent_1",
                 "eng_1",
                 oversized_value_user,
                 assistant_entry,
                 persistence: PersistenceAdapter
               )

      oversized_map_user =
        Map.put(user_entry, :metadata, %{
          transport: String.duplicate("x", 800),
          backend: String.duplicate("y", 800),
          mode: String.duplicate("z", 800)
        })

      assert {:error, {:invalid_user_entry, :metadata_too_large}} =
               Comms.record_engagement_turn(
                 "agent_1",
                 "eng_1",
                 oversized_map_user,
                 assistant_entry,
                 persistence: PersistenceAdapter
               )

      assert FakePersistence.calls(persistence_agent).appended == []
    end

    test "rejects a non-map user_entry or assistant_entry with a typed error instead of raising",
         %{
           user_entry: user_entry,
           assistant_entry: assistant_entry,
           persistence_agent: persistence_agent
         } do
      for bogus <- [nil, "a string", [content: "hi"], 123] do
        assert {:error, {:invalid_user_entry, :not_a_map}} =
                 Comms.record_engagement_turn("agent_1", "eng_1", bogus, assistant_entry,
                   persistence: PersistenceAdapter
                 )

        assert {:error, {:invalid_assistant_entry, :not_a_map}} =
                 Comms.record_engagement_turn("agent_1", "eng_1", user_entry, bogus,
                   persistence: PersistenceAdapter
                 )
      end

      assert FakePersistence.calls(persistence_agent).appended == []
    end

    test "propagates a failed append instead of reporting success", %{
      user_entry: user_entry,
      assistant_entry: assistant_entry
    } do
      {:ok, persistence_agent} =
        FakePersistence.start_link(append_result: {:error, :boom})

      PersistenceAdapter.start(persistence_agent)

      assert {:error, :boom} =
               Comms.record_engagement_turn("agent_1", "eng_1", user_entry, assistant_entry,
                 persistence: PersistenceAdapter
               )
    end

    test "propagates an ensure_session failure without appending", %{
      user_entry: user_entry,
      assistant_entry: assistant_entry
    } do
      {:ok, persistence_agent} =
        FakePersistence.start_link(ensure_session_result: {:error, :session_unavailable})

      PersistenceAdapter.start(persistence_agent)

      assert {:error, :session_unavailable} =
               Comms.record_engagement_turn("agent_1", "eng_1", user_entry, assistant_entry,
                 persistence: PersistenceAdapter
               )

      assert FakePersistence.calls(persistence_agent).appended == []
    end

    test "rejects an unknown opts key, a duplicate key, and a non-keyword-list opts value before touching any seam",
         %{
           user_entry: user_entry,
           assistant_entry: assistant_entry,
           persistence_agent: persistence_agent
         } do
      assert {:error, {:invalid_opts, {:unknown_keys, [:bogus]}}} =
               Comms.record_engagement_turn("agent_1", "eng_1", user_entry, assistant_entry,
                 bogus: true
               )

      assert {:error, {:invalid_opts, :duplicate_keys}} =
               Comms.record_engagement_turn("agent_1", "eng_1", user_entry, assistant_entry, [
                 {:persistence, PersistenceAdapter},
                 {:persistence, PersistenceAdapter}
               ])

      assert {:error, {:invalid_opts, :not_a_keyword_list}} =
               Comms.record_engagement_turn("agent_1", "eng_1", user_entry, assistant_entry, %{
                 persistence: PersistenceAdapter
               })

      assert FakePersistence.calls(persistence_agent).appended == []
    end
  end

  describe "load_engagement_transcript/3" do
    test "forwards only :limit/:before_timestamp plus the forced :engagement_id", %{
      persistence_agent: persistence_agent
    } do
      before_ts = ~U[2026-01-01 00:00:00.000000Z]

      assert [] =
               Comms.load_engagement_transcript("agent_1", "eng_1",
                 persistence: PersistenceAdapter,
                 limit: 5,
                 before_timestamp: before_ts
               )

      assert %{load: {"agent-session-agent_1", forwarded_opts}} =
               FakePersistence.calls(persistence_agent)

      assert Enum.sort(forwarded_opts) ==
               Enum.sort(limit: 5, before_timestamp: before_ts, engagement_id: "eng_1")
    end

    test "returns the fake's result unchanged on the valid path" do
      {:ok, persistence_agent} =
        FakePersistence.start_link(load_result: [%{id: "e1", role: :user, content: "hi"}])

      PersistenceAdapter.start(persistence_agent)

      assert [%{id: "e1", role: :user, content: "hi"}] =
               Comms.load_engagement_transcript("agent_1", "eng_1",
                 persistence: PersistenceAdapter
               )
    end

    test "returns an explicit error for a blank/oversized id — not []" do
      assert {:error, {:invalid_id, :agent_id, :blank}} =
               Comms.load_engagement_transcript("", "eng_1", persistence: PersistenceAdapter)

      assert {:error, {:invalid_id, :engagement_id, :too_large}} =
               Comms.load_engagement_transcript("agent_1", String.duplicate("a", 257),
                 persistence: PersistenceAdapter
               )
    end

    test "rejects an unknown opts key, a duplicate key, and a non-keyword-list opts value" do
      assert {:error, {:invalid_opts, {:unknown_keys, [:bogus]}}} =
               Comms.load_engagement_transcript("agent_1", "eng_1", bogus: true)

      assert {:error, {:invalid_opts, :duplicate_keys}} =
               Comms.load_engagement_transcript("agent_1", "eng_1", [{:limit, 1}, {:limit, 2}])

      assert {:error, {:invalid_opts, :not_a_keyword_list}} =
               Comms.load_engagement_transcript("agent_1", "eng_1", %{limit: 1})
    end
  end
end
