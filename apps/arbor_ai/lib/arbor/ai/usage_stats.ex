defmodule Arbor.AI.UsageStats do
  @moduledoc """
  Tracks success/failure rates, latency, and cost per backend+model+tier.

  The UsageStats module provides observability for AI routing by tracking:
  - Success/failure counts and rates
  - Latency metrics (average and p95)
  - Token usage and costs
  - Reliability rankings for routing decisions

  ## Features

  - Per-backend+model stats aggregation
  - Configurable rolling window (default: 7 days)
  - Optional file persistence for restart recovery
  - Reliability alerts when success rate drops below threshold

  ## Configuration

      config :arbor_ai,
        enable_stats_tracking: true,
        stats_retention_days: 7,
        stats_persistence: false,
        stats_persistence_path: "~/.arbor/usage-stats.json",
        reliability_alert_threshold: 0.8

  ## Usage

      # Record successful LLM call
      UsageStats.record_success(:anthropic, %{
        model: "claude-opus-4",
        tier: :critical,
        latency_ms: 2340,
        input_tokens: 1000,
        output_tokens: 500,
        cost: 0.045
      })

      # Record failed call
      UsageStats.record_failure(:anthropic, %{
        model: "claude-opus-4",
        tier: :critical,
        latency_ms: 5000,
        error: "timeout"
      })

      # Query stats
      UsageStats.get_stats(:anthropic)
      UsageStats.success_rate(:anthropic, "claude-opus-4")
      UsageStats.reliability_ranking()
  """

  use GenServer
  require Logger

  alias Arbor.Signals

  # ETS table name
  @table __MODULE__

  # Maximum latency samples to keep for percentile calculation
  @max_latency_samples 100

  # Prune interval (daily)
  @prune_interval_ms 24 * 60 * 60 * 1000

  # ============================================================================
  # Types
  # ============================================================================

  @type stat_key :: {backend :: atom(), model :: String.t()}

  @type stats :: %{
          requests: non_neg_integer(),
          successes: non_neg_integer(),
          failures: non_neg_integer(),
          total_input_tokens: non_neg_integer(),
          total_output_tokens: non_neg_integer(),
          total_cost_usd: float(),
          avg_latency_ms: float(),
          p95_latency_ms: float(),
          last_success: DateTime.t() | nil,
          last_failure: DateTime.t() | nil,
          last_error: String.t() | nil
        }

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a successful LLM call.

  ## Parameters

  - `backend` - The backend atom (e.g., :anthropic, :openai)
  - `metadata` - Map with :model, :tier, :latency_ms, :input_tokens, :output_tokens, :cost

  ## Examples

      UsageStats.record_success(:anthropic, %{
        model: "claude-opus-4",
        tier: :critical,
        latency_ms: 2340,
        input_tokens: 1000,
        output_tokens: 500,
        cost: 0.045
      })
  """
  @spec record_success(atom(), map()) :: :ok
  def record_success(backend, metadata) when is_atom(backend) and is_map(metadata) do
    if started?() do
      GenServer.cast(__MODULE__, {:record_success, backend, metadata})
    else
      :ok
    end
  end

  @doc """
  Record a failed LLM call.

  ## Parameters

  - `backend` - The backend atom (e.g., :anthropic, :openai)
  - `metadata` - Map with :model, :tier, :latency_ms, :error

  ## Examples

      UsageStats.record_failure(:anthropic, %{
        model: "claude-opus-4",
        tier: :critical,
        latency_ms: 5000,
        error: "timeout"
      })
  """
  @spec record_failure(atom(), map()) :: :ok
  def record_failure(backend, metadata) when is_atom(backend) and is_map(metadata) do
    if started?() do
      GenServer.cast(__MODULE__, {:record_failure, backend, metadata})
    else
      :ok
    end
  end

  @doc """
  Get stats for a backend (aggregated across all models).
  """
  @spec get_stats(atom()) :: stats()
  def get_stats(backend) when is_atom(backend) do
    if started?() do
      GenServer.call(__MODULE__, {:get_stats, backend})
    else
      empty_stats()
    end
  end

  @doc """
  Get stats for a specific backend and model combination.
  """
  @spec get_stats(atom(), atom() | String.t()) :: stats()
  def get_stats(backend, model) when is_atom(backend) do
    if started?() do
      GenServer.call(__MODULE__, {:get_stats, backend, normalize_model(model)})
    else
      empty_stats()
    end
  end

  @doc """
  Get all stats as a map keyed by {backend, model}.
  """
  @spec all_stats() :: %{stat_key() => stats()}
  def all_stats do
    if started?() do
      GenServer.call(__MODULE__, :all_stats)
    else
      %{}
    end
  end

  @doc """
  Get success rate for a backend (0.0-1.0, aggregated across models).
  """
  @spec success_rate(atom()) :: float()
  def success_rate(backend) when is_atom(backend) do
    stats = get_stats(backend)
    calculate_success_rate(stats)
  end

  @doc """
  Get success rate for a specific backend and model (0.0-1.0).
  """
  @spec success_rate(atom(), atom() | String.t()) :: float()
  def success_rate(backend, model) when is_atom(backend) do
    stats = get_stats(backend, model)
    calculate_success_rate(stats)
  end

  @doc """
  Get all backends sorted by success rate (descending).

  Returns a list of `{backend, success_rate}` tuples.
  """
  @spec reliability_ranking() :: [{atom(), float()}]
  def reliability_ranking do
    if started?() do
      GenServer.call(__MODULE__, :reliability_ranking)
    else
      []
    end
  end

  @doc """
  Reset all stats.
  """
  @spec reset() :: :ok
  def reset do
    if started?() do
      GenServer.cast(__MODULE__, :reset)
    else
      :ok
    end
  end

  @doc """
  Reset stats for a specific backend.
  """
  @spec reset(atom()) :: :ok
  def reset(backend) when is_atom(backend) do
    if started?() do
      GenServer.cast(__MODULE__, {:reset, backend})
    else
      :ok
    end
  end

  @doc """
  Check if the UsageStats GenServer is running.
  """
  @spec started?() :: boolean()
  def started? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create ETS table for fast lookups
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    # Schedule daily pruning
    schedule_prune()

    # Load persisted state if enabled
    maybe_load_persistence()

    Logger.info("UsageStats started",
      retention_days: retention_days(),
      persistence: persistence_enabled?()
    )

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record_success, backend, metadata}, state) do
    model = normalize_model(Map.get(metadata, :model, "unknown"))
    tier = Map.get(metadata, :tier, :unknown)
    latency_ms = Map.get(metadata, :latency_ms, 0)
    input_tokens = Map.get(metadata, :input_tokens, 0)
    output_tokens = Map.get(metadata, :output_tokens, 0)
    cost = Map.get(metadata, :cost, 0.0)
    now = DateTime.utc_now()

    key = {backend, model}
    stats = get_or_create_stats(key)

    # Update stats
    updated_stats = %{
      stats
      | requests: stats.requests + 1,
        successes: stats.successes + 1,
        total_input_tokens: stats.total_input_tokens + input_tokens,
        total_output_tokens: stats.total_output_tokens + output_tokens,
        total_cost_usd: stats.total_cost_usd + cost,
        last_success: now
    }

    # Update latency metrics
    updated_stats = update_latency(updated_stats, latency_ms)

    # Store updated stats
    :ets.insert(@table, {key, updated_stats})

    # Maybe persist
    maybe_save_persistence()

    Logger.debug("Recorded success",
      backend: backend,
      model: model,
      tier: tier,
      latency_ms: latency_ms
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_failure, backend, metadata}, state) do
    model = normalize_model(Map.get(metadata, :model, "unknown"))
    tier = Map.get(metadata, :tier, :unknown)
    latency_ms = Map.get(metadata, :latency_ms, 0)
    error = Map.get(metadata, :error, "unknown")
    now = DateTime.utc_now()

    key = {backend, model}
    stats = get_or_create_stats(key)

    # Update stats
    updated_stats = %{
      stats
      | requests: stats.requests + 1,
        failures: stats.failures + 1,
        last_failure: now,
        last_error: to_string(error)
    }

    # Update latency metrics
    updated_stats = update_latency(updated_stats, latency_ms)

    # Store updated stats
    :ets.insert(@table, {key, updated_stats})

    # Check reliability threshold and emit alert if needed
    check_reliability_alert(backend, model, updated_stats)

    # Maybe persist
    maybe_save_persistence()

    Logger.debug("Recorded failure",
      backend: backend,
      model: model,
      tier: tier,
      error: error
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast(:reset, state) do
    :ets.delete_all_objects(@table)
    maybe_save_persistence()
    Logger.info("UsageStats reset")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:reset, backend}, state) do
    # Delete all entries for this backend
    :ets.select_delete(@table, [
      {{{backend, :_}, :_}, [], [true]}
    ])

    maybe_save_persistence()
    Logger.info("UsageStats reset for backend", backend: backend)
    {:noreply, state}
  end

  @impl true
  def handle_call({:get_stats, backend}, _from, state) do
    # Aggregate stats across all models for this backend
    stats =
      :ets.select(@table, [
        {{{backend, :_}, :"$1"}, [], [:"$1"]}
      ])
      |> aggregate_stats()

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:get_stats, backend, model}, _from, state) do
    key = {backend, model}

    stats =
      case :ets.lookup(@table, key) do
        [{^key, s}] -> export_stats(s)
        [] -> empty_stats()
      end

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:all_stats, _from, state) do
    stats =
      :ets.tab2list(@table)
      |> Enum.into(%{}, fn {key, s} -> {key, export_stats(s)} end)

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:reliability_ranking, _from, state) do
    # Get all backends with their aggregated success rates
    backends =
      :ets.tab2list(@table)
      |> Enum.group_by(fn {{backend, _model}, _stats} -> backend end)
      |> Enum.map(fn {backend, entries} ->
        stats = entries |> Enum.map(fn {_key, s} -> s end) |> aggregate_stats_internal()
        rate = calculate_success_rate(stats)
        {backend, rate}
      end)
      |> Enum.sort_by(fn {_backend, rate} -> rate end, :desc)

    {:reply, backends, state}
  end

  @impl true
  def handle_info(:prune, state) do
    prune_old_entries()
    schedule_prune()
    {:noreply, state}
  end

  @impl true
  def handle_info(:emit_daily_summary, state) do
    emit_daily_summary()
    schedule_daily_summary()
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_or_create_stats(key) do
    case :ets.lookup(@table, key) do
      [{^key, stats}] -> stats
      [] -> new_stats()
    end
  end

  defp new_stats do
    %{
      requests: 0,
      successes: 0,
      failures: 0,
      total_input_tokens: 0,
      total_output_tokens: 0,
      total_cost_usd: 0.0,
      latency_samples: [],
      last_success: nil,
      last_failure: nil,
      last_error: nil,
      first_recorded: DateTime.utc_now()
    }
  end

  defp empty_stats do
    %{
      requests: 0,
      successes: 0,
      failures: 0,
      total_input_tokens: 0,
      total_output_tokens: 0,
      total_cost_usd: 0.0,
      avg_latency_ms: 0.0,
      p95_latency_ms: 0.0,
      last_success: nil,
      last_failure: nil,
      last_error: nil
    }
  end

  defp export_stats(stats) do
    %{
      requests: stats.requests,
      successes: stats.successes,
      failures: stats.failures,
      total_input_tokens: stats.total_input_tokens,
      total_output_tokens: stats.total_output_tokens,
      total_cost_usd: Float.round(stats.total_cost_usd, 4),
      avg_latency_ms: calculate_avg_latency(stats.latency_samples),
      p95_latency_ms: calculate_p95_latency(stats.latency_samples),
      last_success: stats.last_success,
      last_failure: stats.last_failure,
      last_error: stats.last_error
    }
  end

  defp update_latency(stats, latency_ms) when latency_ms > 0 do
    samples = [latency_ms | stats.latency_samples]
    # Keep only the most recent samples for percentile calculation
    trimmed = Enum.take(samples, @max_latency_samples)
    %{stats | latency_samples: trimmed}
  end

  defp update_latency(stats, _latency_ms), do: stats

  defp calculate_avg_latency([]), do: 0.0

  defp calculate_avg_latency(samples) do
    # Enum.sum returns integer if all samples are integers, so convert to float first
    sum = Enum.sum(samples)
    Float.round(sum / length(samples), 2)
  end

  defp calculate_p95_latency([]), do: 0.0

  defp calculate_p95_latency(samples) do
    sorted = Enum.sort(samples, :desc)
    index = max(0, round(length(sorted) * 0.05) - 1)
    value = Enum.at(sorted, index, 0)
    # Value might be integer, convert to float before rounding
    value * 1.0
  end

  defp calculate_success_rate(%{requests: 0}), do: 1.0
  defp calculate_success_rate(%{requests: r, successes: s}), do: Float.round(s / r, 4)

  defp aggregate_stats([]), do: empty_stats()

  defp aggregate_stats(stats_list) do
    aggregated = aggregate_stats_internal(stats_list)
    export_stats(aggregated)
  end

  defp aggregate_stats_internal([]), do: new_stats()

  defp aggregate_stats_internal(stats_list) do
    Enum.reduce(stats_list, new_stats(), fn s, acc ->
      %{
        acc
        | requests: acc.requests + s.requests,
          successes: acc.successes + s.successes,
          failures: acc.failures + s.failures,
          total_input_tokens: acc.total_input_tokens + s.total_input_tokens,
          total_output_tokens: acc.total_output_tokens + s.total_output_tokens,
          total_cost_usd: acc.total_cost_usd + s.total_cost_usd,
          latency_samples:
            (acc.latency_samples ++ s.latency_samples) |> Enum.take(@max_latency_samples),
          last_success: latest_datetime(acc.last_success, s.last_success),
          last_failure: latest_datetime(acc.last_failure, s.last_failure),
          last_error: s.last_error || acc.last_error
      }
    end)
  end

  defp latest_datetime(nil, dt), do: dt
  defp latest_datetime(dt, nil), do: dt

  defp latest_datetime(dt1, dt2) do
    if DateTime.compare(dt1, dt2) == :gt, do: dt1, else: dt2
  end

  defp normalize_model(model) when is_atom(model), do: Atom.to_string(model)
  defp normalize_model(model) when is_binary(model), do: model
  defp normalize_model(_), do: "unknown"

  defp check_reliability_alert(backend, model, stats) do
    threshold = reliability_alert_threshold()
    rate = calculate_success_rate(stats)

    # Only alert if we have enough data and rate dropped below threshold
    if stats.requests >= 5 and rate < threshold do
      emit_reliability_alert(backend, model, rate, stats.failures, threshold)
    end
  end

  defp emit_reliability_alert(backend, model, rate, failures, threshold) do
    verbosity = signal_verbosity()

    if verbosity != :quiet do
      Signals.emit(:ai, :reliability_alert, %{
        backend: backend,
        model: model,
        success_rate: rate,
        threshold: threshold,
        recent_failures: failures
      })
    end
  end

  defp emit_daily_summary do
    verbosity = signal_verbosity()

    if verbosity != :quiet do
      all = all_stats()

      total_requests = all |> Map.values() |> Enum.map(& &1.requests) |> Enum.sum()
      total_cost = all |> Map.values() |> Enum.map(& &1.total_cost_usd) |> Enum.sum()

      ranking = reliability_ranking()
      top_backend = List.first(ranking)
      least_reliable = List.last(ranking)

      Signals.emit(:ai, :usage_summary, %{
        period: :daily,
        total_requests: total_requests,
        total_cost_usd: Float.round(total_cost, 4),
        top_backend: top_backend,
        least_reliable: least_reliable,
        backends_count: length(ranking)
      })
    end
  end

  defp prune_old_entries do
    retention = retention_days()
    cutoff = DateTime.add(DateTime.utc_now(), -retention * 24 * 60 * 60, :second)

    # ETS select_delete cannot pattern-match into map values, so iterate and filter
    pruned =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_key, stats} ->
        case stats[:first_recorded] do
          %DateTime{} = ts -> DateTime.compare(ts, cutoff) == :lt
          _ -> false
        end
      end)
      |> Enum.each(fn {key, _stats} -> :ets.delete(@table, key) end)

    Logger.debug("Pruned old usage stats", retention_days: retention, pruned: pruned)
  end

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval_ms)
  end

  defp schedule_daily_summary do
    # Schedule for next midnight UTC
    now = DateTime.utc_now()
    tomorrow = Date.add(Date.utc_today(), 1)

    midnight =
      DateTime.new!(tomorrow, ~T[00:00:00], "Etc/UTC")
      |> DateTime.to_unix(:millisecond)

    now_ms = DateTime.to_unix(now, :millisecond)
    delay = midnight - now_ms

    Process.send_after(self(), :emit_daily_summary, delay)
  end

  # Persistence helpers

  defp maybe_load_persistence do
    if persistence_enabled?() do
      path = persistence_path()

      if File.exists?(path) do
        case File.read(path) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, data} ->
                load_persisted_data(data)
                Logger.info("Loaded usage stats from persistence")

              {:error, _} ->
                Logger.warning("Failed to parse usage stats persistence file")
            end

          {:error, reason} ->
            Logger.warning("Failed to read usage stats persistence file", reason: reason)
        end
      end
    end

    # Schedule daily summary after loading
    schedule_daily_summary()
  end

  defp load_persisted_data(data) when is_map(data) do
    Enum.each(data, fn {key_str, stats_map} ->
      case parse_key(key_str) do
        {:ok, key} ->
          stats = %{
            requests: Map.get(stats_map, "requests", 0),
            successes: Map.get(stats_map, "successes", 0),
            failures: Map.get(stats_map, "failures", 0),
            total_input_tokens: Map.get(stats_map, "total_input_tokens", 0),
            total_output_tokens: Map.get(stats_map, "total_output_tokens", 0),
            total_cost_usd: Map.get(stats_map, "total_cost_usd", 0.0),
            latency_samples: Map.get(stats_map, "latency_samples", []),
            last_success: parse_datetime(Map.get(stats_map, "last_success")),
            last_failure: parse_datetime(Map.get(stats_map, "last_failure")),
            last_error: Map.get(stats_map, "last_error"),
            first_recorded:
              parse_datetime(Map.get(stats_map, "first_recorded")) || DateTime.utc_now()
          }

          :ets.insert(@table, {key, stats})

        :error ->
          :ok
      end
    end)
  end

  defp load_persisted_data(_), do: :ok

  defp parse_key(key_str) when is_binary(key_str) do
    case String.split(key_str, ":") do
      [backend_str, model] ->
        backend = String.to_existing_atom(backend_str)
        {:ok, {backend, model}}

      _ ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp parse_key(_), do: :error

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp maybe_save_persistence do
    if persistence_enabled?() do
      data =
        :ets.tab2list(@table)
        |> Enum.into(%{}, fn {{backend, model}, stats} ->
          key = "#{backend}:#{model}"

          value = %{
            requests: stats.requests,
            successes: stats.successes,
            failures: stats.failures,
            total_input_tokens: stats.total_input_tokens,
            total_output_tokens: stats.total_output_tokens,
            total_cost_usd: stats.total_cost_usd,
            latency_samples: stats.latency_samples,
            last_success: format_datetime(stats.last_success),
            last_failure: format_datetime(stats.last_failure),
            last_error: stats.last_error,
            first_recorded: format_datetime(stats.first_recorded)
          }

          {key, value}
        end)

      path = persistence_path()
      dir = Path.dirname(path)

      unless File.exists?(dir) do
        File.mkdir_p!(dir)
      end

      case Jason.encode(data) do
        {:ok, json} ->
          File.write(path, json)

        {:error, reason} ->
          Logger.warning("Failed to encode usage stats", reason: reason)
      end
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(dt), do: DateTime.to_iso8601(dt)

  # Configuration helpers

  defp retention_days do
    Application.get_env(:arbor_ai, :stats_retention_days, 7)
  end

  defp persistence_enabled? do
    Application.get_env(:arbor_ai, :stats_persistence, false)
  end

  defp persistence_path do
    Application.get_env(:arbor_ai, :stats_persistence_path, "~/.arbor/usage-stats.json")
    |> Path.expand()
  end

  defp reliability_alert_threshold do
    Application.get_env(:arbor_ai, :reliability_alert_threshold, 0.8)
  end

  defp signal_verbosity do
    Application.get_env(:arbor_ai, :signal_verbosity, :normal)
  end
end
