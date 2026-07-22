defmodule Arbor.Contracts.LLM.ProviderObservationTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.LLM.ProviderObservation

  @moduletag :fast

  @valid %{
    provider: :openai,
    account_id: "acct-1",
    source: "responses_probe",
    runtime: :arbor,
    observed_at: "2026-07-22T17:00:00-05:00",
    expires_at: "2026-07-22T18:00:00-05:00",
    availability: :available,
    auth_health: "healthy",
    model_catalog_membership: :present,
    quota_state: :available,
    quota_resets_at: "2026-07-23T00:00:00Z",
    subscription_capacity_state: :limited,
    subscription_capacity_resets_at: "2026-07-23T01:00:00Z",
    concurrency_limit: 8,
    concurrency_in_use: 2,
    requested_model_id: "gpt-5",
    launch_bound_model_id: "gpt-5-2026-07-15",
    confirmed_model_id: "gpt-5-2026-07-15",
    failure_code: :model_mismatch,
    failure_message: "requested id differed from provider-confirmed id"
  }

  test "constructs readiness evidence and normalizes timestamps" do
    assert {:ok, observation} = ProviderObservation.new(@valid)
    assert observation.version == 1
    assert observation.provider == "openai"
    assert observation.observed_at == "2026-07-22T22:00:00Z"
    assert observation.expires_at == "2026-07-22T23:00:00Z"
    assert observation.runtime == "arbor"
    assert observation.subscription_capacity_state == "limited"
    assert observation.confirmed_model_id == "gpt-5-2026-07-15"
  end

  test "allows absent facts but requires source, provider, and observed time" do
    assert {:ok, observation} =
             ProviderObservation.new(
               provider: :ollama,
               source: :local_probe,
               observed_at: "2026-07-22T22:00:00Z"
             )

    assert observation.availability == nil
    assert observation.auth_health == nil
    assert observation.failure_code == nil
    assert ProviderObservation.to_map(observation)["availability"] == nil

    for missing <- [:provider, :source, :observed_at] do
      assert {:error, _} = ProviderObservation.new(Map.delete(@valid, missing))
    end
  end

  test "rejects stale expiry ordering and closed enum values" do
    assert {:error, {:invalid_field, "expires_at"}} =
             ProviderObservation.new(Map.put(@valid, :expires_at, "2026-07-22T16:59:59Z"))

    for {field, value} <- [
          {:availability, :online},
          {:auth_health, "valid"},
          {:model_catalog_membership, "listed"},
          {:quota_state, :plenty},
          {:subscription_capacity_state, "free"},
          {:runtime, :shell},
          {:failure_code, "payment_declined"}
        ] do
      refute ProviderObservation.valid?(Map.put(@valid, field, value))
    end
  end

  test "requires a complete bounded failure code and message pair" do
    assert {:error, {:invalid_field, "failure_message"}} =
             ProviderObservation.new(Map.delete(@valid, :failure_message))

    assert {:error, {:invalid_field, "failure_message"}} =
             ProviderObservation.new(Map.put(@valid, :failure_code, nil))

    assert {:error, {:invalid_field, "failure_message"}} =
             ProviderObservation.new(
               Map.put(@valid, :failure_message, String.duplicate("x", 513))
             )
  end

  test "rejects closed-object authority fields, hostile terms, and oversized identifiers" do
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
               ProviderObservation.new(Map.put(@valid, key, "secret"))
    end

    hostile = [self(), fn -> :term end, {:bad, :term}, %{nested: :term}, ["ok" | :improper]]

    for value <- hostile do
      refute ProviderObservation.valid?(Map.put(@valid, :confirmed_model_id, value))
      assert {:error, _} = ProviderObservation.digest(Map.put(@valid, :confirmed_model_id, value))
    end

    refute ProviderObservation.valid?(Map.put(@valid, :provider, String.duplicate("p", 513)))
  end

  test "canonical bytes and digest are stable across key and enum aliases" do
    assert {:ok, first_bytes} = ProviderObservation.canonical_bytes(@valid)

    assert {:ok, second_bytes} =
             ProviderObservation.canonical_bytes(
               Enum.into(@valid, %{}, fn {k, v} -> {Atom.to_string(k), v} end)
             )

    assert first_bytes == second_bytes

    assert first_bytes ==
             ~s({"version":1,"provider":"openai","account_id":"acct-1","source":"responses_probe","runtime":"arbor","observed_at":"2026-07-22T22:00:00Z","expires_at":"2026-07-22T23:00:00Z","availability":"available","auth_health":"healthy","model_catalog_membership":"present","quota_state":"available","quota_resets_at":"2026-07-23T00:00:00Z","subscription_capacity_state":"limited","subscription_capacity_resets_at":"2026-07-23T01:00:00Z","concurrency_limit":8,"concurrency_in_use":2,"requested_model_id":"gpt-5","launch_bound_model_id":"gpt-5-2026-07-15","confirmed_model_id":"gpt-5-2026-07-15","failure_code":"model_mismatch","failure_message":"requested id differed from provider-confirmed id"})

    assert {:ok, digest} = ProviderObservation.digest(@valid)
    assert digest == "sha256:0adac562156959d721825685c54612e9eeaaaa39d3ab19478eaa02d12aaba6fa"
  end

  test "round-trips through JSON" do
    assert {:ok, observation} = ProviderObservation.new(@valid)
    map = ProviderObservation.to_map(observation)
    assert Map.keys(map) |> Enum.all?(&is_binary/1)
    assert Jason.decode!(Jason.encode!(map)) == map
    assert {:ok, decoded} = ProviderObservation.new(Jason.decode!(Jason.encode!(map)))
    assert ProviderObservation.to_map(decoded) == map
  end
end
