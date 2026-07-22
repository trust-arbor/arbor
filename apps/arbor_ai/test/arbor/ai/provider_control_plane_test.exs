defmodule Arbor.AI.ProviderControlPlaneTest do
  use ExUnit.Case, async: false

  alias Arbor.AI
  alias Arbor.AI.QuotaTracker
  alias Arbor.AI.ProviderControlPlane.BudgetProjection

  @observed_at ~U[2026-07-22 20:00:00Z]
  @budget_status %{
    daily_budget: 10.0,
    spent_today: 3.25,
    remaining: 6.75,
    backends: %{
      openai: %{requests: 4, tokens: 1_000, cost: 3.25},
      claude_subscription: %{requests: 2, tokens: 500, cost: 0.0}
    }
  }

  @quota_status %{}

  @moduletag :fast

  defp snapshot(provider, opts \\ []) do
    AI.provider_budget_snapshot(
      provider,
      Keyword.merge(
        [
          budget_status: @budget_status,
          quota_status: @quota_status,
          observed_at: @observed_at,
          expiry_seconds: 60
        ],
        opts
      )
    )
  end

  test "projects API spend without assigning aggregate remaining to a provider" do
    assert {:ok, %{snapshot: snapshot, digest: digest}} = snapshot(:openai)

    assert snapshot["provider"] == "openai"
    assert snapshot["current_spend"] == 3.25
    assert snapshot["request_count"] == 4
    refute Map.has_key?(snapshot, "configured_spend_ceiling")
    refute Map.has_key?(snapshot, "remaining_spend")
    assert snapshot["subscription_capacity_state"] == "unknown"
    assert String.starts_with?(digest, "sha256:")
    assert {:ok, _json} = Jason.encode(snapshot)
  end

  test "default facade reads the existing bounded tracker owners" do
    assert {:ok, %{snapshot: snapshot, digest: digest}} =
             AI.provider_budget_snapshot(:openai, observed_at: @observed_at)

    assert snapshot["provider"] == "openai"
    assert snapshot["subscription_capacity_state"] == "unknown"
    assert String.starts_with?(digest, "sha256:")
  end

  test "keeps subscription capacity explicit and independent from zero API spend" do
    assert {:ok, %{snapshot: snapshot}} = snapshot("claude_subscription")

    assert snapshot["current_spend"] == 0.0
    assert snapshot["subscription_capacity_state"] == "unknown"
    refute Map.has_key?(snapshot, "remaining_spend")
    refute Jason.encode!(snapshot) =~ "free"
  end

  test "uses an explicitly configured provider ceiling only for that provider" do
    assert {:ok, %{snapshot: snapshot}} =
             snapshot(:openai, provider_ceilings: %{"openai" => 5.0})

    assert snapshot["configured_spend_ceiling"] == 5.0
    assert snapshot["remaining_spend"] == 1.75
  end

  test "keeps valid overspend evidence at a zero remaining provider budget" do
    overspent = put_in(@budget_status, [:backends, :openai, :cost], 7.25)

    assert {:ok, %{snapshot: snapshot}} =
             snapshot(:openai, budget_status: overspent, provider_ceilings: %{"openai" => 5.0})

    assert snapshot["current_spend"] == 7.25
    assert snapshot["configured_spend_ceiling"] == 5.0
    assert snapshot["remaining_spend"] == 0.0
  end

  test "projects exhausted quota and its reset, then available after reset" do
    future = DateTime.add(@observed_at, 900, :second)
    past = DateTime.add(@observed_at, -900, :second)

    assert {:ok, %{snapshot: exhausted}} =
             snapshot(:gemini,
               quota_status: %{
                 "gemini" => %{
                   available: false,
                   available_at: future,
                   reason: "provider secret and /private/provider/path"
                 }
               }
             )

    assert exhausted["quota_state"] == "exhausted"
    assert exhausted["quota_resets_at"] == DateTime.to_iso8601(future)
    refute Jason.encode!(exhausted) =~ "provider secret"
    refute Jason.encode!(exhausted) =~ "/private/provider/path"

    assert {:ok, %{snapshot: reset}} =
             snapshot(:gemini,
               quota_status: %{"gemini" => %{available: false, available_at: past}}
             )

    assert reset["quota_state"] == "available"
    refute Map.has_key?(reset, "quota_resets_at")
  end

  test "fails closed when either tracker is unavailable" do
    opts = [
      budget_reader: fn -> {:error, :unavailable} end,
      quota_reader: fn -> {:ok, %{}} end
    ]

    assert {:error, :unavailable} =
             AI.provider_budget_snapshot("openai", Keyword.merge(opts, observed_at: @observed_at))

    assert {:error, :unavailable} =
             AI.provider_budget_snapshot("openai",
               budget_reader: fn -> {:ok, @budget_status} end,
               quota_reader: fn -> {:error, :unavailable} end,
               observed_at: @observed_at
             )
  end

  test "real QuotaTracker snapshots mark future reset as exhausted and past reset as available" do
    backend = :quota_snapshot_regression
    future = DateTime.add(DateTime.utc_now(), 3_600, :second)
    past = DateTime.add(DateTime.utc_now(), -3_600, :second)

    on_exit(fn ->
      QuotaTracker.clear(backend)
      :timer.sleep(10)
    end)

    QuotaTracker.mark_quota_exhausted(backend, until: future)
    :timer.sleep(20)

    assert {:ok, status} = QuotaTracker.snapshot_status(limit: 128)
    assert status["quota_snapshot_regression"].available == false
    assert status["quota_snapshot_regression"].available_at == DateTime.to_iso8601(future)

    QuotaTracker.mark_quota_exhausted(backend, until: past)
    :timer.sleep(20)

    assert {:ok, status} = QuotaTracker.snapshot_status(limit: 128)
    assert status["quota_snapshot_regression"].available == true
  end

  test "shuts down a timed-out bounded reader" do
    parent = self()

    reader = fn ->
      send(parent, {:bounded_reader_started, self()})
      Process.sleep(5_000)
      {:ok, @budget_status}
    end

    assert {:error, :unavailable} =
             AI.provider_budget_snapshot("openai",
               budget_reader: reader,
               quota_reader: fn -> {:ok, %{}} end,
               observed_at: @observed_at
             )

    assert_receive {:bounded_reader_started, reader_pid}
    refute Process.alive?(reader_pid)
  end

  test "fails closed for malformed bounded tracker state without leaking it" do
    assert {:error, :malformed} =
             snapshot(:openai,
               budget_status: %{
                 backends: %{"openai" => %{requests: 1, cost: "secret /tmp/provider"}}
               }
             )
  end

  test "digest is deterministic for identical normalized inputs" do
    assert {:ok, first} = snapshot(:openai, provider_ceilings: %{"openai" => 5.0})
    assert {:ok, second} = snapshot("openai", provider_ceilings: %{:openai => 5.0})

    assert first == second
  end

  test "unknown string providers are not dynamically interned" do
    provider = "provider-never-interned-7f3b0b9d"
    assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end

    assert {:ok, %{snapshot: snapshot}} = snapshot(provider)
    assert snapshot["provider"] == provider
    assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end
  end

  test "observation timestamp and expiry are injectable" do
    assert {:ok, %{snapshot: snapshot}} =
             snapshot(:openai, observed_at: @observed_at, expiry_seconds: 5)

    assert snapshot["observed_at"] == "2026-07-22T20:00:00Z"
    assert snapshot["expires_at"] == "2026-07-22T20:00:05Z"
  end

  test "pure projection rejects oversized and malformed inputs" do
    oversized = Map.new(1..129, fn index -> {"provider-#{index}", %{requests: 1, cost: 0.0}} end)

    assert {:error, :malformed} =
             BudgetProjection.project(:openai, %{backends: oversized}, %{},
               observed_at: @observed_at
             )
  end
end
