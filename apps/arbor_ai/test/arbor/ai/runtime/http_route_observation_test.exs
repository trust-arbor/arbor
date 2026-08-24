defmodule Arbor.AI.Runtime.HttpRouteObservationTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.AI.Runtime.HttpRouteObservation
  alias Arbor.Contracts.LLM.ProviderObservation

  @now ~U[2026-08-23 18:00:00Z]

  test "keyless arbor HTTP candidate is present on arbor, never ACP" do
    assert {:ok, attrs} =
             HttpRouteObservation.from_candidate(
               %{
                 provider: "opencode_zen",
                 ref: "x-preview-f-free",
                 runtime: "arbor",
                 auth: :none
               },
               @now
             )

    assert {:ok, obs} = ProviderObservation.new(attrs)
    assert obs.source == "arbor_http_route"
    assert obs.runtime == "arbor"
    assert obs.provider == "opencode_zen"
    assert obs.requested_model_id == "x-preview-f-free"
    assert obs.availability == "available"
    assert obs.model_catalog_membership == "present"
    assert obs.subscription_capacity_state == "not_applicable"
    assert is_nil(obs.auth_health)
    refute obs.source == "acp_provider_readiness"
  end

  test "API-key arbor HTTP candidate emits auth_health so strict routing can admit it" do
    assert {:ok, attrs} =
             HttpRouteObservation.from_candidate(
               %{
                 provider: "openrouter",
                 ref: "openrouter/anthropic/claude-3-5-haiku-latest",
                 runtime: "arbor",
                 auth: :api_key
               },
               @now
             )

    assert {:ok, obs} = ProviderObservation.new(attrs)
    assert obs.auth_health == "healthy"
    assert obs.source == "arbor_http_route"
    refute is_nil(obs.auth_health)
    refute obs.auth_health == "unknown"
  end

  test "rejects a blank provider rather than emitting an ACP-shaped row" do
    assert {:error, :invalid_observation} =
             HttpRouteObservation.from_candidate(
               %{provider: "", ref: "x", runtime: "arbor", auth: :none},
               @now
             )
  end
end
