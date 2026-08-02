defmodule Arbor.Voice.BudgetLedgerTest do
  @moduledoc """
  Shell tests for `Arbor.Voice.BudgetLedger`: attestation gating, CAS write
  shape, bounded retry, malformed-record safety, backend error propagation,
  and reservation provenance (VOICE-24 prerequisite).

  All tests inject a private, network-free fake backend through explicit
  `opts` — never `Application.put_env` — per the packet's hermeticity
  requirement.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Voice.BudgetLedger
  alias Arbor.Voice.BudgetLedger.Reservation
  alias Arbor.Voice.Test.BudgetLedgerFakeBackend, as: Fake
  alias Arbor.Voice.Test.BudgetLedgerNoCasBackend
  alias Arbor.Voice.Test.BudgetLedgerNoDurabilityBackend
  alias Arbor.Voice.Test.BudgetLedgerWeakDurabilityBackend

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

  setup do
    name = :"budget_ledger_fake_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Fake.start_link(agent_name: name)
    on_exit(fn -> Fake.stop(name) end)
    %{opts: [backend: Fake, backend_opts: [agent_name: name]], name: name}
  end

  describe "readiness/1 and attestation" do
    test "ok only with a CAS-capable, node_restart-durable backend", %{opts: opts} do
      assert {:ok, %{durability: :node_restart}} = BudgetLedger.readiness(opts)
    end

    test "rejects a backend missing compare_and_swap/4" do
      name = :"budget_ledger_no_cas_#{System.unique_integer([:positive])}"

      assert {:error, :unsupported} =
               BudgetLedger.readiness(
                 backend: BudgetLedgerNoCasBackend,
                 backend_opts: [agent_name: name]
               )
    end

    test "rejects a backend missing durability_class/1" do
      name = :"budget_ledger_no_dur_#{System.unique_integer([:positive])}"

      assert {:error, :unsupported} =
               BudgetLedger.readiness(
                 backend: BudgetLedgerNoDurabilityBackend,
                 backend_opts: [agent_name: name]
               )
    end

    test "rejects a backend reporting durability below :node_restart" do
      name = :"budget_ledger_weak_dur_#{System.unique_integer([:positive])}"

      assert {:error, :not_node_restart} =
               BudgetLedger.readiness(
                 backend: BudgetLedgerWeakDurabilityBackend,
                 backend_opts: [agent_name: name]
               )
    end

    test "fails closed under this app's checked-in test config (no backend configured)" do
      assert {:error, :disabled} = BudgetLedger.readiness([])
    end

    test "namespace is fixed — an opts :namespace key is rejected, not silently honored", %{
      opts: opts
    } do
      assert {:error, :invalid_options} = BudgetLedger.readiness(opts ++ [namespace: :other])
    end

    test "rejects now_unix_ms in readiness opts", %{opts: opts} do
      assert {:error, :invalid_options} =
               BudgetLedger.readiness(opts ++ [now_unix_ms: 0])
    end

    test "rejects an unknown opts key", %{opts: opts} do
      assert {:error, :invalid_options} = BudgetLedger.readiness(opts ++ [bogus: true])
    end
  end

  describe "attestation gates every operation, not only readiness" do
    test "consume attests CAS support before reading persistence" do
      key = String.duplicate("a", 64) <> ":2026-08-02"

      reservation = %Reservation{
        id: vres("x"),
        key: key,
        utc_day: "2026-08-02",
        requested_ms: 1,
        reserved_at_ms: 0,
        expires_at_ms: 1
      }

      name = :"budget_ledger_no_cas_consume_#{System.unique_integer([:positive])}"

      assert {:error, :unsupported} =
               BudgetLedger.consume(reservation, 1,
                 backend: BudgetLedgerNoCasBackend,
                 backend_opts: [agent_name: name]
               )
    end

    test "release attests CAS support before reading persistence" do
      key = String.duplicate("a", 64) <> ":2026-08-02"

      reservation = %Reservation{
        id: vres("x"),
        key: key,
        utc_day: "2026-08-02",
        requested_ms: 1,
        reserved_at_ms: 0,
        expires_at_ms: 1
      }

      name = :"budget_ledger_no_cas_release_#{System.unique_integer([:positive])}"

      assert {:error, :unsupported} =
               BudgetLedger.release(reservation,
                 backend: BudgetLedgerNoCasBackend,
                 backend_opts: [agent_name: name]
               )
    end

    test "remaining attests CAS support before reading persistence" do
      name = :"budget_ledger_no_cas_remaining_#{System.unique_integer([:positive])}"

      assert {:error, :unsupported} =
               BudgetLedger.remaining("user-1", "2026-08-02", 60_000,
                 backend: BudgetLedgerNoCasBackend,
                 backend_opts: [agent_name: name]
               )
    end
  end

  describe "caller input validation gates every operation" do
    @tag spec: "VOICE-24"
    test "reserve rejects an empty user_id", %{opts: opts} do
      assert {:error, :invalid_user_id} =
               BudgetLedger.reserve("", "2026-08-02", 100, 60_000, opts)
    end

    @tag spec: "VOICE-24"
    test "reserve rejects a whitespace-only user_id", %{opts: opts} do
      assert {:error, :invalid_user_id} =
               BudgetLedger.reserve("   ", "2026-08-02", 100, 60_000, opts)
    end

    @tag spec: "VOICE-24"
    test "reserve rejects an invalid UTF-8 user_id", %{opts: opts} do
      assert {:error, :invalid_user_id} =
               BudgetLedger.reserve(<<0xFF>>, "2026-08-02", 100, 60_000, opts)
    end
  end

  describe "reservation provenance — forged claims fail closed" do
    @tag spec: "VOICE-24"
    test "consume rejects a forged requested_ms with mismatched fingerprint", %{opts: opts} do
      assert {:ok, r} = BudgetLedger.reserve("user-1", "2026-08-02", 100, 60_000, opts)
      forged = %{r | requested_ms: r.requested_ms + 1}
      assert {:error, :reservation_mismatch} = BudgetLedger.consume(forged, 50, opts)
      assert {:error, :reservation_mismatch} = BudgetLedger.release(forged, opts)
    end

    @tag spec: "VOICE-24"
    test "consume and release reject non-Reservation input", %{opts: opts} do
      assert {:error, :invalid_reservation} = BudgetLedger.consume(%{id: "x"}, 50, opts)
      assert {:error, :invalid_reservation} = BudgetLedger.consume(nil, 50, opts)
      assert {:error, :invalid_reservation} = BudgetLedger.release(%{id: "x"}, opts)
      assert {:error, :invalid_reservation} = BudgetLedger.release(nil, opts)
    end

    @tag spec: "VOICE-24"
    test "consume rejects a reservation whose expiry violates the minimum invariant before backend IO",
         %{
           opts: opts,
           name: name
         } do
      assert {:ok, r} = BudgetLedger.reserve("user-1", "2026-08-02", 100, 60_000, opts)
      forged = %{r | expires_at_ms: r.reserved_at_ms + r.requested_ms - 1}

      :ok = Fake.clear_history(name)

      assert {:error, :invalid_reservation} = BudgetLedger.consume(forged, 50, opts)
      assert Fake.history(name) == []
    end

    @tag spec: "VOICE-24"
    test "consume rejects forged timestamps", %{opts: opts} do
      assert {:ok, r} = BudgetLedger.reserve("user-1", "2026-08-02", 100, 60_000, opts)
      forged = %{r | expires_at_ms: r.expires_at_ms + 1}
      assert {:error, :reservation_mismatch} = BudgetLedger.consume(forged, 50, opts)
    end

    @tag spec: "VOICE-24"
    test "release rejects an id swapped onto another live reservation's fields", %{opts: opts} do
      assert {:ok, r1} = BudgetLedger.reserve("user-1", "2026-08-02", 100, 60_000, opts)
      assert {:ok, r2} = BudgetLedger.reserve("user-1", "2026-08-02", 150, 60_000, opts)
      forged = %{r1 | id: r2.id}
      assert {:error, :reservation_mismatch} = BudgetLedger.release(forged, opts)
    end

    @tag spec: "VOICE-24"
    test "consume and release reject a key/day mismatch before touching persistence", %{
      opts: opts
    } do
      assert {:ok, r} = BudgetLedger.reserve("user-1", "2026-08-02", 100, 60_000, opts)
      forged = %{r | utc_day: "2026-08-03"}
      assert {:error, :invalid_reservation} = BudgetLedger.consume(forged, 50, opts)
      assert {:error, :invalid_reservation} = BudgetLedger.release(forged, opts)
    end
  end

  describe "CAS write shape and key privacy" do
    @tag spec: "VOICE-24"
    test "first reserve issues an insert (:not_found expected CAS) and hashes the user id in the key",
         %{
           opts: opts,
           name: name
         } do
      assert {:ok, %Reservation{} = r} =
               BudgetLedger.reserve("user-1", "2026-08-02", 1000, 60_000, opts)

      assert String.starts_with?(r.id, "vres_")
      assert byte_size(r.id) == 5 + 32

      [suffix] = String.split(r.id, "vres_", trim: true)
      assert String.match?(suffix, ~r/^[0-9a-f]{32}$/)

      expected_key =
        Base.encode16(:crypto.hash(:sha256, "user-1"), case: :lower) <> ":" <> "2026-08-02"

      assert r.key == expected_key

      assert [%{key: ^expected_key, cas_expected: :not_found}] =
               Enum.filter(Fake.history(name), &(&1.kind == :compare_and_swap))
    end

    @tag spec: "VOICE-24"
    test "second reserve updates and fences on the observed Record generation and revision", %{
      opts: opts,
      name: name
    } do
      assert {:ok, r1} = BudgetLedger.reserve("user-1", "2026-08-02", 1000, 60_000, opts)
      assert {:ok, r2} = BudgetLedger.reserve("user-1", "2026-08-02", 1000, 60_000, opts)

      history = Enum.filter(Fake.history(name), &(&1.kind == :compare_and_swap))
      assert length(history) == 2

      [
        %{cas_expected: :not_found},
        %{cas_expected: {:value, %Arbor.Contracts.Persistence.Record{}}} = update
      ] = history

      assert update.key == r1.key
      assert r1.key == r2.key
    end

    @tag spec: "VOICE-24"
    test "raw user id does not appear anywhere in the durable key or data", %{
      opts: opts,
      name: name
    } do
      assert {:ok, %Reservation{} = r} =
               BudgetLedger.reserve("user-1", "2026-08-02", 1000, 60_000, opts)

      refute String.contains?(r.key, "user-1")
      data = Fake.peek(name, r.key).data
      refute String.contains?(Jason.encode!(data), "user-1")
    end
  end

  describe "reserve/5 admission and options" do
    @tag spec: "VOICE-24"
    test "rejects unknown options", %{opts: opts} do
      assert {:error, :invalid_options} =
               BudgetLedger.reserve("user-1", "2026-08-02", 100, 60_000, opts ++ [bogus: true])
    end

    @tag spec: "VOICE-24"
    test "budget_exhausted when the sum exceeds the limit", %{opts: opts} do
      assert {:ok, _r} = BudgetLedger.reserve("user-1", "2026-08-02", 50_000, 60_000, opts)

      assert {:error, :budget_exhausted} =
               BudgetLedger.reserve("user-1", "2026-08-02", 11_000, 60_000, opts)
    end

    @tag spec: "VOICE-24"
    test "a duplicate injected reservation_id is rejected", %{opts: opts} do
      id = vres("abc123")

      assert {:ok, _r} =
               BudgetLedger.reserve(
                 "user-1",
                 "2026-08-02",
                 1000,
                 60_000,
                 opts ++ [reservation_id: id]
               )

      assert {:error, :duplicate_reservation_id} =
               BudgetLedger.reserve(
                 "user-1",
                 "2026-08-02",
                 1000,
                 60_000,
                 opts ++ [reservation_id: id]
               )
    end
  end

  describe "bounded CAS conflict handling" do
    @tag spec: "VOICE-24"
    test "bounded conflicts eventually succeed", %{opts: opts, name: name} do
      # Pre-populate the record so subsequent reserves are updates, not inserts.
      assert {:ok, _r} = BudgetLedger.reserve("user-1", "2026-08-02", 1, 60_000, opts)

      Fake.set_conflict_count(name, 3)

      assert {:ok, %Reservation{}} =
               BudgetLedger.reserve("user-1", "2026-08-02", 1000, 60_000, opts)
    end

    @tag spec: "VOICE-24"
    test "retry exhaustion returns :contention", %{opts: opts, name: name} do
      # Pre-populate the record so subsequent reserves are updates.
      assert {:ok, _r} = BudgetLedger.reserve("user-1", "2026-08-02", 1, 60_000, opts)

      Fake.set_conflict_count(name, 100)

      assert {:error, :contention} =
               BudgetLedger.reserve("user-1", "2026-08-02", 1000, 60_000, opts)
    end
  end

  describe "malformed durable records fail closed and are never overwritten" do
    @tag spec: "VOICE-24"
    test "reserve detects a malformed record and returns an error without mutating it", %{
      opts: opts,
      name: name
    } do
      key = Base.encode16(:crypto.hash(:sha256, "user-1"), case: :lower) <> ":" <> "2026-08-02"

      bad_record =
        Arbor.Contracts.Persistence.Record.new(key, %{
          "version" => 1,
          "utc_day" => "2026-08-02",
          "daily_limit_ms" => 60_000,
          "consumed_ms" => 0,
          "active_reservations" => [],
          "settlements" => [
            %{
              "id" => vres("bad"),
              "kind" => "consumed",
              "elapsed_ms" => 999_999,
              "settled_at_ms" => 0,
              "fingerprint" => String.duplicate("0", 64),
              "requested_ms" => 1
            }
          ]
        })

      :ok = Fake.put(key, bad_record, agent_name: name)

      assert {:error, :malformed_state} =
               BudgetLedger.reserve("user-1", "2026-08-02", 1000, 60_000, opts)

      stored = Fake.peek(name, key)
      assert stored.data == bad_record.data
    end

    @tag spec: "VOICE-24"
    test "reserve rejects a durable list far over the cap without traversing it or overwriting",
         %{
           opts: opts,
           name: name
         } do
      key = Base.encode16(:crypto.hash(:sha256, "user-1"), case: :lower) <> ":" <> "2026-08-02"

      huge_active =
        for i <- 1..300,
            do: %{
              "id" => vres("huge#{i}"),
              "requested_ms" => 1,
              "reserved_at_ms" => 0,
              "expires_at_ms" => 0,
              "fingerprint" => String.duplicate("0", 64)
            }

      bad_record =
        Arbor.Contracts.Persistence.Record.new(key, %{
          "version" => 1,
          "utc_day" => "2026-08-02",
          "daily_limit_ms" => 60_000,
          "consumed_ms" => 0,
          "active_reservations" => huge_active,
          "settlements" => []
        })

      :ok = Fake.put(key, bad_record, agent_name: name)

      assert {:error, :malformed_state} =
               BudgetLedger.reserve("user-1", "2026-08-02", 1000, 60_000, opts)

      stored = Fake.peek(name, key)
      assert stored.data == bad_record.data
    end
  end

  describe "backend error propagation" do
    @tag spec: "VOICE-24"
    test "reserve propagates backend get failures", %{opts: opts, name: name} do
      Fake.set_get_error(name, :db_down)

      assert {:error, {:backend_error, :db_down}} =
               BudgetLedger.reserve("user-1", "2026-08-02", 1, 60_000, opts)
    end

    @tag spec: "VOICE-24"
    test "reserve propagates backend CAS failures", %{opts: opts, name: name} do
      assert {:ok, _r} = BudgetLedger.reserve("user-1", "2026-08-02", 1, 60_000, opts)
      Fake.set_cas_error(name, :store_timeout)

      assert {:error, {:backend_error, :store_timeout}} =
               BudgetLedger.reserve("user-1", "2026-08-02", 1, 60_000, opts)
    end
  end

  describe "consume/3, release/2, remaining/4" do
    @tag spec: "VOICE-24"
    test "consume settles usage and remaining reflects it", %{opts: opts} do
      assert {:ok, r} = BudgetLedger.reserve("user-1", "2026-08-02", 1000, 60_000, opts)
      assert :ok = BudgetLedger.consume(r, 400, opts)
      assert {:ok, 59_600} = BudgetLedger.remaining("user-1", "2026-08-02", 60_000, opts)
    end

    @tag spec: "VOICE-24"
    test "consume is idempotent for a replay with the same elapsed value", %{opts: opts} do
      assert {:ok, r} = BudgetLedger.reserve("user-1", "2026-08-02", 1000, 60_000, opts)
      assert :ok = BudgetLedger.consume(r, 400, opts)
      assert :ok = BudgetLedger.consume(r, 400, opts)
    end

    @tag spec: "VOICE-24"
    test "consume fails closed on a larger conflicting replay", %{opts: opts} do
      assert {:ok, r} = BudgetLedger.reserve("user-1", "2026-08-02", 1000, 60_000, opts)
      assert :ok = BudgetLedger.consume(r, 400, opts)
      assert {:error, :conflicting_replay} = BudgetLedger.consume(r, 401, opts)
    end

    @tag spec: "VOICE-24"
    test "consume fails closed when elapsed exceeds the reservation", %{opts: opts} do
      assert {:ok, r} = BudgetLedger.reserve("user-1", "2026-08-02", 1000, 60_000, opts)
      assert {:error, :elapsed_exceeds_reservation} = BudgetLedger.consume(r, 1001, opts)
    end

    @tag spec: "VOICE-24"
    test "release returns the reservation to the allowance and is idempotent", %{opts: opts} do
      assert {:ok, r} = BudgetLedger.reserve("user-1", "2026-08-02", 1000, 60_000, opts)
      assert :ok = BudgetLedger.release(r, opts)
      assert :ok = BudgetLedger.release(r, opts)
      assert {:ok, 60_000} = BudgetLedger.remaining("user-1", "2026-08-02", 60_000, opts)
    end

    @tag spec: "VOICE-24"
    test "remaining reports the full daily limit before any reservation", %{opts: opts} do
      assert {:ok, 60_000} = BudgetLedger.remaining("user-1", "2026-08-02", 60_000, opts)
    end
  end
end
