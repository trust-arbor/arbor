defmodule Arbor.Security.AuditRetirementOwnerTest do
  @moduledoc """
  Owner-level acceptance of terminal-identity retirement (Floor-and-Ledger v3,
  slice 3): the T1/T2/T3 triggers, the publication backoff, the paused-ledger
  posture, cutover continuity, partial acknowledgements, a sink outage,
  status and `admission_open` (status-only readiness; never part of the
  qualification policy snapshot).

  New-API tests: on the parent 52a2cc3fa they fail by absence (no test-only
  owner arities, no retirement status, no ledger). The exact-parent
  regressions for the live bug are in
  `audit_retirement_owner_security_regression_test.exs`.

  `async: false`: tests register an audit consumer through Application env,
  swap the registered journal owner, and trace the owner process.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :integration

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security
  alias Arbor.Security.AuditJournalCore, as: Core
  alias Arbor.Security.AuditJournalFileCore, as: FileCore
  alias Arbor.Security.AuditJournalOwner, as: Owner
  alias Arbor.Security.AuditRetirementLedgerCore, as: LedgerCore
  alias Arbor.Security.CapabilityAuditCore
  alias Arbor.Security.Contracts.AuditJournal

  @time "2026-09-28T12:00:00Z"
  @source %{
    "committed_digest" => String.duplicate("ab", 32),
    "committed_frames" => 40,
    "committed_offset" => 100_000
  }
  @retired_event [:arbor, :security, :audit_journal, :retired]
  @failed_event [:arbor, :security, :audit_journal, :publication_failed]
  @paused_event [:arbor, :security, :audit_journal, :ledger_paused]

  setup do
    handler = "audit-retire-owner-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler,
        [@retired_event, @failed_event, @paused_event],
        &__MODULE__.forward_event/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  @doc false
  def forward_event(event, measurements, metadata, pid),
    do: send(pid, {:audit_event, event, measurements, metadata})

  describe "T1 (boot)" do
    test "the live exhausted shape retires at boot and serves a full increase budget" do
      root = unique_root()
      write_journal(root, v2_snapshot(delivered_terminals(1..4096)))
      {name, _pid} = start_owner(root)

      assert [{%{count: 4096, duration_ms: ms}, %{trigger: :boot, ledger_frames: 1}}] =
               drain(@retired_event)

      assert ms >= 0
      status = status!(name)
      assert status["retirement"]["floor"] == 3
      assert status["retirement"]["ledger_state"] == "bound"
      assert status["retirement"]["last_error"] == "none"
      assert status["capacity"]["retained_operation_count"] == 0
      assert status["capacity"]["retired_operation_total"] == 4096
      assert status["capacity"]["remaining_increase_admissions"] == 3072
      assert status["capacity"]["remaining_soft_entries"] == 3071
      assert status["committed_frames"] == 1
    end

    @tag :slow
    test "a transient boot fault serves, backs off, then T3 retires on the first refused grant" do
      root = unique_root()
      write_journal(root, v2_snapshot(delivered_terminals(1..4096)))
      {name, _pid} = start_owner(root, inject: [ledger_write_error: :eio])

      assert [{_, %{trigger: :boot, outcome: :not_published, reason: :ledger_write_failed}}] =
               drain(@failed_event)

      status = status!(name)
      assert status["serving"] == true
      assert status["poisoned"] == false
      assert status["last_error"] == "none"
      assert status["retirement"]["last_error"] == "ledger_write_failed"
      assert status["retirement"]["floor"] == 1
      assert status["capacity"]["retained_operation_count"] == 4096
      # A failed retiring attempt claims no retirement headroom: status and
      # readiness report what the next grant actually meets.
      assert status["capacity"]["retirable_operation_count"] == 4096
      assert status["capacity"]["remaining_increase_admissions"] == 0
      assert status["admission_open"] == false

      # Inside the backoff window T3 does not publish.
      assert {:error, :capacity_exhausted} = Owner.prepare(name, grant(1))
      assert [] = drain(@failed_event)
      assert status!(name)["last_refusal"] == "capacity_exhausted"

      # A persistent fault: after the window the attempt fails again and the
      # grant stays refused (runbook: the storage fault must be fixed).
      wait_backoff()
      assert {:error, :capacity_exhausted} = Owner.prepare(name, grant(2))
      assert [{_, %{trigger: :capacity, reason: :ledger_write_failed}}] = drain(@failed_event)
      assert status!(name)["retirement"]["last_error"] == "ledger_write_failed"

      # The fault clears: the first refused grant after the window retires the
      # 4096 delivered identities and the exact record is admitted.
      :ok = Owner.__test_inject__(name, :clear)
      wait_backoff()
      intent = grant(3)
      assert {:ok, admitted, "prepared"} = Owner.prepare(name, intent)
      assert admitted["operation_id"] == intent["operation_id"]
      assert [{%{count: 4096}, %{trigger: :capacity}}] = drain(@retired_event)

      status = status!(name)
      assert status["retirement"]["floor"] == 3
      assert status["retirement"]["ledger_state"] == "bound"
      assert status["retirement"]["last_error"] == "none"
      assert status["capacity"]["retained_operation_count"] == 1
      assert status["admission_open"] == true
    end

    test "an ambiguous boot publication serves poisoned and never stops the owner" do
      root = unique_root()
      write_journal(root, v2_snapshot(delivered_terminals(1..600)))
      Process.flag(:trap_exit, true)
      {name, pid} = start_owner(root, inject: [compact_dir_sync: :eio])

      assert Process.alive?(pid)

      assert [{_, %{trigger: :boot, outcome: :publish_uncertain, reason: :dir_sync_failed}}] =
               drain(@failed_event)

      status = status!(name)
      assert status["poisoned"] == true
      assert status["serving"] == false
      assert status["last_error"] == "commit_uncertain"
      assert {:error, :journal_poisoned} = Owner.append(name, record(grant(1), "prepared"))

      # The rename landed: a clean restart finds the v3 snapshot and its bound
      # ledger frame.
      {name, _pid} = restart_owner(pid, root)
      status = status!(name)
      assert status["serving"] == true
      assert status["retirement"]["floor"] == 3
      assert status["retirement"]["ledger_state"] == "bound"
      assert status["capacity"]["retired_operation_total"] == 600
    end

    test "a torn-tail journal skips T1 and starts degraded as before" do
      root = unique_root()
      write_journal(root, v2_snapshot(delivered_terminals(1..600)))
      File.write!(journal_path(root), "AJL", [:append])
      {name, _pid} = start_owner(root)

      status = status!(name)
      assert status["torn_tail"] == true
      assert status["serving"] == false
      assert status["retirement"]["floor"] == 1
      assert [] = drain(@retired_event)
      refute File.exists?(ledger_path(root))
    end

    test "a paused ledger at boot is logged once; T1 installs v3 non-retiring and admission is closed" do
      root = unique_root()
      write_journal(root, v2_snapshot(delivered_terminals(1..3)))
      plant_ledger(root, "stale ledger bytes")

      log =
        capture_log([level: :error], fn ->
          {name, _pid} = start_owner(root, name: :audit_retire_paused_boot)
          send(self(), {:started, name})
        end)

      assert_received {:started, name}
      on_exit(fn -> stop_name(name) end)
      assert length(Regex.scan(~r/retirement ledger is ahead/, log)) == 1
      assert [{%{count: 1}, %{ledger_state: :ahead, occasion: :open}}] = drain(@paused_event)

      status = status!(name)
      assert status["retirement"]["floor"] == 3
      assert status["retirement"]["ledger_state"] == "ahead"
      assert status["capacity"]["retired_operation_total"] == 0
      assert status["capacity"]["retirable_operation_count"] == 3
      # Retirement headroom counts as zero while paused.
      assert status["capacity"]["remaining_increase_admissions"] == 3072 - 3
      assert File.read!(ledger_path(root)) == "stale ledger bytes"

      refute admission_open?(name)
    end
  end

  describe "T3 (capacity relief)" do
    test "the capacity-error retry admits the caller's exact record and operation id" do
      root = unique_root()
      write_journal(root, v3_snapshot(rejected_terminals(1..2561), delivered_terminals(1..511)))
      {name, _pid} = start_owner(root)
      assert [] = drain(@retired_event)
      assert status!(name)["capacity"]["retained_operation_count"] == 3072

      intent = producer_grant("cap_" <> String.duplicate("e", 32))
      assert {:ok, admitted, "prepared"} = Owner.prepare(name, intent)
      assert admitted == intent
      assert [{%{count: 511}, %{trigger: :capacity}}] = drain(@retired_event)

      assert {:ok, pending} = Owner.pending_operations(name)
      assert Enum.map(pending, & &1["operation_id"]) == [intent["operation_id"]]
      status = status!(name)
      assert status["capacity"]["retained_operation_count"] == 2562
      assert status["capacity"]["retired_operation_total"] == 511
      assert status["retirement"]["ledger_frames"] == 1
      assert status["last_refusal"] == "none"
    end

    test "partial acknowledgements retire exactly the acknowledged operations" do
      root = unique_root()
      register_consumer!()
      write_journal(root, v3_snapshot(rejected_terminals(1..3052), %{}))
      {name, _pid} = start_owner(root)

      intents = for n <- 1..20, do: grant(n)
      Enum.each(intents, &apply!(name, &1))
      {acked, rest} = Enum.split(intents, 7)
      Enum.each(acked, &ack!(name, &1))
      assert status!(name)["capacity"]["retirable_operation_count"] == 7
      assert [] = drain(@retired_event)

      # The 3073rd retained identity is refused by capacity; the relief retires
      # exactly the 7 delivered operations and admits the retry.
      assert {:ok, _, "prepared"} = Owner.prepare(name, grant(100))
      assert [{%{count: 7}, %{trigger: :capacity}}] = drain(@retired_event)

      assert {:ok, batch} = Owner.delivery_batch(name)

      assert Enum.map(batch, & &1["operation_id"]) ==
               Enum.sort(Enum.map(rest, & &1["operation_id"]))

      assert [frame] = decode_ledger(root)
      retired = frame.batch["retired"]
      assert Enum.sort(Map.keys(retired)) == Enum.sort(Enum.map(acked, & &1["operation_id"]))

      for intent <- acked do
        [status, class, intent_sha | _] = String.split(retired[intent["operation_id"]], "|")
        assert status == "delivered"
        assert class == "authority_increase"
        assert intent_sha == digest(intent)
      end

      assert status!(name)["capacity"]["retired_operation_total"] == 7

      # The second acknowledgement round retires the rest at the next relief.
      Enum.each(rest, &ack!(name, &1))

      Enum.reduce_while(101..120, nil, fn n, _ ->
        assert {:ok, _, "prepared"} = Owner.prepare(name, grant(n))
        if drain(@retired_event) == [], do: {:cont, nil}, else: {:halt, :ok}
      end)

      assert status!(name)["capacity"]["retired_operation_total"] == 20
      assert length(decode_ledger(root)) == 2
    end

    @tag :slow
    test "the publication backoff allows one attempt per 5 s window under a ledger fault" do
      root = unique_root()
      write_journal(root, v3_snapshot(rejected_terminals(1..2561), delivered_terminals(1..511)))
      {name, _pid} = start_owner(root)
      :ok = Owner.__test_inject__(name, :ledger_write_error, :eio)

      assert {:error, :soft_capacity_exhausted} = Owner.prepare(name, grant(1))
      assert [{_, %{trigger: :capacity, reason: :ledger_write_failed}}] = drain(@failed_event)

      # Within the window: refused without a publication attempt.
      assert {:error, :soft_capacity_exhausted} = Owner.prepare(name, grant(2))
      assert [] = drain(@failed_event)
      assert status!(name)["retirement"]["last_error"] == "ledger_write_failed"
      assert status!(name)["last_refusal"] == "soft_capacity_exhausted"

      :ok = Owner.__test_inject__(name, :clear)
      wait_backoff()
      assert {:ok, _, "prepared"} = Owner.prepare(name, grant(3))
      assert [{%{count: 511}, %{trigger: :capacity}}] = drain(@retired_event)
      assert status!(name)["retirement"]["last_error"] == "none"
    end

    test "a ledger proven short on a live handle pauses it; the restart reports :mismatch once" do
      root = unique_root()
      register_consumer!()
      # T1 retires 5 delivered identities into ledger frame 1 at boot.
      write_journal(
        root,
        v2_snapshot(Map.merge(rejected_terminals(1..3066), delivered_terminals(1..5)))
      )

      {name, pid} = start_owner(root)
      assert [{%{count: 5}, %{trigger: :boot}}] = drain(@retired_event)
      assert status!(name)["retirement"]["ledger_state"] == "bound"

      Enum.each(1..6, &lifecycle!(name, grant(&1)))
      assert status!(name)["capacity"]["retained_operation_count"] == 3072

      # The next retiring append truncates below the bound and fails: the live
      # handle proves the ledger short, pauses, and publishes non-retiring.
      :ok = Owner.__test_inject__(name, :ledger_truncate_below_bound)

      log =
        capture_log([level: :error], fn ->
          assert {:error, :soft_capacity_exhausted} = Owner.prepare(name, grant(50))
        end)

      :ok = Owner.__test_inject__(name, :clear)
      assert log =~ "retirement ledger is mismatch"
      assert [{_, %{ledger_state: :mismatch, occasion: :publication}}] = drain(@paused_event)
      # The same call published non-retiring (nothing retired, binding kept).
      assert [{%{count: 0}, %{trigger: :capacity, ledger_state: :mismatch, ledger_frames: 1}}] =
               drain(@retired_event)

      status = status!(name)
      assert status["serving"] == true
      assert status["retirement"]["ledger_state"] == "mismatch"
      assert status["capacity"]["retirable_operation_count"] == 6
      assert status["capacity"]["remaining_increase_admissions"] == 0
      assert status["last_refusal"] == "soft_capacity_exhausted"
      # Every attempt while paused arms the backoff.
      assert Owner.prepare(name, grant(51)) == {:error, :soft_capacity_exhausted}
      assert [] = drain(@failed_event) ++ drain(@retired_event)

      log =
        capture_log([level: :error], fn ->
          {restarted, _pid} = restart_owner(pid, root, name: :audit_retire_mismatch_restart)
          send(self(), {:restarted, restarted})
        end)

      assert_received {:restarted, restarted}
      on_exit(fn -> stop_name(restarted) end)
      assert length(Regex.scan(~r/retirement ledger is mismatch \(open\)/, log)) == 1
      assert [{_, %{ledger_state: :mismatch, occasion: :open}}] = drain(@paused_event)
      assert status!(restarted)["retirement"]["ledger_state"] == "mismatch"

      refute admission_open?(restarted)
    end

    test "under a paused ledger the 4096-retained endpoint refuses reductions instead of retiring" do
      terminals = v3_snapshot(rejected_terminals(1..3585), delivered_terminals(1..511))

      # Paused: no retirement headroom, no relief, the reduction is refused.
      paused_root = unique_root()
      write_journal(paused_root, terminals)
      plant_ledger(paused_root, "stale ledger bytes")
      {paused, _pid} = start_owner(paused_root)
      before = status!(paused)
      assert {:error, :capacity_exhausted} = Owner.prepare(paused, revoke_intent(3, 1))
      assert status!(paused)["committed_frames"] == before["committed_frames"]
      assert status!(paused)["last_refusal"] == "capacity_exhausted"
      assert [] = drain(@retired_event)

      # The same bytes with a healthy ledger retire and admit the reduction.
      root = unique_root()
      write_journal(root, terminals)
      {healthy, _pid} = start_owner(root)
      assert {:ok, _, "prepared"} = Owner.prepare(healthy, revoke_intent(3, 1))
      assert [{%{count: 511}, _}] = drain(@retired_event)
    end
  end

  describe "T2 (acknowledgement)" do
    test "the triggering acknowledgement returns before the publication; the next one waits" do
      root = unique_root()
      register_consumer!()
      write_journal(root, v3_snapshot(%{}, delivered_terminals(1..511)))
      {name, _pid} = start_owner(root)
      [first, second] = [grant(1), grant(2)]
      apply!(name, first)
      apply!(name, second)
      :ok = Owner.__test_inject__(name, :ledger_append_delay, 1_500)

      {first_us, first_reply} = :timer.tc(fn -> ack(name, first) end)
      {second_us, second_reply} = :timer.tc(fn -> ack(name, second) end)
      :ok = Owner.__test_inject__(name, :clear)

      assert first_reply == {:ok, :committed}
      assert second_reply == {:ok, :committed}
      assert div(first_us, 1000) < 500
      assert div(second_us, 1000) >= 1_000
      assert [{%{count: 512, duration_ms: ms}, %{trigger: :acknowledge}}] = drain(@retired_event)
      assert ms >= 1_500

      status = status!(name)
      assert status["capacity"]["retired_operation_total"] == 512
      assert status["capacity"]["retirable_operation_count"] == 1
    end

    test "a persistent fault re-arms T2 once per retire_batch acknowledgements" do
      root = unique_root()
      register_consumer!()
      write_journal(root, v3_snapshot(%{}, delivered_terminals(1..511)))
      {name, pid} = start_owner(root)
      :ok = Owner.__test_inject__(name, :ledger_write_error, :eio)

      lifecycle!(name, grant(1))
      # T2 runs after the acknowledgement's reply; a call queued behind it
      # returns only once the attempt is over.
      _ = status!(name)
      assert [{_, %{trigger: :acknowledge, reason: :ledger_write_failed}}] = drain(@failed_event)
      assert :sys.get_state(pid).t2_armed_at == 512 + 512

      Enum.each(2..4, &lifecycle!(name, grant(&1)))
      _ = status!(name)
      assert [] = drain(@failed_event)
      assert status!(name)["retirement"]["last_error"] == "ledger_write_failed"
      assert status!(name)["capacity"]["retirable_operation_count"] == 515
    end

    test "T2 is skipped inside an active publication backoff window" do
      root = unique_root()
      register_consumer!()
      write_journal(root, v3_snapshot(%{}, delivered_terminals(1..511)))
      {name, pid} = start_owner(root)
      assert :sys.get_state(pid).t2_armed_at == 512

      # A window armed by an earlier unpublished attempt. Every real arming
      # path also re-arms T2 at retirable + 512, so the window is set directly
      # to pin the skip itself.
      set_backoff(pid, 60_000)
      lifecycle!(name, grant(1))
      _ = status!(name)
      assert [] = drain(@retired_event) ++ drain(@failed_event)
      assert status!(name)["capacity"]["retirable_operation_count"] == 512

      # Once the window has lapsed the next acknowledgement publishes.
      set_backoff(pid, -1)
      lifecycle!(name, grant(2))
      _ = status!(name)
      assert [{%{count: 513}, %{trigger: :acknowledge}}] = drain(@retired_event)
    end

    @tag :slow
    @tag timeout: 900_000
    test "sustained distinct v3 lifecycles beyond 4096 with immediate acknowledgements" do
      root = unique_root()
      register_consumer!()
      {name, _pid} = start_owner(root)
      total = 10 * 512

      max_retained =
        Enum.reduce(1..total, 0, fn n, max_retained ->
          intent = grant(n)
          assert {:ok, _, "prepared"} = Owner.prepare(name, intent)
          assert {:ok, :committed} = Owner.observe(name, intent["operation_id"], :applied)
          assert {:ok, [item]} = Owner.delivery_batch(name)

          assert {:ok, :committed} =
                   Owner.acknowledge_delivery(name, item["operation_id"], item["intent_sha256"])

          status = status!(name)
          retained = status["capacity"]["retained_operation_count"]
          assert retained <= 512 + status["pending_count"]
          max(max_retained, retained)
        end)

      publications = drain(@retired_event)
      durations = publications |> Enum.map(fn {m, _} -> m.duration_ms end) |> Enum.sort()
      p99 = Enum.at(durations, max(0, ceil(length(durations) * 0.99) - 1))

      IO.puts(
        "\n[audit retirement sustained] lifecycles=#{total} publications=#{length(publications)} " <>
          "max_retained=#{max_retained} publication_ms=#{inspect(durations)} p99_ms=#{p99}"
      )

      assert length(publications) == div(total, 512)

      assert Enum.all?(publications, fn {m, meta} ->
               m.count == 512 and meta.trigger == :acknowledge
             end)

      assert p99 < 5_000

      status = status!(name)
      assert status["capacity"]["retired_operation_total"] == total
      assert status["capacity"]["retained_operation_count"] == 0
      assert status["retirement"]["ledger_frames"] == div(total, 512)
      assert status["retirement"]["ledger_state"] == "bound"
      assert status["last_refusal"] == "none"
      assert File.stat!(journal_path(root)).size < 1_000_000
    end
  end

  describe "sink outage" do
    @tag :slow
    @tag timeout: 600_000
    test "without acknowledgements pending grows until the entry clause refuses; acknowledging reopens admission" do
      root = unique_root()
      {name, _pid} = start_owner(root)
      assert admission_open?(name)

      applied =
        Enum.reduce_while(1..1400, [], fn n, acc ->
          intent = grant(n)

          case Owner.prepare(name, intent) do
            {:ok, _, "prepared"} ->
              {:ok, :committed} = Owner.observe(name, intent["operation_id"], :applied)
              {:cont, [intent | acc]}

            {:error, :soft_capacity_exhausted} ->
              {:halt, Enum.reverse(acc)}
          end
        end)

      assert length(applied) in 1020..1025
      assert [] = drain(@retired_event) ++ drain(@failed_event)

      status = status!(name)
      assert status["last_refusal"] == "soft_capacity_exhausted"
      assert status["pending_count"] == length(applied)
      assert status["capacity"]["retirable_operation_count"] == 0
      assert status["capacity"]["remaining_increase_admissions"] > 0
      capacity = status["capacity"]
      # Exactly the entry clause: one more increase needs 3 entries.
      assert capacity["remaining_soft_entries"] - capacity["reserved_entries"] < 3
      refute admission_open?(name)

      register_consumer!()
      {:ok, batch} = Owner.delivery_batch(name)

      # The 512th acknowledgement triggers T2 after its reply; the next one
      # waits for the publication. Reservation accounting is incremental, so
      # a publication re-folding ~1000 pending operations stays well inside
      # the 5 s call timeout: no queued acknowledgement may time out.
      replies =
        batch
        |> Enum.take(600)
        |> Enum.map(fn item ->
          Owner.acknowledge_delivery(name, item["operation_id"], item["intent_sha256"])
        end)

      assert Enum.all?(replies, &(&1 == {:ok, :committed}))

      assert [{%{count: 512, duration_ms: ms}, %{trigger: :acknowledge}}] =
               drain(@retired_event, [], 30_000)

      IO.puts(
        "\n[audit retirement sink outage] pending=#{length(applied)} first T2 publication " <>
          "duration_ms=#{ms}"
      )

      assert ms < 5_000

      status = status!(name)
      assert status["capacity"]["retired_operation_total"] == 512
      assert status["pending_count"] == length(applied) - 600
      assert admission_open?(name)
      assert {:ok, _, "prepared"} = Owner.prepare(name, grant(5000))
    end
  end

  describe "cutover continuity" do
    test "a v2 operation pending at cutover is continued by its v3 twin, delivered, then retired" do
      root = unique_root()
      register_consumer!()
      v2 = intent(2, 1)
      write_v2_journal(root, rejected_terminals(1..3070), [record(v2, "prepared")])
      {name, pid} = start_owner(root)
      # T1 cut the v2 snapshot over to v3 (nothing delivered to retire) and
      # kept the pending v2 operation in the manifest.
      assert [{%{count: 0}, %{trigger: :boot, ledger_state: :absent}}] = drain(@retired_event)

      status = status!(name)
      assert status["retirement"]["floor"] == 3
      assert status["retirement"]["prepared_count"] == 1
      assert status["retirement"]["oldest_prepared_age_seconds"] > 0

      twin = intent(3, 1)
      refute twin["operation_id"] == v2["operation_id"]

      calls =
        trace_alias_calls(pid, fn ->
          assert {:ok, original, "prepared"} = Owner.prepare(name, twin)
          assert original == v2
        end)

      assert calls == 1

      assert {:ok, :committed} = Owner.observe(name, v2["operation_id"], :applied)
      assert {:ok, original, "effect_applied"} = Owner.prepare(name, twin)
      assert original["operation_id"] == v2["operation_id"]
      ack!(name, v2)

      # Nothing legacy is pending any more: no alias is derived.
      assert trace_alias_calls(pid, fn ->
               assert {:ok, _, "prepared"} = Owner.prepare(name, grant(2))
             end) == 0

      # The delivered v2 identity retires at the next relief and is then
      # refused by the floor.
      assert {:ok, _, "prepared"} = Owner.prepare(name, grant(3))
      assert [{%{count: 1}, %{trigger: :capacity}}] = drain(@retired_event)
      assert [frame] = decode_ledger(root)
      assert Map.keys(frame.batch["retired"]) == [v2["operation_id"]]
      assert {:error, :retired_version} = Owner.append(name, record(v2, "prepared"))
    end
  end

  describe "before cutover (spec section 7 row C)" do
    # Section 4.3 is normative: the gated alias continues PENDING v1/v2
    # operations only. Before the cutover publication lands (here: T1 kept
    # failing), a v3 prepare with the same facts as a hot DELIVERED v2
    # operation is therefore a new identity, the stated raw/rollback residual
    # of section 11 (the facade cannot present it against a monotonic store:
    # the live record short-circuits and a revoked one changes the facts). The
    # v2 identity itself is refused as terminal.
    test "a v3 twin of a hot delivered v2 operation is a new identity; the v2 prepare is terminal" do
      root = unique_root()
      v2 = intent(2, 1)
      write_v2_journal(root, %{}, v2_lifecycle(v2))
      {name, _pid} = start_owner(root, inject: [ledger_write_error: :eio])

      assert [{_, %{trigger: :boot, reason: :ledger_write_failed}}] = drain(@failed_event)
      assert status!(name)["retirement"]["floor"] == 1
      assert status!(name)["capacity"]["retirable_operation_count"] == 1

      assert {:error, :operation_terminal} = Owner.prepare(name, v2)
      twin = intent(3, 1)
      assert {:ok, admitted, "prepared"} = Owner.prepare(name, twin)
      assert admitted["operation_id"] == twin["operation_id"]
      refute admitted["operation_id"] == v2["operation_id"]
    end
  end

  describe "status and readiness" do
    test "a fresh operational journal is open for admission with the retirement map" do
      {name, _pid} = start_owner(unique_root())
      status = status!(name)
      assert status["last_refusal"] == "none"

      assert status["retirement"] == %{
               "floor" => 3,
               "ledger_state" => "absent",
               "ledger_frames" => 0,
               "prepared_count" => 0,
               "oldest_prepared_age_seconds" => 0,
               "last_error" => "none"
             }

      assert admission_open?(name)
    end

    test "admission is closed when no increase can be admitted by the retained dimension" do
      root = unique_root()
      write_journal(root, v3_snapshot(rejected_terminals(1..3072), %{}))
      {name, _pid} = start_owner(root)
      assert status!(name)["capacity"]["remaining_increase_admissions"] == 0
      refute admission_open?(name)
    end

    # Decision H9: expose readiness, never gate qualification on it. The
    # execution policy snapshot is digested into the SecurityQualification
    # profile fingerprint, so a readiness field there would change the
    # fingerprint (and the exact approval URI) whenever a delivery backlog
    # closed admission. A branch-internal regression pin: it fails with the
    # behavior of intermediate commit ed9712a1b, which put `admission_open`
    # into the snapshot's authority-journal identity (re-proven by mutating
    # `qualification_journal_identity/0` back to that). The parent 52a2cc3fa
    # had no readiness field, so the pinned behavior held there, but this
    # test cannot run on it: its setup writes v3 snapshots
    # (`AuditJournal.snapshot_kind/1`), which the parent lacks.
    test "security regression: journal admission readiness never changes the qualification policy snapshot" do
      # A fresh journal (open) and one whose retained dimension admits no
      # increase (closed), both serving.
      {open, _pid} = start_owner(unique_root())
      closed_root = unique_root()
      write_journal(closed_root, v3_snapshot(rejected_terminals(1..3072), %{}))
      {closed, _pid} = start_owner(closed_root)

      open_snapshot = with_registered_owner(open, fn -> Security.execution_policy_snapshot() end)

      closed_snapshot =
        with_registered_owner(closed, fn -> Security.execution_policy_snapshot() end)

      assert {:ok, identity} = open_snapshot.authority_journal
      refute Map.has_key?(identity, "admission_open")
      assert open_snapshot == closed_snapshot

      assert :erlang.term_to_binary(open_snapshot, [:deterministic]) ==
               :erlang.term_to_binary(closed_snapshot, [:deterministic])

      # Readiness itself is still exposed, in status.
      assert admission_open?(open)
      refute admission_open?(closed)
    end

    test "admission_open follows the exact entry clause of the next increase" do
      root = unique_root()
      {name, _pid} = start_owner(root)

      # Prepared-only increases: each writes 1 entry and reserves 2, lowering
      # `remaining_soft_entries - reserved_entries` by 3. One rejected
      # operation first shifts that value by one so the walk passes through
      # exactly 3 (the last admissible value). Readiness must flip exactly
      # when the core starts refusing the next increase.
      rejected = grant(0)
      assert {:ok, _, "prepared"} = Owner.prepare(name, rejected)

      assert {:ok, :committed} =
               Owner.observe(name, rejected["operation_id"], {:rejected, "before_mismatch"})

      capacity = status!(name)["capacity"]
      assert rem(capacity["remaining_soft_entries"] - capacity["reserved_entries"], 3) == 0

      outcome =
        Enum.reduce_while(1..1100, :open, fn n, :open ->
          ready? = admission_open?(name)

          case Owner.prepare(name, grant(n)) do
            {:ok, _, "prepared"} ->
              assert ready?, "admission_open was false but increase #{n} was admitted"
              {:cont, :open}

            {:error, :soft_capacity_exhausted} ->
              refute ready?, "admission_open was true but increase #{n} was refused"
              {:halt, {:refused_at, n}}
          end
        end)

      assert {:refused_at, n} = outcome
      assert n in 1020..1025
      # The refused call's T3 compaction reclaims the rejected operation's two
      # records, which still leaves less than one increase.
      capacity = status!(name)["capacity"]
      assert (capacity["remaining_soft_entries"] - capacity["reserved_entries"]) in 0..2
      refute admission_open?(name)
    end

    test "prepare refuses every terminal identity and records the refusal" do
      root = unique_root()
      register_consumer!()
      {name, _pid} = start_owner(root)
      target = grant(1)
      lifecycle!(name, target)
      before = status!(name)
      assert {:error, :operation_terminal} = Owner.prepare(name, target)
      after_refusal = status!(name)
      assert after_refusal["last_refusal"] == "operation_terminal"
      assert Map.delete(after_refusal, "last_refusal") == Map.delete(before, "last_refusal")
    end

    # Slice 4 (H11): ephemeral operational journals retire in memory and
    # report real headroom (audit_retirement_ephemeral_test.exs); neither
    # they nor small journals ever have a ledger.
    test "ephemeral and small journals report no retirement ledger" do
      {:ok, eph} =
        Owner.start_link(
          mode: :ephemeral,
          capacity_profile: :operational,
          name: :audit_retire_eph
        )

      on_exit(fn -> stop_name(:audit_retire_eph) end)
      assert status!(eph)["retirement"]["ledger_state"] == "none"
      assert status!(eph)["retirement"]["floor"] == 1

      {:ok, _small} =
        Owner.start_link(mode: :durable, root: unique_root(), name: :audit_retire_small)

      on_exit(fn -> stop_name(:audit_retire_small) end)
      assert status!(:audit_retire_small)["retirement"]["ledger_state"] == "none"
      assert status!(:audit_retire_small)["capacity"]["retire_batch"] == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Owner and consumer helpers

  defp start_owner(root, opts \\ []) do
    name = Keyword.get(opts, :name, :"audit_retire_#{System.unique_integer([:positive])}")
    extra = Keyword.delete(opts, :name)

    {:ok, pid} =
      Owner.start_link(
        [mode: :durable, root: root, name: name, capacity_profile: :operational] ++ extra
      )

    Process.unlink(pid)
    on_exit(fn -> stop(pid) end)
    {name, pid}
  end

  defp with_registered_owner(name, fun) when is_function(fun, 0),
    do: with_registered_owner(name, fn _server -> fun.() end)

  # Swap the registered owner so the arity-0 facade (and
  # execution_policy_snapshot) read this journal; `fun` receives the
  # registered name to address it by. Returns `fun`'s result.
  defp with_registered_owner(name, fun) when is_function(fun, 1) do
    original = Process.whereis(Owner)
    pid = Process.whereis(name)
    true = Process.unregister(Owner)
    true = Process.unregister(name)
    true = Process.register(pid, Owner)

    try do
      fun.(Owner)
    after
      if Process.whereis(Owner) == pid, do: Process.unregister(Owner)
      if Process.alive?(pid), do: Process.register(pid, name)
      Process.register(original, Owner)
    end
  end

  defp restart_owner(pid, root, opts \\ []) do
    stop(pid)
    start_owner(root, opts)
  end

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp stop_name(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> stop(pid)
      _ -> :ok
    end
  end

  defp status!(name) do
    assert {:ok, status} = Owner.status(name)
    status
  end

  defp apply!(name, intent) do
    assert {:ok, _, "prepared"} = Owner.prepare(name, intent)
    assert {:ok, :committed} = Owner.observe(name, intent["operation_id"], :applied)
  end

  defp ack(name, intent),
    do: Owner.acknowledge_delivery(name, intent["operation_id"], digest(intent))

  defp ack!(name, intent), do: assert({:ok, :committed} = ack(name, intent))

  defp lifecycle!(name, intent) do
    apply!(name, intent)
    ack!(name, intent)
  end

  defp register_consumer! do
    name = :"audit_retire_consumer_#{System.unique_integer([:positive])}"
    true = Process.register(self(), name)
    previous = Application.fetch_env(:arbor_security, :authority_audit_consumer_name)
    Application.put_env(:arbor_security, :authority_audit_consumer_name, name)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:arbor_security, :authority_audit_consumer_name, value)

        :error ->
          Application.delete_env(:arbor_security, :authority_audit_consumer_name)
      end
    end)

    name
  end

  defp admission_open?(name), do: status!(name)["admission_open"]

  defp wait_backoff, do: Process.sleep(5_100)

  defp set_backoff(pid, from_now_ms) do
    :sys.replace_state(pid, fn state ->
      %{state | publication_backoff_until: System.monotonic_time(:millisecond) + from_now_ms}
    end)
  end

  defp drain(event, acc \\ [], wait \\ 50) do
    receive do
      {:audit_event, ^event, measurements, metadata} ->
        drain(event, [{measurements, metadata} | acc], 50)
    after
      wait -> Enum.reverse(acc)
    end
  end

  defp trace_alias_calls(pid, fun) do
    mfa = {AuditJournal, :legacy_alias_operation_id, 1}
    :erlang.trace_pattern(mfa, true, [:global])
    :erlang.trace(pid, true, [:call, {:tracer, self()}])

    try do
      fun.()
    after
      :erlang.trace(pid, false, [:call])
      :erlang.trace_pattern(mfa, false, [:global])
    end

    count_traces(pid, 0)
  end

  defp count_traces(pid, count) do
    receive do
      {:trace, ^pid, :call, {AuditJournal, :legacy_alias_operation_id, _}} ->
        count_traces(pid, count + 1)
    after
      50 -> count
    end
  end

  # ---------------------------------------------------------------------------
  # Journal fixtures

  defp journal_path(root), do: Path.join(root, "audit_journal.v1.log")
  defp ledger_path(root), do: Path.join(root, "audit_journal.v1.retirement.v1.log")

  defp write_journal(root, snapshot, pending \\ []) do
    {:ok, bytes, _replay} = FileCore.encode_compacted(snapshot, pending)
    File.write!(journal_path(root), bytes)
    File.chmod!(journal_path(root), 0o600)
  end

  # A legacy v2 operational snapshot over `terminals` plus pending records.
  defp write_v2_journal(root, terminals, records) do
    {:ok, empty} = Core.new(:operational)

    state =
      Enum.reduce(records, empty, fn record, acc ->
        {:ok, next} = Core.append(acc, record)
        next
      end)

    {:ok, _compacted, v3, pending} = Core.compact(state, @source)

    v2 =
      v3
      |> Map.delete("retirement")
      |> Map.merge(%{
        "version" => 2,
        "kind" => AuditJournal.operational_snapshot_kind(),
        "terminals" => Map.merge(v3["terminals"], terminals)
      })

    write_journal(root, v2, pending)
  end

  defp plant_ledger(root, bytes) do
    File.write!(ledger_path(root), bytes)
    File.chmod!(ledger_path(root), 0o600)
  end

  defp v2_snapshot(terminals) do
    %{
      "version" => 2,
      "kind" => AuditJournal.operational_snapshot_kind(),
      "source" => @source,
      "pending_manifest" => %{},
      "terminals" => terminals,
      "capacity_profile" => "operational"
    }
  end

  defp v3_snapshot(rejected, delivered) do
    %{
      "version" => 3,
      "kind" => AuditJournal.snapshot_kind(3),
      "source" => @source,
      "pending_manifest" => %{},
      "terminals" => Map.merge(rejected, delivered),
      "capacity_profile" => "operational",
      "retirement" => %{"retired_total" => 0, "ledger" => AuditJournal.ledger_genesis_binding()}
    }
  end

  defp delivered_terminals(range) do
    Map.new(range, fn n ->
      {sha({:op, n}),
       "delivered|authority_reduce|#{sha({:i, n})}|prepared:#{sha({:p, n})}|" <>
         "effect_applied:#{sha({:a, n})}|delivered:#{sha({:d, n})}"}
    end)
  end

  defp rejected_terminals(range) do
    Map.new(range, fn n ->
      {sha({:rejected_op, n}),
       "effect_rejected|authority_increase|#{sha({:ri, n})}|prepared:#{sha({:rp, n})}|" <>
         "effect_rejected:#{sha({:rr, n})}"}
    end)
  end

  defp decode_ledger(root),
    do: decode_frames(File.read!(ledger_path(root)), 0, FileCore.genesis_digest(), [])

  defp decode_frames(bytes, offset, _predecessor, acc) when offset == byte_size(bytes),
    do: Enum.reverse(acc)

  defp decode_frames(bytes, offset, predecessor, acc) do
    {:ok, header} = FileCore.decode_header(binary_part(bytes, offset, 72))
    payload = binary_part(bytes, offset + 72, header.payload_len)
    {:ok, frame_digest} = FileCore.verify_frame(header, payload, predecessor)
    {:ok, batch} = LedgerCore.admit_batch_payload(payload)
    decode_frames(bytes, offset + 72 + header.payload_len, frame_digest, [%{batch: batch} | acc])
  end

  # ---------------------------------------------------------------------------
  # Intents and records

  defp grant(n), do: intent(3, n)

  defp producer_grant(capability_id) do
    data = %{
      "id" => capability_id,
      "principal_id" => "agent_retirement_fixture",
      "resource_uri" => "arbor://memory/read/retirement"
    }

    after_entry = CapabilityAuditCore.replacement(Record.new(capability_id, data), :absent)
    {:ok, intent} = CapabilityAuditCore.intent(:grant, :absent, after_entry, data, @time)

    intent
  end

  defp intent(version, n) do
    {:ok, intent} = AuditJournal.admit_intent(facts(version, n))
    intent
  end

  defp revoke_intent(version, n) do
    grant = facts(version, n)

    {:ok, intent} =
      grant
      |> Map.put("operation", "capability_revoke")
      |> Map.put("effect_class", "authority_reduce")
      |> Map.put("before_fence", grant["after_fingerprint"])
      |> Map.put("after_fingerprint", %{"kind" => "tombstone", "generation" => 1})
      |> put_in(["audit", "event_type"], "capability_revoked")
      |> AuditJournal.admit_intent()

    intent
  end

  defp facts(version, n) do
    id = "cap_" <> String.pad_leading(String.downcase(Integer.to_string(n, 16)), 32, "0")

    %{
      "version" => version,
      "kind" => "arbor.security.authority_mutation_intent.v#{version}",
      "operation" => "capability_grant",
      "effect_class" => "authority_increase",
      "authority_namespace" => "capability",
      "authority_key" => id,
      "before_fence" => %{"kind" => "absent"},
      "after_fingerprint" => %{
        "kind" => "live",
        "record_id" => "record-#{n}",
        "generation" => 1,
        "revision" => 1,
        "capability_digest" => String.duplicate("ab", 32)
      },
      "audit" => %{
        "event_type" => "capability_granted",
        "data" => %{
          "capability_id" => id,
          "principal_id" => "agent_fixture",
          "resource_uri" => "arbor://memory/read"
        }
      },
      "prepared_at" => @time
    }
  end

  defp record(intent, "prepared") do
    %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => "prepared",
      "operation_id" => intent["operation_id"],
      "occurred_at" => intent["prepared_at"],
      "intent" => intent
    }
  end

  defp v2_lifecycle(intent) do
    base = %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "operation_id" => intent["operation_id"],
      "occurred_at" => intent["prepared_at"]
    }

    [
      record(intent, "prepared"),
      Map.merge(base, %{
        "record_type" => "effect_applied",
        "observation" => %{
          "kind" => "applied",
          "after_fingerprint" => intent["after_fingerprint"]
        }
      }),
      Map.put(base, "record_type", "delivered")
    ]
  end

  defp digest(intent) do
    {:ok, bytes} = AuditJournal.canonical_intent_bytes(intent)
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp sha(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  defp unique_root do
    dir =
      Path.join(
        System.tmp_dir!(),
        "audit-retire-owner-#{System.pid()}-#{System.unique_integer([:positive])}-" <>
          Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      )

    File.mkdir_p!(dir)
    {:ok, root} = SafePath.resolve_real(dir)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
