defmodule Arbor.Agent.SummaryCache do
  @moduledoc """
  Cache for context summaries.

  Avoids re-summarizing content that hasn't changed.
  Uses content hash (SHA-256) as cache key with configurable TTL.

  Entries are stored in an ETS table with expiration timestamps.
  A periodic cleanup task removes expired entries.
  """

  use GenServer

  require Logger

  @table_name :agent_summary_cache
  @cleanup_interval_ms :timer.minutes(5)

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Look up a cached summary by content hash.

  Returns `{:ok, summary}` if found and not expired,
  `{:error, :not_found}` or `{:error, :expired}` otherwise.
  """
  @spec get(String.t()) :: {:ok, String.t()} | {:error, :not_found | :expired}
  def get(content_hash) do
    case :ets.lookup(@table_name, content_hash) do
      [{^content_hash, summary, expires_at}] ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          {:ok, summary}
        else
          :ets.delete(@table_name, content_hash)
          {:error, :expired}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Store a summary in the cache with TTL.
  """
  @spec put(String.t(), String.t()) :: :ok
  def put(content_hash, summary) do
    ttl_minutes = config(:summary_cache_ttl_minutes, 60)
    expires_at = DateTime.add(DateTime.utc_now(), ttl_minutes, :minute)
    :ets.insert(@table_name, {content_hash, summary, expires_at})
    :ok
  end

  @doc """
  Compute a SHA-256 hash of message content for cache keying.
  """
  @spec hash_content([map()] | term()) :: String.t()
  def hash_content(messages) do
    messages
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Clear all cached summaries.
  """
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @doc """
  Return the number of cached entries.
  """
  @spec size() :: non_neg_integer()
  def size do
    :ets.info(@table_name, :size)
  end

  # ============================================================================
  # GenServer callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    expired_count = cleanup_expired()

    if expired_count > 0 do
      Logger.debug("SummaryCache: cleaned up #{expired_count} expired entries")
    end

    schedule_cleanup()
    {:noreply, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp cleanup_expired do
    now = DateTime.utc_now()

    # Collect expired keys then delete (avoid modifying table during traversal)
    expired_keys =
      :ets.foldl(
        fn {key, _summary, expires_at}, acc ->
          if DateTime.compare(expires_at, now) == :lt do
            [key | acc]
          else
            acc
          end
        end,
        [],
        @table_name
      )

    Enum.each(expired_keys, &:ets.delete(@table_name, &1))
    length(expired_keys)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp config(key, default) do
    Application.get_env(:arbor_agent, key, default)
  end
end
