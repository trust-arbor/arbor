defmodule Arbor.AI.Runtime.HttpRouteObservation do
  @moduledoc """
  Local observation for an in-BEAM HTTP (`:arbor`) non-OAuth route.

  Keyless and API-key providers are not ACP workers. They must not borrow
  `acp_provider_readiness` (wrong runtime, unknown catalog, no concurrency).
  This composer emits model-specific arbor evidence from the admitted
  `%ModelEntry{}` without probing the network or reading OAuth caches.
  """

  alias Arbor.Contracts.LLM.ProviderObservation

  @source "arbor_http_route"
  @runtime "arbor"
  @ttl_seconds 30

  @type candidate :: %{
          provider: String.t(),
          ref: String.t(),
          runtime: String.t(),
          auth: atom()
        }

  @doc """
  Build closed observation attrs for one arbor HTTP candidate.

  Membership is `present` because assembly already admitted this ModelEntry.
  That is routing-catalog membership, not a live remote listing.
  Auth health is omitted for `:none` (no credential exists by design).
  Authenticated HTTP routes (`:api_key`, `:aws`, `:gcp`, `:oauth`) must
  emit `auth_health` — strict routing rejects every `auth != :none` observation
  that omits it (`missing_evidence:auth`). This is catalog-admitted credential
  class, not a live key probe.
  """
  @spec from_candidate(candidate(), DateTime.t()) :: {:ok, map()} | {:error, :invalid_observation}
  def from_candidate(candidate, %DateTime{} = decision_time) when is_map(candidate) do
    with {:ok, provider} <- require_id(candidate, :provider),
         {:ok, ref} <- require_id(candidate, :ref),
         true <- candidate[:runtime] in [@runtime, :arbor, nil] do
      observed_at = DateTime.to_iso8601(decision_time)
      expires_at = DateTime.to_iso8601(DateTime.add(decision_time, @ttl_seconds, :second))

      attrs =
        maybe_put_auth_health(
          %{
            "version" => 1,
            "provider" => provider,
            "source" => @source,
            "runtime" => @runtime,
            "observed_at" => observed_at,
            "expires_at" => expires_at,
            "availability" => "available",
            "model_catalog_membership" => "present",
            "quota_state" => "unknown",
            "subscription_capacity_state" => subscription_state(candidate[:auth]),
            "requested_model_id" => ref
          },
          candidate[:auth]
        )

      case ProviderObservation.new(attrs) do
        {:ok, observation} ->
          case ProviderObservation.to_map(observation) do
            map when is_map(map) -> {:ok, map}
            _ -> {:error, :invalid_observation}
          end

        {:error, _} ->
          {:error, :invalid_observation}
      end
    else
      _ -> {:error, :invalid_observation}
    end
  end

  def from_candidate(_candidate, _decision_time), do: {:error, :invalid_observation}

  defp require_id(map, key) do
    value = Map.get(map, key) || Map.get(map, Atom.to_string(key))

    if is_binary(value) and value != "" and String.valid?(value) do
      {:ok, value}
    else
      :error
    end
  end

  defp subscription_state(:none), do: "not_applicable"
  defp subscription_state(_), do: "unknown"

  defp maybe_put_auth_health(attrs, :none), do: attrs
  defp maybe_put_auth_health(attrs, nil), do: attrs

  defp maybe_put_auth_health(attrs, auth)
       when auth in [:api_key, :aws, :gcp, :oauth] do
    Map.put(attrs, "auth_health", "healthy")
  end

  defp maybe_put_auth_health(attrs, _), do: attrs
end
