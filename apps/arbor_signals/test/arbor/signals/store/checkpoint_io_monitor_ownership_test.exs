defmodule Arbor.Signals.Store.CheckpointIOMonitorOwnershipTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0C4B"

  alias Arbor.Signals.Signal
  alias Arbor.Signals.Store.CheckpointIO
  alias Arbor.Signals.Test.MemoryCheckpointFake

  describe "Store-owned monitor refs" do
    test "source arms Store-owned Process.monitor(worker) and has no arm_for_test seam" do
      source =
        File.read!(
          Path.expand(
            "../../../../lib/arbor/signals/store/checkpoint_io.ex",
            __DIR__
          )
        )

      refute source =~ "arm_for_test"
      refute source =~ "Process.sleep(60_000)"

      # Store path creates its own worker monitor after owner_ready (not foreign mon).
      assert source =~ "worker_mon = Process.monitor(worker)"
      assert source =~ "{op_ref, :store_ready}"
      assert source =~ "settle_after_result"
    end

    test "Store-owned monitor dual_kill observes exact DOWNs without timeout fallback" do
      # Test process acts as Store: spawn_monitor coord, Process.monitor(worker).
      parent = self()

      {coord, coord_mon} =
        spawn_monitor(fn ->
          {worker, _coord_worker_mon} =
            spawn_opt(
              fn ->
                Process.sleep(60_000)
              end,
              [:link, :monitor]
            )

          send(parent, {:worker_pid, worker})
          Process.sleep(60_000)
        end)

      assert_receive {:worker_pid, worker}, 1_000

      # Source-level Store ownership: this process creates the worker mon.
      worker_mon = Process.monitor(worker)

      assert :ok = CheckpointIO.dual_kill_and_drain(coord, coord_mon, worker, worker_mon)
      refute Process.alive?(worker)
      refute Process.alive?(coord)

      refute_receive {:DOWN, ^worker_mon, :process, ^worker, _}, 50
      refute_receive {:DOWN, ^coord_mon, :process, ^coord, _}, 50
    end

    test "foreign coordinator worker mon fails dual_kill without exact DOWN" do
      parent = self()

      {coord, coord_mon} =
        spawn_monitor(fn ->
          {worker, foreign_worker_mon} =
            spawn_opt(
              fn ->
                Process.sleep(60_000)
              end,
              [:link, :monitor]
            )

          send(parent, {:foreign, worker, foreign_worker_mon})
          Process.sleep(60_000)
        end)

      assert_receive {:foreign, worker, foreign_worker_mon}, 1_000

      # Bug class: dual_kill with coordinator's mon ref instead of Store's.
      assert {:error, :worker_down_timeout} =
               CheckpointIO.dual_kill_and_drain(coord, coord_mon, worker, foreign_worker_mon)

      refute Process.alive?(worker)
      refute Process.alive?(coord)
    end

    test "real run/2 success requires completed Store-owned pair-down" do
      name = :"checkpoint_io_pair_down_#{System.unique_integer([:positive])}"
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
  end
end
