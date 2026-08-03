defmodule Arbor.Voice.Session.SettlementTest do
  @moduledoc """
  Tests for `Arbor.Voice.Session.Settlement` (VP-04D1 — VOICE-24
  prerequisite): construction/validation, phase transitions, elapsed
  clamping, retry-after-error, caller-death replay for both consume and
  release, and concurrent-settle safety.

  All tests inject `Arbor.Voice.Test.SettlementFakeLedger` — never the real
  `Arbor.Voice.BudgetLedger` — through explicit `opts`, per hermeticity
  convention. Evidence for the caller-death and concurrency tests is owned by
  this ExUnit test process (the fake ledger's `Agent` plus the `settlement`
  struct itself), so it survives the killed `Task` callers under test.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Voice.BudgetLedger.Reservation
  alias Arbor.Voice.Session.Settlement
  alias Arbor.Voice.Test.SettlementFakeLedger, as: Fake

  defmodule NotALedger do
    @moduledoc false
  end

  defp reservation(opts \\ []) do
    %Reservation{
      id: Keyword.get(opts, :id, "vres_test0000000000000000000000"),
      key:
        Keyword.get(
          opts,
          :key,
          "0000000000000000000000000000000000000000000000000000000000000000:2026-08-02"
        ),
      utc_day: "2026-08-02",
      requested_ms: Keyword.get(opts, :requested_ms, 60_000),
      reserved_at_ms: Keyword.get(opts, :reserved_at_ms, 1_000),
      expires_at_ms: Keyword.get(opts, :expires_at_ms, 61_000)
    }
  end

  setup do
    name = :"settlement_fake_ledger_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Fake.start_link(name: name)
    on_exit(fn -> Fake.stop(name) end)
    %{ledger_opts: [name: name], name: name}
  end

  # ── construction and validation ──

  describe "new/4" do
    @tag spec: "VOICE-24"
    test "constructs with the default release_pending phase and no frozen elapsed", %{
      ledger_opts: ledger_opts
    } do
      assert {:ok, settlement} = Settlement.new(reservation(), Fake, ledger_opts, 1_000)
      assert Settlement.phase(settlement) == :release_pending
      assert Settlement.frozen_elapsed(settlement) == nil
    end

    @tag spec: "VOICE-24"
    test "rejects a non-Reservation struct", %{ledger_opts: ledger_opts} do
      assert {:error, :invalid_reservation} = Settlement.new(%{id: "x"}, Fake, ledger_opts, 1_000)
      assert {:error, :invalid_reservation} = Settlement.new(nil, Fake, ledger_opts, 1_000)
    end

    @tag spec: "VOICE-24"
    test "rejects a reservation with a non-positive requested_ms", %{ledger_opts: ledger_opts} do
      assert {:error, :invalid_reservation} =
               Settlement.new(reservation(requested_ms: 0), Fake, ledger_opts, 1_000)

      assert {:error, :invalid_reservation} =
               Settlement.new(reservation(requested_ms: -1), Fake, ledger_opts, 1_000)
    end

    @tag spec: "VOICE-24"
    test "rejects a ledger module missing consume/3 or release/2", %{ledger_opts: ledger_opts} do
      assert {:error, :invalid_ledger} =
               Settlement.new(reservation(), NotALedger, ledger_opts, 1_000)
    end

    @tag spec: "VOICE-24"
    test "rejects a non-atom ledger", %{ledger_opts: ledger_opts} do
      assert {:error, :invalid_ledger} = Settlement.new(reservation(), "Fake", ledger_opts, 1_000)
    end

    @tag spec: "VOICE-24"
    test "rejects non-keyword ledger_opts", %{ledger_opts: _ledger_opts} do
      assert {:error, :invalid_ledger_opts} = Settlement.new(reservation(), Fake, %{}, 1_000)
      assert {:error, :invalid_ledger_opts} = Settlement.new(reservation(), Fake, [1, 2], 1_000)
    end

    @tag spec: "VOICE-24"
    test "rejects a non-integer start_ms", %{ledger_opts: ledger_opts} do
      assert {:error, :invalid_start_ms} =
               Settlement.new(reservation(), Fake, ledger_opts, "1000")

      assert {:error, :invalid_start_ms} = Settlement.new(reservation(), Fake, ledger_opts, nil)
    end
  end

  # ── arm_consume/1 transitions ──

  describe "arm_consume/1" do
    @tag spec: "VOICE-24"
    test "arms from release_pending into consume_pending", %{ledger_opts: ledger_opts} do
      assert {:ok, settlement} = Settlement.new(reservation(), Fake, ledger_opts, 1_000)
      assert :ok = Settlement.arm_consume(settlement)
      assert Settlement.phase(settlement) == :consume_pending
    end

    @tag spec: "VOICE-24"
    test "repeated arming is idempotent", %{ledger_opts: ledger_opts} do
      assert {:ok, settlement} = Settlement.new(reservation(), Fake, ledger_opts, 1_000)
      assert :ok = Settlement.arm_consume(settlement)
      assert :ok = Settlement.arm_consume(settlement)
      assert Settlement.phase(settlement) == :consume_pending
    end

    @tag spec: "VOICE-24"
    test "rejects arming after done", %{ledger_opts: ledger_opts} do
      assert {:ok, settlement} = Settlement.new(reservation(), Fake, ledger_opts, 1_000)
      assert :ok = Settlement.settle(settlement, 1_500)
      assert Settlement.phase(settlement) == :done
      assert {:error, :already_done} = Settlement.arm_consume(settlement)
    end
  end

  # ── settle/2 release path ──

  describe "settle/2 release path" do
    @tag spec: "VOICE-24"
    test "releases the reservation and reaches done", %{ledger_opts: ledger_opts, name: name} do
      r = reservation()
      assert {:ok, settlement} = Settlement.new(r, Fake, ledger_opts, 1_000)

      assert :ok = Settlement.settle(settlement, 1_500)
      assert Settlement.phase(settlement) == :done
      assert Fake.calls(name) == [{:release, r.id}]
    end

    @tag spec: "VOICE-24"
    test "settle is idempotent once done — no repeat ledger call", %{
      ledger_opts: ledger_opts,
      name: name
    } do
      assert {:ok, settlement} = Settlement.new(reservation(), Fake, ledger_opts, 1_000)
      assert :ok = Settlement.settle(settlement, 1_500)
      assert :ok = Settlement.settle(settlement, 1_600)
      assert :ok = Settlement.settle(settlement, 1_700)
      assert length(Fake.calls(name)) == 1
    end

    @tag spec: "VOICE-24"
    test "rejects a non-integer now_ms without raising", %{ledger_opts: ledger_opts} do
      assert {:ok, settlement} = Settlement.new(reservation(), Fake, ledger_opts, 1_000)
      assert {:error, :invalid_now_ms} = Settlement.settle(settlement, "now")
      assert Settlement.phase(settlement) == :release_pending
    end
  end

  # ── settle/2 consume path — elapsed clamp ──

  describe "settle/2 consume path — elapsed clamp" do
    @tag spec: "VOICE-24"
    test "clamps a now_ms before start_ms to zero", %{ledger_opts: ledger_opts} do
      assert {:ok, settlement} = Settlement.new(reservation(), Fake, ledger_opts, 10_000)
      assert :ok = Settlement.arm_consume(settlement)
      assert :ok = Settlement.settle(settlement, 5_000)
      assert Settlement.frozen_elapsed(settlement) == 0
    end

    @tag spec: "VOICE-24"
    test "freezes the exact elapsed value within bounds", %{ledger_opts: ledger_opts} do
      assert {:ok, settlement} =
               Settlement.new(reservation(requested_ms: 60_000), Fake, ledger_opts, 1_000)

      assert :ok = Settlement.arm_consume(settlement)
      assert :ok = Settlement.settle(settlement, 1_500)
      assert Settlement.frozen_elapsed(settlement) == 500
    end

    @tag spec: "VOICE-24"
    test "clamps a now_ms past requested_ms to requested_ms", %{ledger_opts: ledger_opts} do
      assert {:ok, settlement} =
               Settlement.new(reservation(requested_ms: 1_000), Fake, ledger_opts, 1_000)

      assert :ok = Settlement.arm_consume(settlement)
      assert :ok = Settlement.settle(settlement, 999_999)
      assert Settlement.frozen_elapsed(settlement) == 1_000
    end
  end

  # ── retry after ledger error reuses the frozen elapsed value ──

  describe "retry after injected ledger error" do
    @tag spec: "VOICE-24"
    test "consume retry after error reuses the exact frozen elapsed value", %{
      ledger_opts: ledger_opts,
      name: name
    } do
      r = reservation(requested_ms: 60_000)
      assert {:ok, settlement} = Settlement.new(r, Fake, ledger_opts, 1_000)
      assert :ok = Settlement.arm_consume(settlement)

      Fake.set_mode(name, :error)
      assert {:error, :backend_error} = Settlement.settle(settlement, 1_500)
      assert Settlement.phase(settlement) == :consume_pending
      first_frozen = Settlement.frozen_elapsed(settlement)
      assert first_frozen == 500

      Fake.set_mode(name, :ok)
      assert :ok = Settlement.settle(settlement, 9_999)
      assert Settlement.phase(settlement) == :done
      assert Settlement.frozen_elapsed(settlement) == first_frozen

      assert [{:consume, id, elapsed1}, {:consume, id, elapsed2}] = Fake.calls(name)
      assert id == r.id
      assert elapsed1 == elapsed2
      assert elapsed1 == first_frozen
    end

    @tag spec: "VOICE-24"
    test "release retry after error is idempotent replay", %{
      ledger_opts: ledger_opts,
      name: name
    } do
      r = reservation()
      assert {:ok, settlement} = Settlement.new(r, Fake, ledger_opts, 1_000)

      Fake.set_mode(name, :error)
      assert {:error, :backend_error} = Settlement.settle(settlement, 1_500)
      assert Settlement.phase(settlement) == :release_pending

      Fake.set_mode(name, :ok)
      assert :ok = Settlement.settle(settlement, 1_600)
      assert Settlement.phase(settlement) == :done

      assert [{:release, id1}, {:release, id2}] = Fake.calls(name)
      assert id1 == id2
      assert id1 == r.id
    end
  end

  # ── caller death before ledger IO completes ──

  describe "caller death before completion publication" do
    @tag spec: "VOICE-24"
    test "consume: killing the settling Task after durable ledger acceptance replays without double charge",
         %{ledger_opts: ledger_opts, name: name} do
      r = reservation(requested_ms: 60_000)
      assert {:ok, settlement} = Settlement.new(r, Fake, ledger_opts, 1_000)
      assert :ok = Settlement.arm_consume(settlement)

      test_pid = self()
      Fake.set_mode(name, {:pause_once, test_pid})

      {:ok, task_pid} =
        Task.start(fn ->
          Settlement.settle(settlement, 1_500)
        end)

      assert_receive {:accepted, ^task_pid, {:consume, id, elapsed}}, 1_000
      assert id == r.id
      assert elapsed == 500

      ref = Process.monitor(task_pid)
      Process.exit(task_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^task_pid, :killed}, 1_000

      # Evidence survives the killed caller: the atomics-backed settlement
      # struct and the fake ledger's Agent are both owned by this test
      # process, not by the dead Task.
      assert Settlement.phase(settlement) == :consume_pending
      assert Settlement.frozen_elapsed(settlement) == 500

      assert :ok = Settlement.settle(settlement, 999_999)
      assert Settlement.phase(settlement) == :done
      assert Settlement.frozen_elapsed(settlement) == 500

      assert [{:consume, ^id, 500}, {:consume, ^id, 500}] = Fake.calls(name)
    end

    @tag spec: "VOICE-24"
    test "release: killing the settling Task after durable ledger acceptance replays to done", %{
      ledger_opts: ledger_opts,
      name: name
    } do
      r = reservation()
      assert {:ok, settlement} = Settlement.new(r, Fake, ledger_opts, 1_000)

      test_pid = self()
      Fake.set_mode(name, {:pause_once, test_pid})

      {:ok, task_pid} =
        Task.start(fn ->
          Settlement.settle(settlement, 1_500)
        end)

      assert_receive {:accepted, ^task_pid, {:release, id}}, 1_000
      assert id == r.id

      ref = Process.monitor(task_pid)
      Process.exit(task_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^task_pid, :killed}, 1_000

      assert Settlement.phase(settlement) == :release_pending

      assert :ok = Settlement.settle(settlement, 1_600)
      assert Settlement.phase(settlement) == :done

      assert [{:release, ^id}, {:release, ^id}] = Fake.calls(name)
    end
  end

  # ── concurrent settle calls ──

  describe "concurrent settle calls" do
    @tag spec: "VOICE-24"
    test "concurrent consume settles never split into two elapsed values", %{
      ledger_opts: ledger_opts,
      name: name
    } do
      r = reservation(requested_ms: 60_000)
      assert {:ok, settlement} = Settlement.new(r, Fake, ledger_opts, 1_000)
      assert :ok = Settlement.arm_consume(settlement)

      results =
        1..8
        |> Task.async_stream(fn i -> Settlement.settle(settlement, 1_000 + i) end,
          max_concurrency: 8
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &(&1 == :ok))
      assert Settlement.phase(settlement) == :done

      elapsed_values =
        name
        |> Fake.calls()
        |> Enum.map(fn {:consume, _id, elapsed} -> elapsed end)
        |> Enum.uniq()

      assert elapsed_values == [Settlement.frozen_elapsed(settlement)]
    end

    @tag spec: "VOICE-24"
    test "concurrent release settles end with one logical settlement", %{
      ledger_opts: ledger_opts,
      name: name
    } do
      r = reservation()
      assert {:ok, settlement} = Settlement.new(r, Fake, ledger_opts, 1_000)

      results =
        1..8
        |> Task.async_stream(fn _ -> Settlement.settle(settlement, 1_500) end,
          max_concurrency: 8
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &(&1 == :ok))
      assert Settlement.phase(settlement) == :done
      assert Enum.all?(Fake.calls(name), &(&1 == {:release, r.id}))
    end
  end
end
