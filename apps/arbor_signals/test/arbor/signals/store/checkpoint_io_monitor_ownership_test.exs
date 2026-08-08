defmodule Arbor.Signals.Store.CheckpointIOMonitorOwnershipTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0C4B"

  alias Arbor.Signals.Signal
  alias Arbor.Signals.Store.CheckpointIO
  alias Arbor.Signals.Test.MemoryCheckpointFake

  describe "CheckpointIO.run/2 protocol path" do
    test "real configured save/load succeeds without false exit or timeout" do
      name = :"checkpoint_io_ok_#{System.unique_integer([:positive])}"
      {:ok, _} = MemoryCheckpointFake.start_link(name: name, mode: :ok)
      on_exit(fn -> MemoryCheckpointFake.stop(name) end)

      signal = Signal.new(:memory, :pair_down, %{agent_id: "agent_pair_down"})

      snapshot = %{
        signals: %{signal.id => signal},
        order: [signal.id],
        stats: %{total_stored: 1, total_expired: 0, total_evicted: 0}
      }

      deadline = System.monotonic_time(:millisecond) + 5_000

      assert {:ok, {:loaded, loaded}} =
               CheckpointIO.run({:save_and_load, MemoryCheckpointFake, name, snapshot}, deadline)

      assert loaded == snapshot
    end

    test "timeout cleanup kills blocked worker without late save effect" do
      name = :"checkpoint_io_timeout_#{System.unique_integer([:positive])}"
      test = self()

      {:ok, _} =
        MemoryCheckpointFake.start_link(
          name: name,
          mode: :block_save,
          block_ms: 60_000,
          notify: test
        )

      on_exit(fn -> MemoryCheckpointFake.stop(name) end)

      snapshot = %{
        signals: %{},
        order: [],
        stats: %{total_stored: 0, total_expired: 0, total_evicted: 0}
      }

      deadline = System.monotonic_time(:millisecond) + 200

      result =
        CheckpointIO.run({:save_and_load, MemoryCheckpointFake, name, snapshot}, deadline)

      assert result == {:error, :timeout}

      # Blocked notify may arrive before or after run returns; prove worker death
      # via monitor DOWN (delivered even if already dead when monitored).
      assert_receive {:checkpoint_blocked, :save, worker, _parent, _links}, 2_000
      ref = Process.monitor(worker)
      assert_receive {:DOWN, ^ref, :process, ^worker, _}, 2_000
      refute Process.alive?(worker)

      refute Enum.any?(MemoryCheckpointFake.late_effects(name), fn {op, _, _} ->
               op in [:save, :load]
             end)
    end

    test "worker exit mid-save is closed failure without hang" do
      name = :"checkpoint_io_exit_#{System.unique_integer([:positive])}"
      {:ok, _} = MemoryCheckpointFake.start_link(name: name, mode: :exit_self)
      on_exit(fn -> MemoryCheckpointFake.stop(name) end)

      snapshot = %{
        signals: %{},
        order: [],
        stats: %{total_stored: 0, total_expired: 0, total_evicted: 0}
      }

      deadline = System.monotonic_time(:millisecond) + 3_000

      result =
        CheckpointIO.run({:save_and_load, MemoryCheckpointFake, name, snapshot}, deadline)

      # Deterministic closed exit — must not hang into :timeout (masks receipt bugs).
      assert result == {:error, :exit}
    end

    test "load-only success path" do
      name = :"checkpoint_io_load_#{System.unique_integer([:positive])}"
      signal = Signal.new(:memory, :load_only, %{agent_id: "agent_load_only"})

      snapshot = %{
        signals: %{signal.id => signal},
        order: [signal.id],
        stats: %{total_stored: 1, total_expired: 0, total_evicted: 0}
      }

      {:ok, _} = MemoryCheckpointFake.start_link(name: name, mode: :ok, snapshot: snapshot)
      MemoryCheckpointFake.set_snapshot(name, snapshot)
      on_exit(fn -> MemoryCheckpointFake.stop(name) end)

      deadline = System.monotonic_time(:millisecond) + 5_000

      assert {:ok, {:loaded, loaded}} =
               CheckpointIO.run({:load, MemoryCheckpointFake, name}, deadline)

      assert loaded == snapshot
    end

    test "insufficient deadline fails closed without starting work" do
      name = :"checkpoint_io_tiny_#{System.unique_integer([:positive])}"
      {:ok, _} = MemoryCheckpointFake.start_link(name: name, mode: :ok)
      on_exit(fn -> MemoryCheckpointFake.stop(name) end)

      # remaining <= 1 → immediate timeout at entry
      deadline = System.monotonic_time(:millisecond) + 1

      assert {:error, :timeout} =
               CheckpointIO.run(
                 {:save_and_load, MemoryCheckpointFake, name,
                  %{
                    signals: %{},
                    order: [],
                    stats: %{total_stored: 0, total_expired: 0, total_evicted: 0}
                  }},
                 deadline
               )

      assert MemoryCheckpointFake.calls(name) == []
    end
  end
end
