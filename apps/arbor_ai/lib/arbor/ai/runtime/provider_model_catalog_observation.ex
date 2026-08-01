defmodule Arbor.AI.Runtime.ProviderModelCatalogObservation do
  @moduledoc """
  Pure composition of closed OAuth health, one cached model catalog, and one
  requested provider model id into `ProviderObservation` attributes.

  Does not refresh credentials, call networks, or read the catalog store.
  Network and credential work belong to the refresh boundary on `Arbor.AI`.

  Health inputs are re-admitted through `OAuthHealth.new/1` — partial maps are
  never completed by inference. Usable catalog evidence labels source as
  `arbor_oauth_catalog` and may emit closed `model_absent` failure evidence.

  This composer is model-specific: a non-empty bounded requested model id is
  required. Only `nil` catalog means cache miss / unavailable; a non-nil
  malformed catalog fails closed as `{:error, :invalid_observation}`.
  """

  alias Arbor.AI.Runtime.OAuthHealthObservation
  alias Arbor.AI.Runtime.ProviderModelCatalogEvidence
  alias Arbor.Contracts.LLM.{OAuthHealth, ProviderModelCatalog, ProviderObservation}

  @catalog_source "arbor_oauth_catalog"
  @runtime "arbor"
  @ttl_seconds 30
  @max_model_id_bytes 256
  @model_absent_message "requested model absent from catalog"

  @doc """
  Compose base OAuth health observation attrs with catalog membership evidence.

  Requires a non-empty exact bounded `requested_model_id` — this path never
  emits a generic nil-model observation that could match sibling candidates.

  Membership is exactly one of `"present"`, `"absent"`, or `"unknown"`:

  * `nil` catalog → `"unknown"` (clean cache miss / unavailable)
  * non-nil malformed catalog map/struct → `{:error, :invalid_observation}`
  * usable catalog + exact route/backend/runtime + matching credential generation
    + non-future observed window + non-expired catalog → present/absent by
    exact model-id membership
  * valid but expired, future, generation-mismatched, or route-mismatched
    catalogs → `"unknown"`

  When the catalog is usable, source becomes `#{@catalog_source}`, source
  `observed_at` is preserved, and `expires_at` is the earlier of catalog
  freshness and the local health observation TTL
  (`decision_time + #{@ttl_seconds}s`). Exact absence emits closed
  `model_absent` failure evidence unless a higher-priority base health failure
  is already present.
  """
  @spec compose(
          OAuthHealth.t() | map() | keyword(),
          ProviderModelCatalog.t() | map() | nil,
          String.t(),
          DateTime.t()
        ) :: {:ok, map()} | {:error, :invalid_observation}
  def compose(health, catalog, requested_model_id, %DateTime{} = decision_time) do
    with {:ok, %OAuthHealth{} = health} <- admit_health(health),
         {:ok, model_id} <- admit_requested_model_id(requested_model_id),
         {:ok, base} <- OAuthHealthObservation.from_health(health, decision_time),
         {:ok, {membership, usable_catalog}} <-
           resolve_catalog(health, catalog, model_id, decision_time) do
      attrs =
        base
        |> Map.put("model_catalog_membership", membership)
        |> Map.put("requested_model_id", model_id)
        |> maybe_apply_usable_catalog(usable_catalog, membership, decision_time)

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
  rescue
    _ -> {:error, :invalid_observation}
  catch
    _, _ -> {:error, :invalid_observation}
  end

  def compose(_health, _catalog, _requested_model_id, _decision_time),
    do: {:error, :invalid_observation}

  # ---------------------------------------------------------------------------
  # Health + model id admission
  # ---------------------------------------------------------------------------

  # Closed OAuthHealth only — never invent backend/ownership from a partial map.
  defp admit_health(%OAuthHealth{} = health) do
    case OAuthHealth.new(OAuthHealth.to_map(health)) do
      {:ok, valid} -> {:ok, valid}
      {:error, _} -> :error
    end
  end

  defp admit_health(attrs) when is_map(attrs) or is_list(attrs) do
    case OAuthHealth.new(attrs) do
      {:ok, valid} -> {:ok, valid}
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp admit_health(_), do: :error

  # Model-specific composer: nil/blank/oversized ids are rejected, never genericized.
  defp admit_requested_model_id(id)
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_model_id_bytes do
    if String.valid?(id) and String.trim(id) != "" and
         not String.match?(id, ~r/[\x00-\x1F\x7F]/) do
      {:ok, id}
    else
      :error
    end
  end

  defp admit_requested_model_id(_), do: :error

  # ---------------------------------------------------------------------------
  # Membership
  # ---------------------------------------------------------------------------

  # Only nil means cache miss / unavailable. Non-nil must admit or fail closed.
  defp resolve_catalog(_health, nil, _model_id, _now), do: {:ok, {"unknown", nil}}

  defp resolve_catalog(%OAuthHealth{} = health, catalog, model_id, %DateTime{} = now)
       when is_binary(model_id) do
    case admit_catalog(catalog) do
      {:ok, %ProviderModelCatalog{} = valid} ->
        case ProviderModelCatalogEvidence.assess(
               valid,
               health.route,
               health.backend,
               @runtime,
               health.generation,
               now
             ) do
          {:ok, _usable} ->
            membership = if model_id in valid.model_ids, do: "present", else: "absent"
            {:ok, {membership, valid}}

          {:error, _reason} ->
            # Contract-valid but unusable (expired/future/gen/route mismatch).
            {:ok, {"unknown", nil}}
        end

      :error ->
        # Corrupted required evidence must not masquerade as a clean miss.
        :error
    end
  end

  defp resolve_catalog(_health, _catalog, _model_id, _now), do: :error

  defp admit_catalog(%ProviderModelCatalog{} = catalog) do
    case ProviderModelCatalog.new(ProviderModelCatalog.to_map(catalog)) do
      {:ok, valid} -> {:ok, valid}
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  end

  defp admit_catalog(attrs) when is_map(attrs) or is_list(attrs) do
    case ProviderModelCatalog.new(attrs) do
      {:ok, valid} -> {:ok, valid}
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  end

  defp admit_catalog(_), do: :error

  # ---------------------------------------------------------------------------
  # Observation attrs
  # ---------------------------------------------------------------------------

  defp maybe_apply_usable_catalog(attrs, nil, _membership, _now), do: attrs

  defp maybe_apply_usable_catalog(
         attrs,
         %ProviderModelCatalog{} = catalog,
         membership,
         %DateTime{} = now
       ) do
    attrs
    |> Map.put("source", @catalog_source)
    |> apply_catalog_window(catalog, now)
    |> maybe_model_absent_failure(membership)
  end

  defp apply_catalog_window(attrs, %ProviderModelCatalog{} = catalog, %DateTime{} = now) do
    with {:ok, catalog_expires} <- parse_dt(catalog.expires_at) do
      health_expires = DateTime.add(now, @ttl_seconds, :second)
      expires_at = earlier_datetime(catalog_expires, health_expires)

      attrs
      |> Map.put("observed_at", catalog.observed_at)
      |> Map.put("expires_at", DateTime.to_iso8601(expires_at))
    else
      _ -> attrs
    end
  end

  # Exact absence → closed model_absent, unless base health already failed harder.
  defp maybe_model_absent_failure(attrs, "absent") when is_map(attrs) do
    existing = Map.get(attrs, "failure_code") || Map.get(attrs, :failure_code)

    if is_nil(existing) do
      attrs
      |> Map.put("failure_code", "model_absent")
      |> Map.put("failure_message", @model_absent_message)
    else
      attrs
    end
  end

  defp maybe_model_absent_failure(attrs, _membership), do: attrs

  defp earlier_datetime(%DateTime{} = a, %DateTime{} = b) do
    if DateTime.compare(a, b) == :lt, do: a, else: b
  end

  defp parse_dt(%DateTime{} = dt), do: {:ok, dt}

  defp parse_dt(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_dt(_), do: :error
end
