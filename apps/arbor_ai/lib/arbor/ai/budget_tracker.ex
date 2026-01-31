defmodule Arbor.AI.BudgetTracker do
  @moduledoc """
  Tracks API usage and cost across LLM backends.

  The BudgetTracker provides budget-aware routing by tracking spend per-backend
  and per-day. It enables the router to prefer free backends when budget is low
  and block paid backends when over budget.

  ## Features

  - Per-backend usage tracking (tokens, costs)
  - Daily budget enforcement with automatic reset at midnight
  - Configurable cost models for different providers and models
  - Optional file persistence for restart recovery

  ## Cost Model

  Backends are classified into three cost tiers:
  - **Free**: Local/self-hosted backends (ollama, lmstudio) and subscription CLI tools
  - **Subscription**: CLI tools paid via subscription (treated as $0/token)
  - **API**: Direct API access with per-token pricing

  ## Configuration

      config :arbor_ai,
        enable_budget_tracking: true,
        daily_api_budget_usd: 10.00,
        budget_prefer_free_threshold: 0.5,  # prefer free when < 50% remaining
        budget_persistence: false,
        budget_persistence_path: "~/.arbor/budget-tracker.json",
        cost_overrides: %{}

  ## Usage

      # Record usage after LLM call
      BudgetTracker.record_usage(:anthropic, %{
        model: "claude-opus-4",
        input_tokens: 1000,
        output_tokens: 500
      })

      # Check budget status
      BudgetTracker.budget_remaining()  # => 7.50
      BudgetTracker.should_prefer_free?()  # => false
      BudgetTracker.over_budget?()  # => false

      # Get detailed stats
      BudgetTracker.get_status()
      BudgetTracker.today_stats()
      BudgetTracker.backend_spend(:anthropic)
  """

  use GenServer
  require Logger

  alias Arbor.Signals

  # ETS table name
  @table __MODULE__

  # Default cost per million tokens (can be overridden via config)
  @default_costs %{
    # Free backends (local/subscription)
    {:ollama, :any} => %{input: 0.0, output: 0.0},
    {:lmstudio, :any} => %{input: 0.0, output: 0.0},
    {:opencode, :any} => %{input: 0.0, output: 0.0},

    # Subscription CLI (treated as free since paid monthly)
    {:anthropic, :cli} => %{input: 0.0, output: 0.0},
    {:openai, :cli} => %{input: 0.0, output: 0.0},
    {:gemini, :cli} => %{input: 0.0, output: 0.0},

    # API pricing (per million tokens, USD)
    {:anthropic, :opus} => %{input: 15.0, output: 75.0},
    {:anthropic, :sonnet} => %{input: 3.0, output: 15.0},
    {:anthropic, :haiku} => %{input: 0.25, output: 1.25},
    {:openai, :gpt5} => %{input: 5.0, output: 15.0},
    {:openai, :gpt4} => %{input: 10.0, output: 30.0},
    {:gemini, :pro} => %{input: 1.25, output: 5.0},
    {:gemini, :flash} => %{input: 0.075, output: 0.30}
  }

  # Free backends (no API cost)
  @free_backends [:ollama, :lmstudio, :opencode, :qwen, :grok]

  # Budget threshold levels for warnings
  @threshold_low 0.5
  @threshold_critical 0.2
  @threshold_exhausted 0.0

  # ============================================================================
  # Types
  # ============================================================================

  @type usage :: %{
          backend: atom(),
          model: String.t(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cost_usd: float(),
          timestamp: DateTime.t()
        }

  @type status :: %{
          daily_budget: float(),
          spent_today: float(),
          remaining: float(),
          percent_remaining: float(),
          backends: %{atom() => %{requests: integer(), tokens: integer(), cost: float()}}
        }

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record usage from an LLM call.

  ## Parameters

  - `backend` - The backend atom (e.g., :anthropic, :openai)
  - `metadata` - Map with :model, :input_tokens, :output_tokens

  ## Examples

      BudgetTracker.record_usage(:anthropic, %{
        model: "claude-opus-4",
        input_tokens: 1000,
        output_tokens: 500
      })
  """
  @spec record_usage(atom(), map()) :: :ok
  def record_usage(backend, metadata) when is_atom(backend) and is_map(metadata) do
    if started?() do
      GenServer.cast(__MODULE__, {:record_usage, backend, metadata})
    else
      :ok
    end
  end

  @doc """
  Get comprehensive budget status.

  Returns a map with:
  - `:daily_budget` - Configured daily budget in USD
  - `:spent_today` - Total spent today
  - `:remaining` - Budget remaining
  - `:percent_remaining` - Percentage of budget remaining (0.0 - 1.0)
  - `:backends` - Per-backend breakdown
  """
  @spec get_status() :: {:ok, status()}
  def get_status do
    if started?() do
      GenServer.call(__MODULE__, :get_status)
    else
      {:ok, default_status()}
    end
  end

  @doc """
  Get remaining budget in USD.
  """
  @spec budget_remaining() :: float()
  def budget_remaining do
    if started?() do
      GenServer.call(__MODULE__, :budget_remaining)
    else
      daily_budget()
    end
  end

  @doc """
  Returns true when budget is low enough to prefer free backends.

  Default threshold is 50% of daily budget remaining.
  """
  @spec should_prefer_free?() :: boolean()
  def should_prefer_free? do
    if started?() do
      GenServer.call(__MODULE__, :should_prefer_free?)
    else
      false
    end
  end

  @doc """
  Returns true when spent >= daily budget.
  """
  @spec over_budget?() :: boolean()
  def over_budget? do
    if started?() do
      GenServer.call(__MODULE__, :over_budget?)
    else
      false
    end
  end

  @doc """
  Get total spend for a specific backend today.
  """
  @spec backend_spend(atom()) :: float()
  def backend_spend(backend) when is_atom(backend) do
    if started?() do
      GenServer.call(__MODULE__, {:backend_spend, backend})
    else
      0.0
    end
  end

  @doc """
  Get today's statistics.

  Returns:
  - `:requests` - Total request count
  - `:total_tokens` - Total tokens used
  - `:total_cost` - Total cost in USD
  - `:backends` - Per-backend breakdown
  """
  @spec today_stats() :: map()
  def today_stats do
    if started?() do
      GenServer.call(__MODULE__, :today_stats)
    else
      %{requests: 0, total_tokens: 0, total_cost: 0.0, backends: %{}}
    end
  end

  @doc """
  Manually reset budget tracking (clears all spend data).
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
  Check if a backend is considered "free" (no API cost).
  """
  @spec free_backend?(atom()) :: boolean()
  def free_backend?(backend) when is_atom(backend) do
    backend in @free_backends
  end

  @doc """
  Check if the BudgetTracker is running.
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

    # Initialize today's date
    today = Date.utc_today()
    :ets.insert(@table, {:current_date, today})
    :ets.insert(@table, {:total_spent, 0.0})
    :ets.insert(@table, {:total_requests, 0})
    :ets.insert(@table, {:total_tokens, 0})

    # Schedule midnight reset
    schedule_daily_reset()

    # Load persisted state if enabled
    maybe_load_persistence()

    Logger.info("BudgetTracker started",
      daily_budget: daily_budget(),
      prefer_free_threshold: prefer_free_threshold()
    )

    {:ok, %{last_warning_threshold: nil}}
  end

  @impl true
  def handle_cast({:record_usage, backend, metadata}, state) do
    # Check if we've crossed into a new day
    check_date_rollover()

    # Calculate cost
    model = Map.get(metadata, :model, "unknown")
    input_tokens = Map.get(metadata, :input_tokens, 0)
    output_tokens = Map.get(metadata, :output_tokens, 0)
    cost = calculate_cost(backend, model, input_tokens, output_tokens)

    # Update totals
    [{:total_spent, current_spent}] = :ets.lookup(@table, :total_spent)
    [{:total_requests, current_requests}] = :ets.lookup(@table, :total_requests)
    [{:total_tokens, current_tokens}] = :ets.lookup(@table, :total_tokens)

    new_spent = current_spent + cost
    new_tokens = current_tokens + input_tokens + output_tokens

    :ets.insert(@table, {:total_spent, new_spent})
    :ets.insert(@table, {:total_requests, current_requests + 1})
    :ets.insert(@table, {:total_tokens, new_tokens})

    # Update per-backend stats
    update_backend_stats(backend, input_tokens, output_tokens, cost)

    # Maybe persist
    maybe_save_persistence()

    # Check budget thresholds and emit warnings
    new_state = check_budget_warnings(new_spent, state)

    Logger.debug("Recorded usage",
      backend: backend,
      model: model,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      cost: cost,
      total_spent: new_spent
    )

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:reset, state) do
    do_reset()
    Logger.info("BudgetTracker reset")
    {:noreply, %{state | last_warning_threshold: nil}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    check_date_rollover()

    [{:total_spent, spent}] = :ets.lookup(@table, :total_spent)
    budget = daily_budget()
    remaining = max(0.0, budget - spent)
    percent = if budget > 0, do: remaining / budget, else: 1.0

    backends = collect_backend_stats()

    status = %{
      daily_budget: budget,
      spent_today: Float.round(spent, 4),
      remaining: Float.round(remaining, 4),
      percent_remaining: Float.round(percent, 4),
      backends: backends
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_call(:budget_remaining, _from, state) do
    check_date_rollover()
    [{:total_spent, spent}] = :ets.lookup(@table, :total_spent)
    remaining = max(0.0, daily_budget() - spent)
    {:reply, Float.round(remaining, 4), state}
  end

  @impl true
  def handle_call(:should_prefer_free?, _from, state) do
    check_date_rollover()
    [{:total_spent, spent}] = :ets.lookup(@table, :total_spent)
    budget = daily_budget()
    remaining = max(0.0, budget - spent)
    percent_remaining = if budget > 0, do: remaining / budget, else: 1.0
    {:reply, percent_remaining <= prefer_free_threshold(), state}
  end

  @impl true
  def handle_call(:over_budget?, _from, state) do
    check_date_rollover()
    [{:total_spent, spent}] = :ets.lookup(@table, :total_spent)
    {:reply, spent >= daily_budget(), state}
  end

  @impl true
  def handle_call({:backend_spend, backend}, _from, state) do
    check_date_rollover()

    spend =
      case :ets.lookup(@table, {:backend, backend}) do
        [{_, stats}] -> stats.cost
        [] -> 0.0
      end

    {:reply, Float.round(spend, 4), state}
  end

  @impl true
  def handle_call(:today_stats, _from, state) do
    check_date_rollover()

    [{:total_spent, total_cost}] = :ets.lookup(@table, :total_spent)
    [{:total_requests, total_requests}] = :ets.lookup(@table, :total_requests)
    [{:total_tokens, total_tokens}] = :ets.lookup(@table, :total_tokens)

    stats = %{
      requests: total_requests,
      total_tokens: total_tokens,
      total_cost: Float.round(total_cost, 4),
      backends: collect_backend_stats()
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:daily_reset, state) do
    Logger.info("Daily budget reset triggered")
    do_reset()
    schedule_daily_reset()
    {:noreply, %{state | last_warning_threshold: nil}}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp update_backend_stats(backend, input_tokens, output_tokens, cost) do
    key = {:backend, backend}
    tokens = input_tokens + output_tokens

    case :ets.lookup(@table, key) do
      [{^key, stats}] ->
        new_stats = %{
          stats
          | requests: stats.requests + 1,
            tokens: stats.tokens + tokens,
            cost: stats.cost + cost
        }

        :ets.insert(@table, {key, new_stats})

      [] ->
        :ets.insert(@table, {key, %{requests: 1, tokens: tokens, cost: cost}})
    end
  end

  defp collect_backend_stats do
    :ets.select(@table, [
      {{{:backend, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.into(%{}, fn {backend, stats} ->
      {backend,
       %{
         requests: stats.requests,
         tokens: stats.tokens,
         cost: Float.round(stats.cost, 4)
       }}
    end)
  end

  defp calculate_cost(backend, model, input_tokens, output_tokens) do
    costs = get_cost_rates(backend, model)

    input_cost = input_tokens / 1_000_000 * costs.input
    output_cost = output_tokens / 1_000_000 * costs.output

    input_cost + output_cost
  end

  defp get_cost_rates(backend, model) do
    # Check config overrides first
    overrides = Application.get_env(:arbor_ai, :cost_overrides, %{})

    # Normalize model to tier atom
    tier = model_to_tier(backend, model)

    # Try specific match, then :any, then default
    cond do
      rates = Map.get(overrides, {backend, tier}) -> rates
      rates = Map.get(overrides, {backend, :any}) -> rates
      rates = Map.get(@default_costs, {backend, tier}) -> rates
      rates = Map.get(@default_costs, {backend, :any}) -> rates
      true -> %{input: 0.0, output: 0.0}
    end
  end

  defp model_to_tier(backend, model) when is_binary(model) do
    model_lower = String.downcase(model)

    cond do
      # CLI backends
      String.contains?(model_lower, "-cli") -> :cli
      # Anthropic models
      backend == :anthropic and String.contains?(model_lower, "opus") -> :opus
      backend == :anthropic and String.contains?(model_lower, "sonnet") -> :sonnet
      backend == :anthropic and String.contains?(model_lower, "haiku") -> :haiku
      # OpenAI models
      backend == :openai and String.contains?(model_lower, "gpt-5") -> :gpt5
      backend == :openai and String.contains?(model_lower, "gpt-4") -> :gpt4
      # Gemini models
      backend == :gemini and String.contains?(model_lower, "pro") -> :pro
      backend == :gemini and String.contains?(model_lower, "flash") -> :flash
      # Default to :any for unknown models
      true -> :any
    end
  end

  defp model_to_tier(_backend, tier) when is_atom(tier), do: tier

  defp check_date_rollover do
    today = Date.utc_today()

    case :ets.lookup(@table, :current_date) do
      [{:current_date, ^today}] ->
        :ok

      [{:current_date, _old_date}] ->
        Logger.info("Date rollover detected, resetting budget")
        do_reset()
        :ets.insert(@table, {:current_date, today})
    end
  end

  defp do_reset do
    # Clear all backend-specific stats
    :ets.select_delete(@table, [
      {{{:backend, :_}, :_}, [], [true]}
    ])

    # Reset totals
    :ets.insert(@table, {:total_spent, 0.0})
    :ets.insert(@table, {:total_requests, 0})
    :ets.insert(@table, {:total_tokens, 0})
    :ets.insert(@table, {:current_date, Date.utc_today()})

    maybe_save_persistence()
  end

  defp schedule_daily_reset do
    # Calculate time until next midnight UTC
    now = DateTime.utc_now()
    tomorrow = Date.add(Date.utc_today(), 1)

    midnight =
      DateTime.new!(tomorrow, ~T[00:00:00], "Etc/UTC")
      |> DateTime.to_unix(:millisecond)

    now_ms = DateTime.to_unix(now, :millisecond)
    delay = midnight - now_ms

    Process.send_after(self(), :daily_reset, delay)
    Logger.debug("Scheduled daily reset in #{div(delay, 3600_000)} hours")
  end

  defp check_budget_warnings(spent, state) do
    budget = daily_budget()
    remaining = max(0.0, budget - spent)
    percent = if budget > 0, do: remaining / budget, else: 1.0

    threshold =
      cond do
        percent <= @threshold_exhausted -> :exhausted
        percent <= @threshold_critical -> :critical
        percent <= @threshold_low -> :low
        true -> nil
      end

    # Only emit if crossing into a new threshold level
    if threshold != nil and threshold != state.last_warning_threshold do
      emit_budget_warning(budget, spent, remaining, threshold)
      %{state | last_warning_threshold: threshold}
    else
      state
    end
  end

  defp emit_budget_warning(budget, spent, remaining, threshold) do
    Logger.warning("Budget warning",
      threshold: threshold,
      daily_budget: budget,
      spent_today: spent,
      remaining: remaining
    )

    if signal_verbosity() != :quiet or threshold in [:critical, :exhausted] do
      Signals.emit(:ai, :budget_warning, %{
        daily_budget: budget,
        spent_today: Float.round(spent, 4),
        remaining: Float.round(remaining, 4),
        threshold: threshold
      })
    end
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
                # Only restore if same date
                if Map.get(data, "date") == Date.to_iso8601(Date.utc_today()) do
                  :ets.insert(@table, {:total_spent, Map.get(data, "spent", 0.0)})
                  :ets.insert(@table, {:total_requests, Map.get(data, "requests", 0)})
                  :ets.insert(@table, {:total_tokens, Map.get(data, "tokens", 0)})
                  Logger.info("Loaded budget state from persistence")
                end

              {:error, _} ->
                Logger.warning("Failed to parse budget persistence file")
            end

          {:error, reason} ->
            Logger.warning("Failed to read budget persistence file", reason: reason)
        end
      end
    end
  end

  defp maybe_save_persistence do
    if persistence_enabled?() do
      [{:total_spent, spent}] = :ets.lookup(@table, :total_spent)
      [{:total_requests, requests}] = :ets.lookup(@table, :total_requests)
      [{:total_tokens, tokens}] = :ets.lookup(@table, :total_tokens)

      data = %{
        date: Date.to_iso8601(Date.utc_today()),
        spent: spent,
        requests: requests,
        tokens: tokens
      }

      path = persistence_path()
      dir = Path.dirname(path)

      unless File.exists?(dir) do
        File.mkdir_p!(dir)
      end

      case Jason.encode(data) do
        {:ok, json} ->
          File.write(path, json)

        {:error, reason} ->
          Logger.warning("Failed to encode budget state", reason: reason)
      end
    end
  end

  defp default_status do
    %{
      daily_budget: daily_budget(),
      spent_today: 0.0,
      remaining: daily_budget(),
      percent_remaining: 1.0,
      backends: %{}
    }
  end

  # Configuration helpers

  defp daily_budget do
    Application.get_env(:arbor_ai, :daily_api_budget_usd, 10.0)
  end

  defp prefer_free_threshold do
    Application.get_env(:arbor_ai, :budget_prefer_free_threshold, 0.5)
  end

  defp persistence_enabled? do
    Application.get_env(:arbor_ai, :budget_persistence, false)
  end

  defp persistence_path do
    Application.get_env(:arbor_ai, :budget_persistence_path, "~/.arbor/budget-tracker.json")
    |> Path.expand()
  end

  defp signal_verbosity do
    Application.get_env(:arbor_ai, :signal_verbosity, :normal)
  end
end
