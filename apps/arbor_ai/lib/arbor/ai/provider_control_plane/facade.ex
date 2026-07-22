defmodule Arbor.AI.ProviderControlPlane do
  @moduledoc """
  Bounded provider budget and capacity evidence.

  The control plane reads only the existing `BudgetTracker` and
  `QuotaTracker`; it does not own a ledger. API spend is marginal USD spend
  recorded by `BudgetTracker`. Subscription and local capacity is independent
  evidence and defaults to `unknown`, never to an economically-free state.
  """

  alias Arbor.AI.{BudgetTracker, QuotaTracker}
  alias Arbor.AI.ProviderControlPlane.BudgetProjection

  @max_entries 128
  @read_timeout_ms 500

  @spec snapshot(atom() | String.t(), keyword()) ::
          {:ok, %{snapshot: map(), digest: String.t()}} | {:error, :unavailable | :malformed}
  def snapshot(provider, opts \\ [])

  def snapshot(provider, opts) when is_list(opts) do
    with {:ok, budget_status} <- read_status(:budget, opts),
         {:ok, quota_status} <- read_status(:quota, opts) do
      BudgetProjection.project(provider, budget_status, quota_status, projection_opts(opts))
    else
      {:error, :unavailable} -> {:error, :unavailable}
      _ -> {:error, :malformed}
    end
  end

  def snapshot(_provider, _opts), do: {:error, :malformed}

  @spec snapshots(keyword()) ::
          {:ok, [%{snapshot: map(), digest: String.t()}]} | {:error, :unavailable | :malformed}
  def snapshots(opts \\ [])

  def snapshots(opts) when is_list(opts) do
    with {:ok, budget_status} <- read_status(:budget, opts),
         {:ok, quota_status} <- read_status(:quota, opts),
         {:ok, providers} <-
           BudgetProjection.providers(budget_status, quota_status, projection_opts(opts)),
         {:ok, snapshots} <-
           project_all(providers, budget_status, quota_status, projection_opts(opts)) do
      {:ok, snapshots}
    else
      {:error, :unavailable} -> {:error, :unavailable}
      _ -> {:error, :malformed}
    end
  end

  def snapshots(_opts), do: {:error, :malformed}

  defp project_all(providers, budget_status, quota_status, opts) do
    Enum.reduce_while(providers, {:ok, []}, fn provider, {:ok, acc} ->
      case BudgetProjection.project(provider, budget_status, quota_status, opts) do
        {:ok, snapshot} -> {:cont, {:ok, [snapshot | acc]}}
        {:error, :malformed} -> {:halt, {:error, :malformed}}
      end
    end)
    |> case do
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      error -> error
    end
  end

  defp read_status(kind, opts) do
    case Keyword.get(opts, status_key(kind)) do
      nil ->
        case Keyword.get(opts, reader_key(kind)) do
          nil -> tracker_read(kind)
          reader -> safe_read(reader)
        end

      status ->
        {:ok, status}
    end
  end

  defp tracker_read(:budget) do
    safe_read(fn -> BudgetTracker.snapshot_status(limit: @max_entries) end)
  end

  defp tracker_read(:quota) do
    safe_read(fn -> QuotaTracker.snapshot_status(limit: @max_entries) end)
  end

  defp safe_read(reader) do
    case Task.async(fn -> invoke_reader(reader) end) |> Task.await(@read_timeout_ms) do
      {:ok, status} -> {:ok, status}
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, _} -> {:error, :malformed}
      _ -> {:error, :malformed}
    end
  catch
    :exit, _ -> {:error, :unavailable}
    _, _ -> {:error, :malformed}
  end

  defp status_key(:budget), do: :budget_status
  defp status_key(:quota), do: :quota_status

  defp reader_key(:budget), do: :budget_reader
  defp reader_key(:quota), do: :quota_reader

  defp invoke_reader(reader) when is_function(reader, 0), do: reader.()
  defp invoke_reader(reader) when is_function(reader, 1), do: reader.(limit: @max_entries)
  defp invoke_reader(_reader), do: {:error, :malformed}

  defp projection_opts(opts) do
    now = Keyword.get(opts, :observed_at, Keyword.get(opts, :now, DateTime.utc_now()))

    opts
    |> Keyword.put(:observed_at, now)
    |> Keyword.put_new(:provider_ceilings, configured_ceilings())
    |> Keyword.put_new(:subscription_capacity_states, configured_capacity_states())
  end

  defp configured_ceilings do
    Application.get_env(
      :arbor_ai,
      :provider_spend_ceilings_usd,
      Application.get_env(:arbor_ai, :provider_budget_ceilings_usd, %{})
    )
  end

  defp configured_capacity_states do
    Application.get_env(:arbor_ai, :subscription_capacity_states, %{})
  end
end
