defmodule Arbor.Signals.MemoryAgentContentPrivacyTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0C4B"

  alias Arbor.Signals
  alias Arbor.Signals.Signal
  alias Arbor.Signals.Store
  alias Arbor.Signals.Test.MemoryCheckpointFake

  @target "agent_privacy_target"
  @prefix "agent_privacy_target_x"
  @other "agent_privacy_other"

  setup do
    prev_mod = Application.get_env(:arbor_signals, :checkpoint_module)
    prev_store = Application.get_env(:arbor_signals, :checkpoint_store)

    # Default live-only for isolation unless a test configures checkpointing.
    Application.put_env(:arbor_signals, :checkpoint_module, nil)
    Application.put_env(:arbor_signals, :checkpoint_store, nil)

    restart_store()
    Store.clear()

    on_exit(fn ->
      MemoryCheckpointFake.stop()

      if prev_mod do
        Application.put_env(:arbor_signals, :checkpoint_module, prev_mod)
      else
        Application.put_env(:arbor_signals, :checkpoint_module, nil)
      end

      if prev_store do
        Application.put_env(:arbor_signals, :checkpoint_store, prev_store)
      else
        Application.delete_env(:arbor_signals, :checkpoint_store)
      end

      # Restore a clean store for other tests.
      if Process.whereis(Store), do: Store.clear()
    end)

    :ok
  end

  describe "contract facade envelopes" do
    test "short names and verbose callbacks share closed envelopes" do
      assert :ok = Signals.delete_memory_agent_content(@target, timeout_ms: 1_000)
      assert {:ok, true} = Signals.memory_agent_content_absent?(@target, timeout_ms: 1_000)

      assert :ok =
               Signals.delete_retained_memory_signal_content_for_agent(@target, timeout_ms: 1_000)

      assert {:ok, true} =
               Signals.check_retained_memory_signal_content_absent_for_agent(@target,
                 timeout_ms: 1_000
               )
    end

    test "invalid agent id and timeout are closed pre-dispatch atoms" do
      assert {:error, :invalid_agent_id} = Signals.delete_memory_agent_content("")
      assert {:error, :invalid_agent_id} = Signals.delete_memory_agent_content(123)
      assert {:error, :invalid_agent_id} = Signals.memory_agent_content_absent?("")

      assert {:error, :invalid_precondition} =
               Signals.delete_memory_agent_content(@target, timeout_ms: 0)

      assert {:error, :invalid_precondition} =
               Signals.delete_memory_agent_content(@target, timeout_ms: 70_000)
    end

    test "non-keyword opts return invalid_precondition without raising" do
      assert {:error, :invalid_precondition} =
               Signals.delete_memory_agent_content(@target, [{"timeout_ms", 1_000}])

      assert {:error, :invalid_precondition} =
               Signals.memory_agent_content_absent?(@target, [{"timeout_ms", 1_000}])

      assert {:error, :invalid_precondition} =
               Signals.delete_memory_agent_content(@target, [:timeout_ms, 1_000])
    end
  end

  describe "malformed owner state fail closed without Store death" do
    test "non-queue order and missing owner keys return invalid_precondition" do
      store_pid = Process.whereis(Store)
      assert is_pid(store_pid)

      :sys.replace_state(Store, fn state ->
        %{state | order: :not_a_queue}
      end)

      assert {:error, :invalid_precondition} =
               Signals.delete_memory_agent_content(@target, timeout_ms: 1_000)

      assert {:error, :invalid_precondition} =
               Signals.memory_agent_content_absent?(@target, timeout_ms: 1_000)

      assert Process.alive?(store_pid)
      assert Process.whereis(Store) == store_pid

      :sys.replace_state(Store, fn state ->
        state
        |> Map.delete(:order)
        |> Map.put(:signals, %{})
      end)

      assert {:error, :invalid_precondition} =
               Signals.delete_memory_agent_content(@target, timeout_ms: 1_000)

      assert Process.alive?(store_pid)

      # Restore a valid empty owner so later tests are not poisoned.
      :sys.replace_state(Store, fn state ->
        %{
          state
          | signals: %{},
            order: :queue.new(),
            stats: %{total_stored: 0, total_expired: 0, total_evicted: 0}
        }
      end)
    end
  end

  describe "post-accept Store exit mapping" do
    test "pre-accept missing Store is store_unavailable" do
      supervisor = Arbor.Signals.Supervisor
      _ = Supervisor.terminate_child(supervisor, Store)
      _ = Supervisor.delete_child(supervisor, Store)

      assert Process.whereis(Store) == nil

      assert {:error, :store_unavailable} =
               Signals.delete_memory_agent_content(@target, timeout_ms: 1_000)

      assert {:error, :store_unavailable} =
               Signals.memory_agent_content_absent?(@target, timeout_ms: 1_000)

      restart_store()
    end

    test "shutdown during accepted privacy call is target-bound indeterminate" do
      {:ok, _} =
        MemoryCheckpointFake.start_link(
          name: MemoryCheckpointFake,
          mode: :block_save,
          block_ms: 30_000,
          notify: self()
        )

      Application.put_env(:arbor_signals, :checkpoint_module, MemoryCheckpointFake)
      Application.put_env(:arbor_signals, :checkpoint_store, MemoryCheckpointFake)
      restart_store()
      Store.clear()

      target = memory_signal(@target, :mem_shutdown)
      Store.put_sync(target)
      store_pid = Process.whereis(Store)

      task =
        Task.async(fn ->
          Signals.delete_memory_agent_content(@target, timeout_ms: 5_000)
        end)

      assert_receive {:checkpoint_blocked, :save, _worker, _parent, _links}, 2_000

      # Call was accepted (mutation + checkpoint dispatch in flight). Shutdown
      # must not report :store_unavailable.
      Process.exit(store_pid, :shutdown)

      result = Task.await(task, 3_000)
      assert {:error, {:delete_indeterminate, @target}} = result
      refute match?({:error, :store_unavailable}, result)

      MemoryCheckpointFake.set_mode(:ok)
      restart_store()
    end
  end

  describe "exact isolation and stats preservation" do
    test "deletes only exact target memory signals and preserves survivors, order, and stats" do
      target = memory_signal(@target, :mem_target)
      prefix = memory_signal(@prefix, :mem_prefix)
      other = memory_signal(@other, :mem_other)
      activity = Signal.new(:activity, :act_same_agent, %{agent_id: @target})

      for s <- [target, prefix, other, activity], do: Store.put_sync(s)

      stats_before = Store.stats()
      {:ok, snap_before} = Store.snapshot()
      order_before = snap_before.order

      assert {:ok, false} = Signals.memory_agent_content_absent?(@target, timeout_ms: 1_000)
      assert :ok = Signals.delete_memory_agent_content(@target, timeout_ms: 1_000)
      assert {:ok, true} = Signals.memory_agent_content_absent?(@target, timeout_ms: 1_000)

      assert {:error, :not_found} = Store.get(target.id)
      assert {:ok, ^prefix} = Store.get(prefix.id)
      assert {:ok, ^other} = Store.get(other.id)
      assert {:ok, ^activity} = Store.get(activity.id)

      {:ok, snap_after} = Store.snapshot()
      assert snap_after.order == Enum.reject(order_before, &(&1 == target.id))

      stats_after = Store.stats()
      assert stats_after.total_stored == stats_before.total_stored
      assert stats_after.total_expired == stats_before.total_expired
      assert stats_after.total_evicted == stats_before.total_evicted

      # Idempotent
      assert :ok = Signals.delete_memory_agent_content(@target, timeout_ms: 1_000)
      {:ok, snap_again} = Store.snapshot()
      assert snap_again.signals == snap_after.signals
      assert snap_again.order == snap_after.order
      assert snap_again.stats == snap_after.stats
    end
  end

  describe "ambiguity and bijection fail closed" do
    test "missing agent_id, string-key-only, and non-binary agent_id reject without mutation" do
      good = memory_signal(@other, :mem_other)
      Store.put_sync(good)

      ambiguous_missing = %{Signal.new(:memory, :bad_missing, %{note: "x"}) | data: %{note: "x"}}
      Store.put_sync(ambiguous_missing)

      assert {:error, :invalid_precondition} =
               Signals.delete_memory_agent_content(@target, timeout_ms: 1_000)

      assert {:error, :invalid_precondition} =
               Signals.memory_agent_content_absent?(@target, timeout_ms: 1_000)

      assert {:ok, _} = Store.get(ambiguous_missing.id)
      assert {:ok, _} = Store.get(good.id)

      Store.clear()
      Store.put_sync(good)

      string_key = %{
        Signal.new(:memory, :bad_string_key, %{})
        | data: %{"agent_id" => @target}
      }

      Store.put_sync(string_key)

      assert {:error, :invalid_precondition} =
               Signals.delete_memory_agent_content(@target, timeout_ms: 1_000)

      assert {:error, :invalid_precondition} =
               Signals.memory_agent_content_absent?(@target, timeout_ms: 1_000)

      Store.clear()
      Store.put_sync(good)

      non_binary = %{Signal.new(:memory, :bad_atom, %{}) | data: %{agent_id: :not_binary}}
      Store.put_sync(non_binary)

      assert {:error, :invalid_precondition} =
               Signals.delete_memory_agent_content(@target, timeout_ms: 1_000)

      assert {:error, :invalid_precondition} =
               Signals.memory_agent_content_absent?(@target, timeout_ms: 1_000)
    end

    test "broken map/order bijection fails closed pre-dispatch" do
      signal = memory_signal(@other, :mem_other)
      Store.put_sync(signal)

      # Map key does not equal signal.id
      :sys.replace_state(Store, fn state ->
        broken = %{signal | id: signal.id}
        %{state | signals: %{"not_the_id" => broken}, order: :queue.from_list([signal.id])}
      end)

      assert {:error, :invalid_precondition} =
               Signals.delete_memory_agent_content(@target, timeout_ms: 1_000)

      assert {:error, :invalid_precondition} =
               Signals.memory_agent_content_absent?(@target, timeout_ms: 1_000)

      # Restore a valid empty store for subsequent tests in this file.
      :sys.replace_state(Store, fn state ->
        %{state | signals: %{}, order: :queue.new()}
      end)

      signal2 = memory_signal(@other, :mem_other2)
      Store.put_sync(signal2)

      # Duplicate order ids / omitted map id
      :sys.replace_state(Store, fn state ->
        %{
          state
          | signals: %{signal2.id => signal2},
            order: :queue.from_list([signal2.id, signal2.id])
        }
      end)

      assert {:error, :invalid_precondition} =
               Signals.delete_memory_agent_content(@target, timeout_ms: 1_000)

      :sys.replace_state(Store, fn state ->
        %{state | signals: %{}, order: :queue.new()}
      end)
    end
  end

  describe "checkpoint configuration modes" do
    test "both-nil is live-only and never calls checkpoint module" do
      Application.put_env(:arbor_signals, :checkpoint_module, nil)
      Application.put_env(:arbor_signals, :checkpoint_store, nil)

      {:ok, _} = MemoryCheckpointFake.start_link(name: MemoryCheckpointFake)
      target = memory_signal(@target, :mem_target)
      Store.put_sync(target)

      assert :ok = Signals.delete_memory_agent_content(@target, timeout_ms: 1_000)
      assert MemoryCheckpointFake.calls() == []
      assert {:ok, true} = Signals.memory_agent_content_absent?(@target, timeout_ms: 1_000)
      assert MemoryCheckpointFake.calls() == []
    end

    test "partial configuration fails closed" do
      Application.put_env(:arbor_signals, :checkpoint_module, MemoryCheckpointFake)
      Application.put_env(:arbor_signals, :checkpoint_store, nil)

      assert {:error, :checkpoint_configuration_invalid} =
               Signals.delete_memory_agent_content(@target, timeout_ms: 1_000)

      Application.put_env(:arbor_signals, :checkpoint_module, nil)
      Application.put_env(:arbor_signals, :checkpoint_store, MemoryCheckpointFake)

      assert {:error, :checkpoint_configuration_invalid} =
               Signals.memory_agent_content_absent?(@target, timeout_ms: 1_000)
    end
  end

  describe "configured checkpoint success, restart, and failure injection" do
    setup do
      {:ok, _} = MemoryCheckpointFake.start_link(name: MemoryCheckpointFake, mode: :ok)
      Application.put_env(:arbor_signals, :checkpoint_module, MemoryCheckpointFake)
      Application.put_env(:arbor_signals, :checkpoint_store, MemoryCheckpointFake)
      restart_store()
      Store.clear()
      :ok
    end

    test "save and load converge; restart does not resurrect target" do
      target = memory_signal(@target, :mem_target)
      survivor = memory_signal(@other, :mem_other)
      Store.put_sync(target)
      Store.put_sync(survivor)

      assert {:ok, false} = Signals.memory_agent_content_absent?(@target, timeout_ms: 2_000)
      assert :ok = Signals.delete_memory_agent_content(@target, timeout_ms: 2_000)
      assert {:ok, true} = Signals.memory_agent_content_absent?(@target, timeout_ms: 2_000)

      cp = MemoryCheckpointFake.get_snapshot()
      assert is_map(cp)
      refute Map.has_key?(cp.signals, target.id)
      assert Map.has_key?(cp.signals, survivor.id)

      restart_store()
      assert {:error, :not_found} = Store.get(target.id)
      assert {:ok, restored} = Store.get(survivor.id)
      assert restored.id == survivor.id
      assert {:ok, true} = Signals.memory_agent_content_absent?(@target, timeout_ms: 2_000)
    end

    test "save failure after live delete returns delete_indeterminate and retains deletion" do
      target = memory_signal(@target, :mem_target)
      Store.put_sync(target)
      MemoryCheckpointFake.set_mode(:fail_save)

      assert {:error, {:delete_indeterminate, @target}} =
               Signals.delete_memory_agent_content(@target, timeout_ms: 2_000)

      assert {:error, :not_found} = Store.get(target.id)

      # Retry converges when backend healthy.
      MemoryCheckpointFake.set_mode(:ok)

      assert :ok = Signals.delete_memory_agent_content(@target, timeout_ms: 2_000)
      assert {:ok, true} = Signals.memory_agent_content_absent?(@target, timeout_ms: 2_000)
    end

    test "loaded-vs-approved mismatch is delete_indeterminate not checkpoint_verification_failed" do
      target = memory_signal(@target, :mem_target)
      Store.put_sync(target)
      MemoryCheckpointFake.set_mode(:mutate_loaded)

      assert {:error, {:delete_indeterminate, @target}} =
               Signals.delete_memory_agent_content(@target, timeout_ms: 2_000)

      assert {:error, :not_found} = Store.get(target.id)
    end

    test "malformed load after dispatch is absence_indeterminate without mutation" do
      target = memory_signal(@target, :mem_target)
      Store.put_sync(target)
      MemoryCheckpointFake.set_snapshot(%{not: :valid})
      MemoryCheckpointFake.set_mode(:malformed_load)

      assert {:error, {:absence_indeterminate, @target}} =
               Signals.memory_agent_content_absent?(@target, timeout_ms: 2_000)

      assert {:ok, _} = Store.get(target.id)
    end

    test "missing save/load exports fail closed pre-dispatch" do
      Application.put_env(:arbor_signals, :checkpoint_module, Enum)
      Application.put_env(:arbor_signals, :checkpoint_store, :some_store)

      assert {:error, :checkpoint_configuration_invalid} =
               Signals.delete_memory_agent_content(@target, timeout_ms: 1_000)
    end
  end

  describe "killable checkpoint topology" do
    setup do
      test = self()

      {:ok, _} =
        MemoryCheckpointFake.start_link(
          name: MemoryCheckpointFake,
          mode: :block_save,
          block_ms: 30_000,
          notify: test
        )

      Application.put_env(:arbor_signals, :checkpoint_module, MemoryCheckpointFake)
      Application.put_env(:arbor_signals, :checkpoint_store, MemoryCheckpointFake)
      restart_store()
      Store.clear()
      :ok
    end

    test "deadline kills blocked save without permanently blocking Store" do
      target = memory_signal(@target, :mem_target)
      Store.put_sync(target)

      assert {:error, {:delete_indeterminate, @target}} =
               Signals.delete_memory_agent_content(@target, timeout_ms: 200)

      # Live deletion retained.
      assert {:error, :not_found} = Store.get(target.id)

      # Store accepts subsequent writes.
      other = memory_signal(@other, :after_timeout)
      assert :ok = Store.put_sync(other)
      assert {:ok, _} = Store.get(other.id)
    end

    test "Store kill while blocked terminates worker; no late save effect" do
      target = memory_signal(@target, :mem_target)
      Store.put_sync(target)
      store_pid = Process.whereis(Store)
      assert is_pid(store_pid)

      task =
        Task.async(fn ->
          Signals.delete_memory_agent_content(@target, timeout_ms: 5_000)
        end)

      assert_receive {:checkpoint_blocked, :save, worker, _parent, _links}, 2_000
      assert Process.alive?(worker)

      # Monitor before kill so the observed reason is :killed, not a :noproc race.
      ref = Process.monitor(store_pid)
      Process.exit(store_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^store_pid, :killed}, 1_000

      # Worker must die (coordinator monitors Store and kills worker; link also applies).
      wait_until_dead(worker, 2_000)

      Process.sleep(100)
      late = MemoryCheckpointFake.late_effects()
      # late_effects only records if block returns; killed workers must not complete save.
      refute Enum.any?(late, fn {op, _, _} -> op in [:save, :load] end)

      _ = Task.shutdown(task, :brutal_kill)

      # Supervisor may already have restarted Store; force clean restart with non-blocking mode.
      MemoryCheckpointFake.set_mode(:ok)
      restart_store()
    end

    test "coordinator hard-kill structurally kills worker; no late effect" do
      target = memory_signal(@target, :mem_target)
      Store.put_sync(target)

      task =
        Task.async(fn ->
          Signals.delete_memory_agent_content(@target, timeout_ms: 5_000)
        end)

      assert_receive {:checkpoint_blocked, :save, worker, parent, links}, 2_000
      assert Process.alive?(worker)

      coordinator =
        cond do
          is_pid(parent) and parent != Process.whereis(Store) -> parent
          true -> Enum.find(links, &(is_pid(&1) and &1 != Process.whereis(Store)))
        end

      assert is_pid(coordinator)
      Process.exit(coordinator, :kill)

      wait_until_dead(worker, 2_000)
      wait_until_dead(coordinator, 2_000)

      Process.sleep(100)
      late = MemoryCheckpointFake.late_effects()
      refute Enum.any?(late, fn {op, _, _} -> op in [:save, :load] end)

      result = Task.await(task, 3_000)
      assert {:error, {:delete_indeterminate, @target}} = result
      assert {:error, :not_found} = Store.get(target.id)

      # Store still healthy for subsequent ops.
      other = memory_signal(@other, :after_coord_kill)
      assert :ok = Store.put_sync(other)
    end

    test "queued write during delete runs only after operation settles" do
      target = memory_signal(@target, :mem_target)
      Store.put_sync(target)
      queued = memory_signal(@other, :queued_during)

      task =
        Task.async(fn ->
          Signals.delete_memory_agent_content(@target, timeout_ms: 300)
        end)

      assert_receive {:checkpoint_blocked, :save, _worker, _parent, _links}, 2_000

      # Cast while Store is inside the privacy handle_call; must not apply yet.
      :ok = Store.put(queued)

      result = Task.await(task, 2_000)
      assert {:error, {:delete_indeterminate, @target}} = result

      # After settle: deletion retained and queued write applied.
      assert {:error, :not_found} = Store.get(target.id)
      assert {:ok, _} = Store.get(queued.id)
    end
  end

  defp memory_signal(agent_id, type) do
    Signal.new(:memory, type, %{agent_id: agent_id, marker: System.unique_integer([:positive])})
  end

  defp restart_store(opts \\ []) do
    supervisor = Arbor.Signals.Supervisor

    # Avoid hanging terminate/2 checkpoint save when a blocking fake mode is active.
    if Process.whereis(MemoryCheckpointFake) do
      MemoryCheckpointFake.set_mode(:ok)
    end

    case Supervisor.terminate_child(supervisor, Store) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.delete_child(supervisor, Store) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    {:ok, _} = Supervisor.start_child(supervisor, {Store, opts})
    Process.sleep(20)
    :ok
  end

  defp wait_until_dead(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> Process.alive?(pid) end)
    |> Enum.reduce_while(true, fn alive, _ ->
      cond do
        not alive ->
          {:halt, :ok}

        System.monotonic_time(:millisecond) >= deadline ->
          flunk("process #{inspect(pid)} still alive after #{timeout_ms}ms")

        true ->
          Process.sleep(10)
          {:cont, true}
      end
    end)
  end
end
