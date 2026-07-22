defmodule Arbor.AI.ProviderControlPlane.BudgetProjection do
  @moduledoc """
  Pure projection of bounded tracker reads into budget evidence.

  This module does not read application configuration, call a tracker, or use
  the clock. The shell supplies those inputs so normalization and digest
  behavior stay deterministic.
  """

  alias Arbor.Contracts.LLM.BudgetSnapshot

  @max_entries 128
  @max_provider_bytes 512
  @max_ttl_seconds 300
  @default_ttl_seconds 60
  @source "arbor_ai_trackers"

  @type result :: {:ok, %{snapshot: map(), digest: String.t()}} | {:error, :malformed}

  @spec project(term(), term(), term(), keyword()) :: result()
  def project(provider, budget_status, quota_status, opts \\ []) do
    with {:ok, provider} <- normalize_provider(provider),
         {:ok, budget} <- normalize_budget_status(budget_status),
         {:ok, quota} <- normalize_quota_status(quota_status),
         {:ok, observed_at, observed_datetime} <- observation_time(opts),
         {:ok, expires_at} <- expiry(observed_datetime, opts),
         {:ok, ceiling} <- provider_ceiling(provider, opts),
         {:ok, subscription_state} <- subscription_state(provider, opts),
         {:ok, quota_state, quota_reset} <- quota_projection(provider, quota, observed_datetime),
         attrs <-
           snapshot_attrs(
             provider,
             budget,
             ceiling,
             subscription_state,
             quota_state,
             quota_reset,
             observed_at,
             expires_at
           ),
         {:ok, snapshot} <- BudgetSnapshot.normalize(attrs),
         {:ok, digest} <- BudgetSnapshot.digest(snapshot) do
      {:ok, %{snapshot: snapshot, digest: digest}}
    else
      _ -> {:error, :malformed}
    end
  end

  @spec providers(term(), term(), keyword()) :: {:ok, [String.t()]} | {:error, :malformed}
  def providers(budget_status, quota_status, opts \\ []) do
    with {:ok, budget} <- normalize_budget_status(budget_status),
         {:ok, quota} <- normalize_quota_status(quota_status),
         {:ok, configured} <- configured_provider_names(opts) do
      names =
        (Map.keys(budget.backends) ++ Map.keys(quota) ++ configured)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, names}
    else
      _ -> {:error, :malformed}
    end
  end

  defp snapshot_attrs(
         provider,
         budget,
         ceiling,
         subscription_state,
         quota_state,
         quota_reset,
         observed_at,
         expires_at
       ) do
    stats = Map.get(budget.backends, provider, %{requests: 0, cost: 0.0})
    current_spend = stats.cost

    %{
      provider: provider,
      source: @source,
      observed_at: observed_at,
      expires_at: expires_at,
      current_spend: current_spend,
      request_count: stats.requests,
      quota_state: quota_state,
      subscription_capacity_state: subscription_state
    }
    |> maybe_put_ceiling(ceiling, current_spend)
    |> maybe_put(:quota_resets_at, quota_reset)
  end

  defp maybe_put_ceiling(attrs, nil, _current_spend), do: attrs

  defp maybe_put_ceiling(attrs, ceiling, current_spend) do
    attrs
    |> Map.put(:configured_spend_ceiling, ceiling)
    |> Map.put(:remaining_spend, max(0.0, ceiling - current_spend))
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp normalize_budget_status(status) when is_map(status) do
    with {:ok, backends} <- fetch(status, :backends),
         true <- is_map(backends),
         true <- map_size(backends) <= @max_entries,
         {:ok, normalized} <- normalize_backend_entries(backends) do
      {:ok, %{backends: normalized}}
    else
      _ -> {:error, :malformed}
    end
  end

  defp normalize_budget_status(_status), do: {:error, :malformed}

  defp normalize_backend_entries(backends) do
    Enum.reduce_while(backends, {:ok, %{}}, fn {provider, stats}, {:ok, acc} ->
      with {:ok, provider} <- normalize_provider(provider),
           true <- is_map(stats),
           {:ok, requests} <- required_nonnegative_integer(stats, :requests),
           {:ok, cost} <- required_nonnegative_number(stats, :cost) do
        if Map.has_key?(acc, provider) do
          {:halt, {:error, :malformed}}
        else
          {:cont, {:ok, Map.put(acc, provider, %{requests: requests, cost: cost})}}
        end
      else
        _ -> {:halt, {:error, :malformed}}
      end
    end)
  end

  defp normalize_quota_status(status) when is_map(status) do
    if map_size(status) <= @max_entries do
      Enum.reduce_while(status, {:ok, %{}}, fn {provider, info}, {:ok, acc} ->
        with {:ok, provider} <- normalize_provider(provider),
             true <- is_map(info),
             available when is_boolean(available) <- fetch_or_nil(info, :available),
             {:ok, available_at} <- normalize_datetime(fetch_or_nil(info, :available_at)) do
          if Map.has_key?(acc, provider) do
            {:halt, {:error, :malformed}}
          else
            {:cont,
             {:ok, Map.put(acc, provider, %{available: available, available_at: available_at})}}
          end
        else
          _ -> {:halt, {:error, :malformed}}
        end
      end)
    else
      {:error, :malformed}
    end
  end

  defp normalize_quota_status(_status), do: {:error, :malformed}

  defp quota_projection(provider, quota, observed_datetime) do
    case Map.get(quota, provider) do
      nil ->
        {:ok, "available", nil}

      %{available: available, available_at: reset_at} ->
        active = DateTime.compare(reset_at, observed_datetime) == :gt

        if not available and active do
          {:ok, "exhausted", DateTime.to_iso8601(reset_at)}
        else
          {:ok, "available", nil}
        end
    end
  end

  defp provider_ceiling(provider, opts) do
    ceilings = Keyword.get(opts, :provider_ceilings, %{})

    with true <- is_map(ceilings),
         true <- map_size(ceilings) <= @max_entries do
      Enum.reduce_while(ceilings, {:ok, nil}, fn {key, value}, {:ok, found} ->
        with {:ok, key} <- normalize_provider(key),
             {:ok, value} <- optional_nonnegative_number(value) do
          cond do
            found != nil and key == provider -> {:halt, {:error, :malformed}}
            key == provider -> {:cont, {:ok, value}}
            true -> {:cont, {:ok, found}}
          end
        else
          _ -> {:halt, {:error, :malformed}}
        end
      end)
    else
      _ -> {:error, :malformed}
    end
  end

  defp subscription_state(provider, opts) do
    explicit = Keyword.get(opts, :subscription_capacity_state)
    states = Keyword.get(opts, :subscription_capacity_states, %{})

    value =
      cond do
        not is_nil(explicit) -> explicit
        is_map(states) -> lookup_named(states, provider, "unknown")
        true -> :malformed
      end

    case normalize_enum(value, ["available", "limited", "exhausted", "unknown", "not_applicable"]) do
      {:ok, state} -> {:ok, state}
      _ -> {:error, :malformed}
    end
  end

  defp configured_provider_names(opts) do
    names =
      Keyword.get(opts, :providers, []) ++
        map_keys(Keyword.get(opts, :provider_ceilings, %{})) ++
        map_keys(Keyword.get(opts, :subscription_capacity_states, %{}))

    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case normalize_provider(name) do
        {:ok, name} -> {:cont, {:ok, [name | acc]}}
        _ -> {:halt, {:error, :malformed}}
      end
    end)
  end

  defp map_keys(map) when is_map(map), do: Map.keys(map)
  defp map_keys(_map), do: []

  defp lookup_named(map, provider, default) do
    Enum.find_value(map, default, fn {key, value} ->
      case normalize_provider(key) do
        {:ok, ^provider} -> value
        _ -> nil
      end
    end)
  end

  defp observation_time(opts) do
    value = Keyword.get(opts, :observed_at, Keyword.get(opts, :now))

    with {:ok, datetime} <- normalize_datetime(value) do
      {:ok, DateTime.to_iso8601(datetime), datetime}
    end
  end

  defp expiry(observed_datetime, opts) do
    ttl = Keyword.get(opts, :expiry_seconds, @default_ttl_seconds)

    if is_integer(ttl) and ttl > 0 and ttl <= @max_ttl_seconds,
      do: {:ok, DateTime.add(observed_datetime, ttl, :second) |> DateTime.to_iso8601()},
      else: {:error, :malformed}
  end

  defp normalize_provider(provider) when is_atom(provider),
    do: normalize_provider(Atom.to_string(provider))

  defp normalize_provider(provider)
       when is_binary(provider) and byte_size(provider) > 0 and
              byte_size(provider) <= @max_provider_bytes do
    if String.valid?(provider) and String.trim(provider) != "" and
         not String.match?(provider, ~r/[\x00-\x1F\x7F]/),
       do: {:ok, provider},
       else: {:error, :malformed}
  end

  defp normalize_provider(_provider), do: {:error, :malformed}

  defp normalize_datetime(%DateTime{} = datetime), do: {:ok, datetime}

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :malformed}
    end
  end

  defp normalize_datetime(_value), do: {:error, :malformed}

  defp normalize_enum(value, allowed) when is_atom(value),
    do: normalize_enum(Atom.to_string(value), allowed)

  defp normalize_enum(value, allowed) when is_binary(value) do
    if value in allowed, do: {:ok, value}, else: {:error, :malformed}
  end

  defp normalize_enum(_value, _allowed), do: {:error, :malformed}

  defp optional_nonnegative_number(nil), do: {:ok, nil}
  defp optional_nonnegative_number(value), do: nonnegative_number(value)

  defp nonnegative_number(value) when is_integer(value) and value >= 0 and value <= 1.0e18,
    do: {:ok, value}

  defp nonnegative_number(value) when is_float(value) and value >= 0.0 and value <= 1.0e18,
    do: {:ok, value}

  defp nonnegative_number(_value), do: {:error, :malformed}

  defp nonnegative_integer(nil), do: {:ok, 0}

  defp nonnegative_integer(value)
       when is_integer(value) and value >= 0 and value <= 1_000_000_000_000,
       do: {:ok, value}

  defp nonnegative_integer(_value), do: {:error, :malformed}

  defp required_nonnegative_integer(map, key) do
    case fetch(map, key) do
      {:ok, value} -> nonnegative_integer(value)
      :error -> {:error, :malformed}
    end
  end

  defp required_nonnegative_number(map, key) do
    case fetch(map, key) do
      {:ok, value} -> nonnegative_number(value)
      :error -> {:error, :malformed}
    end
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp fetch_or_nil(map, key) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end
end
