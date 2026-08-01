defmodule Arbor.AI.Runtime.ReviewedProviderRouteProfileTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.Runtime.{ProviderRouter, RouteCatalog}

  @moduletag :fast
  @config_path Path.expand("../../../../../..", __DIR__)
               |> Path.join("config/provider_route_profile.exs")

  test "reviewed profile keeps deployment policy and eval provenance coherent" do
    dev = read_ai_config(:dev)
    prod = read_ai_config(:prod)
    dev_profile = Keyword.fetch!(dev, :provider_route_profile)
    prod_profile = Keyword.fetch!(prod, :provider_route_profile)

    assert dev_profile.enabled
    refute prod_profile.enabled
    assert Map.delete(dev_profile, :enabled) == Map.delete(prod_profile, :enabled)

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

  defp read_ai_config(env) do
    @config_path
    |> Config.Reader.read!(env: env)
    |> Keyword.fetch!(:arbor_ai)
  end
end
