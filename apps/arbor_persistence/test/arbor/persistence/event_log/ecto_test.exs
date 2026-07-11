defmodule Arbor.Persistence.EventLog.EctoTest do
  @moduledoc """
  Tests for the Ecto-backed EventLog (adapter-agnostic — the module
  works against PostgreSQL or SQLite3 depending on Repo config).

  These tests target PostgreSQL specifically because they rely on the
  `Ecto.Adapters.SQL.Sandbox` pool, which is a Postgres-only feature.
  The module itself is unit-tested against SQLite indirectly via the
  `:fast` ETS+fallthrough suite.

  ## Setup Required

  These tests require a running PostgreSQL database:

      mix ecto.create -r Arbor.Persistence.Repo
      mix ecto.migrate -r Arbor.Persistence.Repo

  ## Running

      mix test --include database

  Or for just this file:

      mix test apps/arbor_persistence/test/arbor/persistence/event_log/ecto_test.exs --include database

  ## Configuration

  Required in config/test.exs:

      config :arbor_persistence, Arbor.Persistence.Repo,
        database: "arbor_test",
        username: "postgres",
        password: "postgres",
        hostname: "localhost",
        pool: Ecto.Adapters.SQL.Sandbox
  """

  use Arbor.Persistence.DatabaseCase, async: false

  import Ecto.Query

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Ecto, as: EventLog
  alias Arbor.Persistence.Repo

  @moduletag :integration
  @moduletag :database

  setup do
    # Clean up events table before each test
    Repo.delete_all(Arbor.Persistence.Schemas.Event)
    :ok
  end

  describe "append/3" do
    test "appends a single event" do
      event = Event.new("stream-1", "test.event", %{key: "value"})
      assert {:ok, [persisted]} = EventLog.append("stream-1", event, repo: Repo)

      assert persisted.stream_id == "stream-1"
      assert persisted.event_number == 1
      assert persisted.global_position == 1
      assert persisted.type == "test.event"
      assert persisted.data == %{key: "value"}
    end

    test "appends multiple events with incrementing numbers" do
      events = [
        Event.new("stream-1", "test.first", %{n: 1}),
        Event.new("stream-1", "test.second", %{n: 2}),
        Event.new("stream-1", "test.third", %{n: 3})
      ]

      assert {:ok, persisted} = EventLog.append("stream-1", events, repo: Repo)

      assert length(persisted) == 3
      assert Enum.map(persisted, & &1.event_number) == [1, 2, 3]
      assert Enum.map(persisted, & &1.global_position) == [1, 2, 3]
    end

    test "maintains separate numbering per stream" do
      events_a = [Event.new("stream-a", "test.a", %{})]
      events_b = [Event.new("stream-b", "test.b", %{})]

      {:ok, [a1]} = EventLog.append("stream-a", events_a, repo: Repo)
      {:ok, [b1]} = EventLog.append("stream-b", events_b, repo: Repo)

      {:ok, [a2]} =
        EventLog.append("stream-a", [Event.new("stream-a", "test.a2", %{})], repo: Repo)

      # Event numbers are per-stream
      assert a1.event_number == 1
      assert b1.event_number == 1
      assert a2.event_number == 2

      # Global positions are across all streams
      assert a1.global_position == 1
      assert b1.global_position == 2
      assert a2.global_position == 3
    end

    test "enforces CAS and backend-owned freshness without trusting domain timestamp" do
      future = DateTime.add(DateTime.utc_now(), 86_400, :second)
      event = Event.new("guarded", "started", %{}, timestamp: future)

      assert {:ok, [_]} = EventLog.append("guarded", event, repo: Repo, expected_version: 0)

      assert {:error, :version_conflict} =
               EventLog.append("guarded", Event.new("guarded", "duplicate", %{}),
                 repo: Repo,
                 expected_version: 0
               )

      assert {:ok, %Event{timestamp: ^future}} =
               EventLog.read_stream_head("guarded", repo: Repo)

      assert {:ok, %Event{event_number: 1}} =
               EventLog.read_stream_head("guarded", repo: Repo, max_current_age_ms: 60_000)

      terminal = Event.new("guarded", "terminal", %{}, timestamp: future)

      assert {:ok, [_]} =
               EventLog.append("guarded", terminal,
                 repo: Repo,
                 expected_version: 1,
                 max_current_age_ms: 60_000
               )

      assert {:ok, nil} =
               EventLog.read_stream_head("guarded", repo: Repo, max_current_age_ms: 0)

      assert {:error, :deadline_exceeded} =
               EventLog.append("guarded", Event.new("guarded", "expired", %{}),
                 repo: Repo,
                 expected_version: 2,
                 max_current_age_ms: 0
               )

      # Historical reads remain domain-time based and do not hide expired events.
      assert {:ok, historical} = EventLog.read_stream("guarded", repo: Repo)
      assert Enum.map(historical, & &1.timestamp) == [future, future]
    end

    test "database supplies committed_at on both supported adapters" do
      event = Event.new("commit-authority", "created", %{})
      assert {:ok, [_]} = EventLog.append("commit-authority", event, repo: Repo)

      schema = Repo.one!(Arbor.Persistence.Schemas.Event)
      assert %DateTime{} = schema.committed_at
      assert Repo.__adapter__() in [Ecto.Adapters.Postgres, Ecto.Adapters.SQLite3]
    end

    test "freshness precondition fails closed for an empty stream" do
      event = Event.new("empty", "terminal", %{})

      assert {:error, :deadline_exceeded} =
               EventLog.append("empty", event,
                 repo: Repo,
                 expected_version: 0,
                 max_current_age_ms: 60_000
               )
    end

    test "missing durable commit evidence fails freshness closed" do
      events = [
        Event.new("legacy", "created", %{}),
        Event.new("legacy", "current_head", %{})
      ]

      assert {:ok, [_, _]} = EventLog.append("legacy", events, repo: Repo)

      from(e in Arbor.Persistence.Schemas.Event,
        where: e.stream_id == "legacy" and e.event_number == 2
      )
      |> Repo.update_all(set: [committed_at: nil])

      assert {:ok, nil} =
               EventLog.read_stream_head("legacy", repo: Repo, max_current_age_ms: 60_000)

      assert {:error, :deadline_exceeded} =
               EventLog.append("legacy", Event.new("legacy", "terminal", %{}),
                 repo: Repo,
                 expected_version: 2,
                 max_current_age_ms: 60_000
               )

      assert {:ok, [%Event{}, %Event{}]} = EventLog.read_stream("legacy", repo: Repo)
    end

    test "same exact append reconciles idempotently and changed content conflicts" do
      event = Event.new("idempotent", "created", %{value: 1})
      assert {:ok, [first]} = EventLog.append("idempotent", event, repo: Repo)
      assert {:ok, operation} = Arbor.Persistence.EventLog.build_operation("idempotent", [event])

      assert {:ok, {:committed, [reconciled]}} =
               EventLog.reconcile_append(operation, repo: Repo)

      assert reconciled.id == first.id
      assert {:ok, [retried]} = EventLog.append("idempotent", event, repo: Repo)
      assert retried.id == first.id
      assert retried.global_position == first.global_position

      changed = %Event{event | data: %{value: 2}}

      assert {:error, :event_identity_conflict} =
               EventLog.append("idempotent", changed, repo: Repo)

      assert {:ok, 1} = EventLog.stream_version("idempotent", repo: Repo)
    end

    test "stream and global position exhaustion are controlled before encoding" do
      insert_positioned_event!("stream-full", 2_147_483_647, 1)

      assert {:error, :stream_position_exhausted} =
               EventLog.append(
                 "stream-full",
                 Event.new("stream-full", "must-not-encode", %{}),
                 repo: Repo
               )

      Repo.delete_all(Arbor.Persistence.Schemas.Event)
      insert_positioned_event!("global-seed", 1, 9_223_372_036_854_775_807)

      assert {:error, :global_position_exhausted} =
               EventLog.append(
                 "global-full",
                 Event.new("global-full", "must-not-encode", %{}),
                 repo: Repo
               )
    end
  end

  describe "read_stream/2" do
    test "reads all events from a stream" do
      events = [
        Event.new("stream-1", "test.1", %{n: 1}),
        Event.new("stream-1", "test.2", %{n: 2}),
        Event.new("stream-1", "test.3", %{n: 3})
      ]

      {:ok, _} = EventLog.append("stream-1", events, repo: Repo)

      assert {:ok, read} = EventLog.read_stream("stream-1", repo: Repo)
      assert length(read) == 3
      assert Enum.map(read, & &1.type) == ["test.1", "test.2", "test.3"]
    end

    test "reads from a specific event number" do
      events = [
        Event.new("stream-1", "test.1", %{}),
        Event.new("stream-1", "test.2", %{}),
        Event.new("stream-1", "test.3", %{})
      ]

      {:ok, _} = EventLog.append("stream-1", events, repo: Repo)

      assert {:ok, read} = EventLog.read_stream("stream-1", repo: Repo, from: 2)
      assert length(read) == 2
      assert Enum.map(read, & &1.event_number) == [2, 3]
    end

    test "limits results" do
      events = for i <- 1..10, do: Event.new("stream-1", "test.#{i}", %{})
      {:ok, _} = EventLog.append("stream-1", events, repo: Repo)

      assert {:ok, read} = EventLog.read_stream("stream-1", repo: Repo, limit: 3)
      assert length(read) == 3
    end

    test "reads backward" do
      events = [
        Event.new("stream-1", "test.1", %{}),
        Event.new("stream-1", "test.2", %{}),
        Event.new("stream-1", "test.3", %{})
      ]

      {:ok, _} = EventLog.append("stream-1", events, repo: Repo)

      assert {:ok, read} = EventLog.read_stream("stream-1", repo: Repo, direction: :backward)
      assert Enum.map(read, & &1.event_number) == [3, 2, 1]
    end

    test "returns empty for nonexistent stream" do
      assert {:ok, []} = EventLog.read_stream("nonexistent", repo: Repo)
    end
  end

  describe "read_all/1" do
    test "reads all events in global order" do
      {:ok, _} = EventLog.append("stream-a", [Event.new("stream-a", "a.1", %{})], repo: Repo)
      {:ok, _} = EventLog.append("stream-b", [Event.new("stream-b", "b.1", %{})], repo: Repo)
      {:ok, _} = EventLog.append("stream-a", [Event.new("stream-a", "a.2", %{})], repo: Repo)

      assert {:ok, all} = EventLog.read_all(repo: Repo)
      assert length(all) == 3
      assert Enum.map(all, & &1.type) == ["a.1", "b.1", "a.2"]
    end

    test "reads from a global position" do
      {:ok, _} = EventLog.append("stream-a", [Event.new("stream-a", "a.1", %{})], repo: Repo)
      {:ok, _} = EventLog.append("stream-b", [Event.new("stream-b", "b.1", %{})], repo: Repo)
      {:ok, _} = EventLog.append("stream-a", [Event.new("stream-a", "a.2", %{})], repo: Repo)

      assert {:ok, all} = EventLog.read_all(repo: Repo, from: 2)
      assert length(all) == 2
      assert Enum.map(all, & &1.type) == ["b.1", "a.2"]
    end
  end

  describe "stream_exists?/2" do
    test "returns false for nonexistent stream" do
      refute EventLog.stream_exists?("nonexistent", repo: Repo)
    end

    test "returns true for existing stream" do
      {:ok, _} = EventLog.append("stream-1", [Event.new("stream-1", "test", %{})], repo: Repo)
      assert EventLog.stream_exists?("stream-1", repo: Repo)
    end
  end

  describe "stream_version/2" do
    test "returns 0 for nonexistent stream" do
      assert {:ok, 0} = EventLog.stream_version("nonexistent", repo: Repo)
    end

    test "returns current version" do
      {:ok, _} = EventLog.append("stream-1", [Event.new("stream-1", "test", %{})], repo: Repo)
      {:ok, _} = EventLog.append("stream-1", [Event.new("stream-1", "test", %{})], repo: Repo)

      assert {:ok, 2} = EventLog.stream_version("stream-1", repo: Repo)
    end
  end

  describe "list_streams/1" do
    test "returns empty list when no streams exist" do
      assert {:ok, []} = EventLog.list_streams(repo: Repo)
    end

    test "returns all stream IDs" do
      {:ok, _} = EventLog.append("stream-a", [Event.new("stream-a", "test", %{})], repo: Repo)
      {:ok, _} = EventLog.append("stream-b", [Event.new("stream-b", "test", %{})], repo: Repo)
      {:ok, _} = EventLog.append("stream-c", [Event.new("stream-c", "test", %{})], repo: Repo)

      assert {:ok, streams} = EventLog.list_streams(repo: Repo)
      assert Enum.sort(streams) == ["stream-a", "stream-b", "stream-c"]
    end
  end

  describe "stream_count/1" do
    test "returns 0 when no streams exist" do
      assert {:ok, 0} = EventLog.stream_count(repo: Repo)
    end

    test "returns correct count of distinct streams" do
      {:ok, _} = EventLog.append("stream-a", [Event.new("stream-a", "test", %{})], repo: Repo)
      {:ok, _} = EventLog.append("stream-b", [Event.new("stream-b", "test", %{})], repo: Repo)
      {:ok, _} = EventLog.append("stream-a", [Event.new("stream-a", "test2", %{})], repo: Repo)

      assert {:ok, 2} = EventLog.stream_count(repo: Repo)
    end
  end

  describe "event_count/1" do
    test "returns 0 when no events exist" do
      assert {:ok, 0} = EventLog.event_count(repo: Repo)
    end

    test "returns total events across all streams" do
      {:ok, _} = EventLog.append("stream-a", [Event.new("stream-a", "t", %{})], repo: Repo)

      {:ok, _} =
        EventLog.append(
          "stream-b",
          [Event.new("stream-b", "t", %{}), Event.new("stream-b", "t", %{})],
          repo: Repo
        )

      assert {:ok, 3} = EventLog.event_count(repo: Repo)
    end
  end

  defp insert_positioned_event!(stream_id, event_number, global_position) do
    event =
      Event.new(stream_id, "seed", %{},
        event_number: event_number,
        global_position: global_position
      )

    %Arbor.Persistence.Schemas.Event{}
    |> Arbor.Persistence.Schemas.Event.changeset(
      Arbor.Persistence.Schemas.Event.from_event(event)
    )
    |> Repo.insert!()
  end
end
