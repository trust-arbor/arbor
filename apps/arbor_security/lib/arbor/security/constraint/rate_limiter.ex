defmodule Arbor.Security.Constraint.RateLimiter do
  @moduledoc """
  Token bucket rate limiter for capability constraint enforcement.

  Tracks per-`{principal_id, resource_uri}` token buckets. Each bucket holds
  up to `max_tokens` tokens and refills at a steady rate over the configured
  refill period.

  Uses `System.monotonic_time(:millisecond)` internally to avoid clock-jump
  sensitivity.
  """

  use GenServer

  alias Arbor.Security.Config

  @type bucket_key :: {String.t(), String.t()}
  @type bucket :: %{
          tokens: float(),
          max_tokens: pos_integer(),
          last_refill: integer(),
          last_activity: integer()
        }

  # ===========================================================================
  # Client API
  # ===========================================================================

  @doc """
  Start the rate limiter.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Consume one token from the bucket for `{principal_id, resource_uri}`.

  If the bucket doesn't exist, it is lazily created with `max_tokens` capacity.
  Returns `:ok` if a token was available, `{:error, :rate_limited}` otherwise.
  """
  @spec consume(String.t(), String.t(), pos_integer()) :: :ok | {:error, :rate_limited}
  def consume(principal_id, resource_uri, max_tokens) do
    GenServer.call(__MODULE__, {:consume, {principal_id, resource_uri}, max_tokens})
  end

  @doc """
  Check remaining tokens without consuming.
  """
  @spec remaining(String.t(), String.t(), pos_integer()) :: non_neg_integer()
  def remaining(principal_id, resource_uri, max_tokens) do
    GenServer.call(__MODULE__, {:remaining, {principal_id, resource_uri}, max_tokens})
  end

  @doc """
  Reset a specific bucket (for testing/admin).
  """
  @spec reset(String.t(), String.t()) :: :ok
  def reset(principal_id, resource_uri) do
    GenServer.call(__MODULE__, {:reset, {principal_id, resource_uri}})
  end

  @doc """
  Return rate limiter statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ===========================================================================
  # GenServer callbacks
  # ===========================================================================

  @impl true
  def init(_opts) do
    schedule_cleanup()
    {:ok, %{buckets: %{}}}
  end

  @impl true
  def handle_call({:consume, key, max_tokens}, _from, state) do
    now = System.monotonic_time(:millisecond)
    {bucket, state} = get_or_create_bucket(state, key, max_tokens, now)
    bucket = refill(bucket, now)

    if bucket.tokens >= 1.0 do
      bucket = %{bucket | tokens: bucket.tokens - 1.0, last_activity: now}
      {:reply, :ok, put_bucket(state, key, bucket)}
    else
      bucket = %{bucket | last_activity: now}
      {:reply, {:error, :rate_limited}, put_bucket(state, key, bucket)}
    end
  end

  def handle_call({:remaining, key, max_tokens}, _from, state) do
    now = System.monotonic_time(:millisecond)
    {bucket, state} = get_or_create_bucket(state, key, max_tokens, now)
    bucket = refill(bucket, now)
    # Update last_refill but NOT last_activity (read-only check)
    state = put_bucket(state, key, bucket)
    {:reply, trunc(bucket.tokens), state}
  end

  def handle_call({:reset, key}, _from, state) do
    {:reply, :ok, %{state | buckets: Map.delete(state.buckets, key)}}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      bucket_count: map_size(state.buckets),
      buckets:
        Map.new(state.buckets, fn {key, bucket} ->
          {key, %{tokens: trunc(bucket.tokens), max_tokens: bucket.max_tokens}}
        end)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    ttl_ms = Config.rate_limit_bucket_ttl_seconds() * 1_000

    buckets =
      Map.filter(state.buckets, fn {_key, bucket} ->
        now - bucket.last_activity < ttl_ms
      end)

    schedule_cleanup()
    {:noreply, %{state | buckets: buckets}}
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp get_or_create_bucket(state, key, max_tokens, now) do
    case Map.fetch(state.buckets, key) do
      {:ok, bucket} ->
        {bucket, state}

      :error ->
        bucket = %{
          tokens: max_tokens * 1.0,
          max_tokens: max_tokens,
          last_refill: now,
          last_activity: now
        }

        {bucket, put_bucket(state, key, bucket)}
    end
  end

  defp refill(bucket, now) do
    elapsed_ms = now - bucket.last_refill

    if elapsed_ms <= 0 do
      bucket
    else
      refill_period_ms = Config.rate_limit_refill_period_seconds() * 1_000
      refill_rate = bucket.max_tokens / refill_period_ms
      added = elapsed_ms * refill_rate
      new_tokens = min(bucket.tokens + added, bucket.max_tokens * 1.0)
      %{bucket | tokens: new_tokens, last_refill: now}
    end
  end

  defp put_bucket(state, key, bucket) do
    %{state | buckets: Map.put(state.buckets, key, bucket)}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, Config.rate_limit_cleanup_interval_ms())
  end
end
