defmodule Arbor.AI.Runtime.OAuthHealthObservationTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.Runtime.OAuthHealthObservation
  alias Arbor.Contracts.LLM.OAuthHealth

  @moduletag :fast
  @now ~U[2026-07-22 22:00:00Z]

  test "maps every closed OAuthHealth status" do
    statuses = [
      {"ready", "available", "healthy", nil},
      {"login_required", "unavailable", "unavailable", "auth_required"},
      {"migration_required", "unavailable", "unavailable", "auth_required"},
      {"expired", "unavailable", "expired", "auth_expired"},
      {"invalid", "unavailable", "invalid", "auth_required"},
      {"relogin_required", "unavailable", "invalid", "auth_required"},
      {"source_unavailable", "unavailable", "unavailable", "transport_error"},
      {"store_unreadable", "unavailable", "unavailable", "protocol_error"}
    ]

    for {status, availability, auth, code} <- statuses do
      attrs = base_attrs(status)
      assert {:ok, health} = OAuthHealth.new(attrs)
      assert {:ok, obs} = OAuthHealthObservation.from_health(health, @now)
      assert obs["provider"] == "openai_oauth"
      assert obs["source"] == "arbor_oauth_health"
      assert obs["runtime"] == "arbor"
      assert obs["availability"] == availability
      assert obs["auth_health"] == auth
      assert obs["quota_state"] == "unknown"
      refute Map.has_key?(obs, "account_id")
      assert is_nil(Map.get(obs, "account_id"))

      if code do
        assert obs["failure_code"] == code
        assert is_binary(obs["failure_message"])
      else
        refute Map.has_key?(obs, "failure_code")
      end
    end
  end

  test "source_unsupported only for xai_oauth backend path" do
    assert {:ok, health} =
             OAuthHealth.new(%{
               version: 1,
               route: "xai_oauth",
               backend: "xai",
               status: "source_unsupported",
               owner: "source_owned",
               origin: "external_cli",
               source: "grok_file"
             })

    assert {:ok, obs} = OAuthHealthObservation.from_health(health, @now)
    assert obs["provider"] == "xai_oauth"
    assert obs["failure_code"] == "protocol_error"
    assert obs["availability"] == "unavailable"
  end

  test "malformed status fails closed" do
    assert {:error, :invalid_observation} =
             OAuthHealthObservation.from_health(%{route: "openai_oauth", status: "nope"}, @now)
  end

  test "oauth_route?/1 is exact table only" do
    assert OAuthHealthObservation.oauth_route?("openai_oauth")
    assert OAuthHealthObservation.oauth_route?(:xai_oauth)
    refute OAuthHealthObservation.oauth_route?("openai")
    refute OAuthHealthObservation.oauth_route?("xai")
    refute OAuthHealthObservation.oauth_route?("grok")
  end

  defp base_attrs("ready") do
    %{
      version: 1,
      route: "openai_oauth",
      backend: "openai",
      status: "ready",
      owner: "arbor_owned",
      origin: "arbor_login",
      source: "arbor_oauth_store",
      generation: 1
    }
  end

  defp base_attrs("expired") do
    %{
      version: 1,
      route: "openai_oauth",
      backend: "openai",
      status: "expired",
      owner: "arbor_owned",
      origin: "arbor_login",
      source: "arbor_oauth_store",
      generation: 1
    }
  end

  defp base_attrs(status)
       when status in [
              "login_required",
              "migration_required",
              "store_unreadable"
            ] do
    %{version: 1, route: "openai_oauth", backend: "openai", status: status}
  end

  defp base_attrs(status)
       when status in ["invalid", "relogin_required", "source_unavailable"] do
    %{
      version: 1,
      route: "openai_oauth",
      backend: "openai",
      status: status,
      owner: "source_owned",
      origin: "external_cli",
      source: "codex_file"
    }
  end
end
