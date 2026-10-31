defmodule Arbor.Historian.StreamRegistryTest do
  use ExUnit.Case, async: true

  alias Arbor.Historian.StreamRegistry

  setup do
    {:ok, pid} =
      StreamRegistry.start_link(
        # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
        name: :"registry_#{System.unique_integer([:positive])}"
      )

    %{registry: pid}
  end

  describe "record_event/3" do
    test "records a new stream", %{registry: registry} do
      now = DateTime.utc_now()
      StreamRegistry.record_event(registry, "global", now)

      {:ok, meta} = StreamRegistry.get_stream(registry, "global")
      assert meta.event_count == 1
      assert meta.first_event_at == now
      assert meta.last_event_at == now
    end

    test "increments count on existing stream", %{registry: registry} do
      t1 = ~U[2026-01-01 00:00:00Z]
      t2 = ~U[2026-01-01 01:00:00Z]

      StreamRegistry.record_event(registry, "s1", t1)
      StreamRegistry.record_event(registry, "s1", t2)

      {:ok, meta} = StreamRegistry.get_stream(registry, "s1")
      assert meta.event_count == 2
      assert meta.first_event_at == t1
      assert meta.last_event_at == t2
    end

    test "preserves first_event_at across multiple events", %{registry: registry} do
      t1 = ~U[2026-01-01 00:00:00Z]
      t2 = ~U[2026-01-01 01:00:00Z]
      t3 = ~U[2026-01-01 02:00:00Z]

      StreamRegistry.record_event(registry, "s1", t1)
      StreamRegistry.record_event(registry, "s1", t2)
      StreamRegistry.record_event(registry, "s1", t3)

      {:ok, meta} = StreamRegistry.get_stream(registry, "s1")
      assert meta.event_count == 3
      # first_event_at is set on the first call and never changes
      assert meta.first_event_at == t1
      # last_event_at always updates to the latest
      assert meta.last_event_at == t3
    end

    test "tracks independent streams separately", %{registry: registry} do
      t1 = ~U[2026-01-10 08:00:00Z]
      t2 = ~U[2026-01-10 09:00:00Z]
      t3 = ~U[2026-01-10 10:00:00Z]

      StreamRegistry.record_event(registry, "stream_a", t1)
      StreamRegistry.record_event(registry, "stream_b", t2)
      StreamRegistry.record_event(registry, "stream_a", t3)

      {:ok, meta_a} = StreamRegistry.get_stream(registry, "stream_a")
      assert meta_a.event_count == 2
      assert meta_a.first_event_at == t1
      assert meta_a.last_event_at == t3

      {:ok, meta_b} = StreamRegistry.get_stream(registry, "stream_b")
      assert meta_b.event_count == 1
      assert meta_b.first_event_at == t2
      assert meta_b.last_event_at == t2
    end
  end

  describe "get_stream/2" do
    test "returns error for unknown stream", %{registry: registry} do
      assert {:error, :not_found} = StreamRegistry.get_stream(registry, "nonexistent")
    end

    test "returns error for never-recorded stream ID", %{registry: registry} do
      # Record a different stream, then query for one that doesn't exist
      StreamRegistry.record_event(registry, "exists", DateTime.utc_now())
      assert {:error, :not_found} = StreamRegistry.get_stream(registry, "does_not_exist")
    end

    test "returns full metadata for known stream", %{registry: registry} do
      now = ~U[2026-06-15 12:30:00Z]
      StreamRegistry.record_event(registry, "detailed", now)

      {:ok, meta} = StreamRegistry.get_stream(registry, "detailed")
      assert is_map(meta)
      assert Map.has_key?(meta, :event_count)
      assert Map.has_key?(meta, :first_event_at)
      assert Map.has_key?(meta, :last_event_at)
      assert meta.event_count == 1
      assert meta.first_event_at == now
      assert meta.last_event_at == now
    end
  end

  describe "list_streams/1" do
    test "returns all known stream IDs", %{registry: registry} do
      now = DateTime.utc_now()
      StreamRegistry.record_event(registry, "alpha", now)
      StreamRegistry.record_event(registry, "beta", now)

      streams = StreamRegistry.list_streams(registry)
      assert Enum.sort(streams) == ["alpha", "beta"]
    end

    test "returns empty for fresh registry", %{registry: registry} do
      assert StreamRegistry.list_streams(registry) == []
    end

    test "does not duplicate stream IDs for repeated events", %{registry: registry} do
      now = DateTime.utc_now()
      StreamRegistry.record_event(registry, "s1", now)
      StreamRegistry.record_event(registry, "s1", now)
      StreamRegistry.record_event(registry, "s1", now)

      streams = StreamRegistry.list_streams(registry)
      assert streams == ["s1"]
    end
  end

  describe "all_streams/1" do
    test "returns full metadata map", %{registry: registry} do
      now = DateTime.utc_now()
      StreamRegistry.record_event(registry, "s1", now)

      all = StreamRegistry.all_streams(registry)
      assert is_map(all)
      assert Map.has_key?(all, "s1")
      assert all["s1"].event_count == 1
    end

    test "returns empty map for fresh registry", %{registry: registry} do
      all = StreamRegistry.all_streams(registry)
      assert all == %{}
    end

    test "returns metadata for all tracked streams", %{registry: registry} do
      t1 = ~U[2026-01-01 00:00:00Z]
      t2 = ~U[2026-01-01 01:00:00Z]
      t3 = ~U[2026-01-01 02:00:00Z]

      StreamRegistry.record_event(registry, "global", t1)
      StreamRegistry.record_event(registry, "agent:a1", t2)
      StreamRegistry.record_event(registry, "category:security", t3)
      # Second event on global
      StreamRegistry.record_event(registry, "global", t3)

      all = StreamRegistry.all_streams(registry)
      assert map_size(all) == 3

      assert all["global"].event_count == 2
      assert all["global"].first_event_at == t1
      assert all["global"].last_event_at == t3

      assert all["agent:a1"].event_count == 1
      assert all["agent:a1"].first_event_at == t2

      assert all["category:security"].event_count == 1
      assert all["category:security"].first_event_at == t3
    end
  end

  describe "total_events/1" do
    test "returns sum of all event counts", %{registry: registry} do
      now = DateTime.utc_now()
      StreamRegistry.record_event(registry, "s1", now)
      StreamRegistry.record_event(registry, "s2", now)
      StreamRegistry.record_event(registry, "s1", now)

      assert StreamRegistry.total_events(registry) == 3
    end

    test "returns 0 for fresh registry", %{registry: registry} do
      assert StreamRegistry.total_events(registry) == 0
    end

    test "counts across many streams correctly", %{registry: registry} do
      now = DateTime.utc_now()

      # 3 events on stream_a
      for _ <- 1..3, do: StreamRegistry.record_event(registry, "stream_a", now)
      # 2 events on stream_b
      for _ <- 1..2, do: StreamRegistry.record_event(registry, "stream_b", now)
      # 5 events on stream_c
      for _ <- 1..5, do: StreamRegistry.record_event(registry, "stream_c", now)

      assert StreamRegistry.total_events(registry) == 10
    end

    test "single stream total equals stream event_count", %{registry: registry} do
      now = DateTime.utc_now()
      StreamRegistry.record_event(registry, "only_stream", now)
      StreamRegistry.record_event(registry, "only_stream", now)

      assert StreamRegistry.total_events(registry) == 2

      {:ok, meta} = StreamRegistry.get_stream(registry, "only_stream")
      assert meta.event_count == 2
    end
  end

  describe "reset/1" do
    test "clears all data", %{registry: registry} do
      StreamRegistry.record_event(registry, "s1", DateTime.utc_now())
      StreamRegistry.reset(registry)

      assert StreamRegistry.list_streams(registry) == []
      assert StreamRegistry.total_events(registry) == 0
    end

    test "allows recording events after reset", %{registry: registry} do
      now = DateTime.utc_now()
      StreamRegistry.record_event(registry, "before_reset", now)
      StreamRegistry.reset(registry)

      # After reset, old streams are gone
      assert {:error, :not_found} = StreamRegistry.get_stream(registry, "before_reset")

      # Can record new events
      StreamRegistry.record_event(registry, "after_reset", now)
      {:ok, meta} = StreamRegistry.get_stream(registry, "after_reset")
      assert meta.event_count == 1
    end
  end
end
