defmodule Arbor.Signals.Store.CheckpointIO.ReceiptCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0C4B"

  alias Arbor.Signals.Store.CheckpointIO.ReceiptCore

  describe "split_remaining/1" do
    test "remaining <= 1 fails work immediately" do
      assert {:error, :timeout} = ReceiptCore.split_remaining(0)
      assert {:error, :timeout} = ReceiptCore.split_remaining(1)
      assert {:error, :timeout} = ReceiptCore.split_remaining(-5)
    end

    test "remaining > 1 uses always-valid bounded reserve" do
      assert {:ok, %{reserve: 1, work_budget: 1}} = ReceiptCore.split_remaining(2)
      assert {:ok, %{reserve: 1, work_budget: 4}} = ReceiptCore.split_remaining(5)
      assert {:ok, %{reserve: 5, work_budget: 20}} = ReceiptCore.split_remaining(25)
      assert {:ok, %{reserve: 20, work_budget: 80}} = ReceiptCore.split_remaining(100)
      assert {:ok, %{reserve: 250, work_budget: 1750}} = ReceiptCore.split_remaining(2000)
    end

    test "reserve invariants for remaining > 1" do
      for remaining <- [2, 3, 10, 25, 99, 100, 500, 2000, 10_000] do
        assert {:ok, %{reserve: reserve, work_budget: work}} =
                 ReceiptCore.split_remaining(remaining)

        assert reserve >= 1
        assert reserve <= remaining - 1
        assert reserve <= 250
        assert work + reserve == remaining
        assert work >= 1
      end
    end
  end

  describe "split_deadlines/2" do
    test "computes fixed D_work once from outer and now" do
      d_outer = 1_000_000
      now = d_outer - 100

      assert {:ok, d_work, ^d_outer} = ReceiptCore.split_deadlines(d_outer, now)
      assert d_work == d_outer - 20
      assert d_work < d_outer
    end

    test "insufficient remaining returns timeout" do
      d_outer = 1000
      assert {:error, :timeout} = ReceiptCore.split_deadlines(d_outer, d_outer)
      assert {:error, :timeout} = ReceiptCore.split_deadlines(d_outer, d_outer - 1)
    end
  end

  describe "receipt transitions" do
    setup do
      op_ref = make_ref()
      coord = self()
      coord_mon = make_ref()
      d_work = 10_000
      d_outer = 12_000

      receipt = ReceiptCore.new(op_ref, d_work, d_outer, coord, coord_mon)
      worker = self()
      worker_mon = make_ref()

      {:ok,
       receipt: receipt,
       op_ref: op_ref,
       coord_mon: coord_mon,
       worker: worker,
       worker_mon: worker_mon,
       d_work: d_work,
       d_outer: d_outer}
    end

    test "d_work is immutable across transitions", ctx do
      r0 = ctx.receipt
      {r1, {:arm_worker, w}} = ReceiptCore.apply_event(r0, {:owner_ready, ctx.worker})
      assert w == ctx.worker
      r1 = ReceiptCore.arm_worker(r1, ctx.worker, ctx.worker_mon)
      {r2, :settle_kill_both} = ReceiptCore.apply_event(r1, {:result, {:ok, :payload}})
      {r3, :continue} = ReceiptCore.apply_event(r2, {:worker_down, ctx.worker_mon})

      assert r0.d_work == ctx.d_work
      assert r1.d_work == ctx.d_work
      assert r2.d_work == ctx.d_work
      assert r3.d_work == ctx.d_work
      assert r3.d_outer == ctx.d_outer
    end

    test "result-before-DOWN admits only after both downs", ctx do
      r = arm(ctx)
      {r, :settle_kill_both} = ReceiptCore.apply_event(r, {:result, {:ok, {:loaded, %{}}}})
      {r, :continue} = ReceiptCore.apply_event(r, {:worker_down, ctx.worker_mon})
      refute match?({:done, _}, r.outcome)

      {r, {:done, {:ok, {:loaded, %{}}}}} =
        ReceiptCore.apply_event(r, {:coord_down, ctx.coord_mon})

      assert r.worker_down
      assert r.coord_down
      assert r.phase == :closed
    end

    test "worker-DOWN-before-result then admits after coord down", ctx do
      r = arm(ctx)
      {r, :continue} = ReceiptCore.apply_event(r, {:worker_down, ctx.worker_mon})
      assert r.worker_down
      assert r.phase == :running

      {r, :settle_kill_both} = ReceiptCore.apply_event(r, {:result, {:ok, :v}})
      {r, {:done, {:ok, :v}}} = ReceiptCore.apply_event(r, {:coord_down, ctx.coord_mon})
      assert r.phase == :closed
    end

    test "coord-DOWN then result peeks into settle and admits after worker down", ctx do
      r = arm(ctx)
      # Simulate shell peek: result applied before coord_down event.
      {r, :settle_kill_both} = ReceiptCore.apply_event(r, {:result, {:error, :failed}})
      {r, :continue} = ReceiptCore.apply_event(r, {:coord_down, ctx.coord_mon})
      {r, {:done, {:error, :failed}}} = ReceiptCore.apply_event(r, {:worker_down, ctx.worker_mon})
      assert r.phase == :closed
    end

    test "coord-DOWN without result is fail_closed", ctx do
      r = arm(ctx)
      {r, {:fail_closed_no_result, :exit}} = ReceiptCore.apply_event(r, {:coord_down, ctx.coord_mon})
      {r, {:done, {:error, :exit}}} = ReceiptCore.complete_fail_closed(r, :exit)
      assert r.phase == :closed
    end

    test "result then coord-DOWN then worker-DOWN admits", ctx do
      r = arm(ctx)
      {r, :settle_kill_both} = ReceiptCore.apply_event(r, {:result, {:ok, 1}})
      {r, :continue} = ReceiptCore.apply_event(r, {:coord_down, ctx.coord_mon})
      {r, {:done, {:ok, 1}}} = ReceiptCore.apply_event(r, {:worker_down, ctx.worker_mon})
      assert r.outcome == {:done, {:ok, 1}}
    end

    test "pre-arm result is never admitted", ctx do
      r = ctx.receipt
      assert r.phase == :arming

      {r2, {:reject_pre_arm_result, :dispatch_failed}} =
        ReceiptCore.apply_event(r, {:result, {:ok, :must_not_admit}})

      assert r2.result == :none
      assert r2.phase == :arming

      {r3, {:done, {:error, :dispatch_failed}}} =
        ReceiptCore.complete_pre_arm_reject(r2, :dispatch_failed)

      refute match?({:ok, _}, r3.outcome |> elem(1))
      assert r3.outcome == {:done, {:error, :dispatch_failed}}
    end

    test "work timeout requests teardown and completes as timeout", ctx do
      r = arm(ctx)
      {r, :timeout_teardown} = ReceiptCore.apply_event(r, :work_timeout)
      {r, {:done, {:error, :timeout}}} = ReceiptCore.apply_event(r, :timeout_teardown_complete)
      assert r.phase == :closed
    end

    test "missing quiescence after result is closed exit", ctx do
      r = arm(ctx)
      {r, :settle_kill_both} = ReceiptCore.apply_event(r, {:result, {:ok, :x}})
      # Only one down proven.
      {r, :continue} = ReceiptCore.apply_event(r, {:worker_down, ctx.worker_mon})
      {r, {:done, {:error, :exit}}} = ReceiptCore.apply_event(r, :quiescence_failed)
      assert r.outcome == {:done, {:error, :exit}}
    end

    test "one-shot: second worker_down is ignored", ctx do
      r = arm(ctx)
      {r, :continue} = ReceiptCore.apply_event(r, {:worker_down, ctx.worker_mon})
      assert r.worker_down
      {r2, :ignore} = ReceiptCore.apply_event(r, {:worker_down, ctx.worker_mon})
      assert r2.worker_down
      assert r2.d_work == ctx.d_work
    end

    test "one-shot: second coord_down is ignored", ctx do
      r = arm(ctx)
      {r, {:fail_closed_no_result, :exit}} = ReceiptCore.apply_event(r, {:coord_down, ctx.coord_mon})
      {r2, :ignore} = ReceiptCore.apply_event(r, {:coord_down, ctx.coord_mon})
      assert r2.coord_down
    end

    test "coord down while arming is dispatch_failed", ctx do
      r = ctx.receipt
      {r, {:done, {:error, :dispatch_failed}}} = ReceiptCore.apply_event(r, {:coord_down, ctx.coord_mon})
      assert r.phase == :closed
    end

    test "foreign monitor refs are ignored", ctx do
      r = arm(ctx)
      foreign = make_ref()
      {r2, :ignore} = ReceiptCore.apply_event(r, {:worker_down, foreign})
      refute r2.worker_down
      {r3, :ignore} = ReceiptCore.apply_event(r, {:coord_down, foreign})
      refute r3.coord_down
    end

    test "both_down? is false before arm and never means coord-only", ctx do
      r = ctx.receipt
      assert r.worker_mon == nil
      refute ReceiptCore.both_down?(r)

      # Coord DOWN alone while still arming must not look like dual quiescence.
      {r_coord, {:done, {:error, :dispatch_failed}}} =
        ReceiptCore.apply_event(r, {:coord_down, ctx.coord_mon})

      assert r_coord.coord_down
      refute ReceiptCore.both_down?(r_coord)

      # Armed but only one side down is still false.
      r_armed = arm(ctx)
      refute ReceiptCore.both_down?(r_armed)
      {r_w, :continue} = ReceiptCore.apply_event(r_armed, {:worker_down, ctx.worker_mon})
      refute ReceiptCore.both_down?(r_w)

      # Both Store-owned receipts after arm.
      {r_both, :settle_kill_both} = ReceiptCore.apply_event(r_armed, {:result, {:ok, :x}})
      {r_both, :continue} = ReceiptCore.apply_event(r_both, {:worker_down, ctx.worker_mon})
      {r_both, {:done, {:ok, :x}}} = ReceiptCore.apply_event(r_both, {:coord_down, ctx.coord_mon})
      assert ReceiptCore.both_down?(r_both)
    end
  end

  defp arm(ctx) do
    {r, {:arm_worker, _}} = ReceiptCore.apply_event(ctx.receipt, {:owner_ready, ctx.worker})
    ReceiptCore.arm_worker(r, ctx.worker, ctx.worker_mon)
  end
end
