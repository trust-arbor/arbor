defmodule Arbor.AI.Runtime.OAuthHealthObservation do
  @moduledoc """
  Pure mapping from closed `OAuthHealth` to base `ProviderObservation` attrs.

  Does not refresh credentials, call networks, or carry tokens/account IDs.
  """

  alias Arbor.Contracts.LLM.OAuthHealth

  @routes MapSet.new(["openai_oauth", "xai_oauth"])
  @source "arbor_oauth_health"
  @runtime "arbor"
  @ttl_seconds 30

  @status_table %{
    "ready" => {"available", "healthy", nil, nil},
    "login_required" => {"unavailable", "unavailable", "auth_required", "oauth login required"},
    "migration_required" =>
      {"unavailable", "unavailable", "auth_required", "oauth migration required"},
    "expired" => {"unavailable", "expired", "auth_expired", "oauth credential expired"},
    "invalid" => {"unavailable", "invalid", "auth_required", "oauth credential invalid"},
    "relogin_required" => {"unavailable", "invalid", "auth_required", "oauth relogin required"},
    "source_unavailable" =>
      {"unavailable", "unavailable", "transport_error", "oauth source unavailable"},
    "source_unsupported" =>
      {"unavailable", "unavailable", "protocol_error", "oauth source unsupported"},
    "store_unreadable" =>
      {"unavailable", "unavailable", "protocol_error", "oauth store unreadable"}
  }

  @spec oauth_route?(term()) :: boolean()
  def oauth_route?(provider) when provider in ["openai_oauth", "xai_oauth"], do: true
  def oauth_route?(:openai_oauth), do: true
  def oauth_route?(:xai_oauth), do: true
  def oauth_route?(_), do: false

  @spec from_health(OAuthHealth.t() | map(), DateTime.t()) ::
          {:ok, map()} | {:error, :invalid_observation}
  def from_health(%OAuthHealth{} = health, %DateTime{} = decision_time) do
    from_health(
      %{
        route: health.route,
        status: health.status
      },
      decision_time
    )
  end

  def from_health(%{route: route, status: status}, %DateTime{} = decision_time)
      when is_binary(route) and is_binary(status) do
    if MapSet.member?(@routes, route) do
      case Map.fetch(@status_table, status) do
        {:ok, {availability, auth_health, failure_code, failure_message}} ->
          observed_at = DateTime.to_iso8601(decision_time)
          expires_at = DateTime.to_iso8601(DateTime.add(decision_time, @ttl_seconds, :second))

          attrs = %{
            "version" => 1,
            "provider" => route,
            "source" => @source,
            "runtime" => @runtime,
            "observed_at" => observed_at,
            "expires_at" => expires_at,
            "availability" => availability,
            "auth_health" => auth_health,
            "model_catalog_membership" => "unknown",
            "quota_state" => "unknown",
            "subscription_capacity_state" => "unknown"
          }

          attrs =
            if is_nil(failure_code) do
              attrs
            else
              attrs
              |> Map.put("failure_code", failure_code)
              |> Map.put("failure_message", failure_message)
            end

          {:ok, attrs}

        :error ->
          {:error, :invalid_observation}
      end
    else
      {:error, :invalid_observation}
    end
  end

  def from_health(_health, _decision_time), do: {:error, :invalid_observation}
end
