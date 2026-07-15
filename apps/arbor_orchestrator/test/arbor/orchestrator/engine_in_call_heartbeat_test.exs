defmodule Arbor.Orchestrator.EngineInCallHeartbeatTest do
  @moduledoc """
  Regression test for the in-call heartbeat ticker. Surfaced by the
  TDD-cycle demo running RLE against `qwen3.6-27b-mtp`: multi-minute
  LLM calls would let the pipeline's heartbeat go stale beyond the 90 s
  threshold, and `RecoveryCoordinator` emitted spurious stale-heartbeat
  warnings every 30 s. The owner-still-connected guard prevented
  actual recovery from firing, but the log spam was real.

  Fix in `Arbor.Orchestrator.Engine`: wrap every handler invocation
  in a heartbeat ticker that refreshes the canonical PipelineStatus /
  RunJournal entry every 30 s while the handler is in flight. Killed
  on return, and independently monitors the Engine owner so
  `Process.exit(owner, :kill)` (which bypasses `after`) cannot leak
  the ticker forever.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.PipelineStatus

  setup do
    run_id = "run_heartbeat_test_#{System.unique_integer([:positive, :monotonic])}"
    old_sync = DateTime.add(DateTime.utc_now(), -120, :second)

    PipelineStatus.put(%{
      run_id: run_id,
      pipeline_id: run_id,
      status: :running,
      last_ets_sync: old_sync,
      last_heartbeat: old_sync,
      started_at: old_sync,
      total_nodes: 1,
      completed_count: 0
    })

    on_exit(fn ->
      _ = PipelineStatus.delete(run_id)
    end)

    {:ok, old_sync: old_sync, run_id: run_id}
  end

  test "a long-running handler call refreshes the lifecycle heartbeat mid-flight", %{
    old_sync: old_sync,
    run_id: run_id
  } do
    {:module, _} = Code.ensure_loaded(Arbor.Orchestrator.Engine)

    apply(Arbor.Orchestrator.Engine, :touch_in_call_heartbeat_for_test, [run_id])

    entry = PipelineStatus.get(run_id)
    assert entry.status == :running

    assert DateTime.diff(entry.last_ets_sync, old_sync, :second) > 100,
           "Expected last_ets_sync to be refreshed past the seeded stale value"
  end

  test "with_in_call_heartbeat is a no-op when run_id is nil" do
    # The nil-run-id branch must not crash, just call fun and return its result.
    result =
      apply(Arbor.Orchestrator.Engine, :with_in_call_heartbeat_for_test, [nil, fn -> 42 end])

    assert result == 42
  end

  test "heartbeat ticker dies when its Engine owner is brutally killed", %{run_id: run_id} do
    {:module, _} = Code.ensure_loaded(Arbor.Orchestrator.Engine)
    test = self()

    {owner, mon} =
      spawn_monitor(fn ->
        apply(Arbor.Orchestrator.Engine, :with_in_call_heartbeat_for_test, [
          run_id,
          fn ->
            # Signal that the in-call scope is active so the test can locate
            # the unlinked ticker before killing this owner.
            send(test, {:owner_in_call, self()})

            receive do
              :never -> :ok
            after
              60_000 -> :ok
            end
          end
        ])
      end)

    assert_receive {:owner_in_call, ^owner}, 2_000

    ticker =
      await_owner_monitor_ticker(owner, 2_000)

    assert is_pid(ticker)
    assert Process.alive?(ticker)
    refute ticker == owner

    # Brutal kill bypasses the owner's after-cleanup; ticker must still exit
    # via its independent Process.monitor(owner) path (not a link).
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^mon, :process, ^owner, :killed}, 2_000
    refute Process.alive?(owner)

    await_process_dead(ticker, 2_000)
    refute Process.alive?(ticker)
  end

  defp await_owner_monitor_ticker(owner, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_owner_monitor_ticker_loop(owner, deadline)
  end

  defp await_owner_monitor_ticker_loop(owner, deadline) do
    case find_process_monitoring(owner) do
      pid when is_pid(pid) ->
        pid

      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for in-call heartbeat ticker monitoring #{inspect(owner)}")
        else
          Process.sleep(10)
          await_owner_monitor_ticker_loop(owner, deadline)
        end
    end
  end

  defp find_process_monitoring(owner) when is_pid(owner) do
    # Exclude this test process (spawn_monitor of the owner) and the owner itself.
    me = self()

    Enum.find(:erlang.processes(), fn pid ->
      pid != me and pid != owner and
        case Process.info(pid, :monitors) do
          {:monitors, monitors} when is_list(monitors) ->
            Enum.any?(monitors, fn
              {:process, ^owner} -> true
              _ -> false
            end)

          _ ->
            false
        end
    end)
  end

  defp await_process_dead(pid, timeout_ms) when is_pid(pid) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_process_dead_loop(pid, deadline)
  end

  defp await_process_dead_loop(pid, deadline) do
    cond do
      not Process.alive?(pid) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("ticker #{inspect(pid)} still alive after owner kill")

      true ->
        Process.sleep(10)
        await_process_dead_loop(pid, deadline)
    end
  end
end
