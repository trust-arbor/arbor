defmodule Arbor.Memory.MutationAdmissionCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.MutationAdmissionCore, as: Core

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1A"

  @h1 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @h2 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  @h3 "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  @rt "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  @node "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  @foreign "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

  describe "new/1" do
    @tag packet: "VP-05D2C3I1A"
    test "bootstraps open empty state from nil" do
      assert {:ok, state} = Core.new(nil)
      assert state.gate == :open
      assert state.gate_gen == 1
      assert state.roots == %{}
      assert state.fence_gen == 0
      assert state.fence_hash == nil
    end

    @tag packet: "VP-05D2C3I1A"
    test "new(nil, bounds) normalizes and rejects invalid bounds" do
      assert {:ok, _} = Core.new(nil, %{})
      assert {:ok, _} = Core.new(nil, %{max_active_roots: 8, max_record_encoded_bytes: 1024})
      assert {:error, :invalid_request} = Core.new(nil, %{max_active_roots: 0})
      assert {:error, :invalid_request} = Core.new(nil, %{max_active_roots: 9999})
      assert {:error, :invalid_request} = Core.new(nil, %{max_record_encoded_bytes: 0})
      assert {:error, :invalid_request} = Core.new(nil, %{max_record_encoded_bytes: -1})
      assert {:error, :invalid_request} = Core.new(nil, :not_a_map)
      assert {:error, :invalid_request} = Core.new(nil, %{max_active_roots: "x"})
    end

    @tag packet: "VP-05D2C3I1A"
    test "rejects malformed and non-map data" do
      assert {:error, :invalid_request} = Core.new(%{"v" => 2})
      assert {:error, :invalid_request} = Core.new(%{"v" => 1, "gate" => "nope"})
      assert {:error, :invalid_request} = Core.new(%{v: 1})
      assert {:error, :invalid_request} = Core.new("x")
      assert {:error, :invalid_request} = Core.new(%{"v" => 1, "extra" => true})
    end

    @tag packet: "VP-05D2C3I1A"
    test "rejects oversized root sets" do
      huge_roots =
        for i <- 1..300, into: %{} do
          h = Base.encode16(:crypto.hash(:sha256, Integer.to_string(i)), case: :lower)

          {h,
           %{
             "lineage_hash" => h,
             "node_fp" => @node,
             "runtime_fp" => @rt
           }}
        end

      data = %{
        "v" => 1,
        "gate" => "open",
        "gate_gen" => 1,
        "roots" => huge_roots,
        "fence_gen" => 0,
        "fence_hash" => nil
      }

      assert {:error, :invalid_request} = Core.new(data)
    end

    @tag packet: "VP-05D2C3I1A"
    test "round-trips valid data via to_data" do
      assert {:ok, s0} = Core.new(nil)
      assert {:ok, s1} = Core.acquire_new(s0, @h1, @h1, @node, @rt)
      data = Core.to_data(s1)
      assert {:ok, s2} = Core.new(data)
      assert s2.gate == :open
      assert Map.has_key?(s2.roots, @h1)
    end
  end

  describe "acquire / drain ordering" do
    @tag packet: "VP-05D2C3I1A"
    test "open acquisition and capacity" do
      assert {:ok, s} = Core.new(nil)
      assert {:ok, s} = Core.acquire_new(s, @h1, @h1, @node, @rt)

      assert {:error, :capacity_exceeded} =
               Core.acquire_new(s, @h2, @h2, @node, @rt, %{max_active_roots: 1})
    end

    @tag packet: "VP-05D2C3I1A"
    test "acquire versus drain: draining rejects new lineage, allows reenter" do
      assert {:ok, s} = Core.new(nil)
      assert {:ok, s} = Core.acquire_new(s, @h1, @h1, @node, @rt)
      assert {:ok, s} = Core.begin_drain(s)
      assert s.gate == :draining
      assert s.gate_gen == 2
      assert Map.has_key?(s.roots, @h1)
      assert {:error, :draining} = Core.acquire_new(s, @h2, @h2, @node, @rt)
      assert :ok = Core.assert_reenterable(s, @h1)
    end

    @tag packet: "VP-05D2C3I1A"
    test "destroyed rejects acquire and reenter" do
      assert {:ok, s} = Core.new(nil)
      assert {:ok, s} = Core.begin_drain(s)
      assert {:ok, s, %{fence_gen: 1}} = Core.issue_fence(s, @h2)
      assert {:ok, s, :committed} = Core.mark_destroyed(s, @h2, 1)
      assert s.gate == :destroyed
      assert {:error, :destroyed} = Core.acquire_new(s, @h1, @h1, @node, @rt)
      assert {:error, :destroyed} = Core.assert_reenterable(s, @h1)
    end
  end

  describe "handoff release fence destroy" do
    @tag packet: "VP-05D2C3I1A"
    test "handoff refreshes fps without second root" do
      assert {:ok, s} = Core.new(nil)
      assert {:ok, s} = Core.acquire_new(s, @h1, @h1, @node, @rt)
      assert {:ok, s} = Core.handoff_root(s, @h1, @node, @h3)
      assert map_size(s.roots) == 1
      assert s.roots[@h1].runtime_fp == @h3
    end

    @tag packet: "VP-05D2C3I1A"
    test "outermost release removes root" do
      assert {:ok, s} = Core.new(nil)
      assert {:ok, s} = Core.acquire_new(s, @h1, @h1, @node, @rt)
      assert {:ok, s} = Core.release_root(s, @h1)
      assert s.roots == %{}
      assert {:error, :stale_lease} = Core.release_root(s, @h1)
    end

    @tag packet: "VP-05D2C3I1A"
    test "zero-root fence issuance, rotate, stale fence, terminal destroy" do
      assert {:ok, s} = Core.new(nil)
      assert {:ok, s} = Core.begin_drain(s)
      assert {:ok, s, %{fence_gen: 1}} = Core.issue_fence(s, @h1)
      assert {:ok, s, %{fence_gen: 2}} = Core.issue_fence(s, @h2)
      assert s.fence_hash == @h2
      assert {:error, :stale_fence} = Core.mark_destroyed(s, @h1, 1)
      assert {:ok, s, :committed} = Core.mark_destroyed(s, @h2, 2)
      assert s.gate == :destroyed
      assert {:ok, ^s, :idempotent} = Core.mark_destroyed(s, @h2, 2)
      assert {:error, :stale_fence} = Core.mark_destroyed(s, @h1, 1)
    end

    @tag packet: "VP-05D2C3I1A"
    test "forbidden transitions" do
      assert {:ok, s} = Core.new(nil)
      assert {:error, :not_drained} = Core.issue_fence(s, @h1)
      assert {:error, :not_drained} = Core.mark_destroyed(s, @h1, 1)
      assert {:ok, s} = Core.acquire_new(s, @h1, @h1, @node, @rt)
      assert {:ok, s} = Core.begin_drain(s)
      assert {:error, :not_drained} = Core.issue_fence(s, @h2)
      assert {:ok, s} = Core.release_root(s, @h1)
      assert {:ok, s, _} = Core.issue_fence(s, @h2)
      assert {:ok, s, :committed} = Core.mark_destroyed(s, @h2, 1)
      assert {:error, :destroyed} = Core.begin_drain(s)
    end
  end

  describe "reconcile" do
    @tag packet: "VP-05D2C3I1A"
    test "releases only concrete prior-local roots; keeps ambiguous/foreign/current" do
      assert {:ok, s} = Core.new(nil)

      assert {:ok, s} = Core.acquire_new(s, @h1, @h1, @node, @rt)
      # prior runtime same node
      s = put_in(s.roots[@h1].runtime_fp, @h2)

      assert {:ok, s} = Core.acquire_new(s, @h3, @h3, "ambiguous", @rt)
      foreign_hash = Base.encode16(:crypto.hash(:sha256, "foreign"), case: :lower)
      assert {:ok, s} = Core.acquire_new(s, foreign_hash, foreign_hash, @foreign, @h2)

      current_rt = @rt
      assert {:ok, s2} = Core.reconcile(s, @node, current_rt)
      # prior-local @h1 dropped
      refute Map.has_key?(s2.roots, @h1)
      # ambiguous kept
      assert Map.has_key?(s2.roots, @h3)
      # foreign kept
      assert Map.has_key?(s2.roots, foreign_hash)
    end
  end

  describe "purity" do
    @tag packet: "VP-05D2C3I1A"
    test "core source has no impurity" do
      path =
        Path.expand(
          "../../../lib/arbor/memory/mutation_admission_core.ex",
          __DIR__
        )

      src = File.read!(path)

      forbidden =
        ~r/DateTime\.utc_now|System\.(monotonic|os|system)_time|:rand\.|:erlang\.unique_integer|make_ref|Application\.get_env|GenServer\.|Repo\.|:ets\.|Logger\.|Persistence\./

      refute Regex.match?(forbidden, src)
    end
  end

  describe "status_view" do
    @tag packet: "VP-05D2C3I1A"
    test "exposes only redacted counts" do
      assert {:ok, s} = Core.new(nil)
      assert {:ok, s} = Core.acquire_new(s, @h1, @h1, @node, @rt)
      view = Core.status_view(s)
      assert view == %{gate: :open, gate_generation: 1, active_roots: 1}
      refute Map.has_key?(view, :roots)
    end
  end

  describe "semantic cross-field invariants" do
    @tag packet: "VP-05D2C3I1A"
    test "open cannot carry a fence" do
      data = %{
        "v" => 1,
        "gate" => "open",
        "gate_gen" => 1,
        "roots" => %{},
        "fence_gen" => 1,
        "fence_hash" => @h1
      }

      assert {:error, :invalid_request} = Core.new(data)
    end

    @tag packet: "VP-05D2C3I1A"
    test "destroyed requires zero roots and a current fence" do
      data = %{
        "v" => 1,
        "gate" => "destroyed",
        "gate_gen" => 2,
        "roots" => %{
          @h1 => %{"lineage_hash" => @h1, "node_fp" => @node, "runtime_fp" => @rt}
        },
        "fence_gen" => 1,
        "fence_hash" => @h2
      }

      assert {:error, :invalid_request} = Core.new(data)

      data2 = %{
        "v" => 1,
        "gate" => "destroyed",
        "gate_gen" => 2,
        "roots" => %{},
        "fence_gen" => 0,
        "fence_hash" => nil
      }

      assert {:error, :invalid_request} = Core.new(data2)
    end

    @tag packet: "VP-05D2C3I1A"
    test "draining fence implies zero roots" do
      data = %{
        "v" => 1,
        "gate" => "draining",
        "gate_gen" => 2,
        "roots" => %{
          @h1 => %{"lineage_hash" => @h1, "node_fp" => @node, "runtime_fp" => @rt}
        },
        "fence_gen" => 1,
        "fence_hash" => @h2
      }

      assert {:error, :invalid_request} = Core.new(data)
    end

    @tag packet: "VP-05D2C3I1A"
    test "lineage_hash must equal lease key" do
      data = %{
        "v" => 1,
        "gate" => "open",
        "gate_gen" => 1,
        "roots" => %{
          @h1 => %{"lineage_hash" => @h2, "node_fp" => @node, "runtime_fp" => @rt}
        },
        "fence_gen" => 0,
        "fence_hash" => nil
      }

      assert {:error, :invalid_request} = Core.new(data)
      assert {:ok, s0} = Core.new(nil)
      assert {:error, :invalid_request} = Core.acquire_new(s0, @h1, @h2, @node, @rt)
    end

    @tag packet: "VP-05D2C3I1A"
    test "idempotent destroyed replay rechecks zero roots" do
      assert {:ok, s} = Core.new(nil)
      assert {:ok, s} = Core.begin_drain(s)
      assert {:ok, s, %{fence_gen: 1}} = Core.issue_fence(s, @h2)
      assert {:ok, s, :committed} = Core.mark_destroyed(s, @h2, 1)
      assert {:ok, ^s, :idempotent} = Core.mark_destroyed(s, @h2, 1)

      # Corrupted in-memory destroyed+roots must not idempotent-succeed
      corrupted = %{s | roots: %{@h1 => %{lineage_hash: @h1, node_fp: @node, runtime_fp: @rt}}}
      assert {:error, :invalid_request} = Core.mark_destroyed(corrupted, @h2, 1)

      bad = Core.to_data(s)

      bad =
        Map.put(bad, "roots", %{
          @h1 => %{"lineage_hash" => @h1, "node_fp" => @node, "runtime_fp" => @rt}
        })

      assert {:error, :invalid_request} = Core.new(bad)
    end

    @tag packet: "VP-05D2C3I1A"
    test "enforces max_active_roots bound on decode" do
      roots =
        for i <- 1..2, into: %{} do
          h = Base.encode16(:crypto.hash(:sha256, "r#{i}"), case: :lower)
          {h, %{"lineage_hash" => h, "node_fp" => @node, "runtime_fp" => @rt}}
        end

      data = %{
        "v" => 1,
        "gate" => "open",
        "gate_gen" => 1,
        "roots" => roots,
        "fence_gen" => 0,
        "fence_hash" => nil
      }

      assert {:error, :invalid_request} = Core.new(data, %{max_active_roots: 1})
    end
  end
end
