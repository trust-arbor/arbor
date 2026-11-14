defmodule Arbor.AI.Runtime.ReviewedProviderRouteProfileTest do
  # Not async: these tests set ARBOR_PROVIDER_ROUTE_PROFILE in the OS environment.
  use ExUnit.Case, async: false

  alias Arbor.AI.Runtime.{ProviderRouter, RouteCatalog}

  @moduletag :fast
  @config_path Path.expand("../../../../../..", __DIR__)
               |> Path.join("config/provider_route_profile.exs")

  @switch "ARBOR_PROVIDER_ROUTE_PROFILE"

  test "dev keeps the profile off unless opted in; prod keeps the reviewed default" do
    # Both routes need subscription OAuth logins a fresh install does not have.
    refute profile_enabled?(:dev, nil)
    refute profile_enabled?(:dev, "false")
    assert profile_enabled?(:dev, "true")
    assert profile_enabled?(:dev, "1")

    assert profile_enabled?(:prod, nil)
    refute profile_enabled?(:prod, "0")
  end

  test "an unrecognized switch value fails loudly" do
    assert_raise ArgumentError, ~r/ARBOR_PROVIDER_ROUTE_PROFILE must be true or false/, fn ->
      read_ai_config(:dev, "yes")
    end
  end

  test "reviewed profile keeps deployment policy and eval provenance coherent" do
    dev = read_ai_config(:dev, "true")
    prod = read_ai_config(:prod, nil)
    dev_profile = Keyword.fetch!(dev, :provider_route_profile)
    prod_profile = Keyword.fetch!(prod, :provider_route_profile)

    assert dev_profile.enabled
    assert prod_profile.enabled
    assert Map.delete(dev_profile, :enabled) == Map.delete(prod_profile, :enabled)

    assert Map.new(dev_profile.scoreboard, &{&1.provider, &1.eval_run_ref}) == %{
             "openai_oauth" => "gpt-5-6-sol-heartbeat-2026-08-01-2a1cc2",
             "xai_oauth" => "grok-4-6-heartbeat-2026-08-12-391f1b"
           }

    assert {:ok, catalog} = RouteCatalog.entries(dev_profile.catalog_model_ids)
    assert Enum.map(catalog, & &1.canonical_id) == dev_profile.catalog_model_ids
    assert {:ok, scoreboard} = ProviderRouter.admit_scoreboard(dev_profile.scoreboard)

    assert Enum.all?(scoreboard, fn row ->
             is_binary(row.eval_run_ref) and row.eval_run_ref != "" and
               is_binary(row.last_verified) and row.last_verified != "" and
               Enum.all?(
                 [
                   row.score,
                   row.dangerous_misses,
                   row.format_failure_rate,
                   row.variance,
                   row.marginal_cost,
                   row.latency_ms
                 ],
                 &is_number/1
               )
           end)

    expected_routes = MapSet.new(["openai_oauth", "xai_oauth"])
    assert MapSet.new(dev_profile.providers) == expected_routes

    assert MapSet.new(Map.keys(Keyword.fetch!(dev, :provider_spend_ceilings_usd))) ==
             expected_routes

    assert MapSet.new(Map.keys(Keyword.fetch!(dev, :subscription_capacity_states))) ==
             expected_routes

    assert MapSet.new(Map.keys(Keyword.fetch!(dev, :provider_route_concurrency_limits))) ==
             expected_routes
  end

  defp profile_enabled?(env, switch) do
    read_ai_config(env, switch) |> Keyword.fetch!(:provider_route_profile) |> Map.fetch!(:enabled)
  end

  defp read_ai_config(env, switch) do
    prior = System.get_env(@switch)

    try do
      if switch, do: System.put_env(@switch, switch), else: System.delete_env(@switch)

      @config_path
      |> Config.Reader.read!(env: env)
      |> Keyword.fetch!(:arbor_ai)
    after
      if prior, do: System.put_env(@switch, prior), else: System.delete_env(@switch)
    end
  end
end
