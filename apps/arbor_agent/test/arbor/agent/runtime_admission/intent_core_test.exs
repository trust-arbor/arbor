defmodule Arbor.Agent.RuntimeAdmission.IntentCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.RuntimeAdmission.IntentCore

  @moduletag :fast

  @target "agent_testtarget01"
  @fp_a "fp_aaa"
  @fp_b "fp_bbb"

  test "fence first rejects admit" do
    assert {:error, :target_fenced} =
             IntentCore.admit(
               %{},
               %{@target => "op1"},
               true,
               true,
               @target,
               @fp_a,
               "rai_1",
               0,
               10
             )
  end

  test "not ready rejects" do
    assert {:error, :runtime_admission_not_ready} =
             IntentCore.admit(%{}, %{}, true, false, @target, @fp_a, "rai_1", 0, 10)

    assert {:error, :fence_not_ready} =
             IntentCore.admit(%{}, %{}, false, true, @target, @fp_a, "rai_1", 0, 10)
  end

  test "admit then same fingerprint joins; different conflicts" do
    assert {:ok, :admitted, intent, intents, [{:launch_owner, _}]} =
             IntentCore.admit(%{}, %{}, true, true, @target, @fp_a, "rai_1", 0, 10)

    assert intent.intent_id == "rai_1"

    assert {:ok, :joined, ^intent, ^intents, []} =
             IntentCore.admit(intents, %{}, true, true, @target, @fp_a, "rai_2", 1, 10)

    assert {:error, :conflict} =
             IntentCore.admit(intents, %{}, true, true, @target, @fp_b, "rai_3", 1, 10)
  end

  test "non_idle and settle" do
    {:ok, :admitted, _i, intents, _} =
      IntentCore.admit(%{}, %{}, true, true, @target, @fp_a, "rai_1", 0, 10)

    assert IntentCore.non_idle?(intents, @target)

    assert {:ok, done, cleared} =
             IntentCore.settle(intents, @target, "rai_1", {:applied, self()})

    assert done.phase == :terminal
    refute IntentCore.non_idle?(cleared, @target)
  end

  test "bind_worker requires authenticated owner and exact fingerprint" do
    {:ok, :admitted, _intent, intents, _} =
      IntentCore.admit(%{}, %{}, true, true, @target, @fp_a, "rai_1", 0, 10)

    worker = spawn(fn -> :ok end)

    # Pre-adoption (owner_pid nil / phase :admitted) is conflict, never not_owner.
    assert {:error, :conflict} =
             IntentCore.bind_worker(intents, @target, "rai_1", @fp_a, self(), worker)

    launching = put_in(intents, [@target, :phase], :owner_launching)

    assert {:error, :conflict} =
             IntentCore.bind_worker(launching, @target, "rai_1", @fp_a, self(), worker)

    launch_ref = make_ref()
    {:ok, _, launching2} = IntentCore.begin_owner_launch(intents, @target, launch_ref, 1)

    {:ok, _, bound} =
      IntentCore.bind_launch_owner(launching2, @target, "rai_1", @fp_a, launch_ref, self())

    {:ok, :adopted, _, live} =
      IntentCore.adopt_owner(bound, %{}, true, true, @target, "rai_1", @fp_a, self())

    # Foreign owner cannot bind against a live adopted owner.
    foreign = spawn(fn -> :ok end)

    assert {:error, :not_owner} =
             IntentCore.bind_worker(live, @target, "rai_1", @fp_a, foreign, worker)

    # Wrong fingerprint
    assert {:error, :conflict} =
             IntentCore.bind_worker(live, @target, "rai_1", @fp_b, self(), worker)

    assert {:ok, running} =
             IntentCore.bind_worker(live, @target, "rai_1", @fp_a, self(), worker)

    assert running[@target].worker_pid == worker

    # Authenticate: only bound worker passes
    assert :ok =
             IntentCore.authenticate_worker(running, @target, "rai_1", @fp_a, worker)

    assert {:error, :not_owner} =
             IntentCore.authenticate_worker(running, @target, "rai_1", @fp_a, self())
  end

  test "adopt requires prior launch bind; preserves worker_running" do
    assert {:error, :target_fenced} =
             IntentCore.adopt_owner(
               %{},
               %{@target => "op"},
               true,
               true,
               @target,
               "rai_1",
               @fp_a,
               self()
             )

    # Nil-intent create path is removed.
    assert {:error, :not_found} =
             IntentCore.adopt_owner(%{}, %{}, true, true, @target, "rai_1", @fp_a, self())

    {:ok, :admitted, _, intents, _} =
      IntentCore.admit(%{}, %{}, true, true, @target, @fp_a, "rai_1", 0, 10)

    assert {:error, :owner_not_bound} =
             IntentCore.adopt_owner(intents, %{}, true, true, @target, "rai_1", @fp_a, self())

    launch_ref = make_ref()
    {:ok, _, launching} = IntentCore.begin_owner_launch(intents, @target, launch_ref, 1)

    foreign = spawn(fn -> :ok end)

    assert {:error, :stale_launch} =
             IntentCore.bind_launch_owner(
               launching,
               @target,
               "rai_1",
               @fp_a,
               make_ref(),
               foreign
             )

    {:ok, bound_intent, bound} =
      IntentCore.bind_launch_owner(
        launching,
        @target,
        "rai_1",
        @fp_a,
        launch_ref,
        self()
      )

    assert bound_intent.owner_pid == self()
    assert bound_intent.launch_ref == nil

    assert {:error, :not_owner} =
             IntentCore.adopt_owner(bound, %{}, true, true, @target, "rai_1", @fp_a, foreign)

    {:ok, :adopted, live, live_map} =
      IntentCore.adopt_owner(bound, %{}, true, true, @target, "rai_1", @fp_a, self())

    assert live.phase == :owner_live

    worker = spawn(fn -> :ok end)
    {:ok, running} = IntentCore.bind_worker(live_map, @target, "rai_1", @fp_a, self(), worker)
    assert running[@target].phase == :worker_running

    # Idempotent exact-owner adopt must not downgrade worker_running.
    {:ok, :adopted, again, again_map} =
      IntentCore.adopt_owner(running, %{}, true, true, @target, "rai_1", @fp_a, self())

    assert again.phase == :worker_running
    assert again.worker_pid == worker
    assert again_map[@target].phase == :worker_running
  end

  test "consume_launch_failure only for matching unbound attempt" do
    {:ok, :admitted, _, intents, _} =
      IntentCore.admit(%{}, %{}, true, true, @target, @fp_a, "rai_1", 0, 10)

    ref = make_ref()
    {:ok, _, launching} = IntentCore.begin_owner_launch(intents, @target, ref, 1)
    mon = make_ref()
    {:ok, launching} = IntentCore.attach_launcher(launching, @target, ref, self(), mon)

    assert {:ok, cleared, ^mon} =
             IntentCore.consume_launch_failure(launching, @target, "rai_1", ref)

    assert cleared[@target].launch_ref == nil

    assert {:error, :stale_launch} =
             IntentCore.consume_launch_failure(cleared, @target, "rai_1", ref)
  end

  test "unknown start classification" do
    assert IntentCore.classify_unknown_start("rai_1", {:exact, "rai_1"}) == :applied
    assert IntentCore.classify_unknown_start("rai_1", :bare) == :conflict
    assert IntentCore.classify_unknown_start("rai_1", {:other, "rai_2"}) == :conflict
    assert IntentCore.classify_unknown_start("rai_1", :not_running) == :not_applied
  end

  test "rebind_owners accepts a fully valid unique inventory" do
    snaps = [
      %{
        intent_id: "rai_1",
        target_agent_id: @target,
        fingerprint: "fp_" <> String.duplicate("a", 16),
        child_pid: self(),
        owner_pid: self()
      }
    ]

    assert {:ok, intents} = IntentCore.rebind_owners(%{}, snaps)
    assert intents[@target].phase == :outcome_unknown
    assert intents[@target].owner_pid == self()
    assert IntentCore.non_idle?(intents, @target)
  end

  test "rebind_owners preserves exact worker authority from the fixed owner snapshot" do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

    snaps = [
      %{
        intent_id: "rai_1",
        target_agent_id: @target,
        fingerprint: "fp_" <> String.duplicate("a", 16),
        child_pid: self(),
        owner_pid: self(),
        worker_pid: worker
      }
    ]

    assert {:ok, intents} = IntentCore.rebind_owners(%{}, snaps)
    assert intents[@target].phase == :worker_running
    assert intents[@target].owner_pid == self()
    assert intents[@target].worker_pid == worker

    assert {:error, :invalid_snapshot} =
             IntentCore.rebind_owners(%{}, [Map.put(hd(snaps), :worker_pid, self())])
  end

  test "security regression: rebind_owners fails closed when snap.owner_pid mismatches child_pid" do
    other = spawn(fn -> :ok end)

    assert {:error, :invalid_snapshot} =
             IntentCore.rebind_owners(%{}, [
               %{
                 intent_id: "rai_1",
                 target_agent_id: @target,
                 fingerprint: "fp_" <> String.duplicate("a", 16),
                 child_pid: self(),
                 owner_pid: other
               }
             ])
  end

  test "security regression: rebind_owners fails closed on malformed snapshot" do
    # Incomplete inventory (no enumerated child_pid) and bad shapes fail closed.
    assert {:error, :invalid_snapshot} =
             IntentCore.rebind_owners(%{}, [
               %{
                 intent_id: "rai_1",
                 target_agent_id: @target,
                 fingerprint: "fp_" <> String.duplicate("a", 16)
               }
             ])

    # Snapshot owner_pid alone is not restart authority.
    assert {:error, :invalid_snapshot} =
             IntentCore.rebind_owners(%{}, [
               %{
                 intent_id: "rai_1",
                 target_agent_id: @target,
                 fingerprint: "fp_" <> String.duplicate("a", 16),
                 owner_pid: self()
               }
             ])

    assert {:error, :invalid_snapshot} =
             IntentCore.rebind_owners(%{}, [
               %{
                 intent_id: "not-rai",
                 target_agent_id: @target,
                 fingerprint: "fp_" <> String.duplicate("a", 16),
                 child_pid: self(),
                 owner_pid: self()
               }
             ])

    assert {:error, :invalid_snapshot} =
             IntentCore.rebind_owners(%{}, [
               %{
                 intent_id: "rai_1",
                 target_agent_id: "bad_target",
                 fingerprint: "fp_" <> String.duplicate("a", 16),
                 child_pid: self(),
                 owner_pid: self()
               }
             ])

    assert {:error, :invalid_inventory} = IntentCore.rebind_owners(%{}, :not_a_list)
  end

  test "security regression: rebind_owners fails closed on duplicate target last-wins" do
    fp = "fp_" <> String.duplicate("b", 16)

    snaps = [
      %{
        intent_id: "rai_1",
        target_agent_id: @target,
        fingerprint: fp,
        child_pid: self(),
        owner_pid: self()
      },
      %{
        intent_id: "rai_2",
        target_agent_id: @target,
        fingerprint: fp,
        child_pid: self(),
        owner_pid: self()
      }
    ]

    # Must not overwrite the first owner with the second.
    assert {:error, :duplicate_target} = IntentCore.rebind_owners(%{}, snaps)
  end

  test "security regression: rebind_owners fails closed on duplicate intent_id" do
    fp = "fp_" <> String.duplicate("c", 16)

    snaps = [
      %{
        intent_id: "rai_same",
        target_agent_id: "agent_target_a",
        fingerprint: fp,
        child_pid: self(),
        owner_pid: self()
      },
      %{
        intent_id: "rai_same",
        target_agent_id: "agent_target_b",
        fingerprint: fp,
        child_pid: self(),
        owner_pid: self()
      }
    ]

    assert {:error, :duplicate_intent_id} = IntentCore.rebind_owners(%{}, snaps)
  end

  test "security regression: rebind_owners fails closed on inventory overflow" do
    fp = "fp_" <> String.duplicate("d", 16)

    snaps =
      for i <- 1..257 do
        %{
          intent_id: "rai_#{i}",
          target_agent_id: "agent_t#{i}",
          fingerprint: fp,
          child_pid: self(),
          owner_pid: self()
        }
      end

    assert {:error, :inventory_overflow} = IntentCore.rebind_owners(%{}, snaps)
  end

  test "security regression: rebind_owners rejects non-empty base map" do
    fp = "fp_" <> String.duplicate("e", 16)

    assert {:error, :invalid_inventory} =
             IntentCore.rebind_owners(%{"agent_x" => %{}}, [
               %{
                 intent_id: "rai_1",
                 target_agent_id: @target,
                 fingerprint: fp,
                 child_pid: self(),
                 owner_pid: self()
               }
             ])
  end

  test "begin_settling retains terminal and first-wins; ownerless finalizes" do
    {:ok, :admitted, _, intents, _} =
      IntentCore.admit(%{}, %{}, true, true, @target, @fp_a, "rai_1", 0, 10)

    assert {:ok, :ownerless_finalize, done, mid, _} =
             IntentCore.begin_settling(intents, @target, "rai_1", {:error, :x})

    assert done.phase == :settling
    assert done.terminal == {:error, :x}
    assert IntentCore.non_idle?(mid, @target)

    assert {:ok, finished, cleared} = IntentCore.finalize_ownerless(mid, @target, "rai_1")
    assert finished.terminal == {:error, :x}
    refute IntentCore.non_idle?(cleared, @target)

    # With owner: begin keeps non-idle until finalize_settled on exact barrier.
    {:ok, :admitted, _, intents2, _} =
      IntentCore.admit(%{}, %{}, true, true, @target, @fp_a, "rai_2", 0, 10)

    ref2 = make_ref()
    {:ok, _, launching2} = IntentCore.begin_owner_launch(intents2, @target, ref2, 1)

    {:ok, _, bound2} =
      IntentCore.bind_launch_owner(launching2, @target, "rai_2", @fp_a, ref2, self())

    {:ok, :adopted, _, live} =
      IntentCore.adopt_owner(bound2, %{}, true, true, @target, "rai_2", @fp_a, self())

    assert {:ok, :begin, settling, mid2, [{:shutdown_owner, owner}]} =
             IntentCore.begin_settling(live, @target, "rai_2", {:applied, self()})

    assert owner == self()
    assert settling.phase == :settling
    assert settling.retire_barrier == :await_owner_down
    assert IntentCore.non_idle?(mid2, @target)

    assert {:ok, :already_settling, same, ^mid2, []} =
             IntentCore.begin_settling(mid2, @target, "rai_2", {:error, :second})

    assert same.terminal == {:applied, self()}

    # Legacy settle must not bypass live-owner barrier.
    assert {:error, :owner_barrier_outstanding} =
             IntentCore.settle(mid2, @target, "rai_2", {:error, :bypass})

    assert {:ok, finished2, cleared2} = IntentCore.finalize_settled(mid2, @target, "rai_2")
    assert finished2.terminal == {:applied, self()}
    refute IntentCore.non_idle?(cleared2, @target)

    # finalize_settled rejects ownerless barrier.
    {:ok, :admitted, _, intents3, _} =
      IntentCore.admit(%{}, %{}, true, true, @target, @fp_a, "rai_3", 0, 10)

    {:ok, :ownerless_finalize, _, mid3, _} =
      IntentCore.begin_settling(intents3, @target, "rai_3", {:error, :y})

    assert {:error, :barrier_mismatch} = IntentCore.finalize_settled(mid3, @target, "rai_3")
  end

  test "admit rejects settling and await_worker_down barriers without join" do
    settling = %{
      intent_id: "rai_1",
      target_agent_id: @target,
      kind: :ordinary_start,
      fingerprint: @fp_a,
      phase: :settling,
      owner_pid: self(),
      worker_pid: nil,
      terminal: {:error, :x},
      retire_barrier: :await_owner_down
    }

    assert {:error, :settling} =
             IntentCore.admit(
               %{@target => settling},
               %{},
               true,
               true,
               @target,
               @fp_a,
               "rai_2",
               1,
               10
             )

    await = %{
      intent_id: "rai_1",
      target_agent_id: @target,
      kind: :ordinary_start,
      fingerprint: @fp_a,
      phase: :outcome_unknown,
      owner_pid: nil,
      worker_pid: self(),
      terminal: nil,
      retire_barrier: :await_worker_down
    }

    assert {:error, :settling} =
             IntentCore.admit(
               %{@target => await},
               %{},
               true,
               true,
               @target,
               @fp_a,
               "rai_2",
               1,
               10
             )
  end

  test "note_owner_gone_await_worker keeps worker and kill effect" do
    worker = spawn(fn -> :ok end)
    owner = self()

    intent = %{
      intent_id: "rai_1",
      target_agent_id: @target,
      kind: :ordinary_start,
      fingerprint: @fp_a,
      phase: :worker_running,
      owner_pid: owner,
      worker_pid: worker,
      terminal: nil,
      retire_barrier: :none
    }

    assert {:ok, updated, intents, [{:kill_worker, ^worker}]} =
             IntentCore.note_owner_gone_await_worker(
               %{@target => intent},
               @target,
               "rai_1",
               owner
             )

    assert updated.phase == :outcome_unknown
    assert updated.retire_barrier == :await_worker_down
    assert updated.owner_pid == nil
    assert updated.worker_pid == worker
    assert IntentCore.non_idle?(intents, @target)

    # Late authenticate still accepts exact worker.
    assert :ok =
             IntentCore.authenticate_worker(intents, @target, "rai_1", @fp_a, worker)

    assert IntentCore.settle_eligible_worker?(updated, worker)
  end

  test "security regression: stale owner DOWN does not clear or retire rebound owner" do
    old_owner = spawn(fn -> Process.sleep(60_000) end)
    new_owner = self()
    worker = spawn(fn -> :ok end)

    intent = %{
      intent_id: "rai_1",
      target_agent_id: @target,
      kind: :ordinary_start,
      fingerprint: @fp_a,
      phase: :worker_running,
      owner_pid: new_owner,
      worker_pid: worker,
      terminal: nil,
      retire_barrier: :none
    }

    intents = %{@target => intent}

    assert {:error, :stale_owner} =
             IntentCore.note_owner_gone_await_worker(intents, @target, "rai_1", old_owner)

    assert {:error, :stale_owner} =
             IntentCore.commit_terminal_owner_gone(
               intents,
               @target,
               "rai_1",
               old_owner,
               {:error, :owner_down}
             )

    # Rebound owner still present and non-idle.
    assert intents[@target].owner_pid == new_owner
    assert IntentCore.non_idle?(intents, @target)

    # Settling barrier finalize also rejects stale owner.
    {:ok, :begin, _, settling, _} =
      IntentCore.begin_settling(intents, @target, "rai_1", {:error, :t})

    assert {:error, :stale_owner} =
             IntentCore.finalize_settled(settling, @target, "rai_1", old_owner)

    assert {:ok, _done, cleared} =
             IntentCore.finalize_settled(settling, @target, "rai_1", new_owner)

    refute IntentCore.non_idle?(cleared, @target)
  end

  test "commit_terminal_owner_gone is pure owner-clear + terminal commit" do
    owner = self()

    intent = %{
      intent_id: "rai_1",
      target_agent_id: @target,
      kind: :ordinary_start,
      fingerprint: @fp_a,
      phase: :worker_running,
      owner_pid: owner,
      worker_pid: nil,
      terminal: nil,
      retire_barrier: :none
    }

    assert {:ok, updated, mid} =
             IntentCore.commit_terminal_owner_gone(
               %{@target => intent},
               @target,
               "rai_1",
               owner,
               {:applied, self()}
             )

    assert updated.owner_pid == nil
    assert updated.phase == :settling
    assert updated.terminal == {:applied, self()}
    assert updated.retire_barrier == :none

    assert {:ok, done, cleared} = IntentCore.finalize_ownerless(mid, @target, "rai_1")
    assert done.terminal == {:applied, self()}
    refute IntentCore.non_idle?(cleared, @target)
  end

  test "retry predicates are narrow allowlists" do
    assert IntentCore.retryable_adopt_error?(:runtime_admission_not_ready)
    assert IntentCore.retryable_adopt_error?(:fence_not_ready)
    assert IntentCore.retryable_adopt_error?(:store_restart)
    assert IntentCore.retryable_adopt_error?(:owner_not_bound)
    assert IntentCore.retryable_launcher_failure?(:max_children)
    assert IntentCore.retryable_launcher_failure?(:launcher_exit)
    assert IntentCore.retryable_launcher_failure?(:store_restart)
    assert IntentCore.retryable_launcher_failure?({:launch_bind_failed, :timeout})
    assert IntentCore.retryable_launcher_failure?({:launch_bind_failed, :store_restart})
    assert IntentCore.retryable_launcher_failure?({:launch_bind_failed, :bind_exit})
    assert IntentCore.retryable_launcher_failure?({:error, :max_children})
    refute IntentCore.retryable_launcher_failure?(:target_owner_taken)
    refute IntentCore.retryable_launcher_failure?({:launch_bind_failed, :missing_launch_ref})
    refute IntentCore.retryable_adopt_error?(:conflict)
    refute IntentCore.retryable_adopt_error?(:target_fenced)

    assert IntentCore.retryable_launch_failure?(:store_restart)
    assert IntentCore.retryable_launch_failure?(:max_children)
    assert IntentCore.retryable_launch_failure?(:timeout)
    assert IntentCore.retryable_launch_failure?({:task_supervisor_transient, :max_children})
    refute IntentCore.retryable_launch_failure?({:task_supervisor_transient, :already_started})
    refute IntentCore.retryable_launch_failure?(:not_owner)
    refute IntentCore.retryable_launch_failure?({:bind_failed, :conflict})
    refute IntentCore.retryable_launch_failure?({:launch_failed, :anything})

    assert IntentCore.classify_start_child_error(:max_children) == :max_children
    assert IntentCore.classify_start_child_error({:already_started, self()}) == :already_started
    assert IntentCore.redact_error_reason(String.duplicate("x", 100)) |> String.length() <= 64
  end

  test "classify_live_down never parks" do
    assert {:settle, {:error, :worker_down}} =
             IntentCore.classify_live_down("rai_1", :not_running, :worker)

    assert {:settle, {:conflict, :witness_mismatch}} =
             IntentCore.classify_live_down("rai_1", :bare, :worker)

    assert {:settle, {:applied, pid}} =
             IntentCore.classify_live_down("rai_1", {:exact, "rai_1"}, :worker, self())

    assert pid == self()
  end

  test "security regression: finalize_ownerless rejects live owner; settle ownerless only" do
    {:ok, :admitted, _, intents, _} =
      IntentCore.admit(%{}, %{}, true, true, @target, @fp_a, "rai_1", 0, 10)

    ref = make_ref()
    {:ok, _, launching} = IntentCore.begin_owner_launch(intents, @target, ref, 1)

    {:ok, _, bound} =
      IntentCore.bind_launch_owner(launching, @target, "rai_1", @fp_a, ref, self())

    {:ok, :adopted, _, live} =
      IntentCore.adopt_owner(bound, %{}, true, true, @target, "rai_1", @fp_a, self())

    {:ok, :begin, _, settling, _} =
      IntentCore.begin_settling(live, @target, "rai_1", {:error, :x})

    assert {:error, :owner_barrier_outstanding} =
             IntentCore.finalize_ownerless(settling, @target, "rai_1")

    assert {:error, :owner_barrier_outstanding} =
             IntentCore.settle(settling, @target, "rai_1", {:error, :y})

    # Ownerless settle still works.
    {:ok, :admitted, _, intents2, _} =
      IntentCore.admit(%{}, %{}, true, true, @target, @fp_a, "rai_2", 0, 10)

    assert {:ok, done, cleared} =
             IntentCore.settle(intents2, @target, "rai_2", {:error, :z})

    assert done.terminal == {:error, :z}
    refute IntentCore.non_idle?(cleared, @target)
  end
end
