defmodule Arbor.AI.QuotaTracker do
  @moduledoc """
  Tracks LLM backend quota status and provides fallback strategies.

  When a backend hits a quota limit, it's marked as unavailable for a cooldown
  period. This allows other code to check availability before making requests
  and automatically fall back to alternative backends.

  ## Usage

      # Check if a backend is available
      if QuotaTracker.available?(:gemini) do
        generate_with_gemini(prompt, opts)
      else
        # Use fallback
        generate_with_fallback(prompt, opts)
      end

      # Mark a backend as quota-limited
      QuotaTracker.mark_quota_exhausted(:gemini, hours: 18)

      # Get status of all backends
      QuotaTracker.status()

  ## Automatic Parsing

  The `check_and_mark/2` function can parse error output to automatically
  detect and track quota exhaustion.
  """

  use GenServer
  require Logger

  @default_cooldown_hours 6

  # Patterns that indicate quota exhaustion
  @quota_patterns [
    ~r/exhausted your capacity/i,
    ~r/quota.*exceeded/i,
    ~r/rate limit/i,
    ~r/too many requests/i,
    ~r/resource exhausted/i
  ]

  defstruct backends: %{}

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a backend is available (not in quota cooldown).
  """
  @spec available?(atom()) :: boolean()
  def available?(backend) do
    ensure_started()
    GenServer.call(__MODULE__, {:available?, backend})
  end

  @doc """
  Mark a backend as quota-exhausted with optional cooldown duration.

  Options:
  - `:hours` - Cooldown duration in hours (default: #{@default_cooldown_hours})
  - `:until` - Specific DateTime when quota resets
  - `:message` - Error message for logging
  """
  @spec mark_quota_exhausted(atom(), keyword()) :: :ok
  def mark_quota_exhausted(backend, opts \\ []) do
    ensure_started()
    GenServer.cast(__MODULE__, {:mark_exhausted, backend, opts})
  end

  @doc """
  Check error output for quota patterns and mark the backend if found.

  Returns `true` if quota exhaustion was detected, `false` otherwise.
  """
  @spec check_and_mark(atom(), String.t()) :: boolean()
  def check_and_mark(backend, error_output) when is_binary(error_output) do
    ensure_started()

    if quota_error?(error_output) do
      # Try to extract reset time from the error message
      cooldown = extract_cooldown(error_output)
      mark_quota_exhausted(backend, cooldown)
      true
    else
      false
    end
  end

  @doc """
  Clear quota status for a backend (e.g., after manual reset or testing).
  """
  @spec clear(atom()) :: :ok
  def clear(backend) do
    ensure_started()
    GenServer.cast(__MODULE__, {:clear, backend})
  end

  @doc """
  Get status of all tracked backends.
  """
  @spec status() :: map()
  def status do
    ensure_started()
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Get the best available backend from a list, considering quota status.

  Returns `nil` if none are available.
  """
  @spec best_available([atom()]) :: atom() | nil
  def best_available(backends) when is_list(backends) do
    ensure_started()
    Enum.find(backends, &available?/1)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Schedule periodic cleanup of expired cooldowns
    schedule_cleanup()

    Logger.info("QuotaTracker started")
    {:ok, %__MODULE__{backends: %{}}}
  end

  @impl true
  def handle_call({:available?, backend}, _from, state) do
    available =
      case Map.get(state.backends, backend) do
        nil ->
          true

        %{available_at: available_at} ->
          DateTime.compare(DateTime.utc_now(), available_at) != :lt
      end

    {:reply, available, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    now = DateTime.utc_now()

    status =
      state.backends
      |> Enum.map(fn {backend, info} ->
        remaining =
          case DateTime.diff(info.available_at, now, :minute) do
            mins when mins > 0 -> "#{mins} minutes"
            _ -> "available now"
          end

        {backend,
         %{
           available: DateTime.compare(now, info.available_at) != :lt,
           available_at: info.available_at,
           remaining: remaining,
           reason: info.reason
         }}
      end)
      |> Map.new()

    {:reply, status, state}
  end

  @impl true
  def handle_cast({:mark_exhausted, backend, opts}, state) do
    available_at = calculate_available_at(opts)
    reason = Keyword.get(opts, :message, "quota exhausted")

    Logger.warning("Backend quota exhausted",
      backend: backend,
      available_at: available_at,
      reason: reason
    )

    info = %{
      available_at: available_at,
      marked_at: DateTime.utc_now(),
      reason: reason
    }

    new_backends = Map.put(state.backends, backend, info)
    {:noreply, %{state | backends: new_backends}}
  end

  @impl true
  def handle_cast({:clear, backend}, state) do
    Logger.info("Clearing quota status", backend: backend)
    new_backends = Map.delete(state.backends, backend)
    {:noreply, %{state | backends: new_backends}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = DateTime.utc_now()

    # Remove expired entries
    new_backends =
      state.backends
      |> Enum.reject(fn {_backend, info} ->
        DateTime.compare(now, info.available_at) != :lt
      end)
      |> Map.new()

    schedule_cleanup()
    {:noreply, %{state | backends: new_backends}}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        {:ok, _} = start_link()
        :ok

      _pid ->
        :ok
    end
  end

  defp schedule_cleanup do
    # Cleanup every 5 minutes
    Process.send_after(self(), :cleanup, :timer.minutes(5))
  end

  defp calculate_available_at(opts) do
    cond do
      # Explicit DateTime provided
      until = Keyword.get(opts, :until) ->
        until

      # Hours provided
      hours = Keyword.get(opts, :hours) ->
        DateTime.add(DateTime.utc_now(), hours * 3600, :second)

      # Default cooldown
      true ->
        DateTime.add(DateTime.utc_now(), @default_cooldown_hours * 3600, :second)
    end
  end

  defp quota_error?(output) do
    Enum.any?(@quota_patterns, &Regex.match?(&1, output))
  end

  defp extract_cooldown(output) do
    # Try to extract "reset after Xh Ym Zs" patterns
    cond do
      # Pattern: "reset after 17h35m45s"
      match = Regex.run(~r/reset after (\d+)h(\d+)m/i, output) ->
        [_, hours, mins] = match
        total_hours = String.to_integer(hours) + String.to_integer(mins) / 60
        [hours: ceil(total_hours)]

      # Pattern: "reset in X hours"
      match = Regex.run(~r/reset in (\d+) hours?/i, output) ->
        [_, hours] = match
        [hours: String.to_integer(hours)]

      # Pattern: "try again in X minutes"
      match = Regex.run(~r/try again in (\d+) minutes?/i, output) ->
        [_, mins] = match
        hours = ceil(String.to_integer(mins) / 60)
        [hours: max(1, hours)]

      # Default cooldown
      true ->
        []
    end
  end
end
