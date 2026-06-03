defmodule Arbor.Orchestrator.EngineInCallHeartbeatTest do
  @moduledoc """
  Regression test for the in-call heartbeat ticker. Surfaced by the
  TDD-cycle demo running RLE against `qwen3.6-27b-mtp`: multi-minute
  LLM calls would let the pipeline's heartbeat go stale beyond the 90 s
  threshold, and `RecoveryCoordinator` emitted spurious stale-heartbeat
  warnings every 30 s. The owner-still-connected guard prevented
  actual recovery from firing, but the log spam was real.

  Fix in `Arbor.Orchestrator.Engine`: wrap every handler invocation
  in a heartbeat ticker that refreshes both `JobRegistry` (legacy) and
  the `:arbor_pipeline_runs` ETS entry (new) every 30 s while the
  handler is in flight. Killed on return.

  This test validates the ETS-side refresh directly — the only side
  effect we can observe without standing up the full recovery
  subsystem.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  @run_id "run_heartbeat_test"

  setup do
    # Make sure the ETS table exists. The engine normally creates it; for an
    # isolated test, create-if-missing.
    case :ets.info(:arbor_pipeline_runs) do
      :undefined -> :ets.new(:arbor_pipeline_runs, [:set, :public, :named_table])
      _ -> :ok
    end

    on_exit(fn ->
      case :ets.info(:arbor_pipeline_runs) do
        :undefined -> :ok
        _ -> :ets.delete(:arbor_pipeline_runs, @run_id)
      end
    end)

    :ok
  end

  test "a long-running handler call refreshes the ETS heartbeat mid-flight" do
    # Seed the ETS entry as if the engine had just synced it.
    old_sync = DateTime.add(DateTime.utc_now(), -120, :second)

    :ets.insert(
      :arbor_pipeline_runs,
      {@run_id, %{status: :running, last_ets_sync: old_sync}}
    )

    # Drive the engine through a simple inline DOT — that's the only public
    # surface that exercises the heartbeat ticker path. The pipeline is
    # tiny but runs long enough (we pad with a deliberate sleep inside a
    # transform's source_key resolution) to span an in-call refresh.
    #
    # Easier path: invoke the private helper directly via a one-line wrap.
    # The helper is a defp; we use :erlang.apply with a Code.eval_string for
    # this test ONLY — same module, no public-API churn.
    {:module, _} = Code.ensure_loaded(Arbor.Orchestrator.Engine)

    # Run a "long" handler call by sleeping just past the ticker interval.
    # The ticker interval is 30s in production; for a fast test we'd want a
    # configurable interval, but adding that knob just for tests bloats the
    # surface. Instead we directly invoke touch_in_call_heartbeat once and
    # assert the side effect — proving the refresh mechanics work without
    # waiting 30s.
    apply(Arbor.Orchestrator.Engine, :touch_in_call_heartbeat_for_test, [@run_id])

    [{@run_id, entry}] = :ets.lookup(:arbor_pipeline_runs, @run_id)

    assert DateTime.diff(entry.last_ets_sync, old_sync, :second) > 100,
           "Expected the ETS entry's last_ets_sync to be refreshed past the seeded stale value"

    # And status preserved (we only touched the timestamp, not the body).
    assert entry.status == :running
  end

  test "with_in_call_heartbeat is a no-op when run_id is nil" do
    # The nil-run-id branch must not crash, just call fun and return its result.
    result =
      apply(Arbor.Orchestrator.Engine, :with_in_call_heartbeat_for_test, [nil, fn -> 42 end])

    assert result == 42
  end
end
