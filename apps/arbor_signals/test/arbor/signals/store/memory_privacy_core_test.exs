defmodule Arbor.Signals.Store.MemoryPrivacyCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0C4B"

  alias Arbor.Signals.Signal
  alias Arbor.Signals.Store.MemoryPrivacyCore

  @target "agent_core_target"
  @other "agent_core_other"

  describe "validate_agent_id/1" do
    test "accepts bounded nonempty utf-8 binary" do
      assert {:ok, "agent_1"} = MemoryPrivacyCore.validate_agent_id("agent_1")
    end

    test "rejects empty, non-binary, and oversized ids" do
      assert {:error, :invalid_agent_id} = MemoryPrivacyCore.validate_agent_id("")
      assert {:error, :invalid_agent_id} = MemoryPrivacyCore.validate_agent_id(123)
      assert {:error, :invalid_agent_id} = MemoryPrivacyCore.validate_agent_id(String.duplicate("a", 256))
    end
  end

  describe "validate_timeout_ms/1" do
    test "defaults and bounds" do
      assert {:ok, 5_000} = MemoryPrivacyCore.validate_timeout_ms([])
      assert {:ok, 1} = MemoryPrivacyCore.validate_timeout_ms(timeout_ms: 1)
      assert {:ok, 60_000} = MemoryPrivacyCore.validate_timeout_ms(timeout_ms: 60_000)
      assert {:error, :invalid_precondition} = MemoryPrivacyCore.validate_timeout_ms(timeout_ms: 0)
      assert {:error, :invalid_precondition} = MemoryPrivacyCore.validate_timeout_ms(timeout_ms: 60_001)
    end

    test "rejects non-keyword lists without raising" do
      assert {:error, :invalid_precondition} =
               MemoryPrivacyCore.validate_timeout_ms([{"timeout_ms", 1_000}])

      assert {:error, :invalid_precondition} =
               MemoryPrivacyCore.validate_timeout_ms([:timeout_ms, 1_000])

      assert {:error, :invalid_precondition} = MemoryPrivacyCore.validate_timeout_ms(%{})
      assert {:error, :invalid_precondition} = MemoryPrivacyCore.validate_timeout_ms(nil)
    end
  end

  describe "validate_live_state/1" do
    test "requires queue order and owner keys without raising" do
      s = memory(@other, :ok)
      stats = %{total_stored: 1, total_expired: 0, total_evicted: 0}

      good = %{
        signals: %{s.id => s},
        order: :queue.from_list([s.id]),
        stats: stats
      }

      assert :ok = MemoryPrivacyCore.validate_live_state(good)

      assert {:error, :invalid_precondition} =
               MemoryPrivacyCore.validate_live_state(%{
                 signals: %{s.id => s},
                 order: [s.id],
                 stats: stats
               })

      assert {:error, :invalid_precondition} =
               MemoryPrivacyCore.validate_live_state(%{
                 signals: %{s.id => s},
                 order: :not_a_queue,
                 stats: stats
               })

      assert {:error, :invalid_precondition} =
               MemoryPrivacyCore.validate_live_state(%{signals: %{}, stats: stats})

      assert {:error, :invalid_precondition} = MemoryPrivacyCore.validate_live_state(%{})
      assert {:error, :invalid_precondition} = MemoryPrivacyCore.validate_live_state(nil)
    end
  end

  describe "classify_signal/2 and select_target_ids/2" do
    test "exact target, prefix survivor, non-memory survivor" do
      target = memory(@target, :t)
      prefix = memory(@target <> "_x", :p)
      activity = Signal.new(:activity, :a, %{agent_id: @target})

      assert :target = MemoryPrivacyCore.classify_signal(target, @target)
      assert :survivor = MemoryPrivacyCore.classify_signal(prefix, @target)
      assert :non_memory = MemoryPrivacyCore.classify_signal(activity, @target)

      signals = %{target.id => target, prefix.id => prefix, activity.id => activity}
      assert {:ok, ids} = MemoryPrivacyCore.select_target_ids(signals, @target)
      assert ids == [target.id] or ids == [target.id]
      assert target.id in ids
      refute prefix.id in ids
    end

    test "ambiguous memory rows fail closed" do
      missing = %{memory(@other, :m) | data: %{note: "x"}}
      string_key = %{memory(@other, :m2) | data: %{"agent_id" => @target}}
      non_binary = %{memory(@other, :m3) | data: %{agent_id: :atom}}

      assert :ambiguous = MemoryPrivacyCore.classify_signal(missing, @target)
      assert :ambiguous = MemoryPrivacyCore.classify_signal(string_key, @target)
      assert :ambiguous = MemoryPrivacyCore.classify_signal(non_binary, @target)

      for signal <- [missing, string_key, non_binary] do
        assert {:error, :invalid_precondition} =
                 MemoryPrivacyCore.select_target_ids(%{signal.id => signal}, @target)
      end
    end
  end

  describe "store shape and drop_targets/2" do
    test "bijection requires map key == signal.id and unique order coverage" do
      s = memory(@other, :ok)
      stats = %{total_stored: 1, total_expired: 0, total_evicted: 0}

      assert :ok =
               MemoryPrivacyCore.validate_store_shape(%{s.id => s}, [s.id], stats)

      assert {:error, :invalid_precondition} =
               MemoryPrivacyCore.validate_store_shape(%{"wrong" => s}, [s.id], stats)

      assert {:error, :invalid_precondition} =
               MemoryPrivacyCore.validate_store_shape(%{s.id => s}, [s.id, s.id], stats)

      assert {:error, :invalid_precondition} =
               MemoryPrivacyCore.validate_store_shape(%{s.id => s}, [], stats)
    end

    test "drop_targets preserves survivor order and stats" do
      t = memory(@target, :t)
      a = memory(@other, :a)
      b = memory(@other <> "2", :b)

      state = %{
        signals: %{t.id => t, a.id => a, b.id => b},
        order: :queue.from_list([t.id, a.id, b.id]),
        stats: %{total_stored: 3, total_expired: 1, total_evicted: 2},
        max_signals: 10,
        ttl_seconds: 60
      }

      state2 = MemoryPrivacyCore.drop_targets(state, [t.id])

      assert Map.keys(state2.signals) |> Enum.sort() == Enum.sort([a.id, b.id])
      assert :queue.to_list(state2.order) == [a.id, b.id]
      assert state2.stats == state.stats
      refute MemoryPrivacyCore.has_exact_target?(state2.signals, @target)
    end
  end

  describe "prove_delete_convergence/4" do
    test "requires equal snapshots and no exact target" do
      a = memory(@other, :a)

      state2 = %{
        signals: %{a.id => a},
        order: :queue.from_list([a.id]),
        stats: %{total_stored: 1, total_expired: 0, total_evicted: 0}
      }

      approved = MemoryPrivacyCore.build_snapshot(state2)

      assert :ok =
               MemoryPrivacyCore.prove_delete_convergence(state2, approved, approved, @target)

      mutated = Map.put(approved, :stats, %{total_stored: 9, total_expired: 0, total_evicted: 0})

      assert :failed =
               MemoryPrivacyCore.prove_delete_convergence(state2, approved, mutated, @target)
    end
  end

  describe "strict snapshot_fields/1" do
    test "accepts atom-only or string-only required fields" do
      a = memory(@other, :a)
      stats = %{total_stored: 1, total_expired: 0, total_evicted: 0}

      atom_only = %{signals: %{a.id => a}, order: [a.id], stats: stats}
      assert {:ok, signals, order, ^stats} = MemoryPrivacyCore.snapshot_fields(atom_only)
      assert signals == %{a.id => a}
      assert order == [a.id]

      string_only = %{"signals" => %{a.id => a}, "order" => [a.id], "stats" => stats}
      assert {:ok, ^signals, ^order, ^stats} = MemoryPrivacyCore.snapshot_fields(string_only)
    end

    test "rejects duplicate atom and string representations" do
      a = memory(@other, :a)
      t = memory(@target, :t)
      stats = %{total_stored: 0, total_expired: 0, total_evicted: 0}

      dual = %{
        :signals => %{},
        "signals" => %{t.id => t},
        :order => [],
        "order" => [t.id],
        :stats => stats,
        "stats" => %{total_stored: 1, total_expired: 0, total_evicted: 0}
      }

      assert :error = MemoryPrivacyCore.snapshot_fields(dual)

      assert {:error, :invalid_precondition} =
               MemoryPrivacyCore.validate_loaded_snapshot(dual, @target)

      approved = %{signals: %{a.id => a}, order: [a.id], stats: stats}

      state2 = %{
        signals: %{a.id => a},
        order: :queue.from_list([a.id]),
        stats: stats
      }

      assert :failed =
               MemoryPrivacyCore.prove_delete_convergence(state2, approved, dual, @target)
    end

    test "rejects extra top-level fields" do
      a = memory(@other, :a)
      stats = %{total_stored: 1, total_expired: 0, total_evicted: 0}

      extra = %{
        signals: %{a.id => a},
        order: [a.id],
        stats: stats,
        hidden: %{agent_id: @target}
      }

      assert :error = MemoryPrivacyCore.snapshot_fields(extra)

      assert {:error, :invalid_precondition} =
               MemoryPrivacyCore.validate_loaded_snapshot(extra, @target)

      refute MemoryPrivacyCore.snapshots_equal?(
               %{signals: %{a.id => a}, order: [a.id], stats: stats},
               extra
             )
    end

    test "hidden target under duplicate key never yields absence false-negative ok" do
      t = memory(@target, :t)
      stats = %{total_stored: 0, total_expired: 0, total_evicted: 0}

      # Empty atom signals would look absent if OR-fallback preferred atom first.
      dual = %{
        :signals => %{},
        "signals" => %{t.id => t},
        :order => [],
        "order" => [t.id],
        :stats => stats,
        "stats" => %{total_stored: 1, total_expired: 0, total_evicted: 0}
      }

      # Must not report {:ok, false} (no target) — reject entirely.
      assert {:error, :invalid_precondition} =
               MemoryPrivacyCore.validate_loaded_snapshot(dual, @target)
    end
  end

  defp memory(agent_id, type) do
    Signal.new(:memory, type, %{agent_id: agent_id})
  end
end
