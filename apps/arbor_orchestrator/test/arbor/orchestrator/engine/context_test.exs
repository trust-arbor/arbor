defmodule Arbor.Orchestrator.Engine.ContextTest do
  use ExUnit.Case, async: true

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

    test "lineage/1 returns full lineage map" do
      ctx =
        Context.new()
        |> Context.set("a", 1, "n1")
        |> Context.set("b", 2, "n2")

      assert Context.lineage(ctx) == %{"a" => "n1", "b" => "n2"}
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
end
