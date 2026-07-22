defmodule Arbor.Contracts.LLM.BudgetSnapshotTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.LLM.BudgetSnapshot

  @moduletag :fast

  @valid %{
    provider: "openai",
    account_id: "acct-1",
    source: "ledger",
    observed_at: "2026-07-22T17:00:00-05:00",
    expires_at: "2026-07-22T18:00:00-05:00",
    configured_spend_ceiling: 10.0,
    current_spend: 3.25,
    remaining_spend: 6.75,
    request_count: 12,
    input_tokens: 10_000,
    output_tokens: 4_000,
    quota_state: :available,
    quota_remaining_units: 50_000,
    quota_resets_at: "2026-07-23T00:00:00Z",
    subscription_capacity_state: :limited,
    subscription_capacity_limit: 1_000,
    subscription_capacity_used: 250,
    subscription_capacity_remaining: 750,
    subscription_capacity_resets_at: "2026-07-23T01:00:00Z",
    concurrency_limit: 8,
    concurrency_in_use: 2
  }

  test "keeps marginal spend distinct from subscription capacity" do
    assert {:ok, snapshot} = BudgetSnapshot.new(@valid)
    assert snapshot.configured_spend_ceiling == 10.0
    assert snapshot.current_spend == 3.25
    assert snapshot.remaining_spend == 6.75
    assert snapshot.subscription_capacity_remaining == 750
    refute Map.has_key?(BudgetSnapshot.to_map(snapshot), "cost")
    assert BudgetSnapshot.consistency_tolerance() == 0.000001
  end

  test "validates spend consistency and nonnegative finite numbers" do
    assert {:error, {:invalid_field, "remaining_spend"}} =
             BudgetSnapshot.new(Map.put(@valid, :remaining_spend, 7.0))

    assert {:error, {:invalid_field, "current_spend"}} =
             BudgetSnapshot.new(Map.put(@valid, :current_spend, 11.0))

    for field <- [
          :configured_spend_ceiling,
          :current_spend,
          :remaining_spend,
          :quota_remaining_units
        ] do
      assert {:error, {:invalid_field, _}} = BudgetSnapshot.new(Map.put(@valid, field, -1.0))

      assert {:error, {:invalid_field, _}} =
               BudgetSnapshot.new(Map.put(@valid, field, "NaN"))

      assert {:error, {:invalid_field, _}} =
               BudgetSnapshot.new(Map.put(@valid, field, "Infinity"))
    end
  end

  test "allows an unbounded ceiling and optional unobserved facts" do
    attrs = Map.drop(@valid, [:configured_spend_ceiling, :remaining_spend, :current_spend])
    assert {:ok, snapshot} = BudgetSnapshot.new(attrs)
    assert snapshot.configured_spend_ceiling == nil
    assert snapshot.remaining_spend == nil
    assert snapshot.subscription_capacity_state == "limited"
  end

  test "rejects stale expiry ordering and closed enums" do
    assert {:error, {:invalid_field, "expires_at"}} =
             BudgetSnapshot.new(Map.put(@valid, :expires_at, "2026-07-22T16:59:59Z"))

    assert {:error, {:invalid_field, "quota_state"}} =
             BudgetSnapshot.new(Map.put(@valid, :quota_state, :plenty))

    assert {:error, {:invalid_field, "subscription_capacity_state"}} =
             BudgetSnapshot.new(Map.put(@valid, :subscription_capacity_state, "zero_cost"))
  end

  test "rejects closed-object authority fields and hostile terms" do
    for key <- [
          "access_token",
          "refresh_token",
          "token_hash",
          "argv",
          "env",
          "capabilities",
          "callback",
          "authority"
        ] do
      assert {:error, {:unknown_fields, [^key]}} =
               BudgetSnapshot.new(Map.put(@valid, key, "secret"))
    end

    for value <- [self(), fn -> :term end, {:bad, :term}, %{nested: :term}, [1 | :improper]] do
      refute BudgetSnapshot.valid?(Map.put(@valid, :current_spend, value))
      assert {:error, _} = BudgetSnapshot.canonical_bytes(Map.put(@valid, :current_spend, value))
    end
  end

  test "canonical bytes and digest are exact and JSON-round-trippable" do
    assert {:ok, bytes} = BudgetSnapshot.canonical_bytes(@valid)

    assert bytes ==
             ~s({"version":1,"provider":"openai","account_id":"acct-1","source":"ledger","observed_at":"2026-07-22T22:00:00Z","expires_at":"2026-07-22T23:00:00Z","configured_spend_ceiling":10.0,"current_spend":3.25,"remaining_spend":6.75,"request_count":12,"input_tokens":10000,"output_tokens":4000,"quota_state":"available","quota_remaining_units":50000,"quota_resets_at":"2026-07-23T00:00:00Z","subscription_capacity_state":"limited","subscription_capacity_limit":1000,"subscription_capacity_used":250,"subscription_capacity_remaining":750,"subscription_capacity_resets_at":"2026-07-23T01:00:00Z","concurrency_limit":8,"concurrency_in_use":2})

    assert {:ok, digest} = BudgetSnapshot.digest(@valid)
    assert digest == "sha256:bcfce74914ca2ac017143cfb96b0760da88f9c1aa69b93f7847e48abe5ae86a4"

    assert {:ok, snapshot} = BudgetSnapshot.new(@valid)
    map = BudgetSnapshot.to_map(snapshot)
    assert Jason.decode!(Jason.encode!(map)) == map
    assert {:ok, decoded} = BudgetSnapshot.new(Jason.decode!(Jason.encode!(map)))
    assert BudgetSnapshot.to_map(decoded) == map
  end
end
