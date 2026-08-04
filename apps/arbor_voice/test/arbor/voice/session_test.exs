defmodule Arbor.Voice.SessionTest do
  @moduledoc """
  Session lifecycle proofs for VP-04D2B: transactional startup unwind,
  UTC-day budget bounding, hard timeout, forced death, and exclusive
  settlement authority.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Voice
  alias Arbor.Voice.Test.FakeBackend

  alias Arbor.Voice.Test.SessionFakes.{
    ControllableBackend,
    FakeCommsSession,
    FakeEngagementStore,
    FakeLedger,
    FakeSignals,
    TrackingResourceOwner
  }

  defp unique_ids do
    n = System.unique_integer([:positive])
    {"user_#{n}", "agent_#{n}"}
  end

  defp lifecycle_opts(extra \\ []) do
    {:ok, eng} = FakeEngagementStore.start()
    {:ok, ledger} = FakeLedger.start()
    {:ok, signals} = FakeSignals.start()
    {:ok, owner_tracker} = TrackingResourceOwner.start_tracker()

    ControllableBackend.ensure_table!()
    ControllableBackend.set_mode(:ok)

    opts =
      [
        comms: FakeCommsSession,
        engagement_store: FakeEngagementStore,
        ledger: FakeLedger,
        ledger_opts: [],
        resource_owner: TrackingResourceOwner,
        resource_owner_opts: [
          close_timeout_ms: 1_000,
          cleanup_ready_timeout_ms: 200,
          cleanup_attempts: 2,
          cleanup_per_attempt_timeout_ms: 200
        ],
        backend: ControllableBackend,
        backend_opts: [],
        signals: FakeSignals,
        session_budget_ms: 60_000,
        daily_budget_ms: 3_600_000,
        wall_clock: fn -> ~U[2026-08-02 12:00:00.000000Z] end,
        monotonic_clock: fn -> 5_000_000 end
      ]
      |> Keyword.merge(extra)

    %{opts: opts, eng: eng, ledger: ledger, signals: signals, owner_tracker: owner_tracker}
  end

  setup do
    assert is_pid(Process.whereis(Arbor.Voice.SessionSupervisor))
    assert is_pid(Process.whereis(Arbor.Voice.ResourceSupervisor))
    :ok
  end

  test "public stop timeout covers owner close, death confirmation, and scheduling margin" do
    assert Arbor.Voice.Session.stop_call_timeout_ms() >=
             Arbor.Voice.ResourceOwner.close_call_timeout_ms() + 10_000
  end

  test "ready Session drops Settlement after arming the handed-off cleanup" do
    ctx = lifecycle_opts()
    {user_id, agent_id} = unique_ids()

    assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
    assert [{session, _value}] = Registry.lookup(Arbor.Voice.Registry, key)
    state = :sys.get_state(session)

    refute Map.has_key?(state, :settlement)
    refute Map.has_key?(state, :start_ms)

    assert TrackingResourceOwner.stats(ctx.owner_tracker).handoff_cleanup_keys == [
             :budget_settlement
           ]

    assert :ok = Voice.stop_session(key)
  end

  test "stop returns cleanup_pending and never directly settles lease-owned budget" do
    clock_reads = :atomics.new(1, signed: false)

    clock = fn ->
      _ = :atomics.add_get(clock_reads, 1, 1)
      5_000_000
    end

    ctx = lifecycle_opts(monotonic_clock: clock)
    {user_id, agent_id} = unique_ids()

    assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
    owner = TrackingResourceOwner.owner(ctx.owner_tracker)
    TrackingResourceOwner.set_close_mode(ctx.owner_tracker, :cleanup_pending)

    assert {:error, :cleanup_pending} = Voice.stop_session(key)
    assert {:error, :not_found} = Voice.session_status(key)

    wait_until(
      fn ->
        Enum.any?(FakeLedger.calls(ctx.ledger), &match?({:consume, _, _, _}, &1))
      end,
      2_000
    )

    calls = FakeLedger.calls(ctx.ledger)
    assert Enum.count(calls, &match?({:consume, _, _, _}, &1)) == 1
    refute Enum.any?(calls, &match?({:release, _, _}, &1))
    # Construction plus the lease-owned cleanup. A Session-owned settlement
    # attempt before exit would add another clock read.
    assert :atomics.get(clock_reads, 1) == 2
    assert TrackingResourceOwner.stats(ctx.owner_tracker).closes == 1
    wait_until(fn -> not Process.alive?(owner) end, 2_000)
  end

  test "close callback faults stay redacted while public cleanup remains pending" do
    ctx = lifecycle_opts()
    {user_id, agent_id} = unique_ids()

    assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
    owner = TrackingResourceOwner.owner(ctx.owner_tracker)
    TrackingResourceOwner.set_close_mode(ctx.owner_tracker, :raise)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :cleanup_pending} = Voice.stop_session(key)
      end)

    assert {:error, :not_found} = Voice.session_status(key)
    refute log =~ "resource_owner close boom"
    refute inspect(FakeSignals.emissions(ctx.signals)) =~ "resource_owner close boom"

    wait_until(
      fn ->
        Enum.any?(FakeLedger.calls(ctx.ledger), &match?({:consume, _, _, _}, &1))
      end,
      2_000
    )

    assert Enum.count(FakeLedger.calls(ctx.ledger), &match?({:consume, _, _, _}, &1)) == 1
    wait_until(fn -> not Process.alive?(owner) end, 2_000)
  end

  @tag :security_regression
  @tag spec: "VOICE-17"
  test "security regression: public backend_opts cannot inject the internal effect authorizer" do
    ctx = lifecycle_opts(backend_opts: [effect_authorizer: fn _, _ -> :allow end])
    {user_id, agent_id} = unique_ids()

    assert {:error, :invalid_opts} = Voice.start_session(user_id, agent_id, ctx.opts)
    assert FakeLedger.calls(ctx.ledger) == []
    assert TrackingResourceOwner.stats(ctx.owner_tracker).starts == 0
    assert Registry.lookup(Arbor.Voice.Registry, {user_id, agent_id}) == []
  end

  # ---------------------------------------------------------------------------
  # Table-driven startup failures
  # ---------------------------------------------------------------------------

  describe "transactional startup failures" do
    @tag spec: "VOICE-2,VOICE-24"
    test "table: engagement / reserve / owner / cleanup / configure / meta failures unwind exclusively" do
      cases = [
        %{
          name: :engagement_fail,
          setup: fn ctx ->
            FakeEngagementStore.set_result(ctx.eng, {:error, :store_down})
            ctx
          end,
          expect_error: :engagement_unavailable,
          expect_releases: 0,
          expect_owner_closes: 0,
          expect_registers: 0,
          expect_cleanup_runs: 0,
          expect_success_signals: false
        },
        %{
          name: :reserve_fail,
          setup: fn ctx ->
            FakeLedger.set_reserve_mode(ctx.ledger, :budget_exhausted)
            ctx
          end,
          expect_error: :budget_exhausted,
          expect_releases: 0,
          expect_owner_closes: 0,
          expect_registers: 0,
          expect_cleanup_runs: 0,
          expect_success_signals: false
        },
        %{
          name: :owner_start_fail,
          setup: fn ctx ->
            TrackingResourceOwner.set_start_mode(ctx.owner_tracker, :fail)
            ctx
          end,
          expect_error: :start_failed,
          # Owner never started; settlement released directly.
          expect_releases: 1,
          expect_owner_closes: 0,
          expect_registers: 0,
          expect_cleanup_runs: 0,
          expect_success_signals: false
        },
        %{
          name: :accepted_owner_start_fail,
          setup: fn ctx ->
            TrackingResourceOwner.set_start_mode(ctx.owner_tracker, :accepted_fail)
            ctx
          end,
          expect_error: :start_failed,
          # CleanupLease accepted the initial map and is the sole releaser.
          expect_releases: 1,
          expect_owner_closes: 0,
          expect_registers: 0,
          expect_cleanup_runs: 1,
          expect_success_signals: false
        },
        %{
          name: :configure_fail,
          setup: fn ctx ->
            TrackingResourceOwner.set_configure_mode(ctx.owner_tracker, :fail)
            ctx
          end,
          expect_error: :start_failed,
          expect_releases: 1,
          expect_owner_closes: 1,
          expect_registers: 0,
          # The concrete CleanupLease runs accepted cleanup; the facade only observes close.
          expect_cleanup_runs: 0,
          expect_success_signals: false
        },
        %{
          name: :meta_fail,
          setup: fn ctx ->
            TrackingResourceOwner.set_meta_mode(ctx.owner_tracker, :fail)
            ctx
          end,
          expect_error: :start_failed,
          expect_releases: 1,
          expect_owner_closes: 1,
          expect_registers: 0,
          expect_cleanup_runs: 0,
          expect_success_signals: false
        }
      ]

      for c <- cases do
        ctx = lifecycle_opts()
        ctx = c.setup.(ctx)
        {user_id, agent_id} = unique_ids()

        assert {:error, error} = Voice.start_session(user_id, agent_id, ctx.opts),
               "case #{c.name} expected error"

        assert error == c.expect_error, "case #{c.name}: got #{inspect(error)}"

        stats = TrackingResourceOwner.stats(ctx.owner_tracker)
        calls = FakeLedger.calls(ctx.ledger)
        emissions = FakeSignals.emissions(ctx.signals)

        release_calls = Enum.filter(calls, &match?({:release, _, _}, &1))
        consume_calls = Enum.filter(calls, &match?({:consume, _, _, _}, &1))

        assert length(release_calls) == c.expect_releases,
               "case #{c.name}: releases got #{length(release_calls)}"

        assert stats.closes == c.expect_owner_closes, "case #{c.name}: closes"
        assert stats.registers == c.expect_registers, "case #{c.name}: registers"
        assert stats.cleanup_runs == c.expect_cleanup_runs, "case #{c.name}: cleanup runs"

        assert consume_calls == [], "case #{c.name}: no consume on failed start"

        success_types = emissions |> Enum.map(fn {_, t, _, _} -> t end) |> Enum.uniq()

        refute :start in success_types, "case #{c.name}: no :start signal"
        refute :backend_connected in success_types, "case #{c.name}: no :backend_connected"

        # No leaked registry entry
        assert Registry.lookup(Arbor.Voice.Registry, {user_id, agent_id}) == []
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Initial handoff acceptance boundary
  # ---------------------------------------------------------------------------

  describe "initial cleanup handoff boundary" do
    @tag spec: "VOICE-24"
    test "security regression: accepted start failure never triggers direct Session settlement" do
      clock_reads = :atomics.new(1, signed: false)

      clock = fn ->
        _ = :atomics.add_get(clock_reads, 1, 1)
        5_000_000
      end

      ctx = lifecycle_opts(monotonic_clock: clock)
      TrackingResourceOwner.set_start_mode(ctx.owner_tracker, :accepted_fail)
      {user_id, agent_id} = unique_ids()

      assert {:error, :start_failed} = Voice.start_session(user_id, agent_id, ctx.opts)

      calls = FakeLedger.calls(ctx.ledger)
      stats = TrackingResourceOwner.stats(ctx.owner_tracker)

      reserve_calls = Enum.filter(calls, &match?({:reserve, _, _, _, _, _}, &1))
      release_calls = Enum.filter(calls, &match?({:release, _, _}, &1))
      consume_calls = Enum.filter(calls, &match?({:consume, _, _, _}, &1))

      assert length(reserve_calls) == 1
      assert length(release_calls) == 1
      assert consume_calls == []
      assert stats.starts == 1
      assert stats.accepted_failures == 1
      assert stats.cleanup_runs == 1
      assert stats.registers == 0
      assert stats.closes == 0
      assert stats.handoff_cleanup_keys == [:budget_settlement]
      # One construction read plus one lease-owned cleanup read. A direct
      # Session unwind after accepted handoff would perform a third read.
      assert :atomics.get(clock_reads, 1) == 2
      assert Registry.lookup(Arbor.Voice.Registry, {user_id, agent_id}) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Wall-clock boundary: catch + UTC DateTime contract
  # ---------------------------------------------------------------------------

  describe "wall_clock boundary" do
    @tag spec: "VOICE-24"
    test "table: raise/throw/exit/malformed/non-UTC wall_clock fail closed without reserve or success signals" do
      non_utc =
        case DateTime.new(~D[2026-08-02], ~T[12:00:00], "America/New_York") do
          {:ok, dt} ->
            dt

          {:error, _} ->
            # Environments without the zone database still need a non-UTC DateTime.
            %{
              DateTime.utc_now()
              | time_zone: "America/New_York",
                utc_offset: -14_400,
                std_offset: 0
            }
        end

      cases = [
        %{
          name: :raise,
          wall_clock: fn -> raise "injected wall_clock boom" end
        },
        %{
          name: :throw,
          wall_clock: fn -> throw(:wall_clock_throw) end
        },
        %{
          name: :exit,
          wall_clock: fn -> exit(:wall_clock_exit) end
        },
        %{
          name: :malformed_atom,
          wall_clock: fn -> :not_a_datetime end
        },
        %{
          name: :malformed_naive,
          wall_clock: fn -> ~N[2026-08-02 12:00:00] end
        },
        %{
          name: :malformed_integer,
          wall_clock: fn -> 1_725_000_000 end
        },
        %{
          name: :non_utc_datetime,
          wall_clock: fn -> non_utc end
        },
        %{
          # Internally inconsistent %DateTime{}: claims Etc/UTC but non-zero offset.
          # Must fail the UTC contract without reserving (not merely a non-DateTime).
          name: :malformed_datetime_nonzero_utc_offset,
          wall_clock: fn ->
            %DateTime{
              year: 2026,
              month: 8,
              day: 2,
              hour: 12,
              minute: 0,
              second: 0,
              microsecond: {0, 6},
              time_zone: "Etc/UTC",
              zone_abbr: "UTC",
              utc_offset: 3_600,
              std_offset: 0
            }
          end
        },
        %{
          name: :malformed_datetime_nonzero_std_offset,
          wall_clock: fn ->
            %{~U[2026-08-02 12:00:00.000000Z] | std_offset: 3_600}
          end
        },
        %{
          # Contradictory abbreviation must not be admitted as a UTC instant.
          name: :malformed_datetime_non_utc_abbreviation,
          wall_clock: fn ->
            %{~U[2026-08-02 12:00:00.000000Z] | zone_abbr: "EST"}
          end
        },
        %{
          # Semantically invalid calendar date (day 32) with otherwise-UTC shell.
          name: :malformed_datetime_invalid_date,
          wall_clock: fn ->
            %DateTime{
              year: 2026,
              month: 8,
              day: 32,
              hour: 12,
              minute: 0,
              second: 0,
              microsecond: {0, 6},
              time_zone: "Etc/UTC",
              zone_abbr: "UTC",
              utc_offset: 0,
              std_offset: 0
            }
          end
        },
        %{
          # Semantically invalid microsecond component with otherwise-UTC shell.
          name: :malformed_datetime_invalid_microsecond,
          wall_clock: fn ->
            %DateTime{
              year: 2026,
              month: 8,
              day: 2,
              hour: 12,
              minute: 0,
              second: 0,
              microsecond: {1_000_000, 6},
              time_zone: "Etc/UTC",
              zone_abbr: "UTC",
              utc_offset: 0,
              std_offset: 0
            }
          end
        }
      ]

      for c <- cases do
        ctx = lifecycle_opts(wall_clock: c.wall_clock)
        {user_id, agent_id} = unique_ids()

        assert {:error, :start_failed} = Voice.start_session(user_id, agent_id, ctx.opts),
               "case #{c.name}: expected :start_failed"

        calls = FakeLedger.calls(ctx.ledger)
        emissions = FakeSignals.emissions(ctx.signals)
        stats = TrackingResourceOwner.stats(ctx.owner_tracker)

        assert Enum.filter(calls, &match?({:reserve, _, _, _, _, _}, &1)) == [],
               "case #{c.name}: must not reserve"

        assert Enum.filter(calls, &match?({:release, _, _}, &1)) == [],
               "case #{c.name}: must not release"

        assert Enum.filter(calls, &match?({:consume, _, _, _}, &1)) == [],
               "case #{c.name}: must not consume"

        assert stats.starts == 0, "case #{c.name}: must not start owner"
        assert stats.closes == 0, "case #{c.name}: must not close owner"
        assert stats.registers == 0, "case #{c.name}: must not register cleanup"

        success_types = emissions |> Enum.map(fn {_, t, _, _} -> t end) |> Enum.uniq()
        refute :start in success_types, "case #{c.name}: no :start signal"
        refute :backend_connected in success_types, "case #{c.name}: no :backend_connected"
        refute :stop in success_types, "case #{c.name}: no :stop signal"
        refute :budget_exhausted in success_types, "case #{c.name}: no :budget_exhausted"

        assert Registry.lookup(Arbor.Voice.Registry, {user_id, agent_id}) == [],
               "case #{c.name}: no registry leak"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # UTC day / duration calculation
  # ---------------------------------------------------------------------------

  describe "UTC-day budget bounding" do
    @tag spec: "VOICE-24"
    test "reserves min(session_budget_ms, ms_to_utc_midnight) with injected wall clock" do
      # 23:59:50 UTC → 10_000 ms to midnight
      wall = fn -> ~U[2026-08-02 23:59:50.000000Z] end

      ctx =
        lifecycle_opts(wall_clock: wall, session_budget_ms: 60_000, daily_budget_ms: 3_600_000)

      {user_id, agent_id} = unique_ids()

      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:ok, status} = Voice.session_status(key)
      assert status.reserved_ms == 10_000

      calls = FakeLedger.calls(ctx.ledger)
      reserve_calls = Enum.filter(calls, &match?({:reserve, _, _, _, _, _}, &1))
      assert [{:reserve, ^user_id, "2026-08-02", 10_000, 3_600_000, _}] = reserve_calls

      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-24"
    test "session budget smaller than ms-to-midnight wins" do
      wall = fn -> ~U[2026-08-02 00:00:00.000000Z] end
      ctx = lifecycle_opts(wall_clock: wall, session_budget_ms: 5_000, daily_budget_ms: 3_600_000)
      {user_id, agent_id} = unique_ids()

      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert {:ok, %{reserved_ms: 5_000}} = Voice.session_status(key)
      assert :ok = Voice.stop_session(key)
    end
  end

  # ---------------------------------------------------------------------------
  # Monotonic consumption on normal stop
  # ---------------------------------------------------------------------------

  describe "monotonic consumption" do
    @tag spec: "VOICE-24"
    test "normal stop consumes elapsed ms from injected monotonic clock" do
      start_ms = 1_000_000
      stop_ms = 1_012_500
      clock = :atomics.new(1, signed: true)
      :atomics.put(clock, 1, start_ms)

      mono = fn -> :atomics.get(clock, 1) end

      ctx =
        lifecycle_opts(
          monotonic_clock: mono,
          session_budget_ms: 60_000
        )

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)

      :atomics.put(clock, 1, stop_ms)
      assert :ok = Voice.stop_session(key)

      consume_calls =
        ctx.ledger
        |> FakeLedger.calls()
        |> Enum.filter(&match?({:consume, _, _, _}, &1))

      assert [{:consume, _id, 12_500, _opts}] = consume_calls
    end
  end

  # ---------------------------------------------------------------------------
  # Hard timeout
  # ---------------------------------------------------------------------------

  describe "hard timeout" do
    @tag spec: "VOICE-22,VOICE-24"
    test "hard timer settles, closes backend, emits budget_exhausted, terminates session" do
      ctx =
        lifecycle_opts(
          session_budget_ms: 50,
          wall_clock: fn -> ~U[2026-08-02 12:00:00.000000Z] end
        )

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      assert [{pid, _}] = Registry.lookup(Arbor.Voice.Registry, key)

      # Wait for hard timeout (50ms reserved) + cleanup
      wait_until(fn -> not Process.alive?(pid) end, 5_000)
      wait_until(fn -> Registry.lookup(Arbor.Voice.Registry, key) == [] end, 2_000)

      emissions = FakeSignals.emissions(ctx.signals)

      assert Enum.any?(emissions, fn {c, t, _, _} -> c == :voice and t == :budget_exhausted end)
      refute Enum.any?(emissions, fn {c, t, _, _} -> c == :voice and t == :stop end)

      # emit/4 with a closed opts list
      assert Enum.all?(emissions, fn {_c, _t, _data, opts} -> opts == [] end)

      # Backend closed
      wait_until(fn -> ControllableBackend.close_count() >= 1 end, 2_000)

      # Budget settled (consume)
      wait_until(
        fn ->
          Enum.any?(FakeLedger.calls(ctx.ledger), &match?({:consume, _, _, _}, &1))
        end,
        2_000
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Concurrent daily reservation denial
  # ---------------------------------------------------------------------------

  describe "concurrent reservation denial" do
    @tag spec: "VOICE-24"
    test "propagates budget_exhausted when daily allowance is already reserved" do
      user_id = "user_shared_#{System.unique_integer([:positive])}"
      agent_a = "agent_a_#{System.unique_integer([:positive])}"
      agent_b = "agent_b_#{System.unique_integer([:positive])}"

      # Real BudgetLedger + fake persistence backend for concurrent denial.
      name = :"session_budget_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Arbor.Voice.Test.BudgetLedgerFakeBackend.start_link(agent_name: name)

      on_exit(fn -> Arbor.Voice.Test.BudgetLedgerFakeBackend.stop(name) end)

      {:ok, _eng} = FakeEngagementStore.start()
      {:ok, _signals} = FakeSignals.start()

      ledger_opts = [
        backend: Arbor.Voice.Test.BudgetLedgerFakeBackend,
        backend_opts: [agent_name: name]
      ]

      opts = [
        comms: FakeCommsSession,
        engagement_store: FakeEngagementStore,
        ledger: Arbor.Voice.BudgetLedger,
        ledger_opts: ledger_opts,
        backend: FakeBackend,
        signals: FakeSignals,
        session_budget_ms: 3_600_000,
        daily_budget_ms: 3_600_000,
        wall_clock: fn -> ~U[2026-08-02 12:00:00.000000Z] end,
        monotonic_clock: fn -> System.monotonic_time(:millisecond) end
      ]

      assert {:ok, key_a} = Voice.start_session(user_id, agent_a, opts)

      assert {:error, :budget_exhausted} = Voice.start_session(user_id, agent_b, opts)

      assert :ok = Voice.stop_session(key_a)
    end
  end

  # ---------------------------------------------------------------------------
  # Forced Session death → ResourceOwner cleanup (no terminate/2 reliance)
  # ---------------------------------------------------------------------------

  describe "forced session death" do
    @tag spec: "VOICE-7,VOICE-24"
    test "killing Session after readiness closes backend and consumes via retained Settlement" do
      ControllableBackend.ensure_table!()
      ControllableBackend.set_mode(:ok)
      ControllableBackend.reset_close_count()

      {:ok, _eng} = FakeEngagementStore.start()
      {:ok, ledger} = FakeLedger.start()
      {:ok, signals} = FakeSignals.start()

      opts = [
        comms: FakeCommsSession,
        engagement_store: FakeEngagementStore,
        ledger: FakeLedger,
        ledger_opts: [],
        # Real ResourceOwner — forced-death proof must not use Session.terminate/2.
        resource_owner: Arbor.Voice.ResourceOwner,
        resource_owner_opts: [
          close_timeout_ms: 1_000,
          cleanup_ready_timeout_ms: 200,
          cleanup_attempts: 2,
          cleanup_per_attempt_timeout_ms: 200
        ],
        backend: ControllableBackend,
        backend_opts: [],
        signals: FakeSignals,
        session_budget_ms: 60_000,
        daily_budget_ms: 3_600_000,
        wall_clock: fn -> ~U[2026-08-02 12:00:00.000000Z] end,
        monotonic_clock: fn -> System.monotonic_time(:millisecond) end
      ]

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, opts)
      assert [{session_pid, _}] = Registry.lookup(Arbor.Voice.Registry, key)
      assert Process.alive?(session_pid)

      # Prove readiness signals fired before kill.
      emissions_before = FakeSignals.emissions(signals)
      assert Enum.any?(emissions_before, fn {_, t, _, _} -> t == :start end)
      assert Enum.all?(emissions_before, fn {_c, _t, _d, opts} -> opts == [] end)

      # Kill Session hard — do NOT call stop; do not rely on terminate/2.
      Process.exit(session_pid, :kill)
      wait_until(fn -> not Process.alive?(session_pid) end, 2_000)

      # ResourceOwner monitor path closes backend.
      wait_until(fn -> ControllableBackend.close_count() >= 1 end, 5_000)
      assert ControllableBackend.close_count() == 1

      # Retained Settlement consumed via cleanup (not Session.terminate/2).
      wait_until(
        fn ->
          Enum.any?(FakeLedger.calls(ledger), &match?({:consume, _, _, _}, &1))
        end,
        5_000
      )

      consume_calls =
        ledger
        |> FakeLedger.calls()
        |> Enum.filter(&match?({:consume, _, _, _}, &1))

      assert length(consume_calls) == 1
      assert [{:consume, _id, elapsed, _}] = consume_calls
      assert is_integer(elapsed) and elapsed >= 0

      # No registry leak
      wait_until(fn -> Registry.lookup(Arbor.Voice.Registry, key) == [] end, 2_000)
    end
  end

  # ---------------------------------------------------------------------------
  # Cleanup settle soft-error retry via ResourceOwner {:error, _} contract
  # ---------------------------------------------------------------------------

  describe "settlement cleanup failure-then-retry" do
    @tag spec: "VOICE-7,VOICE-24"
    test "consume fails once then succeeds: two cleanup attempts, one durable success" do
      ControllableBackend.ensure_table!()
      ControllableBackend.set_mode(:ok)

      {:ok, _eng} = FakeEngagementStore.start()
      {:ok, ledger} = FakeLedger.start()
      {:ok, _signals} = FakeSignals.start()

      # First consume fails → Settlement.settle returns {:error, _}; ResourceOwner
      # retries; second succeeds. Kill Session so only cleanup settles.
      FakeLedger.set_consume_fail_remaining(ledger, 1)

      opts = [
        comms: FakeCommsSession,
        engagement_store: FakeEngagementStore,
        ledger: FakeLedger,
        ledger_opts: [],
        resource_owner: Arbor.Voice.ResourceOwner,
        resource_owner_opts: [
          close_timeout_ms: 2_000,
          cleanup_ready_timeout_ms: 200,
          cleanup_attempts: 3,
          cleanup_per_attempt_timeout_ms: 500
        ],
        backend: ControllableBackend,
        backend_opts: [],
        signals: FakeSignals,
        session_budget_ms: 60_000,
        daily_budget_ms: 3_600_000,
        wall_clock: fn -> ~U[2026-08-02 12:00:00.000000Z] end,
        monotonic_clock: fn -> System.monotonic_time(:millisecond) end
      ]

      {user_id, agent_id} = unique_ids()
      assert {:ok, key} = Voice.start_session(user_id, agent_id, opts)
      assert [{session_pid, _}] = Registry.lookup(Arbor.Voice.Registry, key)

      Process.exit(session_pid, :kill)
      wait_until(fn -> not Process.alive?(session_pid) end, 2_000)

      wait_until(
        fn ->
          consume_calls =
            ledger
            |> FakeLedger.calls()
            |> Enum.filter(&match?({:consume, _, _, _}, &1))

          length(consume_calls) == 2
        end,
        5_000
      )

      consume_calls =
        ledger
        |> FakeLedger.calls()
        |> Enum.filter(&match?({:consume, _, _, _}, &1))

      # Exactly two cleanup attempts: fail once, then durable success.
      assert length(consume_calls) == 2
      # No release leak — consume path won.
      refute Enum.any?(FakeLedger.calls(ledger), &match?({:release, _, _}, &1))
      wait_until(fn -> Registry.lookup(Arbor.Voice.Registry, key) == [] end, 2_000)
      wait_until(fn -> ControllableBackend.close_count() >= 1 end, 2_000)
    end
  end

  # ---------------------------------------------------------------------------
  # Post-reserve clock failure must release (no leak)
  # ---------------------------------------------------------------------------

  describe "post-reserve failure releases reservation" do
    @tag spec: "VOICE-24"
    test "injected monotonic clock failure after reserve releases the exact reservation" do
      ctx =
        lifecycle_opts(monotonic_clock: fn -> raise "injected clock boom" end)

      {user_id, agent_id} = unique_ids()
      assert {:error, :start_failed} = Voice.start_session(user_id, agent_id, ctx.opts)

      calls = FakeLedger.calls(ctx.ledger)
      reserve_calls = Enum.filter(calls, &match?({:reserve, _, _, _, _, _}, &1))
      release_calls = Enum.filter(calls, &match?({:release, _, _}, &1))

      assert length(reserve_calls) == 1
      assert length(release_calls) == 1
      assert Registry.lookup(Arbor.Voice.Registry, {user_id, agent_id}) == []
      refute Enum.any?(calls, &match?({:consume, _, _, _}, &1))
    end

    @tag spec: "VOICE-24"
    test "non-integer monotonic clock after reserve releases without system-clock fallback" do
      ctx = lifecycle_opts(monotonic_clock: fn -> :not_an_integer end)
      {user_id, agent_id} = unique_ids()

      assert {:error, :start_failed} = Voice.start_session(user_id, agent_id, ctx.opts)

      calls = FakeLedger.calls(ctx.ledger)
      assert length(Enum.filter(calls, &match?({:reserve, _, _, _, _, _}, &1))) == 1
      assert length(Enum.filter(calls, &match?({:release, _, _}, &1))) == 1
      assert Registry.lookup(Arbor.Voice.Registry, {user_id, agent_id}) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Signal transport failure must not crash a ready session
  # ---------------------------------------------------------------------------

  describe "signal resilience" do
    @tag spec: "VOICE-22"
    test "raising signals during stop does not prevent clean shutdown" do
      ctx = lifecycle_opts()
      {user_id, agent_id} = unique_ids()

      assert {:ok, key} = Voice.start_session(user_id, agent_id, ctx.opts)
      FakeSignals.set_mode(ctx.signals, :raise)

      assert :ok = Voice.stop_session(key)
      wait_until(fn -> Registry.lookup(Arbor.Voice.Registry, key) == [] end, 2_000)
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met before timeout")
      else
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end
end
