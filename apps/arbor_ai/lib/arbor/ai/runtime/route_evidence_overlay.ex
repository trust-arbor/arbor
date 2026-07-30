defmodule Arbor.AI.Runtime.RouteEvidenceOverlay do
  @moduledoc """
  Pure merge of base observation attrs with route-failure, quota, and
  node-local concurrency evidence.

  Never upgrades availability from unavailable to available. Does not write stores.
  """

  @spec overlay(map(), map() | nil, map() | nil, DateTime.t()) :: map()
  def overlay(base, route_failure, quota_entry, %DateTime{} = decision_time)
      when is_map(base) do
    base
    |> overlay_route_failure(route_failure, decision_time)
    |> overlay_quota(quota_entry, decision_time)
  end

  @doc """
  Overlay exact-route concurrency fields from a snapshot entry.

  `snap_entry` is `%{concurrency_limit: n, concurrency_in_use: u}` for the
  observation's exact `{provider, runtime}`, or `nil` when the route is
  unconfigured (leaves concurrency evidence missing so strict routing rejects).
  Never invents zeros for unconfigured routes.
  """
  @spec overlay_concurrency(map(), map() | nil) :: map()
  def overlay_concurrency(attrs, nil) when is_map(attrs), do: attrs

  def overlay_concurrency(attrs, snap_entry) when is_map(attrs) and is_map(snap_entry) do
    limit = Map.get(snap_entry, :concurrency_limit) || Map.get(snap_entry, "concurrency_limit")
    in_use = Map.get(snap_entry, :concurrency_in_use) || Map.get(snap_entry, "concurrency_in_use")

    if is_integer(limit) and limit >= 0 and is_integer(in_use) and in_use >= 0 do
      attrs
      |> Map.put(key(attrs, "concurrency_limit"), limit)
      |> Map.put(key(attrs, "concurrency_in_use"), in_use)
    else
      attrs
    end
  end

  def overlay_concurrency(attrs, _), do: attrs

  defp overlay_route_failure(attrs, nil, _now), do: attrs

  defp overlay_route_failure(attrs, failure, now) when is_map(failure) do
    expires_at = Map.get(failure, :expires_at) || Map.get(failure, "expires_at")
    class = Map.get(failure, :class) || Map.get(failure, "class")

    if active?(expires_at, now) do
      case class do
        :auth ->
          attrs
          |> put_worse_availability("unavailable")
          |> put_worse_auth("invalid")
          |> put_failure("auth_required", "oauth responses auth failure")
          |> maybe_cap_expires(expires_at)

        :tier_denied ->
          attrs
          |> put_worse_availability("unavailable")
          |> Map.put(key(attrs, "subscription_capacity_state"), "exhausted")
          |> Map.put(
            key(attrs, "subscription_capacity_resets_at"),
            iso(expires_at)
          )
          |> put_failure("tier_denied", "oauth tier denied")
          |> maybe_cap_expires(expires_at)

        :transport ->
          attrs
          |> put_worse_availability("unavailable")
          |> put_failure("transport_error", "oauth transport failure")
          |> maybe_cap_expires(expires_at)

        :protocol ->
          attrs
          |> put_worse_availability("unavailable")
          |> put_failure("protocol_error", "oauth protocol failure")
          |> maybe_cap_expires(expires_at)

        :outage ->
          attrs
          |> put_worse_availability("unavailable")
          |> put_failure("provider_outage", "provider outage")
          |> maybe_cap_expires(expires_at)

        _ ->
          attrs
      end
    else
      attrs
    end
  end

  defp overlay_route_failure(attrs, _, _), do: attrs

  defp overlay_quota(attrs, nil, _now), do: attrs

  defp overlay_quota(attrs, quota, now) when is_map(quota) do
    available = Map.get(quota, :available)
    available_at = Map.get(quota, :available_at) || Map.get(quota, "available_at")

    available? =
      case available do
        false -> false
        true -> true
        _ -> false
      end

    reset_dt = parse_dt(available_at)

    if not available? and active?(reset_dt, now) do
      attrs
      |> put_worse_availability("unavailable")
      |> Map.put(key(attrs, "quota_state"), "exhausted")
      |> Map.put(key(attrs, "quota_resets_at"), iso(reset_dt))
      |> put_failure("quota_exhausted", "oauth quota exhausted")
      |> maybe_cap_expires(reset_dt)
    else
      attrs
    end
  end

  defp overlay_quota(attrs, _, _), do: attrs

  defp put_worse_availability(attrs, "unavailable") do
    Map.put(attrs, key(attrs, "availability"), "unavailable")
  end

  defp put_worse_auth(attrs, auth_health) do
    current = Map.get(attrs, :auth_health) || Map.get(attrs, "auth_health")

    worse =
      case current do
        "expired" -> "expired"
        "invalid" -> "invalid"
        "unavailable" -> "unavailable"
        _ -> auth_health
      end

    Map.put(attrs, key(attrs, "auth_health"), worse)
  end

  defp put_failure(attrs, code, message) do
    attrs
    |> Map.put(key(attrs, "failure_code"), code)
    |> Map.put(key(attrs, "failure_message"), message)
  end

  defp maybe_cap_expires(attrs, expires_at) do
    case {Map.get(attrs, :expires_at) || Map.get(attrs, "expires_at"), parse_dt(expires_at)} do
      {nil, %DateTime{} = dt} ->
        Map.put(attrs, key(attrs, "expires_at"), DateTime.to_iso8601(dt))

      {existing, %DateTime{} = dt} when is_binary(existing) ->
        case DateTime.from_iso8601(existing) do
          {:ok, current, _} ->
            chosen = if DateTime.compare(dt, current) == :lt, do: dt, else: current
            Map.put(attrs, key(attrs, "expires_at"), DateTime.to_iso8601(chosen))

          _ ->
            Map.put(attrs, key(attrs, "expires_at"), DateTime.to_iso8601(dt))
        end

      _ ->
        attrs
    end
  end

  defp active?(%DateTime{} = expires_at, %DateTime{} = now),
    do: DateTime.compare(expires_at, now) == :gt

  defp active?(expires_at, %DateTime{} = now) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, dt, _} -> DateTime.compare(dt, now) == :gt
      _ -> false
    end
  end

  defp active?(_, _), do: false

  defp parse_dt(%DateTime{} = dt), do: dt

  defp parse_dt(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(iso) when is_binary(iso), do: iso
  defp iso(_), do: nil

  defp key(attrs, string_key) when is_binary(string_key) do
    atom_key =
      case string_key do
        "availability" -> :availability
        "auth_health" -> :auth_health
        "quota_state" -> :quota_state
        "quota_resets_at" -> :quota_resets_at
        "subscription_capacity_state" -> :subscription_capacity_state
        "subscription_capacity_resets_at" -> :subscription_capacity_resets_at
        "failure_code" -> :failure_code
        "failure_message" -> :failure_message
        "expires_at" -> :expires_at
        "concurrency_limit" -> :concurrency_limit
        "concurrency_in_use" -> :concurrency_in_use
        _ -> nil
      end

    cond do
      Map.has_key?(attrs, string_key) -> string_key
      is_atom(atom_key) and Map.has_key?(attrs, atom_key) -> atom_key
      true -> string_key
    end
  end
end
