defmodule Arbor.Shell.AppleContainerUnitRecoveryReconcilerCoreTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Arbor.Shell.AppleContainerUnitRecoveryReconcilerCore, as: Core

  @moduletag :fast

  @hex32 String.duplicate("a", 32)
  @unit_name "arbor-v1-#{@hex32}"
  @token String.duplicate("b", 64)
  @execution_id "exec-recon-1"
  @reserved_at_ms 1_700_000_000_000

  @hex32_b String.duplicate("c", 32)
  @unit_name_b "arbor-v1-#{@hex32_b}"
  @token_b String.duplicate("d", 64)
  @execution_id_b "exec-recon-2"

  defp record(opts \\ []) do
    %{
      unit_name: Keyword.get(opts, :unit_name, @unit_name),
      execution_id: Keyword.get(opts, :execution_id, @execution_id),
      token: Keyword.get(opts, :token, @token),
      reserved_at_ms: Keyword.get(opts, :reserved_at_ms, @reserved_at_ms)
    }
  end

  defp wire(record) do
    %{
      "unit_name" => record.unit_name,
      "execution_id" => record.execution_id,
      "token" => record.token,
      "reserved_at_ms" => record.reserved_at_ms
    }
  end

  defp same_identity_map?(nil, _r), do: false

  defp same_identity_map?(worker, r) do
    worker.unit_name == r.unit_name and worker.token == r.token and
      worker.execution_id == r.execution_id and worker.reserved_at_ms == r.reserved_at_ms
  end

  describe "new/0" do
    test "starts closed and requests journal load" do
      assert {:ok, state, [{:load_journal}]} = Core.new()
      assert state.phase == :closed
      assert state.awaiting_journal
      assert state.workers == %{}
      refute Core.ready?(state)
    end
  end

  describe "startup barrier" do
    test "empty journal becomes ready" do
      {:ok, state, _} = Core.new()
      assert {:ok, state, effects} = Core.apply_journal_ok(state, [])
      assert state.phase == :ready
      assert Core.ready?(state)
      assert effects == []
    end

    test "nonempty journal admits unduplicated starts" do
      {:ok, state, _} = Core.new()
      r1 = record()
      r2 = record(unit_name: @unit_name_b, token: @token_b, execution_id: @execution_id_b)

      assert {:ok, state, effects} = Core.apply_journal_ok(state, [wire(r1), wire(r2)])
      assert state.phase == :startup
      refute Core.ready?(state)
      assert length(effects) == 2
      assert Enum.all?(effects, &match?({:start_worker, _}, &1))
      assert map_size(state.workers) == 2
    end

    test "journal error is not empty and schedules bounded generation-tagged retry" do
      {:ok, state, _} = Core.new()
      gen = state.generation

      assert {:ok, state, [{:retry_after, 50, :load_journal, ^gen}]} =
               Core.apply_journal_error(state, :journal_disabled)

      assert state.phase == :closed
      refute Core.ready?(state)
      assert state.journal_retry_ms == 100

      assert {:ok, state, [{:retry_after, 100, :load_journal, ^gen}]} =
               Core.apply_journal_error(state, :poisoned)

      assert state.journal_retry_ms == 200
    end

    test "ready only after empty re-read and no workers" do
      {:ok, state, _} = Core.new()
      r = record()
      {:ok, state, [{:start_worker, _}]} = Core.apply_journal_ok(state, [wire(r)])

      worker_pid = self()
      receipt_ref = make_ref()
      {:ok, state, []} = Core.worker_started(state, r, worker_pid, receipt_ref)

      # Receipt alone does not settle.
      {:ok, state, [{:verify_settlements}]} =
        Core.apply_worker_receipt(state, worker_pid, @unit_name, receipt_ref)

      # Still present -> no settle.
      {:ok, state, effects} = Core.apply_verify_result(state, [wire(r)])
      refute Enum.any?(effects, &match?({:notify_entry_complete, _, _, _}, &1))
      assert map_size(state.workers) == 1

      # Absent while worker_pid is still live -> retain (receipt without DOWN).
      {:ok, state, effects} = Core.apply_verify_result(state, [])
      refute Enum.any?(effects, &match?({:notify_entry_complete, _, _, _}, &1))
      assert map_size(state.workers) == 1
      refute state.phase == :ready

      # Exact DOWN clears worker_pid; still-absent verify settles and promotes ready.
      {:ok, state, [{:verify_settlements}]} = Core.apply_worker_down(state, worker_pid)
      {:ok, state, effects} = Core.apply_verify_result(state, [])
      assert state.phase == :ready
      assert state.workers == %{}
      assert effects == []
    end
  end

  describe "dedupe and identity" do
    test "exact identity is deduped on re-admit" do
      {:ok, state, _} = Core.new()
      r = record()
      {:ok, state, [{:start_worker, _}]} = Core.apply_journal_ok(state, [wire(r)])
      {:ok, state, []} = Core.worker_started(state, r, self(), make_ref())

      assert {:ok, state, effects} = Core.apply_journal_ok(state, [wire(r)])
      refute Enum.any?(effects, &match?({:start_worker, _}, &1))
      assert map_size(state.workers) == 1
    end

    test "identity mismatch on recover_entry fails closed" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      r = record()
      other = record(token: String.duplicate("e", 64))

      {:ok, state, [{:start_worker, _}]} =
        Core.request_recover_entry(state, r, self(), make_ref())

      assert {:error, :identity_mismatch} =
               Core.request_recover_entry(state, other, self(), make_ref())
    end

    test "reserved_at_ms is part of exact identity" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      r = record()
      other = record(reserved_at_ms: @reserved_at_ms + 1)

      {:ok, state, [{:start_worker, _}]} =
        Core.request_recover_entry(state, r, self(), make_ref())

      assert {:error, :identity_mismatch} =
               Core.request_recover_entry(state, other, self(), make_ref())
    end
  end

  describe "coordinator requests" do
    test "rejects before ready" do
      {:ok, state, _} = Core.new()

      assert {:error, :reconciler_not_ready} =
               Core.request_recover_entry(state, record(), self(), make_ref())

      assert {:error, :reconciler_not_ready} =
               Core.request_recover_all(state, self(), make_ref())
    end

    test "recover_entry admits start and notifies after absence" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      r = record()
      caller = self()
      req_ref = make_ref()

      assert {:ok, state, [{:start_worker, started}]} =
               Core.request_recover_entry(state, r, caller, req_ref)

      assert started.unit_name == @unit_name
      assert state.phase == :recovering

      worker_pid = self()
      wref = make_ref()
      {:ok, state, []} = Core.worker_started(state, r, worker_pid, wref)

      {:ok, state, [{:verify_settlements}]} =
        Core.apply_worker_receipt(state, worker_pid, @unit_name, wref)

      # Receipt + empty journal must not settle while worker_pid is live.
      assert {:ok, state, effects} = Core.apply_verify_result(state, [])
      refute Enum.any?(effects, &match?({:notify_entry_complete, _, _, _}, &1))
      assert map_size(state.workers) == 1
      assert length(state.pending_entry_requests) == 1

      {:ok, state, [{:verify_settlements}]} = Core.apply_worker_down(state, worker_pid)
      assert {:ok, state, effects} = Core.apply_verify_result(state, [])

      assert {:notify_entry_complete, ^caller, @unit_name, ^req_ref} =
               Enum.find(effects, &match?({:notify_entry_complete, _, _, _}, &1))

      assert state.phase == :ready
    end

    test "recover_all loads journal and notifies when empty" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      caller = self()
      req_ref = make_ref()

      assert {:ok, state, [{:load_journal}]} =
               Core.request_recover_all(state, caller, req_ref)

      r = record()
      {:ok, state, [{:start_worker, _}]} = Core.apply_journal_ok(state, [wire(r)])
      worker_pid = self()
      wref = make_ref()
      {:ok, state, []} = Core.worker_started(state, r, worker_pid, wref)

      {:ok, state, [{:verify_settlements}]} =
        Core.apply_worker_receipt(state, worker_pid, @unit_name, wref)

      assert {:ok, state, effects} = Core.apply_verify_result(state, [])
      refute Enum.any?(effects, &match?({:notify_all_complete, _, _}, &1))
      assert map_size(state.workers) == 1

      {:ok, state, [{:verify_settlements}]} = Core.apply_worker_down(state, worker_pid)
      assert {:ok, state, effects} = Core.apply_verify_result(state, [])

      assert {:notify_all_complete, ^caller, ^req_ref} =
               Enum.find(effects, &match?({:notify_all_complete, _, _}, &1))

      assert state.phase == :ready
    end
  end

  describe "receipt matching and worker down" do
    test "forged receipts never settle" do
      {:ok, state, _} = Core.new()
      r = record()
      {:ok, state, [{:start_worker, _}]} = Core.apply_journal_ok(state, [wire(r)])
      wref = make_ref()
      {:ok, state, []} = Core.worker_started(state, r, self(), wref)

      assert {:ok, state, []} =
               Core.apply_worker_receipt(state, self(), @unit_name, make_ref())

      assert {:ok, state, []} =
               Core.apply_worker_receipt(state, self(), @unit_name_b, wref)

      other_pid = spawn(fn -> :ok end)

      assert {:ok, _state, []} =
               Core.apply_worker_receipt(state, other_pid, @unit_name, wref)
    end

    test "worker down with journal absence settles without receipt" do
      {:ok, state, _} = Core.new()
      r = record()
      {:ok, state, [{:start_worker, _}]} = Core.apply_journal_ok(state, [wire(r)])
      worker_pid = self()
      {:ok, state, []} = Core.worker_started(state, r, worker_pid, make_ref())

      {:ok, state, [{:verify_settlements}]} = Core.apply_worker_down(state, worker_pid)
      {:ok, state, _effects} = Core.apply_verify_result(state, [])
      assert state.workers == %{}
      assert state.phase == :ready
    end

    test "worker down with journal presence restarts with backoff" do
      {:ok, state, _} = Core.new()
      r = record()
      {:ok, state, [{:start_worker, _}]} = Core.apply_journal_ok(state, [wire(r)])
      worker_pid = self()
      {:ok, state, []} = Core.worker_started(state, r, worker_pid, make_ref())

      {:ok, state, [{:verify_settlements}]} = Core.apply_worker_down(state, worker_pid)

      assert {:ok, state, effects} = Core.apply_verify_result(state, [wire(r)])
      gen = state.generation
      assert [{:restart_worker_after, 50, restarted, ^gen}] = effects
      assert restarted.unit_name == @unit_name
      assert restarted.reserved_at_ms == @reserved_at_ms
      assert state.workers[@unit_name].restart_ms == 100
    end
  end

  describe "request idempotency and conflicting refs" do
    test "duplicate exact recover_entry is idempotent" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      r = record()
      ref = make_ref()
      caller = self()

      assert {:ok, state, [{:start_worker, _}]} =
               Core.request_recover_entry(state, r, caller, ref)

      assert length(state.pending_entry_requests) == 1

      assert {:ok, state, []} = Core.request_recover_entry(state, r, caller, ref)
      assert length(state.pending_entry_requests) == 1
    end

    test "conflicting recover_entry ref reuse fails closed" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      r = record()
      other = record(unit_name: @unit_name_b, token: @token_b, execution_id: @execution_id_b)
      ref = make_ref()

      assert {:ok, state, [{:start_worker, _}]} =
               Core.request_recover_entry(state, r, self(), ref)

      assert {:error, :conflicting_request_ref} =
               Core.request_recover_entry(state, other, self(), ref)
    end

    test "settled exact recover_entry replay is idempotent with zero effects" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      r = record()
      ref = make_ref()
      caller = self()

      assert {:ok, state, [{:start_worker, _}]} =
               Core.request_recover_entry(state, r, caller, ref)

      worker_pid = self()
      wref = make_ref()
      {:ok, state, []} = Core.worker_started(state, r, worker_pid, wref)

      {:ok, state, [{:verify_settlements}]} =
        Core.apply_worker_receipt(state, worker_pid, @unit_name, wref)

      # Receipt alone must not settle; DOWN then absent verification settles.
      assert {:ok, state, effects} = Core.apply_verify_result(state, [])
      refute Enum.any?(effects, &match?({:notify_entry_complete, _, _, _}, &1))

      {:ok, state, [{:verify_settlements}]} = Core.apply_worker_down(state, worker_pid)
      assert {:ok, state, effects} = Core.apply_verify_result(state, [])

      assert Enum.any?(effects, &match?({:notify_entry_complete, ^caller, @unit_name, ^ref}, &1))
      assert state.pending_entry_requests == []
      assert length(state.settled_requests) == 1
      assert Core.known_request_ref?(state, ref)

      assert {:ok, ^state, []} = Core.request_recover_entry(state, r, caller, ref)
      assert state.pending_entry_requests == []
      assert length(state.settled_requests) == 1
    end

    test "settled conflicting recover_entry ref reuse fails closed" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      r = record()
      other = record(unit_name: @unit_name_b, token: @token_b, execution_id: @execution_id_b)
      ref = make_ref()
      caller = self()

      assert {:ok, state, [{:start_worker, _}]} =
               Core.request_recover_entry(state, r, caller, ref)

      worker_pid = self()
      wref = make_ref()
      {:ok, state, []} = Core.worker_started(state, r, worker_pid, wref)

      {:ok, state, [{:verify_settlements}]} =
        Core.apply_worker_receipt(state, worker_pid, @unit_name, wref)

      assert {:ok, state, _effects} = Core.apply_verify_result(state, [])
      {:ok, state, [{:verify_settlements}]} = Core.apply_worker_down(state, worker_pid)
      assert {:ok, state, _effects} = Core.apply_verify_result(state, [])
      assert state.pending_entry_requests == []
      assert length(state.settled_requests) == 1

      assert {:error, :conflicting_request_ref} =
               Core.request_recover_entry(state, other, caller, ref)

      other_caller = spawn(fn -> :ok end)

      assert {:error, :conflicting_request_ref} =
               Core.request_recover_entry(state, r, other_caller, ref)
    end

    test "duplicate exact recover_all is idempotent" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      ref = make_ref()
      caller = self()

      assert {:ok, state, [{:load_journal}]} =
               Core.request_recover_all(state, caller, ref)

      assert length(state.pending_all_requests) == 1

      assert {:ok, state, []} = Core.request_recover_all(state, caller, ref)
      assert length(state.pending_all_requests) == 1
    end

    test "conflicting recover_all ref reuse fails closed" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      ref = make_ref()

      assert {:ok, state, [{:load_journal}]} =
               Core.request_recover_all(state, self(), ref)

      other_caller = spawn(fn -> :ok end)

      assert {:error, :conflicting_request_ref} =
               Core.request_recover_all(state, other_caller, ref)
    end

    test "settled exact recover_all replay is idempotent with zero effects" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      ref = make_ref()
      caller = self()

      assert {:ok, state, [{:load_journal}]} =
               Core.request_recover_all(state, caller, ref)

      # Empty journal settles recover_all without admitting workers.
      assert {:ok, state, effects} = Core.apply_journal_ok(state, [])

      assert {:notify_all_complete, ^caller, ^ref} =
               Enum.find(effects, &match?({:notify_all_complete, _, _}, &1))

      assert state.pending_all_requests == []
      assert length(state.settled_requests) == 1
      assert Core.known_request_ref?(state, ref)

      assert {:ok, ^state, []} = Core.request_recover_all(state, caller, ref)
      assert state.pending_all_requests == []
    end

    test "settled conflicting recover_all ref reuse fails closed" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      ref = make_ref()
      caller = self()

      assert {:ok, state, [{:load_journal}]} =
               Core.request_recover_all(state, caller, ref)

      assert {:ok, state, _effects} = Core.apply_journal_ok(state, [])
      assert state.pending_all_requests == []

      other_caller = spawn(fn -> :ok end)

      assert {:error, :conflicting_request_ref} =
               Core.request_recover_all(state, other_caller, ref)

      # Entry kind must not reuse an all-settled receipt ref.
      assert {:error, :conflicting_request_ref} =
               Core.request_recover_entry(state, record(), caller, ref)
    end

    test "settled-request ledger is bounded FIFO and never drops pending" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      limit = Core.settled_request_ledger_limit()
      caller = self()

      # Fill the ledger past capacity with distinct settled recover_all refs.
      state =
        Enum.reduce(1..(limit + 3), state, fn _i, acc ->
          ref = make_ref()
          assert {:ok, acc, [{:load_journal}]} = Core.request_recover_all(acc, caller, ref)
          assert {:ok, acc, effects} = Core.apply_journal_ok(acc, [])
          assert Enum.any?(effects, &match?({:notify_all_complete, ^caller, ^ref}, &1))
          acc
        end)

      assert length(state.settled_requests) == limit
      assert state.pending_all_requests == []
      assert state.pending_entry_requests == []

      # Pending rows stay while settled ages out.
      pending_ref = make_ref()
      r = record()

      assert {:ok, state, [{:start_worker, _}]} =
               Core.request_recover_entry(state, r, caller, pending_ref)

      assert length(state.pending_entry_requests) == 1
      assert length(state.settled_requests) == limit
      assert Core.known_request_ref?(state, pending_ref)
    end
  end

  describe "authorize_launch and consume_retry" do
    test "authorize_launch emits launch_worker only for exact present identity" do
      {:ok, state, _} = Core.new()
      r = record()
      {:ok, state, [{:start_worker, _}]} = Core.apply_journal_ok(state, [wire(r)])

      assert {:ok, _state, [{:launch_worker, launched}]} =
               Core.authorize_launch(state, r, [wire(r)])

      assert launched.unit_name == @unit_name
      assert launched.reserved_at_ms == @reserved_at_ms
    end

    test "authorize_launch settles and does not launch when record removed" do
      {:ok, state, _} = Core.new()
      r = record()
      {:ok, state, [{:start_worker, _}]} = Core.apply_journal_ok(state, [wire(r)])

      assert {:ok, state, effects} = Core.authorize_launch(state, r, [])
      refute Enum.any?(effects, &match?({:launch_worker, _}, &1))
      refute Enum.any?(effects, &match?({:start_worker, _}, &1))
      assert state.workers == %{}
      assert state.phase == :ready
    end

    test "authorize_launch does not launch after same-name replacement" do
      {:ok, state, _} = Core.new()
      r = record()
      {:ok, state, [{:start_worker, _}]} = Core.apply_journal_ok(state, [wire(r)])

      replaced =
        record(
          token: String.duplicate("e", 64),
          execution_id: "exec-replaced",
          reserved_at_ms: @reserved_at_ms + 99
        )

      assert {:ok, _state, effects} = Core.authorize_launch(state, r, [wire(replaced)])
      # Never authorizes impure launch of the stale intended identity.
      refute Enum.any?(effects, &match?({:launch_worker, _}, &1))

      refute Enum.any?(effects, fn
               {:start_worker, rec} -> same_identity_map?(rec, r)
               {:launch_worker, rec} -> same_identity_map?(rec, r)
               _ -> false
             end)
    end

    test "authorize_launch after ready does not admit same-name replacement" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      assert state.phase == :ready

      r = record()

      {:ok, state, [{:start_worker, _}]} =
        Core.request_recover_entry(state, r, self(), make_ref())

      replaced =
        record(
          token: String.duplicate("e", 64),
          execution_id: "exec-replaced",
          reserved_at_ms: @reserved_at_ms + 99
        )

      assert {:ok, state, effects} = Core.authorize_launch(state, r, [wire(replaced)])
      refute Enum.any?(effects, &match?({:launch_worker, _}, &1))
      refute Enum.any?(effects, &match?({:start_worker, _}, &1))
      assert state.workers == %{}
    end

    test "stale consume_retry after ready yields zero effects" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      assert state.phase == :ready
      old_gen = 0
      assert state.generation > old_gen

      r = record()

      assert {:ok, ^state, []} =
               Core.consume_retry(state, old_gen, :load_journal)

      assert {:ok, ^state, []} =
               Core.consume_retry(state, old_gen, {:start_worker, r})

      assert {:ok, ^state, []} =
               Core.consume_retry(state, old_gen, :verify_settlements)
    end

    test "matching consume_retry re-emits start_worker not launch_worker" do
      {:ok, state, _} = Core.new()
      r = record()
      {:ok, state, [{:start_worker, _}]} = Core.apply_journal_ok(state, [wire(r)])
      gen = state.generation

      assert {:ok, _state, [{:start_worker, started}]} =
               Core.consume_retry(state, gen, {:start_worker, r})

      assert started.unit_name == @unit_name
    end
  end

  describe "no autonomous post-ready sweep" do
    test "journal reload after ready does not start new workers" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      assert state.phase == :ready

      r = record()
      # Simulate a verify/reload that sees a new live reservation.
      assert {:ok, state, effects} = Core.apply_verify_result(state, [wire(r)])
      refute Enum.any?(effects, &match?({:start_worker, _}, &1))
      assert state.workers == %{}
      assert state.phase == :ready
    end
  end

  describe "live worker same-name replacement exclusion" do
    test "retains live tracked identity and blocks recover_all same-name admission" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      r = record()
      caller = self()
      entry_ref = make_ref()

      assert {:ok, state, [{:start_worker, _}]} =
               Core.request_recover_entry(state, r, caller, entry_ref)

      worker_pid = spawn(fn -> Process.sleep(60_000) end)
      wref = make_ref()
      {:ok, state, []} = Core.worker_started(state, r, worker_pid, wref)

      replaced =
        record(
          token: String.duplicate("e", 64),
          execution_id: "exec-replaced",
          reserved_at_ms: @reserved_at_ms + 99
        )

      all_ref = make_ref()

      assert {:ok, state, [{:load_journal}]} =
               Core.request_recover_all(state, caller, all_ref)

      # Authoritative journal shows only the replacement under the same unit_name.
      assert {:ok, state, effects} = Core.apply_journal_ok(state, [wire(replaced)])

      refute Enum.any?(effects, &match?({:notify_entry_complete, _, _, _}, &1))
      refute Enum.any?(effects, &match?({:notify_all_complete, _, _}, &1))
      refute Enum.any?(effects, &match?({:start_worker, _}, &1))
      refute Enum.any?(effects, &match?({:launch_worker, _}, &1))

      assert map_size(state.workers) == 1
      assert same_identity_map?(state.workers[@unit_name], r)
      assert state.workers[@unit_name].worker_pid == worker_pid
      assert length(state.pending_entry_requests) == 1
      assert length(state.pending_all_requests) == 1
      assert Process.alive?(worker_pid)

      # Receipt without DOWN still must not free the slot or complete requests.
      {:ok, state, [{:verify_settlements}]} =
        Core.apply_worker_receipt(state, worker_pid, @unit_name, wref)

      assert {:ok, state, effects} = Core.apply_verify_result(state, [wire(replaced)])
      refute Enum.any?(effects, &match?({:notify_entry_complete, _, _, _}, &1))
      refute Enum.any?(effects, &match?({:start_worker, _}, &1))
      assert same_identity_map?(state.workers[@unit_name], r)
      assert state.workers[@unit_name].worker_pid == worker_pid

      # Exact DOWN clears pid; still-absent verification settles old then admits
      # the replacement exactly once under recover_all rules.
      true = Process.exit(worker_pid, :kill)
      {:ok, state, [{:verify_settlements}]} = Core.apply_worker_down(state, worker_pid)
      assert is_nil(state.workers[@unit_name].worker_pid)

      assert {:ok, state, effects} = Core.apply_verify_result(state, [wire(replaced)])

      assert Enum.any?(
               effects,
               &match?({:notify_entry_complete, ^caller, @unit_name, ^entry_ref}, &1)
             )

      start_effects = Enum.filter(effects, &match?({:start_worker, _}, &1))
      assert length(start_effects) == 1
      assert [{:start_worker, started}] = start_effects
      assert same_identity_map?(started, replaced)
      assert same_identity_map?(state.workers[@unit_name], replaced)
      assert state.pending_entry_requests == []
      assert length(state.pending_all_requests) == 1

      # Second verify must not re-admit the same replacement.
      assert {:ok, state, effects2} = Core.apply_verify_result(state, [wire(replaced)])
      refute Enum.any?(effects2, &match?({:start_worker, _}, &1))
      assert same_identity_map?(state.workers[@unit_name], replaced)
    end

    test "authorize_launch with live worker and same-name replacement does not settle" do
      {:ok, state, _} = Core.new()
      r = record()
      {:ok, state, [{:start_worker, _}]} = Core.apply_journal_ok(state, [wire(r)])
      worker_pid = spawn(fn -> Process.sleep(60_000) end)
      {:ok, state, []} = Core.worker_started(state, r, worker_pid, make_ref())

      replaced =
        record(
          token: String.duplicate("e", 64),
          execution_id: "exec-replaced",
          reserved_at_ms: @reserved_at_ms + 99
        )

      assert {:ok, state, effects} = Core.authorize_launch(state, r, [wire(replaced)])
      refute Enum.any?(effects, &match?({:launch_worker, _}, &1))
      refute Enum.any?(effects, &match?({:start_worker, _}, &1))
      refute Enum.any?(effects, &match?({:notify_entry_complete, _, _, _}, &1))
      assert same_identity_map?(state.workers[@unit_name], r)
      assert state.workers[@unit_name].worker_pid == worker_pid

      true = Process.exit(worker_pid, :kill)
    end
  end

  describe "show and purity" do
    test "show exposes only bounded counts" do
      {:ok, state, _} = Core.new()
      {:ok, state, []} = Core.apply_journal_ok(state, [])
      shown = Core.show(state)

      assert shown["phase"] == "ready"
      assert shown["worker_count"] == 0
      refute Map.has_key?(shown, "token")
      refute Map.has_key?(shown, "workers")
    end

    test "reconciler core source contains no impure calls" do
      path =
        Path.expand(
          "../../../lib/arbor/shell/apple_container_unit_recovery_reconciler_core.ex",
          __DIR__
        )

      source = File.read!(path)

      for forbidden <- [
            "File.",
            "System.",
            "Application.",
            "GenServer.",
            ":ets.",
            "Process.",
            "Port.",
            "Logger.",
            "Task.",
            "DateTime.utc_now",
            "make_ref",
            "String.to_atom",
            ":rand.",
            "send(",
            "receive "
          ] do
        refute source =~ forbidden, "reconciler core must not call #{forbidden}"
      end

      refute source =~ "Arbor.Security"
      refute source =~ "Arbor.Actions"
      refute source =~ "PortSession"
      refute source =~ "UnitWorker"
      refute source =~ "DrainCoordinator"
    end
  end
end
