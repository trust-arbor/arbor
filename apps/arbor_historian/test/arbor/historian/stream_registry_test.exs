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
  end

  describe "get_stream/2" do
    test "returns error for unknown stream", %{registry: registry} do
      assert {:error, :not_found} = StreamRegistry.get_stream(registry, "nonexistent")
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
  end

  describe "reset/1" do
    test "clears all data", %{registry: registry} do
      StreamRegistry.record_event(registry, "s1", DateTime.utc_now())
      StreamRegistry.reset(registry)

      assert StreamRegistry.list_streams(registry) == []
      assert StreamRegistry.total_events(registry) == 0
    end
  end
end
