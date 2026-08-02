defmodule Arbor.Voice.BudgetLedgerCoreTest do
  @moduledoc """
  Pure table tests for reserve/consume/release/remaining decisions
  (VOICE-24 prerequisite — see `Arbor.Voice.BudgetLedger` for the shell).
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Voice.BudgetLedgerCore, as: Core

  defp vres(seed) do
    suffix =
      seed
      |> :erlang.phash2()
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(32, "0")
      |> String.slice(-32, 32)

    "vres_" <> suffix
  end

  defp fp(seed), do: Base.encode16(:crypto.hash(:sha256, seed), case: :lower)

  defp valid_data do
    %{
      "version" => 1,
      "utc_day" => "2026-08-02",
      "daily_limit_ms" => 60_000,
      "consumed_ms" => 0,
      "active_reservations" => [],
      "settlements" => []
    }
  end

  describe "reserve/5 admission" do
    @tag spec: "VOICE-24"
    test "first reserve on an empty record is admitted" do
      {:ok, state} = Core.new(nil, "2026-08-02", 1000, {:check, 60_000})

      assert {:ok, :admitted, fields} =
               Core.reserve(state, vres("0000000000000000000000000000000a"), 5000, 1000, 1000)

      assert fields.id == vres("0000000000000000000000000000000a")
      assert fields.requested_ms == 5000
      assert fields.reserved_at_ms == 1000
      assert fields.expires_at_ms == 7000
    end

    @tag spec: "VOICE-24"
    test "a reservation exactly equal to the remaining limit is admitted" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 10_000})

      assert {:ok, :admitted, fields} =
               Core.reserve(state, vres("0000000000000000000000000000000a"), 10_000, 0, 0)

      {:ok, state} = Core.commit_reservation(state, fields, fp("a"))

      assert {:error, :budget_exhausted} =
               Core.reserve(state, vres("0000000000000000000000000000000b"), 1, 0, 0)
    end

    @tag spec: "VOICE-24"
    test "exhaustion rejects a reservation that would exceed the daily limit" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 1000})

      assert {:error, :budget_exhausted} =
               Core.reserve(state, vres("0000000000000000000000000000000a"), 1001, 0, 0)
    end

    test "duplicate_reservation_id fails closed for an id already active" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 60_000})
      {:ok, :admitted, fields} = Core.reserve(state, vres("dup"), 1000, 0, 0)
      {:ok, state} = Core.commit_reservation(state, fields, fp("a"))
      assert {:error, :duplicate_reservation_id} = Core.reserve(state, vres("dup"), 500, 0, 0)
    end

    test "duplicate_reservation_id fails closed for an id already settled" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 60_000})
      {:ok, :admitted, fields} = Core.reserve(state, vres("dup"), 1000, 0, 0)
      fpv = fp("a")
      {:ok, state} = Core.commit_reservation(state, fields, fpv)
      {:ok, state} = Core.release(state, vres("dup"), fpv, 100)
      assert {:error, :duplicate_reservation_id} = Core.reserve(state, vres("dup"), 500, 100, 0)
    end

    test "capacity_exceeded once active+settled ids reach the fixed maximum" do
      max = Core.max_ledger_entries()
      {:ok, empty} = Core.new(nil, "2026-08-02", 0, {:check, 1_000_000})

      state =
        Enum.reduce(1..max, empty, fn i, state ->
          {:ok, :admitted, fields} = Core.reserve(state, vres(Integer.to_string(i)), 1, 0, 0)
          {:ok, new_state} = Core.commit_reservation(state, fields, fp("fp#{i}"))
          new_state
        end)

      assert {:error, :capacity_exceeded} = Core.reserve(state, vres("over"), 1, 0, 0)
    end
  end

  describe "consume/5 and release/4" do
    @tag spec: "VOICE-24"
    test "consuming less than requested releases the unused remainder" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 1000})

      {:ok, :admitted, fields} =
        Core.reserve(state, vres("0000000000000000000000000000000a"), 1000, 0, 0)

      fpv = fp("a")
      {:ok, state} = Core.commit_reservation(state, fields, fpv)
      assert Core.remaining(state) == 0

      {:ok, state} = Core.consume(state, vres("0000000000000000000000000000000a"), 400, fpv, 100)
      assert Core.remaining(state) == 600
      assert state.consumed_ms == 400
      assert state.active == []
    end

    @tag spec: "VOICE-24"
    test "explicit release returns the full reservation to the allowance" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 1000})

      {:ok, :admitted, fields} =
        Core.reserve(state, vres("0000000000000000000000000000000a"), 1000, 0, 0)

      fpv = fp("a")
      {:ok, state} = Core.commit_reservation(state, fields, fpv)
      {:ok, state} = Core.release(state, vres("0000000000000000000000000000000a"), fpv, 100)
      assert Core.remaining(state) == 1000
      assert state.consumed_ms == 0
      assert state.active == []
    end

    test "elapsed_exceeds_reservation fails closed" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 60_000})

      {:ok, :admitted, fields} =
        Core.reserve(state, vres("0000000000000000000000000000000a"), 1000, 0, 0)

      fpv = fp("a")
      {:ok, state} = Core.commit_reservation(state, fields, fpv)

      assert {:error, :elapsed_exceeds_reservation} =
               Core.consume(state, vres("0000000000000000000000000000000a"), 1001, fpv, 100)
    end

    test "reservation_not_found for an unknown id" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 60_000})
      assert {:error, :reservation_not_found} = Core.consume(state, vres("ghost"), 10, fp("x"), 0)
      assert {:error, :reservation_not_found} = Core.release(state, vres("ghost"), fp("x"), 0)
    end

    test "consume after release fails with reservation_already_released" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 60_000})

      {:ok, :admitted, fields} =
        Core.reserve(state, vres("0000000000000000000000000000000a"), 1000, 0, 0)

      fpv = fp("a")
      {:ok, state} = Core.commit_reservation(state, fields, fpv)
      {:ok, state} = Core.release(state, vres("0000000000000000000000000000000a"), fpv, 100)

      assert {:error, :reservation_already_released} =
               Core.consume(state, vres("0000000000000000000000000000000a"), 500, fpv, 200)
    end

    test "release after consume fails with reservation_already_consumed" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 60_000})

      {:ok, :admitted, fields} =
        Core.reserve(state, vres("0000000000000000000000000000000a"), 1000, 0, 0)

      fpv = fp("a")
      {:ok, state} = Core.commit_reservation(state, fields, fpv)
      {:ok, state} = Core.consume(state, vres("0000000000000000000000000000000a"), 500, fpv, 200)

      assert {:error, :reservation_already_consumed} =
               Core.release(state, vres("0000000000000000000000000000000a"), fpv, 300)
    end

    test "reservation_mismatch on consume with the wrong fingerprint" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 60_000})

      {:ok, :admitted, fields} =
        Core.reserve(state, vres("0000000000000000000000000000000a"), 1000, 0, 0)

      {:ok, state} = Core.commit_reservation(state, fields, fp("correct"))

      assert {:error, :reservation_mismatch} =
               Core.consume(
                 state,
                 vres("0000000000000000000000000000000a"),
                 500,
                 fp("wrong"),
                 100
               )
    end

    test "reservation_mismatch on release with the wrong fingerprint" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 60_000})

      {:ok, :admitted, fields} =
        Core.reserve(state, vres("0000000000000000000000000000000a"), 1000, 0, 0)

      {:ok, state} = Core.commit_reservation(state, fields, fp("correct"))

      assert {:error, :reservation_mismatch} =
               Core.release(state, vres("0000000000000000000000000000000a"), fp("wrong"), 100)
    end

    test "reservation_mismatch on a settled entry replayed with the wrong fingerprint" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 60_000})

      {:ok, :admitted, fields} =
        Core.reserve(state, vres("0000000000000000000000000000000a"), 1000, 0, 0)

      fpv = fp("correct")
      {:ok, state} = Core.commit_reservation(state, fields, fpv)
      {:ok, state} = Core.consume(state, vres("0000000000000000000000000000000a"), 500, fpv, 100)

      assert {:error, :reservation_mismatch} =
               Core.consume(
                 state,
                 vres("0000000000000000000000000000000a"),
                 500,
                 fp("wrong"),
                 200
               )
    end

    @tag spec: "VOICE-24"
    test "idempotent settlement: same-elapsed replay is a structural no-op" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 1000})

      {:ok, :admitted, fields} =
        Core.reserve(state, vres("0000000000000000000000000000000a"), 1000, 0, 0)

      fpv = fp("a")
      {:ok, state} = Core.commit_reservation(state, fields, fpv)

      {:ok, settled} =
        Core.consume(state, vres("0000000000000000000000000000000a"), 400, fpv, 100)

      assert {:ok, ^settled} =
               Core.consume(settled, vres("0000000000000000000000000000000a"), 400, fpv, 999)
    end

    @tag spec: "VOICE-24"
    test "idempotent release replay is a structural no-op" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 1000})

      {:ok, :admitted, fields} =
        Core.reserve(state, vres("0000000000000000000000000000000a"), 1000, 0, 0)

      fpv = fp("a")
      {:ok, state} = Core.commit_reservation(state, fields, fpv)
      {:ok, released} = Core.release(state, vres("0000000000000000000000000000000a"), fpv, 100)

      assert {:ok, ^released} =
               Core.release(released, vres("0000000000000000000000000000000a"), fpv, 999)
    end

    @tag spec: "VOICE-24"
    test "conflicting_replay: a different elapsed value fails closed" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 1000})

      {:ok, :admitted, fields} =
        Core.reserve(state, vres("0000000000000000000000000000000a"), 1000, 0, 0)

      fpv = fp("a")
      {:ok, state} = Core.commit_reservation(state, fields, fpv)

      {:ok, settled} =
        Core.consume(state, vres("0000000000000000000000000000000a"), 400, fpv, 100)

      assert {:error, :conflicting_replay} =
               Core.consume(settled, vres("0000000000000000000000000000000a"), 401, fpv, 999)
    end
  end

  describe "expiry pruning" do
    @tag spec: "VOICE-24"
    test "an expired active reservation is pruned and its allowance reclaimed" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 1000})

      {:ok, :admitted, fields} =
        Core.reserve(state, vres("0000000000000000000000000000000a"), 1000, 0, 0)

      {:ok, state} = Core.commit_reservation(state, fields, fp("a"))
      assert Core.remaining(state) == 0
      data = Core.to_data(state)

      {:ok, pruned} = Core.new(data, "2026-08-02", 1000, :skip)
      assert Core.remaining(pruned) == 1000

      assert {:error, :reservation_not_found} =
               Core.consume(pruned, vres("0000000000000000000000000000000a"), 100, fp("a"), 1000)

      assert {:ok, :admitted, _fields} =
               Core.reserve(pruned, vres("0000000000000000000000000000000a"), 200, 1000, 0)
    end

    test "a reservation not yet at its expiry survives" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 1000})

      {:ok, :admitted, fields} =
        Core.reserve(state, vres("0000000000000000000000000000000a"), 1000, 0, 0)

      {:ok, state} = Core.commit_reservation(state, fields, fp("a"))
      data = Core.to_data(state)

      {:ok, still_active} = Core.new(data, "2026-08-02", 999, :skip)
      assert Core.remaining(still_active) == 0
    end
  end

  describe "new/4 decode invariants" do
    @tag spec: "VOICE-24"
    test "rejects an extra top-level key" do
      data = Map.put(valid_data(), "extra", 1)
      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    @tag spec: "VOICE-24"
    test "rejects a missing top-level key" do
      data = Map.drop(valid_data(), ["settlements"])
      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    @tag spec: "VOICE-24"
    test "rejects active reservations list above the cap" do
      active = for i <- 1..(Core.max_ledger_entries() + 1), do: valid_active_entry(i)
      data = Map.put(valid_data(), "active_reservations", active)
      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    @tag spec: "VOICE-24"
    test "rejects settlements list above the cap" do
      settlements = for i <- 1..(Core.max_ledger_entries() + 1), do: valid_consumed_settlement(i)
      data = Map.put(valid_data(), "settlements", settlements)
      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    @tag spec: "VOICE-24"
    test "rejects active+settlement combined list above the cap" do
      active = for i <- 1..Core.max_ledger_entries(), do: valid_active_entry(i)

      data =
        valid_data()
        |> Map.put("active_reservations", active)
        |> Map.put("settlements", [valid_consumed_settlement(Core.max_ledger_entries() + 1)])

      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    @tag spec: "VOICE-24"
    test "rejects a consumed settlement whose requested_ms is zero" do
      settlement = valid_consumed_settlement(1, requested_ms: 0, elapsed_ms: 0)

      data = %{
        valid_data()
        | "daily_limit_ms" => 1000,
          "consumed_ms" => 0,
          "settlements" => [settlement]
      }

      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    @tag spec: "VOICE-24"
    test "rejects consumed_ms above the daily limit" do
      data = %{valid_data() | "daily_limit_ms" => 1000, "consumed_ms" => 1001}
      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    @tag spec: "VOICE-24"
    test "rejects consumed_ms + active requested_ms above the daily limit" do
      active = [valid_active_entry(1, requested_ms: 600)]

      data = %{
        valid_data()
        | "daily_limit_ms" => 1000,
          "consumed_ms" => 500,
          "active_reservations" => active
      }

      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    @tag spec: "VOICE-24"
    test "rejects consumed total not equal to sum of consumed settlements" do
      settlement = valid_consumed_settlement(1, elapsed_ms: 100, requested_ms: 100)

      data = %{
        valid_data()
        | "daily_limit_ms" => 1000,
          "consumed_ms" => 200,
          "settlements" => [settlement]
      }

      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    @tag spec: "VOICE-24"
    test "rejects a consumed settlement whose elapsed_ms exceeds requested_ms" do
      settlement = valid_consumed_settlement(1, elapsed_ms: 200, requested_ms: 100)

      data = %{
        valid_data()
        | "daily_limit_ms" => 1000,
          "consumed_ms" => 200,
          "settlements" => [settlement]
      }

      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    @tag spec: "VOICE-24"
    test "rejects expiry earlier than reserved_at_ms + requested_ms" do
      entry = %{
        "id" => vres("early"),
        "requested_ms" => 100,
        "reserved_at_ms" => 1000,
        "expires_at_ms" => 1099,
        "fingerprint" => fp("a")
      }

      data = Map.put(valid_data(), "active_reservations", [entry])
      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    @tag spec: "VOICE-24"
    test "rejects an invalid ISO UTC day" do
      data = %{valid_data() | "utc_day" => "2026-13-02"}
      assert {:error, :malformed_state} = Core.new(data, "2026-13-02", 0, :skip)
    end

    @tag spec: "VOICE-24"
    test "rejects a non-ISO UTC day string" do
      assert {:error, :malformed_state} = Core.new(nil, "08-02-2026", 0, :skip)
    end
  end

  describe "new/4 malformed state" do
    test "rejects an unknown version" do
      data = Map.put(valid_data(), "version", 2)
      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    test "rejects a utc_day mismatch against the requested day" do
      assert {:error, :malformed_state} = Core.new(valid_data(), "2026-08-03", 0, :skip)
    end

    test "rejects a negative consumed_ms" do
      data = Map.put(valid_data(), "consumed_ms", -1)
      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    test "rejects a non-list active_reservations" do
      data = Map.put(valid_data(), "active_reservations", %{})
      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    test "rejects an improper active_reservations tail" do
      entry = %{
        "id" => vres("x"),
        "requested_ms" => 1,
        "reserved_at_ms" => 0,
        "expires_at_ms" => 1,
        "fingerprint" => fp("a")
      }

      data = Map.put(valid_data(), "active_reservations", [entry | :not_a_list])
      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    test "rejects an improper settlements tail" do
      entry = %{
        "id" => vres("x"),
        "kind" => "released",
        "settled_at_ms" => 0,
        "fingerprint" => fp("a")
      }

      data = Map.put(valid_data(), "settlements", [entry | "tail"])
      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    test "rejects an active entry with an extra key" do
      entry = %{
        "id" => vres("x"),
        "requested_ms" => 1,
        "reserved_at_ms" => 0,
        "expires_at_ms" => 1,
        "fingerprint" => fp("a"),
        "extra" => 1
      }

      data = Map.put(valid_data(), "active_reservations", [entry])
      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    test "rejects a released settlement carrying elapsed_ms" do
      entry = %{
        "id" => vres("x"),
        "kind" => "released",
        "elapsed_ms" => 1,
        "settled_at_ms" => 0,
        "fingerprint" => fp("a")
      }

      data = Map.put(valid_data(), "settlements", [entry])
      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    test "rejects a malformed fingerprint" do
      entry = %{
        "id" => vres("x"),
        "requested_ms" => 1,
        "reserved_at_ms" => 0,
        "expires_at_ms" => 1,
        "fingerprint" => "short"
      }

      data = Map.put(valid_data(), "active_reservations", [entry])
      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    test "rejects duplicate ids across active and settlements" do
      active_entry = %{
        "id" => vres("dup"),
        "requested_ms" => 1,
        "reserved_at_ms" => 0,
        "expires_at_ms" => 5,
        "fingerprint" => fp("a")
      }

      settlement_entry = %{
        "id" => vres("dup"),
        "kind" => "released",
        "settled_at_ms" => 2,
        "fingerprint" => fp("a")
      }

      data =
        valid_data()
        |> Map.put("active_reservations", [active_entry])
        |> Map.put("settlements", [settlement_entry])

      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, :skip)
    end

    test "never overwrites: a malformed record's data is not accepted into a usable state" do
      data = Map.put(valid_data(), "daily_limit_ms", -1)
      assert {:error, :malformed_state} = Core.new(data, "2026-08-02", 0, {:check, 60_000})
    end
  end

  describe "conflicting daily_limit_ms" do
    @tag spec: "VOICE-24"
    test "a later call with a different limit is rejected, not silently reinterpreted" do
      data = valid_data()
      assert {:ok, _state} = Core.new(data, "2026-08-02", 0, {:check, 60_000})
      assert {:error, :conflicting_limit} = Core.new(data, "2026-08-02", 0, {:check, 30_000})
    end

    test "consume/release skip the limit check (:skip)" do
      data = Map.put(valid_data(), "daily_limit_ms", 60_000)
      assert {:ok, _state} = Core.new(data, "2026-08-02", 0, :skip)
    end
  end

  describe "arithmetic bounds" do
    setup do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 60_000})
      %{state: state}
    end

    test "rejects zero requested_ms", %{state: state} do
      assert {:error, :invalid_amount} =
               Core.reserve(state, vres("0000000000000000000000000000000a"), 0, 0, 0)
    end

    test "rejects negative requested_ms", %{state: state} do
      assert {:error, :invalid_amount} =
               Core.reserve(state, vres("0000000000000000000000000000000a"), -1, 0, 0)
    end

    test "rejects float requested_ms", %{state: state} do
      assert {:error, :invalid_amount} =
               Core.reserve(state, vres("0000000000000000000000000000000a"), 1.5, 0, 0)
    end

    test "rejects requested_ms over the sanity ceiling", %{state: state} do
      assert {:error, :invalid_amount} =
               Core.reserve(
                 state,
                 vres("0000000000000000000000000000000a"),
                 999_999_999_999_999,
                 0,
                 0
               )
    end

    test "rejects a malformed reservation id", %{state: state} do
      assert {:error, :invalid_reservation_id} = Core.reserve(state, "", 1000, 0, 0)
    end

    test "rejects negative elapsed_ms on consume", %{state: state} do
      {:ok, :admitted, fields} =
        Core.reserve(state, vres("0000000000000000000000000000000a"), 1000, 0, 0)

      fpv = fp("a")
      {:ok, state} = Core.commit_reservation(state, fields, fpv)

      assert {:error, :invalid_amount} =
               Core.consume(state, vres("0000000000000000000000000000000a"), -1, fpv, 0)
    end

    test "rejects float elapsed_ms on consume", %{state: state} do
      {:ok, :admitted, fields} =
        Core.reserve(state, vres("0000000000000000000000000000000a"), 1000, 0, 0)

      fpv = fp("a")
      {:ok, state} = Core.commit_reservation(state, fields, fpv)

      assert {:error, :invalid_amount} =
               Core.consume(state, vres("0000000000000000000000000000000a"), 1.0, fpv, 0)
    end
  end

  describe "to_data/1 round trip" do
    test "encodes and decodes back to the same accounting state" do
      {:ok, state} = Core.new(nil, "2026-08-02", 0, {:check, 1000})

      {:ok, :admitted, fields} =
        Core.reserve(state, vres("0000000000000000000000000000000a"), 300, 0, 0)

      fpv = fp("a")
      {:ok, state} = Core.commit_reservation(state, fields, fpv)
      {:ok, state} = Core.consume(state, vres("0000000000000000000000000000000a"), 100, fpv, 50)

      data = Core.to_data(state)
      assert {:ok, decoded} = Core.new(data, "2026-08-02", 50, {:check, 1000})
      assert decoded.consumed_ms == 100
      assert decoded.active == []
      assert [%{id: id, kind: :consumed, elapsed_ms: 100}] = decoded.settlements
      assert id == vres("0000000000000000000000000000000a")
    end
  end

  defp valid_active_entry(i, opts \\ []) do
    seed = Integer.to_string(i)

    %{
      "id" => vres(seed),
      "requested_ms" => Keyword.get(opts, :requested_ms, 1),
      "reserved_at_ms" => 0,
      "expires_at_ms" => Keyword.get(opts, :expires_at_ms, 1000),
      "fingerprint" => fp(seed)
    }
  end

  defp valid_consumed_settlement(i, opts \\ []) do
    seed = Integer.to_string(i)
    elapsed = Keyword.get(opts, :elapsed_ms, 1)
    requested = Keyword.get(opts, :requested_ms, elapsed)

    %{
      "id" => vres(seed),
      "kind" => "consumed",
      "elapsed_ms" => elapsed,
      "settled_at_ms" => 0,
      "fingerprint" => fp(seed),
      "requested_ms" => requested
    }
  end
end
