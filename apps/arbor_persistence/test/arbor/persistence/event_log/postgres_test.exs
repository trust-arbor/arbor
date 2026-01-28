defmodule Arbor.Persistence.EventLog.PostgresTest do
  @moduledoc """
  Tests for the PostgreSQL EventLog backend.

  ## Setup Required

  These tests require a running PostgreSQL database:

      mix ecto.create -r Arbor.Persistence.Repo
      mix ecto.migrate -r Arbor.Persistence.Repo

  ## Running

      mix test --include database

  Or for just this file:

      mix test apps/arbor_persistence/test/arbor/persistence/event_log/postgres_test.exs --include database

  ## Configuration

  Required in config/test.exs:

      config :arbor_persistence, Arbor.Persistence.Repo,
        database: "arbor_test",
        username: "postgres",
        password: "postgres",
        hostname: "localhost",
        pool: Ecto.Adapters.SQL.Sandbox
  """

  use ExUnit.Case, async: false

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Postgres, as: EventLog
  alias Arbor.Persistence.Repo

  @moduletag :integration
  @moduletag :database

  setup_all do
    # Start the Repo if not already started
    case Repo.start_link() do
      {:ok, pid} -> {:ok, repo_pid: pid}
      {:error, {:already_started, pid}} -> {:ok, repo_pid: pid}
      {:error, reason} -> {:skip, "Database not available: #{inspect(reason)}"}
    end
  end

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
      {:ok, [a2]} = EventLog.append("stream-a", [Event.new("stream-a", "test.a2", %{})], repo: Repo)

      # Event numbers are per-stream
      assert a1.event_number == 1
      assert b1.event_number == 1
      assert a2.event_number == 2

      # Global positions are across all streams
      assert a1.global_position == 1
      assert b1.global_position == 2
      assert a2.global_position == 3
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
      {:ok, _} = EventLog.append("stream-b", [Event.new("stream-b", "t", %{}), Event.new("stream-b", "t", %{})], repo: Repo)

      assert {:ok, 3} = EventLog.event_count(repo: Repo)
    end
  end
end
