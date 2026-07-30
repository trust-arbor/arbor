defmodule Arbor.AI.Runtime.ProviderModelCatalogObservationTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.Runtime.ProviderModelCatalogObservation
  alias Arbor.Contracts.LLM.{OAuthHealth, ProviderModelCatalog, ProviderObservation}

  @moduletag :fast

  @now ~U[2026-07-29 12:02:00Z]
  @observed "2026-07-29T12:00:00Z"
  @expires "2026-07-29T12:05:00Z"
  @health_ttl_seconds 30

  test "present membership when model id is in a usable catalog" do
    health = ready_health(7)
    catalog = catalog!(["gpt-a", "gpt-b"], 7)

    assert {:ok, attrs} =
             ProviderModelCatalogObservation.compose(health, catalog, "gpt-b", @now)

    assert attrs["model_catalog_membership"] == "present"
    assert attrs["requested_model_id"] == "gpt-b"
    assert attrs["provider"] == "openai_oauth"
    assert attrs["source"] == "arbor_oauth_catalog"
    assert attrs["runtime"] == "arbor"
    assert attrs["availability"] == "available"
    assert attrs["auth_health"] == "healthy"
    refute Map.has_key?(attrs, "failure_code")
    # Catalog source timestamps preserved; expiry bounded by health TTL too.
    assert attrs["observed_at"] == @observed

    assert attrs["expires_at"] ==
             DateTime.to_iso8601(DateTime.add(@now, @health_ttl_seconds, :second))

    assert ProviderObservation.valid?(attrs)
    refute Map.has_key?(attrs, "account_id")
    refute Map.has_key?(attrs, "access_token")
  end

  test "absent membership emits model_absent when no higher-priority health failure" do
    health = ready_health(1)
    catalog = catalog!(["gpt-a"], 1)

    assert {:ok, attrs} =
             ProviderModelCatalogObservation.compose(health, catalog, "gpt-missing", @now)

    assert attrs["model_catalog_membership"] == "absent"
    assert attrs["requested_model_id"] == "gpt-missing"
    assert attrs["source"] == "arbor_oauth_catalog"
    assert attrs["failure_code"] == "model_absent"
    assert attrs["failure_message"] == "requested model absent from catalog"
    assert attrs["observed_at"] == @observed
    assert ProviderObservation.valid?(attrs)
  end

  test "absent does not overwrite higher-priority base health failure" do
    assert {:ok, expired_health} =
             OAuthHealth.new(%{
               version: 1,
               route: "openai_oauth",
               backend: "openai",
               status: "expired",
               owner: "arbor_owned",
               origin: "arbor_login",
               source: "arbor_oauth_store",
               generation: 1
             })

    catalog = catalog!(["gpt-a"], 1)

    assert {:ok, attrs} =
             ProviderModelCatalogObservation.compose(
               expired_health,
               catalog,
               "gpt-missing",
               @now
             )

    assert attrs["model_catalog_membership"] == "absent"
    assert attrs["source"] == "arbor_oauth_catalog"
    assert attrs["auth_health"] == "expired"
    assert attrs["failure_code"] == "auth_expired"
    assert attrs["failure_message"] == "oauth credential expired"
    refute attrs["failure_code"] == "model_absent"
  end

  test "missing catalog is unknown and keeps health source and timestamps" do
    health = ready_health(1)

    assert {:ok, attrs} =
             ProviderModelCatalogObservation.compose(health, nil, "gpt-a", @now)

    assert attrs["model_catalog_membership"] == "unknown"
    assert attrs["source"] == "arbor_oauth_health"
    assert attrs["requested_model_id"] == "gpt-a"
    assert attrs["observed_at"] == DateTime.to_iso8601(@now)

    assert attrs["expires_at"] ==
             DateTime.to_iso8601(DateTime.add(@now, @health_ttl_seconds, :second))

    refute Map.has_key?(attrs, "failure_code")
  end

  test "expired catalog is unknown" do
    health = ready_health(1)

    catalog =
      catalog!(["gpt-a"], 1,
        observed_at: "2026-07-29T11:00:00Z",
        expires_at: "2026-07-29T11:05:00Z"
      )

    assert {:ok, attrs} =
             ProviderModelCatalogObservation.compose(health, catalog, "gpt-a", @now)

    assert attrs["model_catalog_membership"] == "unknown"
    assert attrs["source"] == "arbor_oauth_health"
    assert attrs["observed_at"] == DateTime.to_iso8601(@now)
  end

  test "future-observed catalog is unknown" do
    health = ready_health(1)

    catalog =
      catalog!(["gpt-a"], 1,
        observed_at: "2026-07-29T12:10:00Z",
        expires_at: "2026-07-29T12:15:00Z"
      )

    assert {:ok, attrs} =
             ProviderModelCatalogObservation.compose(health, catalog, "gpt-a", @now)

    assert attrs["model_catalog_membership"] == "unknown"
    assert attrs["source"] == "arbor_oauth_health"
  end

  test "credential-generation mismatch is unknown" do
    health = ready_health(5)
    catalog = catalog!(["gpt-a"], 9)

    assert {:ok, attrs} =
             ProviderModelCatalogObservation.compose(health, catalog, "gpt-a", @now)

    assert attrs["model_catalog_membership"] == "unknown"
    assert attrs["source"] == "arbor_oauth_health"
  end

  test "route/backend/runtime mismatch is unknown" do
    health = ready_health(1)
    # Valid xai catalog against openai health
    xai = make_catalog("xai_oauth", "xai", ["grok-1"], 1)

    assert {:ok, attrs} =
             ProviderModelCatalogObservation.compose(health, xai, "grok-1", @now)

    assert attrs["model_catalog_membership"] == "unknown"
    assert attrs["provider"] == "openai_oauth"
    assert attrs["source"] == "arbor_oauth_health"
  end

  test "unhealthy OAuth states without generation keep membership unknown" do
    catalog = catalog!(["gpt-a"], 1)

    for status <- ["login_required", "migration_required", "store_unreadable"] do
      assert {:ok, health} =
               OAuthHealth.new(%{
                 version: 1,
                 route: "openai_oauth",
                 backend: "openai",
                 status: status
               })

      assert {:ok, attrs} =
               ProviderModelCatalogObservation.compose(health, catalog, "gpt-a", @now)

      assert attrs["model_catalog_membership"] == "unknown"
      assert attrs["source"] == "arbor_oauth_health"
      assert attrs["availability"] == "unavailable"
      assert attrs["failure_code"] in ["auth_required", "protocol_error"]
    end
  end

  test "expired health with matching generation can still mark present via catalog" do
    assert {:ok, expired_health} =
             OAuthHealth.new(%{
               version: 1,
               route: "openai_oauth",
               backend: "openai",
               status: "expired",
               owner: "arbor_owned",
               origin: "arbor_login",
               source: "arbor_oauth_store",
               generation: 1
             })

    catalog = catalog!(["gpt-a"], 1)

    assert {:ok, attrs} =
             ProviderModelCatalogObservation.compose(expired_health, catalog, "gpt-a", @now)

    assert attrs["auth_health"] == "expired"
    assert attrs["model_catalog_membership"] == "present"
    assert attrs["source"] == "arbor_oauth_catalog"
    assert attrs["failure_code"] == "auth_expired"
  end

  test "catalog expiry earlier than health TTL is preserved" do
    health = ready_health(1)
    # Catalog expires 10s after decision_time; health TTL is 30s.
    catalog =
      catalog!(["gpt-a"], 1,
        observed_at: "2026-07-29T12:00:00Z",
        expires_at: "2026-07-29T12:02:10Z"
      )

    assert {:ok, attrs} =
             ProviderModelCatalogObservation.compose(health, catalog, "gpt-a", @now)

    assert attrs["model_catalog_membership"] == "present"
    assert attrs["source"] == "arbor_oauth_catalog"
    assert attrs["observed_at"] == "2026-07-29T12:00:00Z"
    assert attrs["expires_at"] == "2026-07-29T12:02:10Z"
  end

  test "xai_oauth empty selectable catalog yields absent with model_absent" do
    assert {:ok, health} =
             OAuthHealth.new(%{
               version: 1,
               route: "xai_oauth",
               backend: "xai",
               status: "ready",
               owner: "arbor_owned",
               origin: "arbor_login",
               source: "arbor_oauth_store",
               generation: 2
             })

    empty = make_catalog("xai_oauth", "xai", [], 2)

    assert {:ok, attrs} =
             ProviderModelCatalogObservation.compose(health, empty, "grok-1", @now)

    assert attrs["provider"] == "xai_oauth"
    assert attrs["model_catalog_membership"] == "absent"
    assert attrs["source"] == "arbor_oauth_catalog"
    assert attrs["failure_code"] == "model_absent"
  end

  test "map health must re-admit through OAuthHealth.new; partial maps fail closed" do
    health = ready_health(1)
    catalog = catalog!(["gpt-a"], 1)

    # Partial route/status map must not invent backend/ownership.
    assert {:error, :invalid_observation} =
             ProviderModelCatalogObservation.compose(
               %{route: "openai_oauth", status: "ready"},
               catalog,
               "gpt-a",
               @now
             )

    assert {:error, :invalid_observation} =
             ProviderModelCatalogObservation.compose(
               %{route: "openai", status: "ready"},
               catalog,
               "gpt-a",
               @now
             )

    # Full closed map form is admitted.
    assert {:ok, attrs} =
             ProviderModelCatalogObservation.compose(
               OAuthHealth.to_map(health),
               catalog,
               "gpt-a",
               @now
             )

    assert attrs["model_catalog_membership"] == "present"
    assert attrs["source"] == "arbor_oauth_catalog"

    assert {:error, :invalid_observation} =
             ProviderModelCatalogObservation.compose(health, catalog, "", @now)

    assert {:error, :invalid_observation} =
             ProviderModelCatalogObservation.compose(health, catalog, "gpt-a", "not-dt")

    assert {:error, :invalid_observation} =
             ProviderModelCatalogObservation.compose(
               health,
               catalog,
               String.duplicate("x", 300),
               @now
             )
  end

  test "nil requested model id is rejected; model-specific composer never genericizes" do
    health = ready_health(1)
    catalog = catalog!(["gpt-a"], 1)

    assert {:error, :invalid_observation} =
             ProviderModelCatalogObservation.compose(health, catalog, nil, @now)

    assert {:error, :invalid_observation} =
             ProviderModelCatalogObservation.compose(health, nil, nil, @now)
  end

  test "non-nil malformed catalog fails closed; only nil is a clean miss" do
    health = ready_health(1)

    assert {:error, :invalid_observation} =
             ProviderModelCatalogObservation.compose(
               health,
               %{not: "a catalog"},
               "gpt-a",
               @now
             )

    assert {:error, :invalid_observation} =
             ProviderModelCatalogObservation.compose(
               health,
               %{
                 route: "openai_oauth",
                 backend: "xai",
                 runtime: "arbor",
                 model_ids: ["gpt-a"],
                 observed_at: @observed,
                 expires_at: @expires,
                 credential_generation: 1
               },
               "gpt-a",
               @now
             )

    assert {:error, :invalid_observation} =
             ProviderModelCatalogObservation.compose(health, "not-a-catalog", "gpt-a", @now)

    # nil alone remains the clean unavailable/miss path.
    assert {:ok, attrs} =
             ProviderModelCatalogObservation.compose(health, nil, "gpt-a", @now)

    assert attrs["model_catalog_membership"] == "unknown"
    assert attrs["requested_model_id"] == "gpt-a"
    assert attrs["source"] == "arbor_oauth_health"
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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

  defp catalog!(model_ids, generation, opts \\ []) do
    make_catalog("openai_oauth", "openai", model_ids, generation, opts)
  end

  defp make_catalog(route, backend, model_ids, generation, opts \\ []) do
    observed = Keyword.get(opts, :observed_at, @observed)
    expires = Keyword.get(opts, :expires_at, @expires)

    {:ok, catalog} =
      ProviderModelCatalog.new(%{
        route: route,
        backend: backend,
        runtime: "arbor",
        model_ids: model_ids,
        observed_at: observed,
        expires_at: expires,
        credential_generation: generation
      })

    catalog
  end
end
