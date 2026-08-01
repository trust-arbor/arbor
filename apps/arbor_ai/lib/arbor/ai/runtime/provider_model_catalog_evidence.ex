defmodule Arbor.AI.Runtime.ProviderModelCatalogEvidence do
  @moduledoc """
  Pure usability assessment for one provider-reported model catalog.

  Readiness and observation composition must apply the same identity, credential
  generation, expiry, and bounded clock-skew rules. This module owns those rules
  and performs no process, configuration, network, or credential IO.
  """

  alias Arbor.Contracts.LLM.ProviderModelCatalog

  @max_future_skew_ms 60_000
  @runtimes ["arbor"]

  @type reason ::
          :malformed
          | :route_mismatch
          | :backend_mismatch
          | :runtime_mismatch
          | :generation_mismatch
          | :observed_in_future
          | :stale

  @spec assess(term(), String.t(), String.t(), String.t(), term(), DateTime.t()) ::
          {:ok, ProviderModelCatalog.t()} | {:error, reason()}
  def assess(catalog, expected_route, expected_backend, expected_runtime, generation, now) do
    with {:ok, valid} <- admit(catalog),
         :ok <- exact_identity(valid, expected_route, expected_backend, expected_runtime),
         :ok <- valid_generation(valid, generation),
         {:ok, observed_at} <- parse_datetime(valid.observed_at),
         {:ok, expires_at} <- parse_datetime(valid.expires_at),
         :ok <- valid_observed_at(observed_at, now),
         :ok <- valid_expiry(expires_at, now) do
      {:ok, valid}
    else
      {:error, reason} when reason in [:route_mismatch, :backend_mismatch, :runtime_mismatch] ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  @spec usable?(term(), String.t(), String.t(), String.t(), term(), DateTime.t()) :: boolean()
  def usable?(catalog, expected_route, expected_backend, expected_runtime, generation, now) do
    match?(
      {:ok, _},
      assess(catalog, expected_route, expected_backend, expected_runtime, generation, now)
    )
  end

  @spec max_future_skew_ms() :: pos_integer()
  def max_future_skew_ms, do: @max_future_skew_ms

  defp admit(%ProviderModelCatalog{} = catalog) do
    case ProviderModelCatalog.new(ProviderModelCatalog.to_map(catalog)) do
      {:ok, valid} -> {:ok, valid}
      {:error, _} -> {:error, :malformed}
    end
  end

  defp admit(attrs) when is_map(attrs) or is_list(attrs) do
    case ProviderModelCatalog.new(attrs) do
      {:ok, valid} -> {:ok, valid}
      {:error, _} -> {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  defp admit(_), do: {:error, :malformed}

  defp exact_identity(catalog, expected_route, expected_backend, expected_runtime) do
    cond do
      catalog.route != expected_route -> {:error, :route_mismatch}
      catalog.backend != expected_backend -> {:error, :backend_mismatch}
      catalog.runtime != expected_runtime -> {:error, :runtime_mismatch}
      expected_runtime not in @runtimes -> {:error, :runtime_mismatch}
      true -> :ok
    end
  end

  defp valid_generation(%ProviderModelCatalog{credential_generation: actual}, expected)
       when is_integer(expected) and expected >= 0,
       do: if(actual == expected, do: :ok, else: {:error, :generation_mismatch})

  defp valid_generation(_catalog, _expected), do: {:error, :generation_mismatch}

  defp valid_observed_at(observed_at, %DateTime{} = now) do
    if DateTime.diff(observed_at, now, :millisecond) <= @max_future_skew_ms,
      do: :ok,
      else: {:error, :observed_in_future}
  end

  defp valid_observed_at(_observed_at, _now), do: {:error, :malformed}

  defp valid_expiry(expires_at, %DateTime{} = now) do
    if DateTime.compare(expires_at, now) == :gt, do: :ok, else: {:error, :stale}
  end

  defp valid_expiry(_expires_at, _now), do: {:error, :malformed}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{} = datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :malformed}
    end
  end

  defp parse_datetime(_), do: {:error, :malformed}
end
