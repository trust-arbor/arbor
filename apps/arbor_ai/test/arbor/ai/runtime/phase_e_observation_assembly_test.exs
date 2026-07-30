defmodule Arbor.AI.Runtime.PhaseEObservationAssemblyTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.Runtime.RouteInputAssembler
  alias Arbor.Contracts.LLM.{BudgetSnapshot, ModelEntry, ProviderEntry, ProviderObservation}

  @moduletag :fast
  @now ~U[2026-07-22 22:00:00Z]
  @availability_enum ProviderObservation.enums()["availability"]
  @auth_health_enum ProviderObservation.enums()["auth_health"]
  @failure_code_enum ProviderObservation.enums()["failure_code"]
  # OAuthHealthObservation TTL is 30 seconds.
  @oauth_ttl_seconds 30

  test "default path uses oauth_health for exact oauth routes never ACP source" do
    # Environment-neutral: prove exact route, source, runtime, bounded timestamps,
    # and a contract-valid closed health state without assuming credentials are
    # ready, expired, or absent.
    model = model_entry("m1", :openai_oauth, :arbor)

    assert {:ok, input} =
             RouteInputAssembler.assemble(
               profile: enabled_profile([model]),
               clock: fn -> @now end,
               budget_reader: fn providers, dt ->
                 {:ok, Enum.map(providers, &budget(&1, dt))}
               end
             )

    obs = hd(input.observations)
    assert obs.provider == "openai_oauth"
    # Empty/miss catalog keeps health source; membership is model-specific unknown.
    assert obs.source == "arbor_oauth_health"
    refute obs.source == "acp_provider_readiness"
    assert obs.runtime == "arbor"
    assert obs.requested_model_id == "m1"
    assert obs.model_catalog_membership == "unknown"
    assert_bounded_timestamps(obs, @now, @oauth_ttl_seconds)
    assert ProviderObservation.valid?(obs)
    assert obs.availability in @availability_enum
    assert is_nil(obs.auth_health) or obs.auth_health in @auth_health_enum
    assert is_nil(obs.failure_code) or obs.failure_code in @failure_code_enum

    # Failure code and message must be paired (contract); ready health has neither.
    if is_nil(obs.failure_code) do
      assert is_nil(obs.failure_message)
    else
      assert is_binary(obs.failure_message)
      assert byte_size(obs.failure_message) > 0
    end
  end

  test "security regression: oauth observation assembly never refreshes credentials" do
    prior = Application.get_env(:arbor_llm, :oauth_refresh_fun)

    Application.put_env(:arbor_llm, :oauth_refresh_fun, fn _, _, _ ->
      flunk("oauth_health / assembly must not refresh credentials")
    end)

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:arbor_llm, :oauth_refresh_fun)
        fun -> Application.put_env(:arbor_llm, :oauth_refresh_fun, fun)
      end
    end)

    model = model_entry("m1", :openai_oauth, :arbor)

    assert {:ok, input} =
             RouteInputAssembler.assemble(
               profile: enabled_profile([model]),
               clock: fn -> @now end,
               budget_reader: fn providers, dt ->
                 {:ok, Enum.map(providers, &budget(&1, dt))}
               end
             )

    obs = hd(input.observations)
    assert obs.source == "arbor_oauth_health"
    assert obs.requested_model_id == "m1"
  end

  test "non-OAuth default reader produces bounded acp_provider_readiness envelope" do
    # Production default observation_reader — no injected observation evidence.
    # Use a known registered ACP provider (grok); readiness returns a bounded
    # envelope whether or not the executable is present.
    model = model_entry("m1", :grok, :acp)

    assert {:ok, input} =
             RouteInputAssembler.assemble(
               profile: enabled_profile([model]),
               clock: fn -> @now end,
               budget_reader: fn providers, dt ->
                 {:ok, Enum.map(providers, &budget(&1, dt))}
               end
             )

    obs = hd(input.observations)
    assert obs.provider == "grok"
    assert obs.source == "acp_provider_readiness"
    refute obs.source == "arbor_oauth_health"
    assert obs.runtime == "acp"
    assert_bounded_timestamps(obs, @now, @oauth_ttl_seconds)
    assert ProviderObservation.valid?(obs)
    assert obs.availability in @availability_enum
    assert is_nil(obs.auth_health) or obs.auth_health in @auth_health_enum
    assert is_nil(obs.failure_code) or obs.failure_code in @failure_code_enum
  end

  test "exact-route isolation: xai failure does not mark openai observation" do
    model_o = model_entry("mo", :openai_oauth, :arbor)
    model_x = model_entry("mx", :xai_oauth, :arbor)

    # Custom reader simulating production overlays with only xai failure present
    assert {:ok, input} =
             RouteInputAssembler.assemble(
               profile: enabled_profile([model_o, model_x]),
               clock: fn -> @now end,
               observation_reader: fn providers, dt ->
                 {:ok,
                  Enum.map(providers, fn p ->
                    base = %{
                      "version" => 1,
                      "provider" => p,
                      "source" => "arbor_oauth_health",
                      "runtime" => "arbor",
                      "observed_at" => DateTime.to_iso8601(dt),
                      "expires_at" => DateTime.to_iso8601(DateTime.add(dt, 30, :second)),
                      "availability" => "available",
                      "auth_health" => "healthy",
                      "model_catalog_membership" => "unknown",
                      "quota_state" => "unknown",
                      "subscription_capacity_state" => "unknown"
                    }

                    if p == "xai_oauth" do
                      Map.merge(base, %{
                        "availability" => "unavailable",
                        "subscription_capacity_state" => "exhausted",
                        "failure_code" => "tier_denied",
                        "failure_message" => "oauth tier denied"
                      })
                    else
                      base
                    end
                  end)}
               end,
               budget_reader: fn providers, dt ->
                 {:ok, Enum.map(providers, &budget(&1, dt))}
               end
             )

    by_provider = Map.new(input.observations, &{&1.provider, &1})
    assert by_provider["openai_oauth"].availability == "available"
    assert by_provider["xai_oauth"].availability == "unavailable"
    assert by_provider["xai_oauth"].subscription_capacity_state == "exhausted"
  end

  defp assert_bounded_timestamps(obs, decision_time, max_ttl_seconds) do
    assert is_binary(obs.observed_at)
    assert is_binary(obs.expires_at)
    assert {:ok, observed_dt, _} = DateTime.from_iso8601(obs.observed_at)
    assert {:ok, expires_dt, _} = DateTime.from_iso8601(obs.expires_at)
    assert DateTime.compare(expires_dt, observed_dt) == :gt
    # Source-owned timestamps preserved from decision clock (not restamped later).
    assert DateTime.compare(observed_dt, decision_time) == :eq or
             abs(DateTime.diff(observed_dt, decision_time, :second)) <= 1

    ttl = DateTime.diff(expires_dt, observed_dt, :second)
    assert ttl > 0
    assert ttl <= max_ttl_seconds
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

  defp model_entry(id, provider, runtime) do
    %ModelEntry{
      canonical_id: id,
      providers: [
        %ProviderEntry{id: provider, ref: id, auth: :api_key, runtimes: [runtime]}
      ],
      family: :test,
      context_window: 100_000,
      max_output_tokens: 4_000
    }
  end

  defp budget(provider, %DateTime{} = dt) do
    {:ok, snap} =
      BudgetSnapshot.new(%{
        version: 1,
        provider: provider,
        source: "arbor_ai_trackers",
        observed_at: DateTime.to_iso8601(dt),
        expires_at: DateTime.to_iso8601(DateTime.add(dt, 300, :second)),
        current_spend: 0.0,
        request_count: 0,
        quota_state: "available",
        subscription_capacity_state: "unknown"
      })

    snap
  end
end
