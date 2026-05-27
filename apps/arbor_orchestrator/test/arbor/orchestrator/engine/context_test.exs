defmodule Arbor.Orchestrator.Engine.ContextTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.Context

  describe "lineage tracking" do
    test "set/4 tracks which node set each key" do
      ctx =
        Context.new()
        |> Context.set("key1", "val1", "node_a")
        |> Context.set("key2", "val2", "node_b")

      assert Context.get(ctx, "key1") == "val1"
      assert Context.get(ctx, "key2") == "val2"
      assert Context.origin(ctx, "key1") == "node_a"
      assert Context.origin(ctx, "key2") == "node_b"
    end

    test "set/3 (without node_id) does not track lineage" do
      ctx =
        Context.new()
        |> Context.set("key1", "val1")

      assert Context.get(ctx, "key1") == "val1"
      assert Context.origin(ctx, "key1") == nil
    end

    test "set/4 overwrites previous lineage for same key" do
      ctx =
        Context.new()
        |> Context.set("key1", "val1", "node_a")
        |> Context.set("key1", "val2", "node_b")

      assert Context.get(ctx, "key1") == "val2"
      assert Context.origin(ctx, "key1") == "node_b"
    end

    test "apply_updates/3 tracks all keys in update map" do
      ctx =
        Context.new()
        |> Context.apply_updates(%{"k1" => "v1", "k2" => "v2"}, "node_x")

      assert Context.get(ctx, "k1") == "v1"
      assert Context.get(ctx, "k2") == "v2"
      assert Context.origin(ctx, "k1") == "node_x"
      assert Context.origin(ctx, "k2") == "node_x"
    end

    test "apply_updates/2 (without node_id) does not track lineage" do
      ctx =
        Context.new()
        |> Context.apply_updates(%{"k1" => "v1"})

      assert Context.get(ctx, "k1") == "v1"
      assert Context.origin(ctx, "k1") == nil
    end

    test "lineage/1 returns full lineage map with enriched entries" do
      ctx =
        Context.new()
        |> Context.set("a", 1, "n1")
        |> Context.set("b", 2, "n2")

      lineage = Context.lineage(ctx)
      # New entries are %LineageEntry{}; support both struct and legacy map shapes in tests
      a = lineage["a"]
      b = lineage["b"]
      assert a.node_id == "n1" and a.operation == :set
      assert b.node_id == "n2" and b.operation == :set
      assert %DateTime{} = Context.step_timestamp(a)
      assert %DateTime{} = Context.step_timestamp(b)
    end

    test "lineage starts empty" do
      ctx = Context.new()
      assert Context.lineage(ctx) == %{}
    end

    test "origin returns nil for untracked keys" do
      ctx = Context.new(%{"existing" => "value"})
      assert Context.origin(ctx, "existing") == nil
      assert Context.origin(ctx, "nonexistent") == nil
    end
  end

  describe "optional now timestamp injection (purity support)" do
    test "set/5 accepts explicit now and records it in lineage" do
      fixed_time = ~U[2026-05-20 12:34:56.000000Z]

      ctx =
        Context.new()
        |> Context.set("key", "value", "node_a", fixed_time)

      entry = Context.lineage_entry(ctx, "key")
      assert entry.node_id == "node_a"
      assert entry.operation == :set
      assert Context.step_timestamp(entry) == fixed_time
      # no pipeline time set on this context
      assert Context.pipeline_timestamp(entry) == nil
    end

    test "apply_updates/4 accepts explicit now and records same timestamp for all keys" do
      fixed_time = ~U[2026-05-20 12:34:57.000000Z]

      ctx =
        Context.new()
        |> Context.apply_updates(%{"k1" => 1, "k2" => 2}, "node_x", fixed_time)

      assert Context.step_timestamp(Context.lineage_entry(ctx, "k1")) == fixed_time
      assert Context.step_timestamp(Context.lineage_entry(ctx, "k2")) == fixed_time
      assert Context.lineage_entry(ctx, "k1").node_id == "node_x"
    end

    test "multiple sets with same explicit now share the timestamp (one logical step)" do
      fixed_time = ~U[2026-05-20 12:34:58.000000Z]

      ctx =
        Context.new()
        |> Context.set("current_node", "n1", "n1", fixed_time)
        |> Context.set("outcome", "success", "n1", fixed_time)

      assert Context.step_timestamp(Context.lineage_entry(ctx, "current_node")) == fixed_time
      assert Context.step_timestamp(Context.lineage_entry(ctx, "outcome")) == fixed_time
    end

    test "passing nil for now falls back to DateTime.utc_now() (backward compat)" do
      ctx = Context.new() |> Context.set("key", "v", "n1", nil)

      entry = Context.lineage_entry(ctx, "key")
      ts = Context.step_timestamp(entry)
      assert ts.__struct__ == DateTime
      # Should be very recent
      assert DateTime.diff(DateTime.utc_now(), ts, :second) < 5
    end

    test "omitting the now argument still works (default nil behavior)" do
      ctx = Context.new() |> Context.set("key", "v", "n1")

      entry = Context.lineage_entry(ctx, "key")
      assert %DateTime{} = Context.step_timestamp(entry)
    end

    test "pipeline_started_at on Context is carried into all lineage entries" do
      pipeline_start = ~U[2026-05-20 09:00:00.000000Z]
      step_time = ~U[2026-05-20 09:00:05.000000Z]

      ctx =
        Context.new(%{}, pipeline_started_at: pipeline_start)
        |> Context.set("goal", "build something", "planner", step_time)
        |> Context.apply_updates(%{"status" => "ready"}, "planner", step_time)

      entry1 = Context.lineage_entry(ctx, "goal")
      entry2 = Context.lineage_entry(ctx, "status")

      assert Context.pipeline_timestamp(entry1) == pipeline_start
      assert Context.pipeline_timestamp(entry2) == pipeline_start
      assert Context.step_timestamp(entry1) == step_time
      assert Context.pipeline_started_at(ctx) == pipeline_start
    end
  end

  describe "backward compatibility" do
    test "new/0 and new/1 still work" do
      ctx0 = Context.new()
      assert Context.snapshot(ctx0) == %{}

      ctx1 = Context.new(%{"k" => "v"})
      assert Context.snapshot(ctx1) == %{"k" => "v"}
    end

    test "set/3 and get/3 still work" do
      ctx = Context.new() |> Context.set("key", "value")
      assert Context.get(ctx, "key") == "value"
      assert Context.get(ctx, "missing", "default") == "default"
    end

    test "apply_updates/2 still works" do
      ctx = Context.new() |> Context.apply_updates(%{"a" => 1, "b" => 2})
      assert Context.get(ctx, "a") == 1
      assert Context.get(ctx, "b") == 2
    end

    test "snapshot/1 still returns only values, not lineage" do
      ctx =
        Context.new()
        |> Context.set("k", "v", "node")

      snapshot = Context.snapshot(ctx)
      assert snapshot == %{"k" => "v"}
      refute Map.has_key?(snapshot, :lineage)
    end
  end

  describe "legacy lineage shape compatibility (old checkpoints / persisted data)" do
    test "origin/2 and lineage_entry/1 tolerate old bare string lineage values" do
      # Very old format: lineage was just node_id strings
      legacy_lineage = %{"old_key" => "some_old_node"}

      ctx = %{Context.new() | lineage: legacy_lineage}

      assert Context.origin(ctx, "old_key") == "some_old_node"
      assert Context.origin(ctx, "missing") == nil
      assert Context.lineage_entry(ctx, "old_key") == "some_old_node"
    end

    test "step_timestamp/1 and pipeline_timestamp/1 handle legacy plain maps with single timestamp field" do
      # Pre-dual-clock format
      legacy_entry = %{node_id: "n42", timestamp: ~U[2026-04-01 12:00:00Z], operation: :set}
      legacy_lineage = %{"legacy" => legacy_entry}

      ctx = %{Context.new() | lineage: legacy_lineage}
      entry = Context.lineage_entry(ctx, "legacy")

      assert Context.origin(ctx, "legacy") == "n42"
      assert Context.step_timestamp(entry) == ~U[2026-04-01 12:00:00Z]
      # no pipeline time in old data
      assert Context.pipeline_timestamp(entry) == nil
    end

    test "new LineageEntry and legacy map shapes coexist and are readable via the same accessors" do
      new_entry = %Context.LineageEntry{
        node_id: "modern",
        step_timestamp: ~U[2026-05-21 10:00:00Z],
        pipeline_timestamp: ~U[2026-05-21 09:55:00Z],
        operation: :merge
      }

      legacy_entry = %{node_id: "legacy", timestamp: ~U[2026-03-01 08:00:00Z], operation: :set}

      mixed = %{"new" => new_entry, "old" => legacy_entry}
      ctx = %{Context.new() | lineage: mixed}

      assert Context.step_timestamp(Context.lineage_entry(ctx, "new")) == ~U[2026-05-21 10:00:00Z]

      assert Context.pipeline_timestamp(Context.lineage_entry(ctx, "new")) ==
               ~U[2026-05-21 09:55:00Z]

      assert Context.step_timestamp(Context.lineage_entry(ctx, "old")) == ~U[2026-03-01 08:00:00Z]
      assert Context.pipeline_timestamp(Context.lineage_entry(ctx, "old")) == nil
    end
  end
end
