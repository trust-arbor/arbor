defmodule Arbor.AI.Runtime.RouteInputAssemblerSecurityRegressionTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Arbor.AI.Runtime.{ProviderRouter, RouteInputAssembler}

  alias Arbor.Contracts.LLM.{
    BudgetSnapshot,
    ModelEntry,
    OAuthHealth,
    ProviderEntry,
    ProviderModelCatalog,
    ProviderObservation
  }

  @moduletag :fast
  @now ~U[2026-07-29 12:02:00Z]
  @observed "2026-07-29T12:00:00Z"
  @expires "2026-07-29T12:05:00Z"
  @generation 7

  setup do
    Arbor.AI.TestSupport.ProviderRouteEvidence.reset!()
    :ok
  end

  test "security regression: OAuth model-a present evidence cannot authorize sibling model-b" do
    # Deterministic ready health + usable catalog containing only model-a.
    # Proves the generic nil-requested_model_id wildcard class is closed at assembly:
    # a single provider-wide present observation would authorize both siblings.
    model_a = oauth_model("model-a")
    model_b = oauth_model("model-b")
    catalog_entry = usable_catalog!(["model-a"], @generation)

    health_calls = :counters.new(1, [])
    snapshot_calls = :counters.new(1, [])

    assert {:ok, input} =
             RouteInputAssembler.assemble(
               profile: enabled_profile([model_a, model_b]),
               clock: fn -> @now end,
               oauth_health_reader: fn route ->
                 :counters.add(health_calls, 1, 1)
                 assert route in ["openai_oauth", :openai_oauth]
                 {:ok, ready_health(@generation)}
               end,
               oauth_catalog_snapshot_reader: fn ->
                 :counters.add(snapshot_calls, 1, 1)
                 {:ok, %{"openai_oauth" => ProviderModelCatalog.to_map(catalog_entry)}}
               end,
               budget_reader: fn providers, dt ->
                 {:ok, Enum.map(providers, &budget(&1, dt))}
               end
             )

    # One health read per exact route; one snapshot per assembly.
    assert :counters.get(health_calls, 1) == 1
    assert :counters.get(snapshot_calls, 1) == 1

    assert length(input.observations) == 2
    by_model = Map.new(input.observations, &{&1.requested_model_id, &1})

    assert Map.has_key?(by_model, "model-a")
    assert Map.has_key?(by_model, "model-b")
    refute Enum.any?(input.observations, &is_nil(&1.requested_model_id))

    obs_a = by_model["model-a"]
    obs_b = by_model["model-b"]

    assert obs_a.provider == "openai_oauth"
    assert obs_b.provider == "openai_oauth"
    assert obs_a.runtime == "arbor"
    assert obs_b.runtime == "arbor"
    assert obs_a.model_catalog_membership == "present"
    assert obs_a.source == "arbor_oauth_catalog"
    assert obs_b.model_catalog_membership == "absent"
    assert obs_b.failure_code == "model_absent"

    # Strict router: present A is eligible; absent B is excluded (catalog_absent).
    # Sibling A's present evidence must not make B eligible.
    route_input = %{
      task_class: "default",
      task_registry: %{"default" => %{requirements: %{}}},
      catalog: [model_a, model_b],
      scoreboard: [
        score_row("model-a", "openai_oauth", 0.9),
        score_row("model-b", "openai_oauth", 0.95)
      ],
      observations: input.observations,
      budgets: input.budgets,
      now: @now,
      policy: %{strict_evidence: true, fallback_limit: 4, params: %{}}
    }

    assert {:ok, decision} = ProviderRouter.decide_route(route_input)
    assert decision["model"] == "model-a"
    assert decision["provider"] == "openai_oauth"

    excluded = decision["rationale"]["excluded"]
    b_entry = Enum.find(excluded, &(&1["model"] == "model-b"))
    assert is_map(b_entry)
    assert "catalog_absent" in b_entry["reasons"]

    # Generic wildcard counterfactual: nil requested_model_id + present would
    # match both siblings under ProviderRouter.matching_observations/2.
    generic =
      %{obs_a | requested_model_id: nil}
      |> then(fn o ->
        {:ok, rebuilt} =
          ProviderObservation.new(%{
            provider: o.provider,
            source: o.source,
            runtime: o.runtime,
            observed_at: o.observed_at,
            expires_at: o.expires_at,
            availability: o.availability,
            auth_health: o.auth_health,
            model_catalog_membership: "present",
            quota_state: o.quota_state || "available",
            subscription_capacity_state: o.subscription_capacity_state || "not_applicable",
            concurrency_limit: o.concurrency_limit || 4,
            concurrency_in_use: o.concurrency_in_use || 0,
            requested_model_id: nil
          })

        rebuilt
      end)

    wild_input = %{
      route_input
      | observations: [generic],
        scoreboard: [
          score_row("model-a", "openai_oauth", 0.1),
          score_row("model-b", "openai_oauth", 0.99)
        ]
    }

    assert {:ok, wild} = ProviderRouter.decide_route(wild_input)
    # Wildcard present evidence can authorize the higher-scored sibling B —
    # the bug class this assembly path must never reintroduce.
    assert wild["model"] == "model-b"
  end

  test "security regression: injected two-arity observation_reader bypasses catalog and health seams" do
    model = oauth_model("model-a")

    obs =
      observation!(
        "openai_oauth",
        "model-a",
        "present",
        @observed,
        @expires
      )

    assert {:ok, input} =
             RouteInputAssembler.assemble(
               profile: enabled_profile([model]),
               clock: fn -> @now end,
               observation_reader: fn providers, dt ->
                 assert providers == ["openai_oauth"]
                 assert dt == @now
                 {:ok, [obs]}
               end,
               oauth_health_reader: fn _ ->
                 flunk("injected observation_reader must bypass oauth_health_reader")
               end,
               oauth_catalog_snapshot_reader: fn ->
                 flunk("injected observation_reader must bypass catalog snapshot")
               end,
               budget_reader: fn providers, dt ->
                 {:ok, Enum.map(providers, &budget(&1, dt))}
               end
             )

    assert [only] = input.observations
    assert only.requested_model_id == "model-a"
    assert only.model_catalog_membership == "present"
  end

  defp oauth_model(id) do
    %ModelEntry{
      canonical_id: id,
      providers: [
        %ProviderEntry{
          id: :openai_oauth,
          ref: id,
          auth: :oauth,
          runtimes: [:arbor],
          pricing: nil
        }
      ],
      family: :test,
      context_window: 100_000,
      max_output_tokens: 4_000,
      capabilities: [:tool_use]
    }
  end

  defp enabled_profile(catalog) do
    providers =
      catalog
      |> Enum.flat_map(fn m -> Enum.map(m.providers, &Atom.to_string(&1.id)) end)
      |> Enum.uniq()

    %{
      enabled: true,
      task_registry: %{"default" => %{requirements: %{}}},
      default_task_class: "default",
      catalog: catalog,
      scoreboard: [],
      providers: providers,
      params: %{}
    }
  end

  defp ready_health(generation) do
    {:ok, health} =
      OAuthHealth.new(%{
        version: 1,
        route: "openai_oauth",
        backend: "openai",
        status: "ready",
        owner: "arbor_owned",
        origin: "arbor_login",
        source: "arbor_oauth_store",
        generation: generation
      })

    health
  end

  defp usable_catalog!(model_ids, generation) do
    {:ok, catalog} =
      ProviderModelCatalog.new(%{
        route: "openai_oauth",
        backend: "openai",
        runtime: "arbor",
        model_ids: model_ids,
        observed_at: @observed,
        expires_at: @expires,
        credential_generation: generation
      })

    catalog
  end

  defp budget(provider, %DateTime{} = dt) do
    {:ok, snap} =
      BudgetSnapshot.new(%{
        version: 1,
        provider: provider,
        source: "arbor_ai_trackers",
        observed_at: DateTime.to_iso8601(dt),
        expires_at: DateTime.to_iso8601(DateTime.add(dt, 300, :second)),
        remaining_spend: 10.0,
        current_spend: 0.0,
        request_count: 0,
        quota_state: "available",
        quota_remaining_units: 10,
        subscription_capacity_state: "not_applicable",
        concurrency_limit: 4,
        concurrency_in_use: 0
      })

    snap
  end

  defp score_row(model, provider, score) do
    %{
      model: model,
      provider: provider,
      runtime: "arbor",
      score: score,
      dangerous_misses: 0,
      format_failure_rate: 0.0,
      variance: 0.0,
      marginal_cost: 0.01,
      latency_ms: 10
    }
  end

  defp observation!(provider, model, membership, observed_at, expires_at) do
    {:ok, obs} =
      ProviderObservation.new(%{
        provider: provider,
        source: "test",
        runtime: "arbor",
        observed_at: observed_at,
        expires_at: expires_at,
        availability: "available",
        auth_health: "healthy",
        model_catalog_membership: membership,
        quota_state: "available",
        subscription_capacity_state: "not_applicable",
        concurrency_limit: 4,
        concurrency_in_use: 0,
        requested_model_id: model
      })

    obs
  end
end
