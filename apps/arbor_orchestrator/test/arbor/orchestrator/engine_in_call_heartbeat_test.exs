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
  on return.

  This test validates the canonical-store refresh directly.
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
end
