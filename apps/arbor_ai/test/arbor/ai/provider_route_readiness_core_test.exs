defmodule Arbor.AI.ProviderRouteReadinessCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.ProviderRouteReadinessCore

  @moduletag :fast

  @now ~U[2026-07-31 12:00:00Z]

  test "disabled policy is closed and outranks downstream evidence" do
    facts =
      facts()
      |> Map.put("policy_enabled", false)
      |> Map.put("durable_replay", %{"status" => "unavailable"})
      |> Map.put("catalog_snapshot", "not-a-snapshot")

    assert ProviderRouteReadinessCore.evaluate(facts, @now) ==
             result("disabled", false, [], [])
  end

  test "one exact required route becomes ready from current matching evidence" do
    assert ProviderRouteReadinessCore.evaluate(facts(), @now) ==
             result("ready", true, ["openai_oauth"], [])
  end

  test "every closed OAuth health status has an explicit readiness class" do
    permanent = ~w(login_required migration_required invalid relogin_required source_unsupported)
    transient = ~w(expired source_unavailable store_unreadable)

    assert ProviderRouteReadinessCore.classify_auth_health("ready") == :ready

    Enum.each(permanent, fn status ->
      assert ProviderRouteReadinessCore.classify_auth_health(status) == :permanent

      assert ProviderRouteReadinessCore.evaluate(facts(health: %{"openai_oauth" => status}), @now) ==
               result(
                 "oauth_health_permanent",
                 false,
                 ["openai_oauth"],
                 ["openai_oauth"]
               )
    end)

    Enum.each(transient, fn status ->
      assert ProviderRouteReadinessCore.classify_auth_health(status) == :transient

      assert ProviderRouteReadinessCore.evaluate(facts(health: %{"openai_oauth" => status}), @now) ==
               result(
                 "oauth_health_transient",
                 false,
                 ["openai_oauth"],
                 ["openai_oauth"]
               )
    end)

    assert ProviderRouteReadinessCore.classify_auth_health("unknown") == :malformed
  end

  test "reader unavailable and malformed health facts are transient and never authorize" do
    for status <- ["unavailable", "malformed"] do
      assert ProviderRouteReadinessCore.evaluate(facts(health: %{"openai_oauth" => status}), @now) ==
               result(
                 "oauth_health_transient",
                 false,
                 ["openai_oauth"],
                 ["openai_oauth"]
               )
    end
  end

  test "two exact required routes are canonicalized and both must be ready" do
    facts =
      facts(
        required_routes: ["xai_oauth", "openai_oauth"],
        catalogs: %{
          "openai_oauth" => catalog("openai_oauth", 3),
          "xai_oauth" => catalog("xai_oauth", 7)
        },
        generations: %{"openai_oauth" => 3, "xai_oauth" => 7}
      )

    assert ProviderRouteReadinessCore.evaluate(facts, @now) ==
             result("ready", true, ["openai_oauth", "xai_oauth"], [])
  end

  test "irrelevant exact catalog entry is ignored, including malformed content" do
    facts =
      facts(
        catalogs: %{
          "openai_oauth" => catalog("openai_oauth", 3),
          "xai_oauth" => %{"malformed" => true}
        },
        generations: %{"openai_oauth" => 3, "xai_oauth" => 99}
      )

    assert ProviderRouteReadinessCore.evaluate(facts, @now)["state"] == "ready"
  end

  test "empty required route set needs no catalog refresh" do
    facts =
      facts(required_routes: [], catalogs: %{}, generations: %{})
      |> Map.put("catalog_snapshot", %{"status" => "refresh_pending", "catalogs" => %{}})

    assert ProviderRouteReadinessCore.evaluate(facts, @now) ==
             result("ready", true, [], [])
  end

  test "duplicate, alias, atom, oversized, and improper required routes fail closed" do
    rejected = [
      ["openai_oauth", "openai_oauth"],
      ["openai"],
      [:openai_oauth],
      ["openai_oauth", "xai_oauth", "openai_oauth"],
      ["openai_oauth" | "xai_oauth"]
    ]

    Enum.each(rejected, fn routes ->
      assert ProviderRouteReadinessCore.evaluate(
               Map.put(facts(), "required_routes", routes),
               @now
             )["state"] == "malformed_input"
    end)
  end

  test "durable replay states gate every catalog decision with deterministic precedence" do
    catalogs = %{"status" => "available", "catalogs" => %{"openai_oauth" => %{}}}

    for {durable, expected} <- [
          {"pending", "durable_replay_pending"},
          {"unavailable", "durable_replay_unavailable"},
          {"malformed", "durable_replay_malformed_or_incomplete"},
          {"incomplete", "durable_replay_malformed_or_incomplete"},
          {"unknown", "durable_replay_malformed_or_incomplete"}
        ] do
      input =
        facts()
        |> Map.put("durable_replay", %{"status" => durable})
        |> Map.put("catalog_snapshot", catalogs)

      assert ProviderRouteReadinessCore.evaluate(input, @now) ==
               result(expected, false, ["openai_oauth"], ["openai_oauth"])
    end
  end

  test "catalog refresh pending is distinct from an available snapshot miss" do
    pending =
      facts()
      |> Map.put("catalog_snapshot", %{"status" => "refresh_pending", "catalogs" => %{}})
      |> Map.put("credential_generations", "not-yet-observed")

    missing = facts(catalogs: %{})

    assert ProviderRouteReadinessCore.evaluate(pending, @now)["state"] ==
             "catalog_refresh_pending"

    assert ProviderRouteReadinessCore.evaluate(missing, @now) ==
             result("catalog_missing", false, ["openai_oauth"], ["openai_oauth"])
  end

  test "catalogs are revalidated through the closed contract" do
    malformed_values = [
      %{"route" => "openai_oauth"},
      Map.put(catalog("openai_oauth", 3), "unexpected", true),
      Map.put(catalog("openai_oauth", 3), "model_ids", ["same", "same"]),
      Map.put(catalog("openai_oauth", 3), "backend", "xai")
    ]

    Enum.each(malformed_values, fn malformed ->
      input = facts(catalogs: %{"openai_oauth" => malformed})

      assert ProviderRouteReadinessCore.evaluate(input, @now) ==
               result("catalog_malformed", false, ["openai_oauth"], ["openai_oauth"])
    end)
  end

  test "snapshot key and provider catalog route identity must match exactly" do
    input = facts(catalogs: %{"openai_oauth" => catalog("xai_oauth", 3)})

    assert ProviderRouteReadinessCore.evaluate(input, @now)["state"] ==
             "catalog_malformed"

    alias_key =
      facts()
      |> Map.put("catalog_snapshot", %{
        "status" => "available",
        "catalogs" => %{"openai" => catalog("openai_oauth", 3)}
      })

    assert ProviderRouteReadinessCore.evaluate(alias_key, @now)["state"] ==
             "catalog_malformed"
  end

  test "catalog observed beyond bounded future skew is malformed" do
    tolerated =
      catalog("openai_oauth", 3,
        observed_at: DateTime.add(@now, 60, :second),
        expires_at: DateTime.add(@now, 5, :minute)
      )

    too_far =
      catalog("openai_oauth", 3,
        observed_at: DateTime.add(@now, 61, :second),
        expires_at: DateTime.add(@now, 5, :minute)
      )

    assert ProviderRouteReadinessCore.evaluate(
             facts(catalogs: %{"openai_oauth" => tolerated}),
             @now
           )["state"] == "ready"

    assert ProviderRouteReadinessCore.evaluate(
             facts(catalogs: %{"openai_oauth" => too_far}),
             @now
           )["state"] == "catalog_malformed"
  end

  test "catalog expiry equal to or before now is stale" do
    for expires_at <- [@now, DateTime.add(@now, -1, :second)] do
      stale =
        catalog("openai_oauth", 3,
          observed_at: DateTime.add(@now, -5, :minute),
          expires_at: expires_at
        )

      assert ProviderRouteReadinessCore.evaluate(
               facts(catalogs: %{"openai_oauth" => stale}),
               @now
             ) == result("catalog_stale", false, ["openai_oauth"], ["openai_oauth"])
    end
  end

  test "missing or drifted credential generation blocks readiness" do
    for generations <- [%{}, %{"openai_oauth" => 4}] do
      assert ProviderRouteReadinessCore.evaluate(
               facts(generations: generations),
               @now
             ) ==
               result(
                 "catalog_generation_mismatch",
                 false,
                 ["openai_oauth"],
                 ["openai_oauth"]
               )
    end
  end

  test "malformed generation and top-level envelopes fail closed" do
    malformed_inputs = [
      facts(generations: %{"openai_oauth" => -1}),
      facts(generations: %{"openai" => 3}),
      Map.put(facts(), "extra", true),
      Map.put(facts(), "policy_enabled", "true")
    ]

    Enum.each(malformed_inputs, fn input ->
      assert ProviderRouteReadinessCore.evaluate(input, @now)["state"] == "malformed_input"
    end)

    malformed_catalog = Map.put(facts(), "catalog_snapshot", %{status: "available"})

    assert ProviderRouteReadinessCore.evaluate(malformed_catalog, @now)["state"] ==
             "catalog_malformed"

    assert ProviderRouteReadinessCore.evaluate(facts(), ~D[2026-07-31])["state"] ==
             "malformed_input"
  end

  test "cross-route catalog rejection precedence is deterministic" do
    malformed_and_missing =
      facts(
        required_routes: ["openai_oauth", "xai_oauth"],
        catalogs: %{"xai_oauth" => %{"malformed" => true}},
        generations: %{"openai_oauth" => 3, "xai_oauth" => 7}
      )

    generation_and_stale =
      facts(
        required_routes: ["openai_oauth", "xai_oauth"],
        catalogs: %{
          "openai_oauth" => catalog("openai_oauth", 3, expires_at: @now),
          "xai_oauth" => catalog("xai_oauth", 7)
        },
        generations: %{"openai_oauth" => 3, "xai_oauth" => 8}
      )

    assert ProviderRouteReadinessCore.evaluate(malformed_and_missing, @now) ==
             result(
               "catalog_malformed",
               false,
               ["openai_oauth", "xai_oauth"],
               ["openai_oauth", "xai_oauth"]
             )

    assert ProviderRouteReadinessCore.evaluate(generation_and_stale, @now) ==
             result(
               "catalog_generation_mismatch",
               false,
               ["openai_oauth", "xai_oauth"],
               ["openai_oauth", "xai_oauth"]
             )
  end

  test "result is JSON-clean and contains no capacity observation" do
    output = ProviderRouteReadinessCore.evaluate(facts(), @now)

    assert {:ok, _json} = Jason.encode(output)
    assert Enum.all?(Map.keys(output), &is_binary/1)
    refute Map.has_key?(output, "capacity")
    refute Map.has_key?(output, "subscription_capacity_state")
  end

  defp facts(opts \\ []) do
    required_routes = Keyword.get(opts, :required_routes, ["openai_oauth"])
    catalogs = Keyword.get(opts, :catalogs, %{"openai_oauth" => catalog("openai_oauth", 3)})
    generations = Keyword.get(opts, :generations, %{"openai_oauth" => 3})
    health = Keyword.get(opts, :health, Map.new(required_routes, &{&1, "ready"}))

    %{
      "policy_enabled" => true,
      "required_routes" => required_routes,
      "durable_replay" => %{"status" => "complete"},
      "auth_health" => health,
      "catalog_snapshot" => %{"status" => "available", "catalogs" => catalogs},
      "credential_generations" => generations
    }
  end

  defp catalog(route, generation, opts \\ []) do
    {backend, model} =
      case route do
        "openai_oauth" -> {"openai", "gpt-5.6"}
        "xai_oauth" -> {"xai", "grok-4.5"}
      end

    observed_at = Keyword.get(opts, :observed_at, DateTime.add(@now, -1, :minute))
    expires_at = Keyword.get(opts, :expires_at, DateTime.add(@now, 4, :minute))

    %{
      "version" => 1,
      "route" => route,
      "backend" => backend,
      "runtime" => "arbor",
      "model_ids" => [model],
      "observed_at" => DateTime.to_iso8601(observed_at),
      "expires_at" => DateTime.to_iso8601(expires_at),
      "credential_generation" => generation
    }
  end

  defp result(state, ready?, required_routes, blocking_routes) do
    %{
      "version" => 1,
      "state" => state,
      "ready" => ready?,
      "required_routes" => required_routes,
      "blocking_routes" => blocking_routes,
      "checked_at" => "2026-07-31T12:00:00Z"
    }
  end
end
